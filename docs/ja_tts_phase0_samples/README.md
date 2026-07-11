# Phase 0 — Japanese TTS validation samples

Gate output for `docs/ja_tts_engine_plan.md` **Phase 0**. Generated on desktop with
plain `onnxruntime` from `MiaoMint/MeloTTS-ONNX` `onnx_exports/ja/model.onnx`
(44.1 kHz, `sid=0`, `noise_scale=0.6`, `noise_scale_w=0.8`, `length_scale=1.0`).

g2p reproduces MeloTTS `melo/text/japanese.py`: `text_normalize`
(NFKC → num2words → keep-japanese → **pykakasi** kanji→katakana) → `g2p`
(Tohoku BERT tokenizer word boundaries → `kata2phoneme`), tones all 0, `tone_start=6`,
`add_blank=1`. BERT is absent from the export (inputs already dropped).

## Samples

| file | text | reading produced (kakasi frontend) | verdict |
|---|---|---|---|
| out_01_hajimemashite | はじめまして、よろしくお願いします。 | お願い→オネガイ | OK |
| out_02_konnichiwa | こんにちは。今日は元気ですか？ | 今日は→**コンニチハ** (want キョウワ) | ❌ reading |
| out_03_kinou_ryouri | 昨日、友達と美味しい料理を食べました。 | キノウ / オイシイ / リョウリ | OK |
| out_04_apuri_long | 初めてこのアプリを使ったけど、色々な国の人と話せて楽しいです。 | 色々→**イロ**, 人→**ニン** (want イロイロ / ヒト) | ❌ reading |
| out_05_name_toma | 私の名前はトマです。あなたのお名前は？ | ナマエ / トマ | OK |
| out_06_name_sara | サラさん、とても優しいですね。 | サラ / ヤサシイ | OK |
| out_07_ashita_3ji | 明日の3時に電話しますね。 | 3時→サンジ | OK |
| out_08_year_2026 | 2026年7月に日本へ行きます。 | ニセンニジュウロクネン / シチガツ | OK |
| out_09_15fun | 待ち合わせは15分後でいいですか？ | 15分→ジュウゴフン | OK |
| out_10_shokuji | よかったら、今度一緒に食事でもどうですか？ | コンド / イッショ / ショクジ | OK |

## Finding

Model quality is good; the **kakasi frontend mis-reads context-dependent kanji**
(今日, 人, 々). `pyopenjtalk`/OpenJTalk reads all of them correctly
(今日は→キョーワ, 色々な国の人→イロイロナクニノヒト). → The native frontend
(plan Phase 1) should use **OpenJTalk for the kanji→kana reading**, then the same
deterministic `kata2phoneme` table. Pitch-accent extraction is **not** needed
(tones are all 0), so Phase 1 is simpler than the plan first assumed.
