// Runtime-agnostic runner. Timing uses the injected `now()` (ms).
import { SCENARIOS, generate, expectedSum } from "./gen.js";
import { zig } from "./libs/zig.js";
import { hyparquet } from "./libs/hyparquet.js";
import { parquetWasm } from "./libs/parquet-wasm.js";

export const RUNS = 3;
export const INTEROP_ROWS = 1000;
const ADAPTERS = [zig, hyparquet, parquetWasm];

/** Initialise every adapter. Failures are kept (as `error`) and reported as n/a. */
export async function initLibs(assets, log = () => {}) {
  const out = [];
  for (const adapter of ADAPTERS) {
    try {
      await adapter.init(assets);
      out.push({ adapter, error: null });
    } catch (e) {
      log(`[init] ${adapter.name}: ${e?.message ?? e}`);
      out.push({ adapter, error: String(e?.message ?? e) });
    }
  }
  return out;
}

function checkResult(res, rows, want) {
  if (res.rows !== rows || res.sum !== want) {
    throw new Error(`checksum mismatch: got rows=${res.rows} sum=${res.sum}, want rows=${rows} sum=${want}`);
  }
}

/** Write every scenario with every library, then read each output with every library. */
export async function interop(libs, log = () => {}) {
  const ok = libs.filter((l) => !l.error);
  const pairs = [];
  for (const w of ok) for (const r of ok) pairs.push({ writer: w.adapter.name, reader: r.adapter.name, cells: {} });
  for (const scn of SCENARIOS) {
    const data = generate(scn, INTEROP_ROWS);
    const want = expectedSum(scn, data);
    for (const w of ok) {
      let bytes = null;
      let writeErr = null;
      try {
        bytes = await w.adapter.write(scn, data);
      } catch (e) {
        writeErr = `write: ${e.message}`;
      }
      for (const r of ok) {
        const pair = pairs.find((p) => p.writer === w.adapter.name && p.reader === r.adapter.name);
        if (writeErr) { pair.cells[scn.name] = "ERR"; log(`[interop] ${w.adapter.name} ${scn.name} ${writeErr}`); continue; }
        try {
          checkResult(await r.adapter.read(bytes, scn), INTEROP_ROWS, want);
          pair.cells[scn.name] = "ok";
        } catch (e) {
          pair.cells[scn.name] = "ERR";
          log(`[interop] ${w.adapter.name} -> ${r.adapter.name} ${scn.name}: ${e.message}`);
        }
      }
    }
  }
  // Libraries that failed to init show as n/a in the matrix.
  for (const l of libs.filter((l) => l.error)) {
    pairs.push({ writer: l.adapter.name, reader: "*", cells: Object.fromEntries(SCENARIOS.map((s) => [s.name, "n/a"])) });
  }
  return { scenarios: SCENARIOS.map((s) => s.name), pairs };
}

/** Timed benchmark. Each phase runs `runs` times; the best time is kept. */
export async function runBench({ rows, libs, log = () => {}, now = () => performance.now(), runs = RUNS, skipInterop = false }) {
  const t0 = now();
  const interopResult = skipInterop ? null : await interop(libs, log);
  const results = [];
  for (const scn of SCENARIOS) {
    const data = generate(scn, rows);
    const want = expectedSum(scn, data);
    for (const { adapter, error } of libs) {
      const rec = {
        lib: adapter.name, scenario: scn.name, rows,
        write_ms: null, write_rows_per_s: null, read_ms: null, read_rows_per_s: null, file_MB: null,
        status: "ok", error: null,
      };
      if (error) {
        rec.status = "n/a";
        rec.error = error;
        results.push(rec);
        continue;
      }
      let bestW = Infinity;
      let bestR = Infinity;
      try {
        for (let run = 0; run < runs; run++) {
          let s = now();
          const bytes = await adapter.write(scn, data);
          bestW = Math.min(bestW, now() - s);
          rec.file_MB = bytes.byteLength / (1024 * 1024);
          s = now();
          const res = await adapter.read(bytes, scn);
          bestR = Math.min(bestR, now() - s);
          checkResult(res, rows, want);
          log(`[${adapter.name}] ${scn.name} run ${run + 1}: write ${(bestW).toFixed(1)}ms read ${bestR.toFixed(1)}ms`);
        }
        rec.write_ms = bestW;
        rec.read_ms = bestR;
        rec.write_rows_per_s = rows / (bestW / 1000);
        rec.read_rows_per_s = rows / (bestR / 1000);
      } catch (e) {
        rec.status = "ERR";
        rec.error = e?.message ?? String(e);
        log(`[${adapter.name}] ${scn.name} ERR: ${rec.error}`);
      }
      results.push(rec);
    }
  }
  const table = formatTable(rows, results);
  return { rows, results, interop: interopResult, elapsed_ms: now() - t0, table };
}


/** Fixed-width table in the native bench's column style. */
export function formatTable(rows, results) {
  const head = [
    "lib".padEnd(18), "scenario".padEnd(15), "rows".padStart(9), "write_ms".padStart(10),
    "write_rows_per_s".padStart(17), "read_ms".padStart(10), "read_rows_per_s".padStart(16), "file_MB".padStart(9),
  ].join(" ");
  const lines = [head];
  const notes = [];
  // Cell text: n/a for unsupported, ERR for failures, otherwise the number.
  const cell = (r, v, digits, width) => {
    let t;
    if (r.status === "n/a") t = "n/a";
    else if (v == null) t = "ERR";
    else t = Number.isFinite(v) ? v.toFixed(digits) : "n/a";
    return t.padStart(width);
  };
  for (const r of results) {
    lines.push([
      r.lib.padEnd(18), r.scenario.padEnd(15), String(rows).padStart(9),
      cell(r, r.write_ms, 2, 10),
      cell(r, r.write_rows_per_s, 0, 17),
      cell(r, r.read_ms, 2, 10),
      cell(r, r.read_rows_per_s, 0, 16),
      cell(r, r.file_MB, 2, 9),
    ].join(" "));
    if (r.error) notes.push(`  ${r.lib} ${r.scenario}: ${r.error}`);
  }
  const body = lines.join("\n");
  return notes.length ? body + "\nnotes:\n" + notes.join("\n") : body;
}

/** Interop matrix as text. */
export function formatInterop(io) {
  if (!io) return "(interop skipped)";
  const w = (s, n) => s.padEnd(n);
  const lines = [`interop (${INTEROP_ROWS} rows) writer -> reader`];
  lines.push(w("writer -> reader", 52) + io.scenarios.map((s) => s.padEnd(15)).join(""));
  for (const p of io.pairs) {
    lines.push(w(`${p.writer} -> ${p.reader}`, 52) + io.scenarios.map((s) => (p.cells[s] ?? "-").padEnd(15)).join(""));
  }
  return lines.join("\n");
}
