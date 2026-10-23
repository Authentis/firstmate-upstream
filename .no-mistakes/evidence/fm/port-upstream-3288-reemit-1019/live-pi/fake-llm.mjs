// Disposable OpenAI-compatible chat-completions endpoint for the lab Pi.
// Logs every request (kind, roles, whether it carries the live digest) to
// requests.jsonl so the driver can count model calls per scenario.
import http from "node:http";
import { appendFileSync } from "node:fs";

const port = Number(process.argv[2]);
const log = process.argv[3];
let seq = 0;

function textOf(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map((p) => p.text ?? "").join("");
  return "";
}

function sse(res, chunks) {
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  for (const c of chunks) res.write(`data: ${JSON.stringify(c)}\n\n`);
  res.write("data: [DONE]\n\n");
  res.end();
}

function chunk(delta, finish = null, usage) {
  const c = { id: `c${seq}`, object: "chat.completion.chunk", created: 0, model: "lab", choices: [{ index: 0, delta, finish_reason: finish }] };
  if (usage) c.usage = usage;
  return c;
}

http.createServer((req, res) => {
  let body = "";
  req.on("data", (d) => (body += d));
  req.on("end", () => {
    seq += 1;
    const json = JSON.parse(body || "{}");
    const messages = json.messages ?? [];
    const system = messages.filter((m) => m.role === "system" || m.role === "developer").map((m) => textOf(m.content)).join("\n");
    const isSummary = system.includes("context summarization assistant");
    const users = messages.filter((m) => m.role === "user").map((m) => textOf(m.content));
    const last = messages[messages.length - 1];
    const allText = messages.map((m) => textOf(m.content)).join("\n");
    const firstUser = users.find((u) => /SCENARIO_[A-Z_]+/.test(u)) ?? "";
    const scenario = (allText.match(/SCENARIO_[A-Z_]+/g) ?? []).at(-1) ?? "none";
    const digestCopies = (allText.match(/LIVE_DIGEST_HEAD/g) ?? []).length;
    const entry = {
      seq, kind: isSummary ? "summary" : "main", scenario,
      lastRole: last?.role, messageCount: messages.length,
      digestCopies, truncNotice: allText.includes("CONTEXT RE-EMIT TRUNCATED"),
      lastIsDigest: textOf(last?.content).includes("LIVE_DIGEST_HEAD"),
      bodyChars: body.length,
    };
    appendFileSync(log, JSON.stringify(entry) + "\n");
    void firstUser;
    if (isSummary) {
      return sse(res, [chunk({ role: "assistant", content: "## Goal\nLab summary.\n" }), chunk({}, "stop", { prompt_tokens: 500, completion_tokens: 20, total_tokens: 520 })]);
    }
    const big = { prompt_tokens: 99000, completion_tokens: 10, total_tokens: 99010 };
    const small = { prompt_tokens: 800, completion_tokens: 10, total_tokens: 810 };
    // AUTO_MID: first main call issues a tool call with a near-full context so
    // Pi compacts before the next model call inside the same run.
    if (scenario === "SCENARIO_AUTO_MID" && last?.role === "user" && !entry.lastIsDigest && !allText.includes("MID_TOOL_DONE")) {
      return sse(res, [
        chunk({ role: "assistant", tool_calls: [{ index: 0, id: `call_${seq}`, type: "function", function: { name: "bash", arguments: JSON.stringify({ command: "echo MID_TOOL_DONE" }) } }] }),
        chunk({}, "tool_calls", big),
      ]);
    }
    if (scenario === "SCENARIO_AUTO_MID" && last?.role === "tool" && (allText.match(/MID_TOOL_DONE/g) ?? []).length < 4 && !allText.includes("SECOND_TOOL")) {
      return sse(res, [
        chunk({ role: "assistant", tool_calls: [{ index: 0, id: `call_${seq}`, type: "function", function: { name: "bash", arguments: JSON.stringify({ command: "echo SECOND_TOOL" }) } }] }),
        chunk({}, "tool_calls", small),
      ]);
    }
    const usage = scenario === "SCENARIO_AUTO_END" && !entry.lastIsDigest && last?.role === "user" ? big : small;
    const reply = entry.lastIsDigest ? "EXTRA_CALL_AFTER_DIGEST" : `done ${scenario}`;
    return sse(res, [chunk({ role: "assistant", content: reply }), chunk({}, "stop", usage)]);
  });
}).listen(port, "127.0.0.1");
