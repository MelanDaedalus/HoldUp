#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
project="$PWD"
build="$project/build"
cache="$build/module-cache"
mkdir -p "$cache"
stage="$(mktemp -d "$build/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

app="$stage/Hold UP.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Resources"
framework="$(bash vendor/prepare-llama.sh "$build/runtime")"

xcrun clang -target arm64-apple-macosx14.0 -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$framework/llama.framework/Headers" -c Sources/BuiltInBridge.c -o "$stage/BuiltInBridge.o"

xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0 -O -module-cache-path "$cache" \
    -module-name ClaimCheck -import-objc-header Sources/BuiltInBridge.h "$stage/BuiltInBridge.o" \
    -F "$framework" -framework llama -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/*.swift -o "$contents/MacOS/ClaimCheck"

xcrun swiftc -module-cache-path "$cache" Resources/MakeIcon.swift -o "$stage/make-icon"
"$stage/make-icon" "$contents/Resources/ClaimCheck.icns"
cp Resources/Info.plist "$contents/"
cp Resources/llama.cpp-LICENSE.txt Resources/Qwen3-LICENSE.txt "$contents/Resources/"
ditto "$framework/llama.framework" "$contents/Frameworks/llama.framework"
codesign --force --sign - --timestamp=none "$contents/Frameworks/llama.framework"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
plutil -lint "$contents/Info.plist"

destination="$build/Hold UP.app"
if [ -e "$destination" ]; then
    mv "$destination" "$stage/Previous.app"
fi
mv "$app" "$destination"
printf '%s\n' "$destination"
