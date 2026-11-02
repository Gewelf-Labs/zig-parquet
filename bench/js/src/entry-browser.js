// Browser entry: loads the WASM assets from the static server, runs the benchmark, publishes results.
import { initLibs, runBench, formatInterop } from "./bench.js";

const out = document.getElementById("out");
const log = (line) => {
  out.textContent += line + "\n";
  console.log(line);
};

async function compile(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return WebAssembly.compileStreaming(res);
}

async function main() {
  const rows = Number(new URLSearchParams(location.search).get("rows") ?? 1_000_000);
  const assets = {
    zigModule: await compile("/zpbench.wasm").catch((e) => (log(`zig: ${e.message}`), null)),
    parquetWasmModule: await compile("/parquet_wasm_bg.wasm"),
  };
  const libs = await initLibs(assets, log);
  const result = await runBench({ rows, libs, log, now: () => performance.now() });
  result.userAgent = navigator.userAgent;
  result.report = `${result.table}\n\n${formatInterop(result.interop)}`;
  out.textContent = result.report + "\n";
  window.__BENCH_RESULT__ = result;
}

main()
  .catch((e) => {
    log(`fatal: ${e?.stack ?? e}`);
    window.__BENCH_ERROR__ = String(e?.stack ?? e);
  })
  .finally(() => {
    window.__BENCH_DONE__ = true;
  });
