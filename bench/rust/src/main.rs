//! Rust counterpart of `zig-parquet/bench/main.zig`.
//!
//! Usage: cargo run --release -- [rows]   (run from bench/rust so .cargo/config.toml applies)
//!
//! Same six scenarios, same data semantics, same checksum as the Zig bench.
//! Each scenario: write (timed), read_rows = parquet-rs row API (timed),
//! read_arrow = ParquetRecordBatchReader (timed). Best of 3 runs per phase.

use std::error::Error;
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use arrow_array::{Array, ArrayRef, BooleanArray, Float64Array, Int32Array, Int64Array, RecordBatch, StringArray};
use arrow_schema::{DataType, Field as ArrowField, Schema};
use parquet::arrow::arrow_reader::ParquetRecordBatchReaderBuilder;
use parquet::arrow::ArrowWriter;
use parquet::basic::{Compression, Encoding};
use parquet::file::properties::WriterProperties;
use parquet::file::reader::{FileReader, SerializedFileReader};
use parquet::record::Field as RecField;
use parquet::schema::types::ColumnPath;

const RUNS: usize = 3;
const DEFAULT_ROWS: usize = 1_000_000;
const TWO_NEG_53: f64 = 1.0 / 9_007_199_254_740_992.0;

/// splitmix64, same spec as the cross-language comparison data.
struct SplitMix(u64);

impl SplitMix {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn f64(&mut self) -> f64 {
        (self.next() >> 11) as f64 * TWO_NEG_53
    }
    fn i32(&mut self) -> i32 {
        (self.next() >> 32) as u32 as i32
    }
    fn i64(&mut self) -> i64 {
        self.next() as i64
    }
    fn bool(&mut self) -> bool {
        self.next() & 1 == 1
    }
    fn idx(&mut self) -> usize {
        (self.next() % 1000) as usize
    }
}

fn one_col(name: &str, dt: DataType, nullable: bool, arr: ArrayRef) -> RecordBatch {
    let schema = Arc::new(Schema::new(vec![ArrowField::new(name, dt, nullable)]));
    RecordBatch::try_new(schema, vec![arr]).expect("valid batch")
}

// ---------------------------------------------------------------------------
// Data generation (untimed). Each builder returns the batch and the expected
// column-0 checksum, computed from the raw generated values.
// ---------------------------------------------------------------------------

fn build_int64_plain(n: usize) -> (RecordBatch, u64) {
    let v: Vec<i64> = (0..n as i64).collect();
    let sum = v.iter().fold(0u64, |s, &x| s.wrapping_add(x as u64));
    (one_col("v", DataType::Int64, false, Arc::new(Int64Array::from(v))), sum)
}

fn build_f64_plain(n: usize) -> (RecordBatch, u64) {
    let mut rng = SplitMix(42);
    let v: Vec<f64> = (0..n).map(|_| rng.f64()).collect();
    let sum = v.iter().fold(0u64, |s, x| s.wrapping_add(x.to_bits()));
    (one_col("v", DataType::Float64, false, Arc::new(Float64Array::from(v))), sum)
}

fn build_int64_nullable(n: usize) -> (RecordBatch, u64) {
    let mut c = 0i64;
    let v: Vec<Option<i64>> = (0..n)
        .map(|i| {
            if i % 3 == 2 {
                None
            } else {
                c += 1;
                Some(c - 1)
            }
        })
        .collect();
    let sum = v.iter().flatten().fold(0u64, |s, &x| s.wrapping_add(x as u64));
    (one_col("v", DataType::Int64, true, Arc::new(Int64Array::from(v))), sum)
}

fn build_str_dict(n: usize) -> (RecordBatch, u64) {
    let dict: Vec<String> = (0..100).map(|i| format!("dictval-{:05}", i)).collect();
    let v: Vec<&str> = (0..n).map(|i| dict[i % 100].as_str()).collect();
    let sum = v.iter().fold(0u64, |s, x| s.wrapping_add(x.len() as u64));
    (one_col("s", DataType::Utf8, true, Arc::new(StringArray::from_iter_values(v))), sum)
}

fn build_str_unique(n: usize) -> (RecordBatch, u64) {
    let v: Vec<String> = (0..n).map(|i| format!("row-{}", i)).collect();
    let sum = v.iter().fold(0u64, |s, x| s.wrapping_add(x.len() as u64));
    (one_col("s", DataType::Utf8, true, Arc::new(StringArray::from_iter_values(v))), sum)
}

fn build_mixed5(n: usize) -> (RecordBatch, u64) {
    let dict: Vec<String> = (0..1000).map(|i| format!("category-{:04}", i)).collect();
    let mut rng = SplitMix(42);
    let mut i32s = Vec::with_capacity(n);
    let mut i64s = Vec::with_capacity(n);
    let mut f64s = Vec::with_capacity(n);
    let mut bools = Vec::with_capacity(n);
    let mut names: Vec<&str> = Vec::with_capacity(n);
    for _ in 0..n {
        i32s.push(rng.i32());
        i64s.push(rng.i64());
        f64s.push(rng.f64());
        bools.push(rng.bool());
        names.push(dict[rng.idx()].as_str());
    }
    let sum = i32s.iter().fold(0u64, |s, &x| s.wrapping_add(x as i64 as u64));
    let schema = Arc::new(Schema::new(vec![
        ArrowField::new("i32", DataType::Int32, true),
        ArrowField::new("i64", DataType::Int64, true),
        ArrowField::new("f64", DataType::Float64, true),
        ArrowField::new("flag", DataType::Boolean, true),
        ArrowField::new("name", DataType::Utf8, true),
    ]));
    let cols: Vec<ArrayRef> = vec![
        Arc::new(Int32Array::from(i32s)),
        Arc::new(Int64Array::from(i64s)),
        Arc::new(Float64Array::from(f64s)),
        Arc::new(BooleanArray::from(bools)),
        Arc::new(StringArray::from_iter_values(names)),
    ];
    (RecordBatch::try_new(schema, cols).expect("valid batch"), sum)
}

// ---------------------------------------------------------------------------
// Writer (timed) and readers (timed)
// ---------------------------------------------------------------------------

/// Writer settings: uncompressed, dictionary off except for the string column(s).
fn writer_props(dict_col: Option<&str>) -> WriterProperties {
    let mut b = WriterProperties::builder()
        .set_compression(Compression::UNCOMPRESSED)
        .set_dictionary_enabled(false);
    if let Some(c) = dict_col {
        b = b.set_column_dictionary_enabled(ColumnPath::from(c), true);
    }
    b.build()
}

fn write_file(path: &Path, batch: &RecordBatch, props: &WriterProperties) -> Result<(), Box<dyn Error>> {
    let file = File::create(path)?;
    let mut w = ArrowWriter::try_new(file, batch.schema(), Some(props.clone()))?;
    w.write(batch)?;
    w.close()?;
    Ok(())
}

fn field_sum(f: &RecField) -> Result<u64, Box<dyn Error>> {
    Ok(match f {
        RecField::Null => 0,
        RecField::Int(v) => *v as i64 as u64,
        RecField::Long(v) => *v as u64,
        RecField::Double(v) => v.to_bits(),
        RecField::Str(s) => s.len() as u64,
        RecField::Bytes(b) => b.data().len() as u64,
        other => return Err(format!("unexpected row field {other:?}").into()),
    })
}

fn read_rows(path: &Path) -> Result<(usize, u64), Box<dyn Error>> {
    let reader = SerializedFileReader::new(File::open(path)?)?;
    let (mut n, mut sum) = (0usize, 0u64);
    for row in reader.get_row_iter(None)? {
        let row = row?;
        let (_, f) = row.get_column_iter().next().ok_or("row has no columns")?;
        sum = sum.wrapping_add(field_sum(f)?);
        n += 1;
    }
    Ok((n, sum))
}

fn arrow_sum(arr: &dyn Array) -> Result<u64, Box<dyn Error>> {
    let any = arr.as_any();
    if let Some(a) = any.downcast_ref::<Int32Array>() {
        Ok(a.iter().fold(0u64, |s, v| s.wrapping_add(v.map_or(0, |x| x as i64 as u64))))
    } else if let Some(a) = any.downcast_ref::<Int64Array>() {
        Ok(a.iter().fold(0u64, |s, v| s.wrapping_add(v.map_or(0, |x| x as u64))))
    } else if let Some(a) = any.downcast_ref::<Float64Array>() {
        Ok(a.iter().fold(0u64, |s, v| s.wrapping_add(v.map_or(0, |x| x.to_bits()))))
    } else if let Some(a) = any.downcast_ref::<StringArray>() {
        Ok(a.iter().fold(0u64, |s, v| s.wrapping_add(v.map_or(0, |x| x.len() as u64))))
    } else {
        Err(format!("unsupported column type {}", arr.data_type()).into())
    }
}

fn read_arrow(path: &Path) -> Result<(usize, u64), Box<dyn Error>> {
    let reader = ParquetRecordBatchReaderBuilder::try_new(File::open(path)?)?.build()?;
    let (mut n, mut sum) = (0usize, 0u64);
    for batch in reader {
        let batch = batch?;
        n += batch.num_rows();
        sum = sum.wrapping_add(arrow_sum(batch.column(0).as_ref())?);
    }
    Ok((n, sum))
}

/// Prints column encodings to stderr. Numeric columns must not be dictionary-encoded;
/// the string column of str_dict and mixed5 must be.
fn check_encodings(path: &Path, name: &str, dict_col: Option<&str>) -> Result<(), Box<dyn Error>> {
    let reader = SerializedFileReader::new(File::open(path)?)?;
    let md = reader.metadata();
    for col in md.row_group(0).columns() {
        let path_str = col.column_path().string();
        let encs: Vec<Encoding> = col.encodings().collect();
        eprintln!("  {name}.{path_str}: {encs:?}");
        let is_dict = encs
            .iter()
            .any(|e| matches!(e, Encoding::PLAIN_DICTIONARY | Encoding::RLE_DICTIONARY));
        if Some(path_str.as_str()) == dict_col {
            if matches!(name, "str_dict" | "mixed5") && !is_dict {
                return Err(format!("{name}.{path_str}: expected dictionary encoding").into());
            }
        } else if is_dict {
            return Err(format!("{name}.{path_str}: unexpected dictionary encoding").into());
        }
    }
    Ok(())
}

struct Scenario {
    name: &'static str,
    build: fn(usize) -> (RecordBatch, u64),
    dict_col: Option<&'static str>,
}

const SCENARIOS: [Scenario; 6] = [
    Scenario { name: "int64_plain", build: build_int64_plain, dict_col: None },
    Scenario { name: "f64_plain", build: build_f64_plain, dict_col: None },
    Scenario { name: "int64_nullable", build: build_int64_nullable, dict_col: None },
    Scenario { name: "str_dict", build: build_str_dict, dict_col: Some("s") },
    Scenario { name: "str_unique", build: build_str_unique, dict_col: Some("s") },
    Scenario { name: "mixed5", build: build_mixed5, dict_col: Some("name") },
];

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1e3
}

fn rows_per_s(rows: usize, d: Duration) -> f64 {
    rows as f64 / d.as_secs_f64()
}

fn run_scenario(sc: &Scenario, rows: usize, out_dir: &Path) -> Result<(), Box<dyn Error>> {
    let (batch, want) = (sc.build)(rows);
    let props = writer_props(sc.dict_col);
    let path = out_dir.join(format!("{}-{}.parquet", sc.name, std::process::id()));

    let (mut best_write, mut best_rows, mut best_arrow) = (Duration::MAX, Duration::MAX, Duration::MAX);
    for _ in 0..RUNS {
        let t = Instant::now();
        write_file(&path, &batch, &props)?;
        best_write = best_write.min(t.elapsed());

        // Untimed warm open, mirroring the Zig bench (Windows first-open stall).
        drop(File::open(&path)?);

        let t = Instant::now();
        let (n, sum) = read_rows(&path)?;
        best_rows = best_rows.min(t.elapsed());
        if n != rows {
            return Err(format!("{}: read_rows row count {n} != {rows}", sc.name).into());
        }
        if sum != want {
            return Err(format!("{}: read_rows checksum {sum} != {want}", sc.name).into());
        }

        let t = Instant::now();
        let (n, sum) = read_arrow(&path)?;
        best_arrow = best_arrow.min(t.elapsed());
        if n != rows {
            return Err(format!("{}: read_arrow row count {n} != {rows}", sc.name).into());
        }
        if sum != want {
            return Err(format!("{}: read_arrow checksum {sum} != {want}", sc.name).into());
        }
    }

    check_encodings(&path, sc.name, sc.dict_col)?;
    let size = fs::metadata(&path)?.len();
    fs::remove_file(&path)?;

    let mb = size as f64 / (1024.0 * 1024.0);
    println!(
        "{:<14} {:>9} {:>10.2} {:>16.0} {:>12.2} {:>15.0} {:>9.2} {:>13.2} {:>21.0}",
        sc.name,
        rows,
        ms(best_write),
        rows_per_s(rows, best_write),
        ms(best_rows),
        rows_per_s(rows, best_rows),
        mb,
        ms(best_arrow),
        rows_per_s(rows, best_arrow),
    );
    Ok(())
}

fn main() -> Result<(), Box<dyn Error>> {
    let rows: usize = match std::env::args().nth(1) {
        Some(s) => s.parse()?,
        None => DEFAULT_ROWS,
    };
    let out_dir: PathBuf = Path::new(env!("CARGO_MANIFEST_DIR")).join("target").join("bench-out");
    fs::create_dir_all(&out_dir)?;

    println!(
        "{:<14} {:>9} {:>10} {:>16} {:>12} {:>15} {:>9} {:>13} {:>21}",
        "scenario", "rows", "write_ms", "write_rows_per_s", "read_rows_ms", "read_rows_per_s", "file_MB", "read_arrow_ms", "read_arrow_rows_per_s"
    );
    for sc in &SCENARIOS {
        run_scenario(sc, rows, &out_dir)?;
    }
    Ok(())
}
