const fs = require("node:fs");

const inputPath = process.argv[2];
const raw = inputPath ? fs.readFileSync(inputPath, "utf8") : fs.readFileSync(0, "utf8");
const line = raw.trim();
const jsonText = line.startsWith("HRM2 ") ? line.slice(5) : line;
const frame = JSON.parse(jsonText);

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function assertNumber(value, label) {
  assert(typeof value === "number" && Number.isFinite(value), `${label} must be numeric`);
}

assert(frame.v === 3, "frame.v must be 3");
assert(typeof frame.ts === "string" && frame.ts.length > 0, "frame.ts is required");
assert(typeof frame.ok === "boolean", "frame.ok must be boolean");
assert(frame.session && typeof frame.session === "object", "frame.session is required");
assert(frame.live && typeof frame.live === "object", "frame.live is required");
assert(frame.views && typeof frame.views === "object", "frame.views is required");

for (const key of ["req", "saved", "usd", "pct", "input"]) {
  assertNumber(frame.session[key], `session.${key}`);
}
assert(typeof frame.session.last === "string", "session.last must be string");

for (const key of ["rtkCmd", "rtkSaved", "rtkPct", "uptime"]) {
  assertNumber(frame.live[key], `live.${key}`);
}
assert(typeof frame.live.proxy === "string", "live.proxy must be string");

for (const viewName of ["day", "week", "month"]) {
  const view = frame.views[viewName];
  assert(view && typeof view === "object", `views.${viewName} is required`);
  assert(typeof view.title === "string" && view.title.length > 0, `views.${viewName}.title is required`);
  for (const key of ["consumed_usd", "saved_usd", "input_tokens", "saved_tokens", "avg_pct"]) {
    assertNumber(view[key], `views.${viewName}.${key}`);
  }
  assert(Array.isArray(view.series), `views.${viewName}.series must be an array`);
  for (const [index, point] of view.series.entries()) {
    assert(typeof point.label === "string" && point.label.length > 0, `views.${viewName}.series[${index}].label is required`);
    assertNumber(point.consumed_usd, `views.${viewName}.series[${index}].consumed_usd`);
    assertNumber(point.saved_usd, `views.${viewName}.series[${index}].saved_usd`);
    assertNumber(point.input_tokens ?? point.input, `views.${viewName}.series[${index}].input_tokens`);
    assertNumber(point.saved_tokens ?? point.saved, `views.${viewName}.series[${index}].saved_tokens`);
  }
}

console.log(
  `HRM2 v3 frame ok: day=${frame.views.day.series.length}, week=${frame.views.week.series.length}, month=${frame.views.month.series.length}`
);
