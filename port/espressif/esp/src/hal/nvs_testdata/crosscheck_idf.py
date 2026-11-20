#!/usr/bin/env python3
"""Check that ESP-IDF's own NVS code reads every crash state of this store's writer.

Usage: python3 <absolute-script-path> <absolute-esp-idf-checkout> [zig]

Runs `zig build test -Dnvs-crash-dump=<file>` in the port directory, which
makes nvs_crash_test.zig write every image its exhaustive crash replay checks,
before and after this store's recovery, with the values allowed there. Then
compiles crosscheck_idf.cpp with unmodified ESP-IDF Storage, PageManager and
Page code and boots ESP-IDF on each image. Exits non-zero if ESP-IDF reads any
value the dump does not allow. Needs a host C++17 compiler; ESP-IDF is only
read. The zig build test gate does not run this script.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

from generate_fixtures import compile_idf_program


def main():
    if len(sys.argv) not in (2, 3):
        raise SystemExit(__doc__)
    idf = Path(sys.argv[1]).resolve(strict=True)
    zig = sys.argv[2] if len(sys.argv) == 3 else "zig"
    here = Path(__file__).resolve().parent
    port = here.parents[2]
    cache = port / ".zig-cache"
    cache.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="idf-crosscheck-", dir=cache) as temp:
        build = Path(temp)
        dump = build / "crash_images.bin"
        subprocess.run([zig, "build", "test", "-Dnvs-crash-dump=" + str(dump)], cwd=port, check=True)
        # As on a target: no host-only Storage::debugCheck after every write.
        exe = compile_idf_program(idf, build, here / "crosscheck_idf.cpp", True, ["NO_DEBUG_STORAGE"])
        result = subprocess.run([str(exe), str(dump)])
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
