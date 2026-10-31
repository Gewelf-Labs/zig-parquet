.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory

LIB_DIR := zig-parquet
CLI_DIR := cli
EXAMPLES_DIR := $(LIB_DIR)/examples

# Toolchain: make <target> ZIG=/path/to/zig   (0.16.x and 0.17.x are supported)
ZIG ?= zig
ZIG_VERSION := $(shell $(ZIG) version)
# Non-0.16 toolchains use their own local cache under <repo>/.zig17 (gitignored).
# $(1) = path from the recipe's working directory back to the repo root.
zcache = $(if $(filter 0.16.%,$(ZIG_VERSION)),,--cache-dir $(1)/.zig17/cache)

# Parameterize builds: `make lib CODECS=c-brotli OPT=ReleaseSmall`
CODECS ?=
OPT ?=
NAME ?=
CODEC_FLAG := $(if $(CODECS),-Dcodecs=$(CODECS))
OPT_FLAG := $(if $(OPT),-Doptimize=$(OPT))

.PHONY: help
help:
	echo "Run from repo root — never cd into subdirs."
	echo ""
	echo "Toolchain: ZIG=<path to zig> (default: zig on PATH; 0.16.x and 0.17.x supported)"
	echo ""
	echo "Targets (all accept CODECS=<spec> OPT=<ReleaseSmall|ReleaseFast|...> ZIG=<zig>):"
	echo "  make build             Build library + CLI"
	echo "  make lib               Build library (honors CODECS, OPT)"
	echo "  make cli               Build pqi CLI (honors CODECS, OPT)"
	echo "  make test              Library + CLI tests (honors CODECS, OPT)"
	echo "  make test-lib          Library tests only (honors CODECS, OPT)"
	echo "  make test-cli          CLI tests only (honors CODECS, OPT)"
	echo "  make example NAME=...  Build an example (honors CODECS, OPT)"
	echo "  make wasm              Verify WASM targets compile and link (no C codecs unless CODECS is set)"
	echo "  make bench             Run the benchmark harness (ReleaseFast, zig-only codecs by default)"
	echo "  make validate-wild     Validate pqi against wild files (failures only)"
	echo "  make validate-wild-all Validate pqi against wild files (show all)"
	echo "  make fmt               zig fmt across sources (requires ZIG=<0.16 zig>)"
	echo "  make clean             Remove .zig-cache and zig-out everywhere"
	echo ""
	echo "Examples:"
	echo "  make test CODECS=zig-only"
	echo "  make test CODECS=c-zstd,zstd"
	echo "  make lib CODECS=c-brotli OPT=ReleaseSmall"
	echo "  make lib CODECS=none OPT=ReleaseSmall"
	echo "  make example NAME=basic"
	echo "  make example NAME=wasm_demo OPT=ReleaseSmall"
	echo "  make test-lib CODECS=zig-only ZIG=C:/tools/zig-0.16.0/zig.exe"
	echo ""
	echo "Examples (NAME=): basic, gen-power-grid, large_file,"
	echo "                  wasm_demo, wasm_freestanding"
	echo ""
	echo "CODECS values: all (default), none, zig-only, c-only,"
	echo "  or comma list of: zstd|snappy|gzip|lz4|brotli (Zig)"
	echo "                    c-zstd|c-snappy|c-gzip|c-lz4|c-brotli (C/C++)"

.PHONY: build
build: lib cli

.PHONY: lib
lib:
	cd $(LIB_DIR) && $(ZIG) build $(call zcache,..) $(CODEC_FLAG) $(OPT_FLAG)

.PHONY: cli
cli:
	cd $(CLI_DIR) && $(ZIG) build $(call zcache,..) $(CODEC_FLAG) $(OPT_FLAG)

.PHONY: test
test: test-lib test-cli

.PHONY: test-lib
test-lib:
	cd $(LIB_DIR) && $(ZIG) build test $(call zcache,..) $(CODEC_FLAG) $(OPT_FLAG)

.PHONY: test-cli
test-cli:
	cd $(CLI_DIR) && $(ZIG) build test $(call zcache,..) $(CODEC_FLAG) $(OPT_FLAG)

.PHONY: example
example:
	@test -n "$(NAME)" || { echo "usage: make example NAME=<basic|gen-power-grid|large_file|wasm_demo|wasm_freestanding>"; exit 1; }
	@test -d $(EXAMPLES_DIR)/$(NAME) || { echo "no such example: $(NAME)"; ls $(EXAMPLES_DIR); exit 1; }
	cd $(EXAMPLES_DIR)/$(NAME) && $(ZIG) build $(call zcache,../../..) $(CODEC_FLAG) $(OPT_FLAG)

.PHONY: wasm
wasm:
	cd $(LIB_DIR) && $(ZIG) build wasm-smoke $(call zcache,..) $(if $(CODECS),$(CODEC_FLAG),-Dcodecs=none)

.PHONY: bench
bench:
	cd $(LIB_DIR) && $(ZIG) build bench $(call zcache,..) -Dcodecs=$(or $(CODECS),zig-only) -Doptimize=ReleaseFast

.PHONY: validate-wild
validate-wild: cli
	cd $(CLI_DIR) && ./validate-wild.sh

.PHONY: validate-wild-all
validate-wild-all: cli
	cd $(CLI_DIR) && ./validate-wild.sh --all

.PHONY: fmt
fmt:
	@case "$(ZIG_VERSION)" in 0.16.*) ;; *) echo "make fmt needs Zig 0.16 (0.17 fmt emits 0.17-only builtins): make fmt ZIG=<0.16 zig>"; exit 1;; esac
	$(ZIG) fmt $(LIB_DIR)/src $(LIB_DIR)/build.zig $(LIB_DIR)/bench $(CLI_DIR)/src $(CLI_DIR)/build.zig

.PHONY: clean
clean:
	rm -rf $(LIB_DIR)/.zig-cache $(LIB_DIR)/zig-out
	rm -rf $(CLI_DIR)/.zig-cache $(CLI_DIR)/zig-out
	rm -rf $(EXAMPLES_DIR)/*/.zig-cache $(EXAMPLES_DIR)/*/zig-out
