/**
 * Containment for the 64-slot SessionStore (installed by fm-unified-exec-contain.sh).
 *
 * Exited records are retained lazily until someone lists or polls them, so a
 * long-lived Pi accumulates them until an insert has to evict.
 * This module reaps exited records on a timer and defines which live sessions
 * the store must never evict.
 * It has no imports so it can be exercised without the package's runtime.
 */
import { appendFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const DEFAULT_KEEP_EXITED = 8;
export const DEFAULT_REAP_INTERVAL_MS = 60_000;

export interface ReapableSession {
	readonly id: number;
	readonly hasExited: boolean;
	readonly exitCode: number | null;
	readonly signal?: string | null;
	readonly lastUsed: number;
	readonly displayCommand: string;
}

/** The firstmate watch timer: the process whose exit wakes the supervisor. */
export function isWatchTimerCommand(command: string): boolean {
	// The script must be what runs (optionally via a shell), not merely mentioned in a longer command.
	return /^\s*(?:(?:\S*\/)?(?:bash|sh|zsh)\s+)?(?:\S*\/)?fm-watch[\w-]*\.sh(?:\s|$)/.test(command);
}

/** A session the store must never evict: the live watch timer, or one with an armed on_exit wake (live or exited). */
export function isPinnedSession(s: ReapableSession, armed: (id: number) => boolean): boolean {
	// An exited session whose wake is still armed keeps its slot until the wake resolves.
	if (armed(s.id)) return true;
	if (s.hasExited) return false;
	return isWatchTimerCommand(s.displayCommand);
}

/**
 * Exited records safe to drop: the exit is known (exit code or signal), no wake
 * is still armed for it, and it is not among the newest `keepNewest` exited records.
 * Returned oldest first.
 * A live session is never returned.
 */
export function selectReapable<T extends ReapableSession>(
	sessions: readonly T[],
	armed: (id: number) => boolean,
	keepNewest: number,
): T[] {
	const exited = sessions.filter((s) => s.hasExited).sort((a, b) => b.lastUsed - a.lastUsed);
	return exited
		.slice(Math.max(0, keepNewest))
		.filter((s) => (s.exitCode !== null || (s.signal ?? null) !== null) && !armed(s.id))
		.reverse();
}

export function reapLogPath(env: NodeJS.ProcessEnv = process.env): string {
	return env.PI_UNIFIED_EXEC_REAP_LOG?.trim() || join(homedir(), ".pi", "agent", "unified-exec-reap.log");
}

function positiveInt(raw: string | undefined, fallback: number, min: number): number {
	const n = Number.parseInt(raw ?? "", 10);
	return Number.isFinite(n) && n >= min ? n : fallback;
}

export interface ReaperOptions {
	list: () => ReapableSession[];
	armed: (id: number) => boolean;
	remove: (id: number) => void;
	log?: (line: string) => void;
	env?: NodeJS.ProcessEnv;
}

export interface Reaper {
	/** One reap pass; returns the ids it removed. */
	reapOnce(): number[];
	start(): void;
	stop(): void;
}

export function createReaper(opts: ReaperOptions): Reaper {
	const env = opts.env ?? process.env;
	const keepNewest = positiveInt(env.PI_UNIFIED_EXEC_REAP_KEEP, DEFAULT_KEEP_EXITED, 0);
	const intervalMs = positiveInt(env.PI_UNIFIED_EXEC_REAP_INTERVAL_MS, DEFAULT_REAP_INTERVAL_MS, 1000);
	const log =
		opts.log ??
		((line: string) => {
			try {
				appendFileSync(reapLogPath(env), `${line}\n`);
			} catch {
				// A log failure must never block the reap or the session.
			}
		});
	let timer: ReturnType<typeof setInterval> | undefined;

	function reapOnce(): number[] {
		const all = opts.list();
		const victims = selectReapable(all, opts.armed, keepNewest);
		const reaped: number[] = [];
		for (const s of victims) {
			// Re-check at removal: the gate is on the record as it is now.
			if (!s.hasExited || opts.armed(s.id)) continue;
			opts.remove(s.id);
			reaped.push(s.id);
			log(
				`${new Date().toISOString()} reaped session=${s.id} exit_code=${s.exitCode ?? "null"} signal=${s.signal ?? "null"} slots_before=${all.length} cmd=${JSON.stringify(s.displayCommand.slice(0, 120))}`,
			);
		}
		return reaped;
	}

	return {
		reapOnce,
		start() {
			if (timer) return;
			timer = setInterval(() => {
				try {
					reapOnce();
				} catch {
					// Containment is best effort; a failed pass retries next tick.
				}
			}, intervalMs);
			timer.unref();
		},
		stop() {
			if (timer) clearInterval(timer);
			timer = undefined;
		},
	};
}
