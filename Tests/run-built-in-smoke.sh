#!/bin/bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [LOCAL_GGUF_PATH]" >&2
    exit 2
fi

project="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
build_dir="${project}/.build/runtime-smoke"
fixture="${1:-${project}/vendor/stories260K.gguf}"
if [[ $# -eq 0 ]]; then
    if [[ ! -f "$fixture" ]]; then
        echo "Pass a local GGUF path or fetch the tiny test-only fixture at:" >&2
        echo "https://huggingface.co/ggml-org/models-moved/resolve/499bc88/tinyllamas/stories260K.gguf" >&2
        exit 1
    fi
    result="$(shasum -a 256 < "$fixture")"
    if [[ "${result%% *}" != "270cba1bd5109f42d03350f60406024560464db173c0e387d91f0426d3bd256d" ]]; then
        echo "SHA-256 mismatch for $fixture" >&2
        exit 1
    fi
fi

slice="$("${project}/vendor/prepare-llama.sh" "$build_dir")"
target=arm64-apple-macosx14.0
xcrun clang -target "$target" -std=c11 -Wall -Wextra -Werror -O2 \
    -I "${slice}/llama.framework/Headers" -c "${project}/Sources/BuiltInBridge.c" \
    -o "${build_dir}/BuiltInBridge.o"
xcrun swiftc -parse-as-library -swift-version 6 -target "$target" \
    -module-cache-path "${build_dir}/ModuleCache" \
    -import-objc-header "${project}/Sources/BuiltInBridge.h" \
    "${project}/Sources/BuiltInEngine.swift" "${project}/Tests/BuiltInEngineSmoke.swift" \
    "${build_dir}/BuiltInBridge.o" -F "$slice" -framework llama \
    -Xlinker -rpath -Xlinker "$slice" -o "${build_dir}/builtin-smoke"
"${build_dir}/builtin-smoke" "$fixture"
