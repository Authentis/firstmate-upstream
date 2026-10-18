// Excerpt of pi-unified-exec 0.13.1 src/index.ts: only the regions fm-unified-exec-contain.sh anchors on,
// with the symbols they reference stubbed so the patched module can be loaded and driven.
import { SessionStore } from "./session-store.ts";
const MAX_SESSIONS = 64;
const LRU_PROTECTED_COUNT = 8;
class SteerGate {
	constructor(_opts) {}
}
const steerInterruptEnabled = () => false;
function removeSession(ctx, id) {
	return ctx.store.remove(id);
}
function updateRunningSessionsUi(_ctx) {}
export let lastCtx;
export default function (pi) {
	const coordinator = { isArmed: () => false };
	const ctx = {
		coordinator,
		// Eviction UI (status clear + warning) is handled at the insert site;
		// no onEvict callback needed.
		store: new SessionStore({ maxSessions: MAX_SESSIONS, lruProtectedCount: LRU_PROTECTED_COUNT }),
		ui: undefined,
		steer: new SteerGate({ enabled: steerInterruptEnabled() }),
	};
	lastCtx = ctx;
	pi.on("session_start", async (_event, eventCtx) => {
		ctx.ui = eventCtx.ui;
		ctx.shuttingDown = false; // reload/new/resume re-arms the extension
	});
	pi.on("session_shutdown", async () => {
		ctx.shuttingDown = true;
	});
}
