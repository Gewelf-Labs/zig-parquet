// Build the browser bundle, serve bench/js over localhost, and drive Chrome and Firefox with Playwright.
// Usage: node run-browsers.mjs [rows]     (env ZPBENCH_WASM overrides the zig wasm path)
import { execFileSync } from "node:child_process";
import { createReadStream, existsSync, mkdirSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox } from "playwright";

const here = dirname(fileURLToPath(import.meta.url));
const dist = join(here, "dist");
const rows = process.argv[2] ?? process.env.ROWS ?? "1000000";
const zigWasm = resolve(here, process.env.ZPBENCH_WASM ?? "../../zig-parquet/zig-out/bin/zpbench.wasm");
const parquetWasm = join(here, "node_modules", "parquet-wasm", "esm", "parquet_wasm_bg.wasm");
const MIME = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm", ".mjs": "text/javascript" };
const DEADLINE_MS = 30 * 60 * 1000;

mkdirSync(dist, { recursive: true });
execFileSync("bun", ["build", "src/entry-browser.js", "--outdir", "dist", "--target", "browser", "--format", "esm"], { cwd: here, stdio: "inherit" });

// Static routes: the page, dist/*, and the two wasm assets under fixed names.
const routes = {
  "/": join(here, "index.html"),
  "/zpbench.wasm": zigWasm,
  "/parquet_wasm_bg.wasm": parquetWasm,
};
function resolvePath(url) {
  const path = new URL(url, "http://x").pathname;
  if (routes[path]) return routes[path];
  if (path.startsWith("/dist/")) {
    const file = join(dist, path.slice("/dist/".length));
    if (file.startsWith(dist)) return file;
  }
  return null;
}
const server = createServer((req, res) => {
  const file = resolvePath(req.url);
  if (!file || !existsSync(file) || !statSync(file).isFile()) {
    res.writeHead(404, { "content-type": "text/plain" }).end("not found");
    return;
  }
  res.writeHead(200, {
    "content-type": MIME[extname(file)] ?? "application/octet-stream",
    "cross-origin-opener-policy": "same-origin",
    "cross-origin-embedder-policy": "require-corp",
    "cache-control": "no-store",
  });
  createReadStream(file).pipe(res);
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const base = `http://127.0.0.1:${server.address().port}`;

async function runIn(launcher, label, opts) {
  const browser = await launcher.launch({ headless: true, ...opts });
  try {
    const version = browser.version();
    const page = await browser.newPage();
    page.on("pageerror", (e) => console.error(`[${label}] page error: ${e.message}`));
    await page.goto(`${base}/?rows=${rows}`);
    await page.waitForFunction(() => window.__BENCH_DONE__ === true, null, { timeout: DEADLINE_MS, polling: 1000 });
    const err = await page.evaluate(() => window.__BENCH_ERROR__ ?? null);
    const result = await page.evaluate(() => window.__BENCH_RESULT__ ?? null);
    if (err || !result) throw new Error(`${label} run failed: ${err ?? "no result"}`);
    console.log(`\nruntime: ${label} ${version}  (rows=${rows})`);
    console.log(result.report);
    return { runtime: label, version, ...result };
  } finally {
    await browser.close();
  }
}

const out = [];
try {
  // Sequential on purpose: runs must not compete for CPU.
  out.push(await runIn(chromium, "Chrome", { channel: "chrome" }));
  out.push(await runIn(firefox, "Firefox", {}));
} finally {
  server.close();
}
const jsonPath = join(dist, "results-browsers.json");
writeFileSync(jsonPath, JSON.stringify(out, null, 2));
console.log(`\nresults JSON: ${jsonPath}`);
