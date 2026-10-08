// Execute a generated spawn extension against a fake Pi event API, never a model.
import { readFileSync } from "node:fs";
const extension = process.argv[2];
const handlers = new Map();
const pi = {
  on(name, handler) { handlers.set(name, handler); },
  events: { on() {} },
};
const source = readFileSync(extension, "utf8");
const { default: register } = await import("data:text/javascript;base64," + Buffer.from(source).toString("base64"));
register(pi);
const handler = handlers.get("message_end");
if (handler) {
  const errorMessage = process.env.FM_FAKE_PI_ERROR || "";
  await handler({ message: { role: "user", stopReason: "stop" } });
  await handler({ message: { role: "assistant", stopReason: process.env.FM_FAKE_PI_STOP_REASON || (errorMessage ? "error" : "toolUse"), errorMessage } });
  // A later successful retry must not erase the first error.
  await handler({ message: { role: "assistant", stopReason: "stop" } });
}
