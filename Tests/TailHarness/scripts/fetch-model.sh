#!/bin/bash
# Fetches the WhisperKit model the app ships and its tokenizer into <dir> with curl, in the layout WhisperKit expects.
set -euo pipefail
dir="${1:?usage: fetch-model.sh <models-dir>}"
variant="openai_whisper-large-v3-v20240930_626MB"
repo="https://huggingface.co/argmaxinc/whisperkit-coreml"
base="$dir/models/argmaxinc/whisperkit-coreml"
mkdir -p "$base"
curl -fsS "https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/main/$variant?recursive=true" \
  | python3 -I -c 'import json,sys; [print(e["path"]) for e in json.load(sys.stdin) if e["type"]=="file"]' \
  | while read -r path; do
      mkdir -p "$base/$(dirname "$path")"
      curl -fsSL -C - --retry 5 -o "$base/$path" "$repo/resolve/main/$path"
    done
tok="$dir/models/openai/whisper-large-v3"
mkdir -p "$tok"
for f in tokenizer.json tokenizer_config.json config.json; do
  curl -fsSL -o "$tok/$f" "https://huggingface.co/openai/whisper-large-v3/resolve/main/$f"
done
