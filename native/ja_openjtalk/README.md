# ja_openjtalk — native OpenJTalk reading frontend

Turns arbitrary Japanese text into a **katakana reading** for the on-device
Japanese voice (see `docs/ja_tts_engine_plan.md`). This is the native half of the
ja frontend; its output feeds the pure-Dart phonemizer
(`lib/swayco/speech/ja_phonemizer.dart`: `expandChoonpu` → `phonemizeKatakana`)
which produces the MeloTTS-ONNX ja model's token/tone tensors.

Equivalent to `pyopenjtalk.g2p(text, kana=True)` — verified matching on 13/15
phrases (the 2 diffs are only 、 vs 。, immaterial after phonemisation). It fixes
the context-kanji mis-reads that kakasi (MeloTTS's default) makes: 今日→キョウ (not
コンニチ), 人→ヒト (not ニン), 々 kept.

## Why only the *reading*
The model needs no pitch accent (JP tones are all 0, `tone_start=6`), so we run
only OpenJTalk's mecab + NJD frontend and concatenate each node's `pron`
(stripping the U+2019 accent mark). No HTS voice, no synthesis — the lib is
~1.2 MB and links no ONNX Runtime, so it can't clash with sherpa's single ORT.

## C API (`src/ja_frontend.h`)
```c
void *ja_frontend_create(const char *dict_dir);   // open_jtalk_dic_utf_8-1.11
char *ja_frontend_kana(void *h, const char *utf8); // -> malloc'd katakana
void  ja_frontend_free(char *s);
void  ja_frontend_destroy(void *h);
```
Dart FFI binding: `lib/swayco/speech/ja_openjtalk_ffi.dart`.

## Build
- **macOS (dev/verify):** `CMAKE="cmake" bash build_macos.sh` →
  `build/macos/libja_openjtalk.dylib`. Verify end-to-end with
  `dart run tool/verify_ja_openjtalk.dart build/macos/libja_openjtalk.dylib <dictDir> test/data/ja_tokens.txt`.
- **iOS / Android:** same two static deps (r9y9 `hts_engine_API` + `open_jtalk`,
  utf8 charset) cross-compiled with the platform toolchain, our `src/ja_frontend.c`
  on top. TODO — the app-side packaging (podspec / CMake + dict download) is M4.

`deps/` (fetched sources) and `build/` are git-ignored.

## Dictionary
`open_jtalk_dic_utf_8-1.11` (~23 MB compressed) is downloaded on demand next to
the model bundle, NOT shipped in the binary.
