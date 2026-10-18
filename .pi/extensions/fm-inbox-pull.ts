import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { runCommandAsync } from "./lib/fm-async-exec.ts";

// Thin trigger for the mid-turn inbox pull. bin/fm-inbox-pull.sh owns every
// semantic (scan set, cursor, throttle, kill switch, replay trip, heartbeat);
// this file only decides WHEN to run it and hands a printed notice to the model.
//
// - After each tool result it runs `peek` and, when the owner printed a notice,
//   steers it into the running turn, so a coordinator inside a long turn hears a
//   steer at the next model request instead of at the next idle prompt.
// - It commits the cursor only once the notice is inside a model request. pi 1.3.0
//   holds a steered custom message until its current turn ends and emits no
//   extension message_end for it, so the `context` event that shows the message in
//   the request is the commit point; a process that dies first leaves the owner's
//   pending set to be replayed (verified, data/fm-rel-inboxpull-1018).
// - A 15 s tick refreshes the heartbeat so a coordinator inside one long tool
//   call or sitting idle still shows liveness. Idle-triggered steers (waking an
//   idle coordinator) are out of scope.
// - It never writes to stdout, stderr or the TUI: every error goes to the owner's
//   log file and heartbeat, because a stray line in the composer made the doorbell
//   guard refuse every ring for hours. Five consecutive failures disable it for
//   the session.
// The owner is always run through `bash <path>`, so its file mode cannot matter.

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const owner = `${root}/bin/fm-inbox-pull.sh`;
const pullDir = `${state}/inbox-pull`;
const logFile = `${pullDir}/log`;
const marker = `${state}/.pi-inbox-pull-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

const IDLE_TICK_MS = 15_000;
const OWNER_TIMEOUT_MS = 5_000;
const MAX_CONSECUTIVE_FAILURES = 5;

// The owner alone owns the 30 s throttle (it persists across restarts and knows
// whether a scan really ran). This only debounces a burst of fast tool results so
// each does not start its own bash process.
const LOCAL_DEBOUNCE_MS = 2_000;

function ownerEnv(): NodeJS.ProcessEnv {
  return {
    ...process.env,
    FM_HOME: fmHome,
    FM_STATE_OVERRIDE: state,
    FM_INBOX_PULL_PID: String(process.pid),
  };
}

function markLoaded(): void {
  try {
    if (!existsSync(state)) return;
    writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
  } catch {
    // The marker is evidence for session-start; failing to write it is not worth a crash.
  }
}

function appendLog(text: string): void {
  try {
    mkdirSync(pullDir, { recursive: true });
    appendFileSync(logFile, `${Math.floor(Date.now() / 1000)} extension: ${text.replace(/\s+/g, " ").slice(0, 300)}\n`);
  } catch {
    // Nothing else is allowed to carry the error to the screen.
  }
}

// Bounds a host call that has no deadline of its own, so one stuck promise cannot
// hold the awaited tool_result handler (and the turn behind it) for ever.
async function withTimeout<T>(work: Promise<T> | T, ms: number, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const expired = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms} ms`)), ms);
    timer.unref?.();
  });
  try {
    return await Promise.race([Promise.resolve(work), expired]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

// The plain text of a custom message, matched as text rather than as its JSON
// serialisation so quotes or backslashes in a path cannot hide the token.
function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((part) => (part && typeof part === "object" && "text" in part ? String((part as { text: unknown }).text) : "")).join("\n");
  }
  return "";
}

async function runOwner(args: readonly string[]): Promise<{ ok: boolean; stdout: string; detail: string }> {
  const result = await runCommandAsync("bash", [owner, ...args], { env: ownerEnv(), cwd: root, timeoutMs: OWNER_TIMEOUT_MS });
  if (result.status !== 0) {
    return { ok: false, stdout: "", detail: `owner ${args[0]} exited ${result.status}: ${result.stderr.trim()}` };
  }
  return { ok: true, stdout: result.stdout, detail: "" };
}

export default function (pi: ExtensionAPI) {
  let lastPeekAt = 0;
  let inFlight = false;
  let consecutiveFailures = 0;
  let disabled = false;
  let stopped = false;
  // A notice pi accepted but has not yet put into a model request: the cursor is
  // committed only once a `context` event shows it inside the request.
  let awaiting: { token: string; txn: string; since: number } | null = null;
  // A tool result that arrived while a beat or another pull held the owner: it
  // runs once they finish, so the turn's last tool result is never left unchecked.
  let pullQueued = false;
  // Bumped on every session start and shutdown: a pull that began in an earlier
  // session must not send a message or touch state in the one that replaced it.
  let generation = 0;
  let idleTimer: ReturnType<typeof setInterval> | undefined;

  const recordFailure = (detail: string): void => {
    consecutiveFailures += 1;
    appendLog(detail);
    void runOwner(["beat", "--error", detail]).catch(() => {});
    if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES && !disabled) {
      disabled = true;
      appendLog(`disabled for this session after ${consecutiveFailures} consecutive failures`);
    }
  };

  const pull = async (): Promise<void> => {
    if (disabled || stopped) return;
    if (process.env.FM_INBOX_PULL === "0") return;
    if (inFlight) {
      pullQueued = true;
      return;
    }
    const at = Date.now();
    // A notice still waiting to enter a request must not be steered twice; give
    // up on it after two minutes so the owner replays it.
    if (awaiting) {
      if (at - awaiting.since < 120_000) return;
      awaiting = null;
    }
    // A wall clock that moved backwards must not silence the pull until it catches up.
    if (at < lastPeekAt) lastPeekAt = 0;
    if (at - lastPeekAt < LOCAL_DEBOUNCE_MS) return;
    lastPeekAt = at;
    inFlight = true;
    const mine = generation;
    try {
      const peek = await runOwner(["peek"]);
      if (mine !== generation) return;
      if (!peek.ok) {
        recordFailure(peek.detail);
        return;
      }
      const notice = peek.stdout.trim();
      if (!notice) {
        consecutiveFailures = 0;
        return;
      }
      try {
        await withTimeout(
          pi.sendMessage(
            { customType: "fm-inbox", content: notice, display: true },
            { deliverAs: "steer", triggerTurn: false },
          ),
          OWNER_TIMEOUT_MS,
          "sendMessage",
        );
      } catch (error) {
        if (mine !== generation) return;
        recordFailure(`sendMessage failed: ${error instanceof Error ? error.message : String(error)}`);
        return;
      }
      if (mine !== generation) return;
      // pi 1.3.0 holds a steered custom message until its current turn ends, and a
      // process that dies first loses it, so commit waits for the `context` event.
      const lines = notice.split("\n");
      const token = lines.find((line) => line.startsWith("inbox-pull-notice:"));
      const txn = (lines.find((line) => line.startsWith("inbox-pull-txn:")) ?? "").slice("inbox-pull-txn:".length);
      if (token && txn) {
        awaiting = { token, txn, since: Date.now() };
      } else {
        recordFailure("owner printed a notice without a record line or transaction");
        return;
      }
      consecutiveFailures = 0;
    } catch (error) {
      if (mine !== generation) return;
      recordFailure(`pull failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      inFlight = false;
      if (pullQueued) {
        pullQueued = false;
        void pull();
      }
    }
  };

  const stopIdleTick = (): void => {
    if (idleTimer) clearInterval(idleTimer);
    idleTimer = undefined;
  };

  if (typeof pi.sendMessage !== "function") {
    disabled = true;
    appendLog("pi.sendMessage is unavailable on this pi; the inbox pull is disabled");
  }

  pi.on("session_start", () => {
    generation += 1;
    stopped = false;
    // A new, resumed, or forked session starts from a clean slate: the previous
    // session's failures, open notice, and debounce say nothing about this one.
    disabled = typeof pi.sendMessage !== "function";
    consecutiveFailures = 0;
    awaiting = null;
    lastPeekAt = 0;
    pullQueued = false;
    markLoaded();
    stopIdleTick();
    // Timers belong to the session: created here, cleared in session_shutdown.
    // The tick touches only the owner process, never a pi runtime object, so a
    // replaced session cannot make it throw.
    // A beat holds the same in-flight flag as a pull, so a pull that arrives mid-beat
    // is skipped without spending its throttle window instead of losing the lock.
    const beat = (): void => {
      if (disabled || stopped || inFlight) return;
      inFlight = true;
      void runOwner(["beat"]).then((result) => {
        if (result.ok) consecutiveFailures = 0;
        else recordFailure(result.detail);
      }).catch(() => {}).finally(() => {
        inFlight = false;
        if (pullQueued) {
          pullQueued = false;
          void pull();
        }
      });
    };
    beat();
    idleTimer = setInterval(beat, IDLE_TICK_MS);
    idleTimer.unref?.();
  });

  // Awaited on purpose: the steer must be queued before pi builds its next model
  // request. pull() is throttled and bounded, and never throws.
  pi.on("tool_result", async () => {
    await pull();
  });

  pi.on("context", async (event) => {
    const wanted = awaiting;
    if (!wanted || stopped) return undefined;
    const seen = (event.messages as Array<{ role?: string; customType?: string; content?: unknown }>).some(
      (message) => message.role === "custom"
        && message.customType === "fm-inbox"
        && contentText(message.content).includes(wanted.token),
    );
    if (!seen) return undefined;
    awaiting = null;
    const commit = await runOwner(["commit", "--txn", wanted.txn]);
    if (commit.ok) consecutiveFailures = 0;
    else recordFailure(commit.detail);
    return undefined;
  });

  pi.on("session_shutdown", () => {
    generation += 1;
    stopped = true;
    stopIdleTick();
  });

  markLoaded();
}
