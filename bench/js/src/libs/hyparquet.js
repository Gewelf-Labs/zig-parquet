// hyparquet (read) + hyparquet-writer (write), pure JS. Uncompressed.
import { parquetRead } from "hyparquet";
import { parquetWriteBuffer } from "hyparquet-writer";
import { termOf } from "../gen.js";

function columnsFor(scn, data) {
  // Numerics: encoding PLAIN (dictionary is only used when RLE_DICTIONARY is requested).
  // Strings: encoding left automatic, so the writer dictionary-encodes unless it does not help.
  switch (scn.id) {
    case 0: return [{ name: "v", data: data.v, type: "INT64", nullable: false, encoding: "PLAIN" }];
    case 1: return [{ name: "v", data: data.v, type: "DOUBLE", nullable: false, encoding: "PLAIN" }];
    case 2: return [{ name: "v", data: data.v, type: "INT64", nullable: true, encoding: "PLAIN" }];
    case 3:
    case 4: return [{ name: "s", data: data.s, type: "STRING", nullable: true }];
    case 5: return [
      { name: "i32", data: data.i32, type: "INT32", nullable: true, encoding: "PLAIN" },
      { name: "i64", data: data.i64, type: "INT64", nullable: true, encoding: "PLAIN" },
      { name: "f64", data: data.f64, type: "DOUBLE", nullable: true, encoding: "PLAIN" },
      { name: "flag", data: data.flag, type: "BOOLEAN", nullable: true, encoding: "PLAIN" },
      { name: "name", data: data.name, type: "STRING", nullable: true },
    ];
  }
  throw new Error(`unknown scenario ${scn.id}`);
}

// hyparquet reads from an AsyncBuffer; slice() must return an ArrayBuffer.
function asyncBuffer(bytes) {
  return {
    byteLength: bytes.byteLength,
    slice(start, end) {
      return bytes.slice(start, end ?? bytes.byteLength).buffer;
    },
  };
}

export const hyparquet = {
  name: "hyparquet+writer",

  async init() {},

  async write(scn, data) {
    return new Uint8Array(parquetWriteBuffer({
      columnData: columnsFor(scn, data),
      codec: "UNCOMPRESSED",
    }));
  },

  async read(bytes, scn) {
    // Column 0 is summed in row order; chunks may arrive out of order, so collect and sort.
    const first = scn.columns[0].name;
    const chunks = [];
    await parquetRead({
      file: asyncBuffer(bytes),
      onChunk(chunk) {
        if (chunk.columnName === first) chunks.push(chunk);
      },
    });
    chunks.sort((a, b) => a.rowStart - b.rowStart);
    let rows = 0;
    let sum = 0;
    for (const c of chunks) {
      const arr = c.columnData;
      for (let i = 0; i < arr.length; i++) sum += termOf(arr[i]);
      rows += arr.length;
    }
    return { rows, sum };
  },
};
