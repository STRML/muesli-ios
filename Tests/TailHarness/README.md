# Tail harness

Measures the "Thank you." Whisper adds after the last word, with the real WhisperKit model on a Mac. Not run in CI:
it needs the 626 MB `large-v3-v20240930_626MB` model (the one the app ships) and `say`.

Fixtures are generated, never committed: macOS `say` speech (3 voices, 8 short phrases, "Thank you", 3 paragraphs of
7 to 12 s) normalised to a phone-microphone level, followed by one of: nothing, 0.3 / 1 / 2 / 4 s of digital silence,
3 s of room tone at -50 or -40 dBFS, or a 15 ms key tap in silence. Plus clips of pure silence and pure room tone.

```sh
cd Tests/TailHarness
# the model and tokenizer: scripts/fetch-model.sh <dir> (curl; WhisperKit's own Hub listing times out on some networks)
swift build -c release -Xswiftc -enable-testing --scratch-path $TMPDIR/tail-build
$TMPDIR/tail-build/release/tail-harness generate $TMPDIR/fixtures
$TMPDIR/tail-build/release/tail-harness run --fixtures $TMPDIR/fixtures --models ~/.cache/muesli-ios-harness \
    --out results.jsonl --settings default,suppressBlank,strict --prep none,trim,guard
$TMPDIR/tail-build/release/tail-harness report results.jsonl
```

`--prep`: `none` is the app before the guard, `trim` trims silence only, `filter` runs the post-filter on untrimmed
audio, `guard` is both (what ships). `--settings` are WhisperKit `DecodingOptions` variants, `default` being what the
app passes (`transcribe(audioPath:)` with no options). The two kits are symlinks to the app's own sources.
