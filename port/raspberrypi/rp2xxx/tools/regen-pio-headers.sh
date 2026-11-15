#!/usr/bin/env bash
# Regenerate the committed comparison oracle with pico-sdk 2.1.1 pioasm.
set -euo pipefail
port=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
check=false
corpus_only=false
for argument in "$@"; do
    case $argument in
        --check) check=true ;;
        --corpus) corpus_only=true ;;
        *) echo "Usage: $0 [--check] [--corpus]" >&2; exit 2 ;;
    esac
done
sdk=
for candidate in "$port"/zig-pkg/*; do
    if [[ -f "$candidate/tools/pioasm/parser.yy" ]]; then
        sdk=$candidate
        break
    fi
done
if [[ -z "$sdk" ]]; then
    echo "pico-sdk is missing from $port/zig-pkg; run zig build first" >&2
    exit 1
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/microzig-pioasm.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
cmake -S "$sdk/tools/pioasm" -B "$scratch/build" -DCMAKE_BUILD_TYPE=Release '-DCMAKE_CXX_FLAGS=-include cstdint'
cmake --build "$scratch/build" --parallel
fixtures="$port/src/hal/pio/assembler/comparison_tests"
status=0
if ! "$corpus_only"; then
    for source in "$fixtures"/*.pio; do
        name=$(basename -- "$source")
        version=0
        case $name in irq.pio|movrx.pio|config_v1.pio) version=1 ;; esac
        "$scratch/build/pioasm" -v "$version" -o c-sdk "$source" "$scratch/$name.h"
        if "$check"; then
            if ! diff -u -- "$source.h" "$scratch/$name.h"; then status=1; fi
        else
            cp -- "$scratch/$name.h" "$source.h"
        fi
    done
fi
assembler="$port/src/hal/pio/assembler"
python3 "$port/tools/pio-corpus.py" "$scratch/build/pioasm" "$assembler/corpus.json" "$scratch/corpus_expected.zig" "$sdk/tools/pioasm/lexer.ll"
zig fmt "$scratch/corpus_expected.zig" >/dev/null
if "$check"; then
    if ! diff -u -- "$assembler/corpus_expected.zig" "$scratch/corpus_expected.zig"; then status=1; fi
else
    cp -- "$scratch/corpus_expected.zig" "$assembler/corpus_expected.zig"
fi
exit "$status"
