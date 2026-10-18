// Anchored, idempotent edit engine for fm-unified-exec-contain.sh.
// Usage: node patch.mjs <apply|check> <package-dir> <reap.ts>
// Every edit must match its anchor exactly once or nothing is written.
import { copyFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const MARK = "fm-unified-exec-contain";
const [mode, pkg, reapSrc] = process.argv.slice(2);
const storePath = join(pkg, "src", "session-store.ts");
const indexPath = join(pkg, "src", "index.ts");

const EDITS = {
  [storePath]: [
    ['import { ExecSession } from "./session.ts";', 'import type { ExecSession } from "./session.ts";'],
    [
      "\tlruProtectedCount: number;\n",
      `\tlruProtectedCount: number;\n\t/** ${MARK}: live sessions the LRU must never evict. */\n\tisPinned?: (session: ExecSession) => boolean;\n`,
    ],
    [
      "\tprivate readonly onEvict: SessionStoreOptions[\"onEvict\"];\n",
      "\tprivate readonly onEvict: SessionStoreOptions[\"onEvict\"];\n\tprivate readonly isPinned: (session: ExecSession) => boolean;\n",
    ],
    [
      "\t\tthis.onEvict = opts.onEvict;\n",
      "\t\tthis.onEvict = opts.onEvict;\n\t\tthis.isPinned = opts.isPinned ?? (() => false);\n",
    ],
    [
      "const exitedCandidate = byRecencyAsc.find((e) => !protectedIds.has(e.id) && e.hasExited);",
      "const exitedCandidate = byRecencyAsc.find((e) => !protectedIds.has(e.id) && !this.isPinned(e) && e.hasExited);",
    ],
    [
      "byRecencyAsc.find((e) => !protectedIds.has(e.id));",
      "byRecencyAsc.find((e) => !protectedIds.has(e.id) && !this.isPinned(e));",
    ],
  ],
  [indexPath]: [
    [
      'import { SessionStore } from "./session-store.ts";\n',
      `import { SessionStore } from "./session-store.ts";\nimport { createReaper, isPinnedSession } from "./reap.ts"; // ${MARK}\n`,
    ],
    [
      "store: new SessionStore({ maxSessions: MAX_SESSIONS, lruProtectedCount: LRU_PROTECTED_COUNT }),",
      "store: new SessionStore({\n\t\t\tmaxSessions: MAX_SESSIONS,\n\t\t\tlruProtectedCount: LRU_PROTECTED_COUNT,\n\t\t\tisPinned: (s) => isPinnedSession(s, (id) => coordinator.isArmed(id)),\n\t\t}),",
    ],
    [
      "\t\tsteer: new SteerGate({ enabled: steerInterruptEnabled() }),\n\t};\n",
      `\t\tsteer: new SteerGate({ enabled: steerInterruptEnabled() }),\n\t};\n\t// ${MARK}: reap exited records on a timer; live and wake-armed sessions are never touched.\n\tconst reaper = createReaper({\n\t\tlist: () => ctx.store.values(),\n\t\tarmed: (id) => ctx.coordinator.isArmed(id),\n\t\tremove: (id) => {\n\t\t\tremoveSession(ctx, id);\n\t\t\tupdateRunningSessionsUi(ctx);\n\t\t},\n\t});\n`,
    ],
    [
      "\t\tctx.shuttingDown = false; // reload/new/resume re-arms the extension\n",
      "\t\tctx.shuttingDown = false; // reload/new/resume re-arms the extension\n\t\treaper.start();\n",
    ],
    ["\t\tctx.shuttingDown = true;\n", "\t\tctx.shuttingDown = true;\n\t\treaper.stop();\n"],
  ],
};

function count(text, needle) {
  let n = 0;
  for (let i = text.indexOf(needle); i !== -1; i = text.indexOf(needle, i + needle.length)) n++;
  return n;
}

const out = new Map();
let applied = 0;
for (const [file, edits] of Object.entries(EDITS)) {
  if (!existsSync(file)) {
    console.error(`missing: ${file}`);
    process.exit(2);
  }
  let text = readFileSync(file, "utf8");
  for (const [from, to] of edits) {
    if (count(text, to) >= 1) {
      applied++;
      continue;
    }
    if (count(text, from) !== 1) {
      console.error(`anchor not found exactly once in ${file}: ${JSON.stringify(from.slice(0, 80))}`);
      process.exit(2);
    }
    text = text.replace(from, () => to);
  }
  out.set(file, text);
}
const total = Object.values(EDITS).reduce((n, e) => n + e.length, 0);
const reapDest = join(pkg, "src", "reap.ts");
const reapCurrent = existsSync(reapDest) ? readFileSync(reapDest, "utf8") : null;
const reapWanted = readFileSync(reapSrc, "utf8");
if (mode === "check") {
  const ok = applied === total && reapCurrent === reapWanted;
  console.log(ok ? "patched" : applied === 0 && reapCurrent === null ? "unpatched" : "partial");
  process.exit(ok ? 0 : 1);
}
if (applied === total && reapCurrent === reapWanted) {
  console.log("already applied");
  process.exit(0);
}
for (const file of out.keys()) {
  if (!existsSync(`${file}.fm-orig`)) copyFileSync(file, `${file}.fm-orig`);
}
for (const [file, text] of out) writeFileSync(file, text);
writeFileSync(reapDest, reapWanted);
console.log("applied");
