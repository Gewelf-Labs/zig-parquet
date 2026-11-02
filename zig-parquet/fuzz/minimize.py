"""Shrink a zp-fuzz input while it keeps the same failure signature.

usage: python zig-parquet/fuzz/minimize.py <target> <in> <out> [--exe zig-parquet/zig-out/bin/zp-fuzz]
Signature = exit code + first output line containing "panic", "fuzz-" or "error:" (digits and the
candidate path are masked, so thread ids and temp names do not count as a change).
Build the exe first: make fuzz-install
"""
import argparse, os, re, subprocess, sys, time

TIMEOUT = 20
KEYS = ("panic", "fuzz-", "error:")


def main():
    ap = argparse.ArgumentParser(description="Minimize a zp-fuzz input")
    ap.add_argument("target")
    ap.add_argument("inp")
    ap.add_argument("out")
    ap.add_argument("--exe", default="zig-parquet/zig-out/bin/zp-fuzz")
    a = ap.parse_args()
    exe = os.path.abspath(a.exe + (".exe" if os.name == "nt" and not a.exe.endswith(".exe") else ""))
    if not os.path.exists(exe):
        sys.exit(f"missing {exe}: run make fuzz-install first")
    cand = os.path.join(os.path.dirname(os.path.abspath(a.out)), "minimize-cand.bin")
    runs = 0

    def signature(b):
        nonlocal runs
        runs += 1
        with open(cand, "wb") as f:
            f.write(b)
        try:
            p = subprocess.run([exe, a.target, "replay", os.path.abspath(cand)], capture_output=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            return None
        lines = (p.stdout + p.stderr).decode("utf-8", "replace").splitlines()
        line = next((ln for ln in lines if any(k in ln for k in KEYS)), "")
        return (p.returncode, re.sub(r"\d+", "#", line.replace(cand, "<cand>")).strip())

    try:
        with open(a.inp, "rb") as f:
            orig = data = f.read()
        want = signature(data)
        if want is None or want == (0, ""):
            sys.exit(f"input does not reproduce a failure (signature {want})")
        t0 = time.time()
        chunk = max(1, len(data) // 2)  # ddmin-lite: delete halving chunks, then single bytes
        while True:
            i = 0
            while i < len(data):
                trial = data[:i] + data[i + chunk:]
                if signature(trial) == want:
                    data = trial
                else:
                    i += chunk
            if chunk == 1:
                break
            chunk //= 2
        for i in range(len(data)):
            if data[i]:
                trial = data[:i] + b"\0" + data[i + 1:]
                if signature(trial) == want:
                    data = trial
        with open(a.out, "wb") as f:
            f.write(data)
        print(f"minimized {len(orig)} -> {len(data)} bytes in {time.time() - t0:.1f}s ({runs} runs)")
        print(f"signature: exit {want[0]}: {want[1]}")
    finally:
        if os.path.exists(cand):
            os.remove(cand)


if __name__ == "__main__":
    main()
