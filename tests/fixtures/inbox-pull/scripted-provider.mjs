// Scripted OpenAI-compatible chat-completions server for the inbox-pull live
// guard. It answers with a fixed number of bash tool calls (each running a
// shell command from the script) and then a final text answer, and it logs one
// line per model request recording what the model could see, so a test asserts
// on the model-side request log rather than on pi's own transcript.
//
// usage: node scripted-provider.mjs <port-file> <request-log> <tool-calls> <command>
// The server binds an ephemeral 127.0.0.1 port and writes it to <port-file>.
// Request log line: ts=<epoch ms> toolMsgs=<n> notices=<comma list of record paths>
// where a record path follows any `inbox-pull-notice:` token found in the body.
import { createServer } from "node:http";
import { appendFileSync, writeFileSync } from "node:fs";

const [portFile, logFile, callsArg, ...commandParts] = process.argv.slice(2);
const calls = Number(callsArg);
const command = commandParts.join(" ");

function sse(res, chunks) {
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  for (const chunk of chunks) res.write(`data: ${JSON.stringify(chunk)}\n\n`);
  res.write("data: [DONE]\n\n");
  res.end();
}

const base = { id: "chatcmpl-scripted", object: "chat.completion.chunk", created: 0, model: "scripted" };

createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    if (req.method !== "POST" || !req.url.endsWith("/chat/completions")) {
      res.writeHead(404).end();
      return;
    }
    // Tool results since the newest user message, so a resumed session that
    // already holds an earlier run's tool results still gets a fresh script.
    let toolMsgs = 0;
    try {
      const messages = JSON.parse(body).messages || [];
      const lastUser = messages.map((m) => m.role).lastIndexOf("user");
      toolMsgs = messages.slice(lastUser + 1).filter((m) => m.role === "tool").length;
    } catch {}
    const notices = [...new Set((body.match(/inbox-pull-notice:[^\s"\\]+/g) || []).map((n) => n.slice("inbox-pull-notice:".length)))];
    appendFileSync(logFile, `ts=${Date.now()} toolMsgs=${toolMsgs} notices=${notices.join(",")}\n`);
    if (toolMsgs < calls) {
      sse(res, [
        { ...base, choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: `call_${toolMsgs}`, type: "function", function: { name: "bash", arguments: JSON.stringify({ command }) } }] }, finish_reason: null }] },
        { ...base, choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
      ]);
    } else {
      sse(res, [
        { ...base, choices: [{ index: 0, delta: { role: "assistant", content: "done" }, finish_reason: null }] },
        { ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
      ]);
    }
  });
}).listen(0, "127.0.0.1", function () {
  writeFileSync(portFile, String(this.address().port));
});
