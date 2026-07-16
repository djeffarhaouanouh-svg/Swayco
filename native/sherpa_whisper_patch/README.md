# sherpa-onnx Whisper byte-fallback UTF-8 fix (v1.13.4)

Fixes silent character dropping in the on-device Whisper STT for every 3-byte
script whose characters get split across byte-fallback tokens: **Japanese,
Chinese, Korean, Hindi**. Latin / Arabic / Cyrillic are unaffected (1–2 byte,
whole-char tokens), so this patch is invisible to them.

## The bug

`Convert()` in `csrc/offline-recognizer-whisper-impl.h` assembles the text
**one token at a time**, calling `ApplyInverseTextNormalization(s)` on each
token before concatenating. `ApplyInverseTextNormalization`
(`csrc/offline-recognizer-impl.cc`) runs `RemoveInvalidUtf8Sequences()`
*unconditionally*.

A byte-fallback token is a single byte of a multi-byte UTF-8 character. On its
own it is **invalid UTF-8**, so `RemoveInvalidUtf8Sequences` deletes it — before
it can be joined with the other bytes of the same character. The character is
destroyed.

Measured drop rate (FLEURS, whisper-small int8, empty result tokens / total):

| script            | dropped | verdict |
|-------------------|---------|---------|
| Latin (fr)        | 0 %     | ok      |
| Arabic / Cyrillic | 0 %     | ok      |
| **Japanese**      | ~15 %   | broken  |
| **Korean**        | ~19 %   | broken  |
| **Hindi**         | ~34 %   | broken  |
| **Chinese**       | ~47 %   | broken  |

## The fix (`byte-fallback-utf8-v1.13.4.patch`, 1 file, 2 hunks)

Concatenate the **raw token bytes first**, then run
`ApplyInverseTextNormalization` + `ApplyHomophoneReplacer` **once on the
complete text**. Multi-byte characters are whole by then, so nothing is dropped.
Applied to both the main text loop and the `segment_texts` loop.

This is also the *correct* placement — inverse text normalisation is meant to
see the full string, not isolated tokens.

## Apply

Same mechanism as `../sherpa_ja_patch`. After cloning sherpa v1.13.4:

```sh
git -C sherpa-onnx apply .../sherpa_ja_patch/external-tokens-v1.13.4.patch
git -C sherpa-onnx apply .../sherpa_whisper_patch/byte-fallback-utf8-v1.13.4.patch
```

The macOS `setup.sh` and the iOS `SETUP.md` in the patched-plugin dirs apply
both. Independent hunks — order does not matter, they touch different files.
