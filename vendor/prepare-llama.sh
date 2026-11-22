#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 BUILD_DIRECTORY" >&2
    exit 2
fi

# ggml-org/llama.cpp release b12248, commit 3837bf0bc02ea5d08f8ee3585fc8c7784a81bce8.
# Digest from https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/b12248.
version=b12248
asset="llama-${version}-xcframework.zip"
url="https://github.com/ggml-org/llama.cpp/releases/download/${version}/${asset}"
sha256="fe38916b41f2a144115db39df860cb2f6f98a476589d5072b0cc3f51dbaf8c10"
slice="build-apple/llama.xcframework/macos-arm64_x86_64"

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
mkdir -p -- "$1"
build_dir="$(cd -- "$1" && pwd -P)"
archive="${script_dir}/${asset}"
download=""
extract_dir=""

cleanup() {
    if [[ -n "$download" ]]; then
        rm -f -- "$download"
    fi
    if [[ -n "$extract_dir" ]]; then
        rm -rf -- "$extract_dir"
    fi
}
trap cleanup EXIT

verify_archive() {
    local result
    result="$(shasum -a 256 < "$1")"
    if [[ "${result%% *}" != "$sha256" ]]; then
        echo "SHA-256 mismatch for $1" >&2
        exit 1
    fi
}

if [[ ! -f "$archive" ]]; then
    archive="${build_dir}/${asset}"
    if [[ ! -f "$archive" ]]; then
        download="$(mktemp "${build_dir}/.llama-download.XXXXXXXX")"
        curl --fail --location --silent --show-error --retry 2 \
            --proto '=https' --proto-redir '=https' --output "$download" "$url"
        verify_archive "$download"
        mv -f -- "$download" "$archive"
        download=""
    fi
fi
verify_archive "$archive"

extract_dir="$(mktemp -d "${build_dir}/llama-${version}.XXXXXXXX")"
unzip -q "$archive" "${slice}/llama.framework/*" -d "$extract_dir"
framework_slice="${extract_dir}/${slice}"
test -f "${framework_slice}/llama.framework/Headers/llama.h"
test -f "${framework_slice}/llama.framework/llama"
printf '%s\n' "$framework_slice"
extract_dir=""
