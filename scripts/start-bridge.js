const { spawnSync } = require("node:child_process");
const path = require("node:path");

const launcher = path.join(__dirname, "start-bridge.vbs");
const interval = process.argv[2] || "5";
const result = spawnSync("cscript", ["//nologo", launcher, interval], {
  stdio: "inherit"
});

process.exit(result.status ?? 1);
