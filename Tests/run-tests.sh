#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
build="$PWD/build"
cache="$build/module-cache"
mkdir -p "$cache"
scratch="$(mktemp -d "$build/tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

swift=(xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0 -module-cache-path "$cache")
"${swift[@]}" Sources/CheckCore.swift Tests/CoreTests.swift -o "$scratch/core"
"$scratch/core"
"${swift[@]}" Sources/{CheckCore,EvidenceReview}.swift Tests/EvidenceReviewTests.swift -o "$scratch/evidence"
"${swift[@]}" Sources/EvidenceWeb.swift Tests/EvidenceWebTests.swift -o "$scratch/evidence-web"
"$scratch/evidence-web"
"$scratch/evidence"
"${swift[@]}" Sources/ModelStore.swift Tests/ModelStoreTests.swift -o "$scratch/storage"
"$scratch/storage" "$scratch/files"
"${swift[@]}" Sources/CheckCore.swift Sources/ModelStore.swift Sources/AppState.swift Sources/EvidenceReview.swift Sources/EvidenceWeb.swift Tests/StateTests.swift -o "$scratch/state"
mkdir "$scratch/preferences"
CFFIXED_USER_HOME="$scratch/preferences" "$scratch/state" "$scratch/state-files"
"${swift[@]}" -D OLLAMA_TESTS Sources/OllamaEngine.swift Tests/OllamaTests.swift -o "$scratch/ollama"
"$scratch/ollama"
"${swift[@]}" Sources/BetaDiagnostics.swift Tests/DiagnosticsTests.swift -o "$scratch/diagnostics"
"$scratch/diagnostics"
