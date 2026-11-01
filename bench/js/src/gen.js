// Canonical data for the six scenarios (mirrors zig-parquet/bench/main.zig).
// Generated once per scenario, outside the timed region.

const MASK64 = (1n << 64n) - 1n;

export function makeRng(seed = 42n) {
  let state = seed;
  return function next() {
    state = (state + 0x9E3779B97F4A7C15n) & MASK64;
    let z = state;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK64;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK64;
    return z ^ (z >> 31n);
  };
}
const f64Of = (x) => Number(x >> 11n) * 2 ** -53;
const i32Of = (x) => Number(BigInt.asIntN(32, x >> 32n));
const i64Of = (x) => BigInt.asIntN(64, x);
const boolOf = (x) => (x & 1n) === 1n;
const idxOf = (x) => Number(x % 1000n);

// Per-scenario column 0 kind, used by the checksum.
export const SCENARIOS = [
  { id: 0, name: "int64_plain", columns: [{ name: "v", type: "int64", nullable: false }] },
  { id: 1, name: "f64_plain", columns: [{ name: "v", type: "double", nullable: false }] },
  { id: 2, name: "int64_nullable", columns: [{ name: "v", type: "int64", nullable: true }] },
  { id: 3, name: "str_dict", columns: [{ name: "s", type: "string", nullable: true }] },
  { id: 4, name: "str_unique", columns: [{ name: "s", type: "string", nullable: true }] },
  {
    id: 5,
    name: "mixed5",
    columns: [
      { name: "i32", type: "int32", nullable: true },
      { name: "i64", type: "int64", nullable: true },
      { name: "f64", type: "double", nullable: true },
      { name: "flag", type: "bool", nullable: true },
      { name: "name", type: "string", nullable: true },
    ],
  },
];

/** Canonical JS data for scenario `scn` at `rows` rows. Returns { rows, ...columns }. */
export function generate(scn, rows) {
  const id = typeof scn === "number" ? scn : scn.id;
  const next = makeRng();
  switch (id) {
    case 0: {
      const v = new BigInt64Array(rows);
      for (let i = 0; i < rows; i++) v[i] = BigInt(i);
      return { rows, v };
    }
    case 1: {
      const v = new Float64Array(rows);
      for (let i = 0; i < rows; i++) v[i] = f64Of(next());
      return { rows, v };
    }
    case 2: {
      const v = new Array(rows);
      let c = 0n;
      for (let i = 0; i < rows; i++) {
        if (i % 3 === 2) v[i] = null;
        else { v[i] = c; c++; }
      }
      return { rows, v };
    }
    case 3:
    case 4: {
      const s = new Array(rows);
      for (let i = 0; i < rows; i++) {
        s[i] = id === 3 ? "dictval-" + String(i % 100).padStart(5, "0") : "row-" + i;
      }
      return { rows, s };
    }
    case 5: {
      const i32 = new Int32Array(rows);
      const i64 = new BigInt64Array(rows);
      const f64 = new Float64Array(rows);
      const flag = new Array(rows);
      const name = new Array(rows);
      for (let i = 0; i < rows; i++) {
        i32[i] = i32Of(next());
        i64[i] = i64Of(next());
        f64[i] = f64Of(next());
        flag[i] = boolOf(next());
        name[i] = "category-" + String(idxOf(next())).padStart(4, "0");
      }
      return { rows, i32, i64, f64, flag, name };
    }
    default:
      throw new Error(`unknown scenario ${id}`);
  }
}

/** UTF-8 byte length of a JS string (exact for any code points). */
export function utf8Length(s) {
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x80) n += 1;
    else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const d = s.charCodeAt(i + 1);
      if (d >= 0xdc00 && d <= 0xdfff) { n += 4; i++; } else n += 3;
    } else n += 3;
  }
  return n;
}

/** Checksum term of one column-0 value: int64 -> Number, double/int32 -> value, string -> UTF-8 bytes, null -> 0. */
export function termOf(v) {
  if (v === null || v === undefined) return 0;
  if (typeof v === "bigint") return Number(v);
  if (typeof v === "string") return utf8Length(v);
  return v;
}

/** Expected checksum over column 0 of canonical data, summed in row order. */
export function expectedSum(scn, data) {
  const id = typeof scn === "number" ? scn : scn.id;
  let sum = 0;
  switch (id) {
    case 0: for (let i = 0; i < data.rows; i++) sum += Number(data.v[i]); break;
    case 1: for (let i = 0; i < data.rows; i++) sum += data.v[i]; break;
    case 2: for (let i = 0; i < data.rows; i++) sum += termOf(data.v[i]); break;
    case 3:
    case 4: for (let i = 0; i < data.rows; i++) sum += utf8Length(data.s[i]); break;
    case 5: for (let i = 0; i < data.rows; i++) sum += data.i32[i]; break;
  }
  return sum;
}
