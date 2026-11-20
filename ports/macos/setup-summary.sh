#!/bin/bash
set -euo pipefail
if ! command -v llama-completion >/dev/null; then
    brew install llama.cpp
fi
dir="$HOME/Library/Application Support/Meeting Recorder/Models"
name="Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
digest="3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597"
mkdir -p "$dir"
cd "$dir"
if test -f "$name" && printf '%s  %s\n' "$digest" "$name" | shasum -a 256 -c -; then
    exit 0
fi
temp=$(mktemp .qwen-download.XXXXXX)
trap 'rm -f "$temp"' EXIT
curl -fLsS --retry 2 "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/$name" -o "$temp"
printf '%s  %s\n' "$digest" "$temp" | shasum -a 256 -c -
mv "$temp" "$name"
