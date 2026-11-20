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
cp transcription/CREDITS.txt "$app/Contents/Resources/"
codesign --force --sign - "$app/Contents/Helpers/meeting-transcriber"
codesign --force --sign - "$app/Contents/Frameworks/libonnxruntime.dylib"
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$target" Sources/*.swift -o "$app/Contents/MacOS/MeetingRecorder"
cp Info.plist "$app/Contents/Info.plist"
cp ../../LICENSE "$app/Contents/Resources/LICENSE"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict --verbose=2 "$app"
ditto -c -k --keepParent "$app" "$out/Meeting-Recorder-macOS-arm64.zip"
