using Workerd = import "/workerd/workerd.capnp";

# Built by run-workerd.mjs into dist/ (worker.js + the two .wasm files).
const config :Workerd.Config = (
  services = [
    (name = "main", worker = (
      modules = [
        (name = "worker.js", esModule = embed "dist/worker.js"),
        (name = "zpbench.wasm", wasm = embed "dist/zpbench.wasm"),
        (name = "parquet_wasm_bg.wasm", wasm = embed "dist/parquet_wasm_bg.wasm"),
      ],
      compatibilityDate = "2026-10-01",
    )),
  ],
  sockets = [
    (name = "http", address = "127.0.0.1:8791", http = (), service = "main"),
  ],
);
