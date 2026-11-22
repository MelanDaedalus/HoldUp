#!/bin/bash
set -euo pipefail

usage() {
    printf 'Usage: %s [--local-test] APP_BUNDLE OUTPUT_DIR\n' "$0"
    printf 'Distribution mode uses CLAIM_CHECK_SIGN_IDENTITY and CLAIM_CHECK_NOTARY_PROFILE.\n'
}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

local_test=false
case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --local-test) local_test=true; shift ;;
esac
if [[ $# -ne 2 ]]; then
    usage >&2
    exit 2
fi

if ! "$local_test"; then
    [[ -n "${CLAIM_CHECK_SIGN_IDENTITY:-}" ]] || fail 'Set CLAIM_CHECK_SIGN_IDENTITY to an installed Developer ID Application signing identity.'
    [[ -n "${CLAIM_CHECK_NOTARY_PROFILE:-}" ]] || fail 'Set CLAIM_CHECK_NOTARY_PROFILE to a notarytool profile stored in Keychain.'
fi

app="${1%/}"
[[ "$app" == *.app && -d "$app" ]] || fail 'Pass the path to the built Hold UP .app bundle.'
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail 'The app bundle must have a numeric version such as 0.4.9.'
binary="$app/Contents/MacOS/ClaimCheck"
[[ -x "$binary" ]] || fail 'The bundle is missing its ClaimCheck executable.'
[[ "$(xcrun lipo -archs "$binary")" == arm64 ]] || fail 'This package targets Apple Silicon and requires an arm64 app build.'
/usr/bin/codesign --verify --deep --strict "$app"

filename="Hold-UP-$version-macOS-arm64"
if "$local_test"; then filename="$filename-local-test"; fi

mkdir -p -- "$2"
output_dir="$(cd -- "$2" >/dev/null && pwd -P)"
output="$output_dir/$filename.dmg"
[[ ! -e "$output" && ! -L "$output" ]] || fail "Move the existing image before packaging again: $output"

stage="$(mktemp -d "$output_dir/.hold-up-dmg.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
payload="$stage/payload"
staged_app="$payload/Hold UP.app"
image="$stage/$filename.dmg"
mkdir "$payload"
/usr/bin/ditto "$app" "$staged_app"
ln -s /Applications "$payload/Applications"

if ! "$local_test"; then
    identity="$CLAIM_CHECK_SIGN_IDENTITY"
    /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$staged_app/Contents/Frameworks/llama.framework"
    /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$staged_app"
    signing_details="$(/usr/bin/codesign --display --verbose=4 "$staged_app" 2>&1)"
    /usr/bin/grep -q '^Authority=Developer ID Application:' <<< "$signing_details" \
        || fail 'Distribution mode requires a Developer ID Application certificate.'
fi
/usr/bin/codesign --verify --deep --strict "$staged_app"

/usr/bin/hdiutil create -srcfolder "$payload" -volname 'Hold UP' -format UDZO "$image"
if ! "$local_test"; then
    /usr/bin/codesign --timestamp --sign "$identity" "$image"
    receipt="$stage/notary-receipt.json"
    xcrun notarytool submit "$image" --keychain-profile "$CLAIM_CHECK_NOTARY_PROFILE" --wait --output-format json > "$receipt"
    status="$(/usr/bin/plutil -extract status raw "$receipt")"
    if [[ "$status" != Accepted ]]; then
        submission="$(/usr/bin/plutil -extract id raw "$receipt")"
        fail "Apple notarization returned $status for submission $submission. Check the notarytool log for this submission."
    fi
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
    /usr/bin/codesign --verify --strict "$image"
fi
/usr/bin/hdiutil verify "$image"

mv -n -- "$image" "$output"
[[ ! -e "$image" ]] || fail "The output already exists: $output"
if "$local_test"; then
    printf 'Local-test image. Apple notarization was skipped.\n'
fi
printf '%s\n' "$output"
