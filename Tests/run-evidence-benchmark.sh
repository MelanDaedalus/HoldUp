#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
fixtures=Tests/evidence-benchmark.json
if [[ "${1:-}" == "--holdout" ]]; then
    fixtures=Tests/evidence-scope-holdout.json
    shift
fi
mkdir -p build/module-cache
swift=(xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0 -module-cache-path build/module-cache
    Sources/CheckCore.swift Sources/EvidenceReview.swift Tests/EvidenceBenchmark.swift)
if [[ "${1:-}" == "--built-in" ]]; then
    shift
    if [[ $# -eq 0 || ! -f "$1" ]]; then
        printf 'Pass the installed model file with --built-in /path/to/model.gguf.\n' >&2
        exit 2
    fi
    framework="$(bash vendor/prepare-llama.sh "$PWD/build/runtime")"
    xcrun clang -target arm64-apple-macosx14.0 -std=c11 -O2 -Wall -Wextra -Werror \
        -I "$framework/llama.framework/Headers" -c Sources/BuiltInBridge.c -o build/BenchmarkBridge.o
    "${swift[@]}" -D BUILT_IN_EVIDENCE_BENCHMARK Sources/BuiltInEngine.swift -import-objc-header Sources/BuiltInBridge.h \
        build/BenchmarkBridge.o -F "$framework" -framework llama -Xlinker -rpath -Xlinker "$framework" \
        -o build/evidence-benchmark-builtin
    exec build/evidence-benchmark-builtin "$fixtures" "$@"
fi
"${swift[@]}" Sources/OllamaEngine.swift -o build/evidence-benchmark
exec build/evidence-benchmark "$fixtures" "$@"
