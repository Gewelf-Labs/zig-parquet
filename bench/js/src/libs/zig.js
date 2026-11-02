// zig-parquet compiled to freestanding WASM (zpbench.wasm). See zig-parquet/bench for the contract.
import { utf8Length } from "../gen.js";

const enc = new TextEncoder();
const IMPORTS = {
  env: { host_read_at: () => -1, host_size: () => 0n, host_write: () => -1, host_close: () => -1 },
};

let ex = null;

function alloc(n) {
  const p = ex.zpb_alloc(n);
  if (!p) throw new Error(`zpb_alloc(${n}) returned 0`);
  return p;
}
// Views are re-created on every use: memory may grow (and detach old views) on any call.
const view = (Ctor, ptr, n) => new Ctor(ex.memory.buffer, ptr, n);

// Strings -> u32 offsets[rows+1] + UTF-8 bytes, written straight into wasm memory.
function packStrings(strs) {
  const n = strs.length;
  const lens = new Uint32Array(n);
  let total = 0;
  for (let i = 0; i < n; i++) total += lens[i] = utf8Length(strs[i]);
  const off = alloc((n + 1) * 4);
  const bytes = alloc(Math.max(total, 1));
  const o = view(Uint32Array, off, n + 1);
  const bv = view(Uint8Array, bytes, total);
  let pos = 0;
  o[0] = 0;
  for (let i = 0; i < n; i++) o[i + 1] = pos += lens[i];
  // One encodeInto for all strings: per-string calls cost ~0.3 us each in browsers.
  const { written } = enc.encodeInto(strs.join(""), bv);
  if (written !== total) throw new Error(`encodeInto wrote ${written} of ${total} bytes`);
  return { off, bytes, total, freed: [[off, (n + 1) * 4], [bytes, Math.max(total, 1)]] };
}

export const zig = {
  name: "zig-parquet (wasm)",

  async init(assets) {
    if (!assets?.zigModule) throw new Error("zpbench.wasm not available");
    ex = new WebAssembly.Instance(assets.zigModule, IMPORTS).exports;
  },

  async write(scn, data) {
    const rows = data.rows;
    const freed = [];
    const tracked = (p, n) => { freed.push([p, n]); return p; };
    try {
      let args;
      switch (scn.id) {
        case 0: {
          const a = tracked(alloc(rows * 8), rows * 8);
          view(BigInt64Array, a, rows).set(data.v);
          args = [0, rows, a, 0, 0, 0, 0, 0];
          break;
        }
        case 1: {
          const a = tracked(alloc(rows * 8), rows * 8);
          view(Float64Array, a, rows).set(data.v);
          args = [1, rows, a, 0, 0, 0, 0, 0];
          break;
        }
        case 2: {
          const a = tracked(alloc(rows * 8), rows * 8);
          const b = tracked(alloc(rows), rows);
          const vals = view(BigInt64Array, a, rows);
          const valid = view(Uint8Array, b, rows);
          const src = data.v;
          for (let i = 0; i < rows; i++) {
            const x = src[i];
            if (x === null) { valid[i] = 0; vals[i] = 0n; } else { valid[i] = 1; vals[i] = x; }
          }
          args = [2, rows, a, b, 0, 0, 0, 0];
          break;
        }
        case 3:
        case 4: {
          const s = packStrings(data.s);
          s.freed.forEach(([p, n]) => freed.push([p, n]));
          args = [scn.id, rows, s.off, s.bytes, 0, 0, 0, 0];
          break;
        }
        case 5: {
          const a = tracked(alloc(rows * 4), rows * 4);
          const b = tracked(alloc(rows * 8), rows * 8);
          const c = tracked(alloc(rows * 8), rows * 8);
          const d = tracked(alloc(rows), rows);
          view(Int32Array, a, rows).set(data.i32);
          view(BigInt64Array, b, rows).set(data.i64);
          view(Float64Array, c, rows).set(data.f64);
          const dv = view(Uint8Array, d, rows);
          for (let i = 0; i < rows; i++) dv[i] = data.flag[i] ? 1 : 0;
          const s = packStrings(data.name);
          s.freed.forEach(([p, n]) => freed.push([p, n]));
          args = [5, rows, a, b, c, d, s.off, s.bytes];
          break;
        }
        default:
          throw new Error(`unknown scenario ${scn.id}`);
      }
      const len = ex.zpb_write(...args);
      if (len < 0) throw new Error(`zpb_write returned ${len}`);
      const out = new Uint8Array(ex.memory.buffer, ex.zpb_out_ptr(), len).slice();
      ex.zpb_out_free();
      return out;
    } finally {
      for (const [p, n] of freed) ex.zpb_free(p, n);
    }
  },

  async read(bytes) {
    const p = alloc(bytes.length);
    view(Uint8Array, p, bytes.length).set(bytes);
    let n;
    try {
      n = ex.zpb_read(p, bytes.length);
      if (n < 0) throw new Error(`zpb_read returned ${n}`);
      let sum = 0;
      const col = view(Float64Array, ex.zpb_col_ptr(), n);
      for (let i = 0; i < n; i++) sum += col[i];
      ex.zpb_col_free();
      return { rows: n, sum };
    } finally {
      ex.zpb_free(p, bytes.length);
    }
  },
};
