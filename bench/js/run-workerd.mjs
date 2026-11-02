// Build the worker bundle, run it under workerd, and print the streamed results.
// Usage: node run-workerd.mjs [rows]     (env ZPBENCH_WASM overrides the zig wasm path)
import { execFileSync, spawn } from "node:child_process";
import { copyFileSync, mkdirSync } from "node:fs";
import { createConnection } from "node:net";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const dist = join(here, "dist");
const PORT = 8791;
const rows = process.argv[2] ?? process.env.ROWS ?? "1000000";
const zigWasm = resolve(here, process.env.ZPBENCH_WASM ?? "../../zig-parquet/zig-out/bin/zpbench.wasm");
// The platform executable from the @cloudflare/workerd-* optional package (the .bin shim is a script).
const platformPkg = `@cloudflare/workerd-${process.platform === "win32" ? "windows" : process.platform}-${process.arch === "arm64" ? "arm64" : "64"}`;
const workerd = createRequire(import.meta.url).resolve(`${platformPkg}/bin/workerd${process.platform === "win32" ? ".exe" : ""}`);

mkdirSync(dist, { recursive: true });
execFileSync("bun", ["build", "src/entry-worker.js", "--outfile", "dist/worker.js", "--target", "browser", "--format", "esm", "--external", "*.wasm"], { cwd: here, stdio: "inherit" });
copyFileSync(zigWasm, join(dist, "zpbench.wasm"));
copyFileSync(join(here, "node_modules", "parquet-wasm", "esm", "parquet_wasm_bg.wasm"), join(dist, "parquet_wasm_bg.wasm"));

const version = execFileSync(workerd, ["--version"], { encoding: "utf8" }).trim();
const server = spawn(workerd, ["serve", "workerd.capnp"], { cwd: here, stdio: ["ignore", "pipe", "pipe"] });
let serverLog = "";
server.stdout.on("data", (d) => (serverLog += d));
server.stderr.on("data", (d) => (serverLog += d));

const kill = () => { try { server.kill(); } catch {} };
process.on("exit", kill);

function waitForPort(timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((ok, fail) => {
    const attempt = () => {
      const sock = createConnection({ port: PORT, host: "127.0.0.1" });
      sock.once("connect", () => { sock.destroy(); ok(); });
      sock.once("error", () => {
        sock.destroy();
        if (Date.now() > deadline) fail(new Error(`workerd did not listen:\n${serverLog}`));
        else setTimeout(attempt, 200);
      });
    };
    attempt();
  });
}

try {
  await waitForPort();
  console.log(`runtime: workerd ${version}`);
  const format = process.env.FORMAT === "json" ? "&format=json" : "";
  const res = await fetch(`http://127.0.0.1:${PORT}/?rows=${rows}${format}`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  // Streamed body: progress lines, then the table (or JSON).
  const decoder = new TextDecoder();
  for await (const chunk of res.body) process.stdout.write(decoder.decode(chunk, { stream: true }));
  process.stdout.write("\n");
} finally {
  kill();
}
