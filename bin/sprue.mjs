#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const VERSION = "0.1.0";
const args = process.argv.slice(2);

if (args.length === 1 && (args[0] === "--version" || args[0] === "-v")) {
  console.log(VERSION);
  process.exit(0);
}

if (process.platform === "win32") {
  console.error("sprue: the Node runner is not released yet; on Windows use WSL.");
  process.exit(1);
}

const runner = fileURLToPath(new URL("./graph.sh", import.meta.url));
const result = spawnSync("sh", [runner, ...args], { stdio: "inherit" });
if (result.error) {
  console.error(`sprue: cannot run ${runner}: ${result.error.message}`);
  process.exit(1);
}
process.exit(result.status ?? 1);
