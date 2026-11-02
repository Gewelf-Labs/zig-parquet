// parquet-wasm (arrow-rs compiled to WASM) with apache-arrow for tables. Uncompressed.
import * as pw from "parquet-wasm/esm/parquet_wasm.js";
import {
  Bool, Field, Float64, Int32, Int64, RecordBatch, Schema, Table, Utf8, Struct,
  makeData, tableFromIPC, tableToIPC, Vector,
} from "apache-arrow";
import { termOf, utf8Length } from "../gen.js";

const enc = new TextEncoder();

let ready = false;

// Build a Table with explicit nullability (arrow infers nullable from null counts).
function buildTable(cols) {
  const fields = cols.map((c) => new Field(c.name, c.type, c.nullable));
  const schema = new Schema(fields);
  const length = cols[0].vec.length;
  const children = cols.map((c) => c.vec.data[0]);
  const struct = makeData({ type: new Struct(fields), length, nullCount: 0, children });
  return new Table(schema, [new RecordBatch(schema, struct)]);
}

// Arrow buffers are built directly. apache-arrow's vectorFromArray uses generated code (new Function),
// which workerd forbids, so nullable/string/bool vectors are assembled from raw buffers.
function utf8Data(strs, n) {
  const offsets = new Int32Array(n + 1);
  const lens = new Uint32Array(n);
  let total = 0;
  for (let i = 0; i < n; i++) total += lens[i] = utf8Length(strs[i]);
  const bytes = new Uint8Array(Math.max(total, 1));
  let pos = 0;
  for (let i = 0; i < n; i++) {
    pos += enc.encodeInto(strs[i], bytes.subarray(pos)).written;
    offsets[i + 1] = pos;
  }
  return makeData({ type: new Utf8(), length: n, nullCount: 0, valueOffsets: offsets, data: bytes });
}

function int64Nullable(values, n) {
  const vals = new BigInt64Array(n);
  const bits = new Uint8Array((n + 7) >> 3);
  let nulls = 0;
  for (let i = 0; i < n; i++) {
    const v = values[i];
    if (v === null) nulls++;
    else { vals[i] = v; bits[i >> 3] |= 1 << (i & 7); }
  }
  return makeData({ type: new Int64(), length: n, nullCount: nulls, data: vals, nullBitmap: bits });
}

function boolData(flags, n) {
  const bits = new Uint8Array((n + 7) >> 3);
  for (let i = 0; i < n; i++) if (flags[i]) bits[i >> 3] |= 1 << (i & 7);
  return makeData({ type: new Bool(), length: n, nullCount: 0, data: bits });
}

function arrowTable(scn, data) {
  const n = data.rows;
  const fixed = (type, values) => makeData({ type, length: n, nullCount: 0, data: values });
  const vec = (type, values) => new Vector([fixed(type, values)]);
  switch (scn.id) {
    case 0: return buildTable([{ name: "v", type: new Int64(), nullable: false, vec: vec(new Int64(), data.v) }]);
    case 1: return buildTable([{ name: "v", type: new Float64(), nullable: false, vec: vec(new Float64(), data.v) }]);
    case 2: return buildTable([{ name: "v", type: new Int64(), nullable: true, vec: new Vector([int64Nullable(data.v, n)]) }]);
    case 3:
    case 4: return buildTable([{ name: "s", type: new Utf8(), nullable: true, vec: new Vector([utf8Data(data.s, n)]) }]);
    case 5: return buildTable([
      { name: "i32", type: new Int32(), nullable: true, vec: vec(new Int32(), data.i32) },
      { name: "i64", type: new Int64(), nullable: true, vec: vec(new Int64(), data.i64) },
      { name: "f64", type: new Float64(), nullable: true, vec: vec(new Float64(), data.f64) },
      { name: "flag", type: new Bool(), nullable: true, vec: new Vector([boolData(data.flag, n)]) },
      { name: "name", type: new Utf8(), nullable: true, vec: new Vector([utf8Data(data.name, n)]) },
    ]);
  }
  throw new Error(`unknown scenario ${scn.id}`);
}

function writerProps(scn) {
  // Dictionary off for numerics/bool; on for strings (and for `name` in mixed5).
  let b = new pw.WriterPropertiesBuilder()
    .setCompression(pw.Compression.UNCOMPRESSED)
    .setDictionaryEnabled(scn.id === 3 || scn.id === 4);
  if (scn.id === 5) b = b.setColumnDictionaryEnabled("name", true);
  return b.build();
}

// Valid-bit test for an Arrow validity bitmap.
const isValid = (bits, i) => (bits[i >> 3] >> (i & 7)) & 1;

function sumColumnZero(table, isString) {
  const vec = table.getChildAt(0);
  let rows = 0;
  let sum = 0;
  for (const d of vec.data) {
    const { length, offset, nullCount, nullBitmap } = d;
    rows += length;
    if (isString) {
      const vo = d.valueOffsets;
      for (let i = 0; i < length; i++) {
        if (nullCount && !isValid(nullBitmap, offset + i)) continue;
        sum += vo[offset + i + 1] - vo[offset + i];
      }
    } else {
      const vals = d.values;
      for (let i = 0; i < length; i++) {
        if (nullCount && !isValid(nullBitmap, offset + i)) continue;
        sum += termOf(vals[offset + i]);
      }
    }
  }
  return { rows, sum };
}

export const parquetWasm = {
  name: "parquet-wasm+arrow",

  async init(assets) {
    if (ready) return;
    if (!assets?.parquetWasmModule) throw new Error("parquet_wasm_bg.wasm not available");
    await pw.default({ module_or_path: assets.parquetWasmModule });
    ready = true;
  },

  async write(scn, data) {
    const table = arrowTable(scn, data);
    // writeParquet consumes both the table and the properties (wasm-bindgen moves them).
    return pw.writeParquet(pw.Table.fromIPCStream(tableToIPC(table, "stream")), writerProps(scn));
  },

  async read(bytes, scn) {
    // intoIPCStream consumes the wasm table.
    const at = tableFromIPC(pw.readParquet(bytes).intoIPCStream());
    return sumColumnZero(at, scn.columns[0].type === "string");
  },
};
