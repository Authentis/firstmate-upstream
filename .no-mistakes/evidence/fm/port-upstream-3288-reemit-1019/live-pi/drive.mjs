// Drive a real `pi --mode rpc` process with the firstmate turnend-guard
// extension loaded, against the lab fake endpoint, through one scenario.
// Usage: node drive.mjs <scenario> <extension-root> <port> <out-dir>
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, existsSync, statSync } from "node:fs";
import { createInterface } from "node:readline";

const [scenario, extRoot, port, outDir] = process.argv.slice(2);
const lab = "/tmp/fm-lab.reemit";
mkdirSync(outDir, { recursive: true });
const reqLog = `${outDir}/requests.jsonl`;
writeFileSync(reqLog, "");

const server = spawn("node", [`${lab}/work/fake-llm.mjs`, port, reqLog], { stdio: "inherit" });
await new Promise((r) => setTimeout(r, 400));

const env = { ...process.env, PI_CODING_AGENT_DIR: `${lab}/piagent`, FM_HOME: lab, PI_OFFLINE: "1" };
for (const k of ["NO_MISTAKES_GATE", "FM_GATE_REFUSE_BYPASS", "FM_ROOT_OVERRIDE", "FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_PROJECTS_OVERRIDE"]) delete env[k];
const models = JSON.parse(readFileSync(`${lab}/piagent/models.json`, "utf8"));
models.providers.lablocal.baseUrl = `http://127.0.0.1:${port}/v1`;
writeFileSync(`${lab}/piagent/models.json`, JSON.stringify(models));

const pi = spawn("pi", [
  "--mode", "rpc", "--no-extensions", "-e", `${extRoot}/.pi/extensions/fm-primary-turnend-guard.ts`,
  "--model", "lablocal/lab-model", "--thinking", "off", "--no-context-files", "--no-skills", "--no-prompt-templates",
  "--no-themes", "--no-mcp", "--offline", "--tools", "bash", "--session-dir", `${outDir}/session`,
], { cwd: `${lab}/work`, env, stdio: ["pipe", "pipe", "pipe"] });
let stderr = "";
pi.stderr.on("data", (d) => (stderr += d));
const events = [];
const waiters = new Map();
let nextId = 1;
createInterface({ input: pi.stdout }).on("line", (line) => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg.type === "response" && waiters.has(msg.id)) { waiters.get(msg.id)(msg); waiters.delete(msg.id); return; }
  events.push(msg.type);
});
function send(cmd) {
  const id = `c${nextId++}`;
  return new Promise((resolve) => { waiters.set(id, resolve); pi.stdin.write(JSON.stringify({ ...cmd, id }) + "\n"); });
}
const pad = " " + "filler words for context size ".repeat(400);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function settle() {
  for (let i = 0; i < 200; i++) {
    await sleep(250);
    const st = await send({ type: "get_state" });
    if (st.data && !st.data.isStreaming && !st.data.isCompacting) break;
  }
  await sleep(4000); // let the extension's async session_compact delivery land
  const st = await send({ type: "get_state" });
  if (st.data?.isStreaming) await settle();
}
const requests = () => readFileSync(reqLog, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
const out = { scenario, extRoot, steps: [] };
const mark = (label) => out.steps.push({ label, requestsSoFar: requests().length });

await sleep(1500);
if (scenario === "manual") {
  await send({ type: "prompt", message: "SCENARIO_MANUAL hello" + pad }); await settle(); mark("after prompt");
  const c1 = await send({ type: "compact" }); await settle(); mark("after manual compact #1");
  out.compact1 = { success: c1.success, error: c1.error };
  await send({ type: "prompt", message: "SCENARIO_MANUAL_NEXT after first compact" + pad }); await settle(); mark("after follow-up prompt #1");
  await send({ type: "compact" }); await settle(); mark("after manual compact #2");
  await send({ type: "prompt", message: "SCENARIO_MANUAL_NEXT after second compact" }); await settle(); mark("after follow-up prompt #2");
  await send({ type: "compact" }); await settle(); mark("after manual compact #3");
  await send({ type: "prompt", message: "SCENARIO_MANUAL_NEXT after third compact" }); await settle(); mark("after follow-up prompt #3");
} else if (scenario === "auto_end") {
  await send({ type: "prompt", message: "SCENARIO_WARMUP first exchange" + pad }); await settle(); mark("after warm-up prompt");
  await send({ type: "prompt", message: "SCENARIO_AUTO_END run until threshold" + pad }); await settle(); mark("after run with end-of-run threshold compaction");
  await send({ type: "prompt", message: "SCENARIO_AUTO_END_NEXT next prompt" }); await settle(); mark("after follow-up prompt");
} else if (scenario === "auto_mid") {
  await send({ type: "prompt", message: "SCENARIO_WARMUP first exchange" + pad }); await settle(); mark("after warm-up prompt");
  await send({ type: "prompt", message: "SCENARIO_AUTO_MID tool loop" + pad }); await settle(); mark("after run with mid-run threshold compaction");
}
const ent = await send({ type: "get_entries" });
const entries = ent.data?.entries ?? [];
out.entries = entries.map((e) => {
  const content = e.content ?? e.message?.content;
  const text = typeof content === "string" ? content : Array.isArray(content) ? content.map((p) => p.text ?? "").join("") : "";
  return {
    type: e.type, role: e.message?.role, customType: e.customType ?? e.message?.customType,
    chars: text.length, compactDigest: text.includes("LIVE_DIGEST_HEAD"),
    truncNotice: text.includes("CONTEXT RE-EMIT TRUNCATED"), hasTail: text.includes("LIVE_DIGEST_TAIL"),
    preview: e.type === "compaction" ? "(compaction)" : text.slice(0, 60),
  };
});
out.requests = requests();
const saved = `${lab}/state/.reemit-latest.txt`;
out.reemitLatest = existsSync(saved) ? { bytes: statSync(saved).size, lines: readFileSync(saved, "utf8").split("\n").length - 1, hasTail: readFileSync(saved, "utf8").includes("LIVE_DIGEST_TAIL") } : null;
out.events = [...new Set(events)];
out.stderrTail = stderr.slice(-800);
writeFileSync(`${outDir}/result.json`, JSON.stringify(out, null, 2));
pi.kill("SIGTERM");
await sleep(500);
server.kill("SIGTERM");
console.log(JSON.stringify({ steps: out.steps, requests: out.requests, reemitLatest: out.reemitLatest,
  digestEntries: out.entries.filter((e) => e.compactDigest), compactions: out.entries.filter((e) => e.type === "compaction").length }, null, 1));
process.exit(0);
