// workerd entry. One GET / runs the whole benchmark and streams progress lines, then the table
// (or JSON with ?format=json). Streaming keeps the response headers flowing during long runs.
import { initLibs, runBench, formatInterop } from "./bench.js";
import zigModule from "./zpbench.wasm";
import parquetWasmModule from "./parquet_wasm_bg.wasm";

// Clock probe: does performance.now() advance during pure CPU work? (Workers may freeze it.)
function clockProbe() {
  const p0 = performance.now();
  const d0 = Date.now();
  while (Date.now() - d0 < 200);
  return { perf_now_delta_ms: performance.now() - p0, date_now_delta_ms: Date.now() - d0 };
}

export default {
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname !== "/") return new Response("not found", { status: 404 });
    const rows = Number(url.searchParams.get("rows") ?? 1_000_000);
    const json = url.searchParams.get("format") === "json";
    const { readable, writable } = new TransformStream();
    const writer = writable.getWriter();
    const enc = new TextEncoder();
    const emit = (line) => { if (!json) writer.write(enc.encode(line + "\n")).catch(() => {}); };

    (async () => {
      try {
        const clock = clockProbe();
        emit(`clock probe: perf_now_delta=${clock.perf_now_delta_ms.toFixed(1)}ms date_now_delta=${clock.date_now_delta_ms}ms`);
        const libs = await initLibs({ zigModule, parquetWasmModule }, emit);
        const result = await runBench({ rows, libs, log: emit, now: () => performance.now() });
        result.clock_probe = clock;
        if (json) {
          await writer.write(enc.encode(JSON.stringify(result, null, 2)));
        } else {
          await writer.write(enc.encode(`${result.table}\n\n${formatInterop(result.interop)}\n`));
        }
      } catch (e) {
        await writer.write(enc.encode(`fatal: ${e?.stack ?? e}\n`)).catch(() => {});
      } finally {
        await writer.close().catch(() => {});
      }
    })();

    return new Response(readable, { headers: { "content-type": json ? "application/json" : "text/plain; charset=utf-8" } });
  },
};
