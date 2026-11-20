#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
out="${1:-../../dist/macos}"
app="$out/Meeting Recorder.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
export MACOSX_DEPLOYMENT_TARGET=13.0
target=arm64-apple-macos13.0
mkdir -p "$app/Contents/Helpers" "$app/Contents/Frameworks"
cargo build --manifest-path transcription/Cargo.toml --target aarch64-apple-darwin --release --locked
cp transcription/target/aarch64-apple-darwin/release/meeting-transcriber "$app/Contents/Helpers/"
python3 transcription/bundle-runtime.py "$app/Contents"
python3 azure-live/bundle.py "$app/Contents"
cp transcription/CREDITS.txt "$app/Contents/Resources/"
codesign --force --sign - "$app/Contents/Helpers/meeting-transcriber"
codesign --force --sign - "$app/Contents/Frameworks/libonnxruntime.dylib"
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$target" Sources/*.swift -o "$app/Contents/MacOS/MeetingRecorder"
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$target" Sources/MeetingSummary.swift Tools/Summarize.swift -o "$app/Contents/Helpers/meeting-summary"
codesign --force --sign - "$app/Contents/Helpers/meeting-summary"
cp Info.plist "$app/Contents/Info.plist"
cp ../../LICENSE "$app/Contents/Resources/LICENSE"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict --verbose=2 "$app"
ditto -c -k --keepParent "$app" "$out/Meeting-Recorder-macOS-arm64.zip"

# Finder copies the same bundle name from the mounted volume on each update.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Meeting Recorder.app"
ln -s /Applications "$stage/Applications"
hdiutil create -ov -format UDZO -volname "Meeting Recorder" -srcfolder "$stage" "$out/Meeting-Recorder-macOS-arm64.dmg"
hdiutil verify "$out/Meeting-Recorder-macOS-arm64.dmg"
