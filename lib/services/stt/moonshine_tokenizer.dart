import 'dart:convert';
import 'dart:io';

/// Decode-only detokenizer for Moonshine, built from the `tokenizer.json`
/// shipped alongside the ONNX graphs.
///
/// We never encode — the model consumes audio, not text — so only the
/// id → piece direction is needed.
///
/// Moonshine uses a SentencePiece-style BPE (`tokenizer.json` declares the
/// decoder sequence Replace(`▁` → space) → ByteFallback → Fuse → Strip):
/// - `▁` prefixes a word boundary;
/// - any character the vocabulary lacks was split into `<0xNN>` byte tokens,
///   which must be concatenated and decoded as UTF-8 together. This is how
///   Japanese, Chinese, Korean and Arabic text survives a 32 k Latin-ish
///   vocabulary, so the fusing is not optional.
///
/// It is *not* GPT-2 byte-level BPE, despite a lone `Ġ` sitting in the vocab.
class MoonshineTokenizer {
  MoonshineTokenizer._(this._pieces, this._specialIds);

  final List<String> _pieces;
  final Set<int> _specialIds;

  static final _byteToken = RegExp(r'^<0x([0-9A-Fa-f]{2})>$');

  static Future<MoonshineTokenizer> load(String tokenizerJsonPath) async {
    final json = jsonDecode(await File(tokenizerJsonPath).readAsString())
        as Map<String, dynamic>;

    final vocab = (json['model'] as Map<String, dynamic>)['vocab']
        as Map<String, dynamic>;
    var maxId = 0;
    for (final id in vocab.values) {
      if (id is int && id > maxId) maxId = id;
    }
    final pieces = List<String>.filled(maxId + 1, '');
    for (final e in vocab.entries) {
      final id = e.value;
      if (id is int && id >= 0) pieces[id] = e.key;
    }

    // Special tokens (<unk>, <s>, </s>, <<ST_n>>) must not reach the transcript.
    final specials = <int>{};
    for (final t in (json['added_tokens'] as List? ?? const [])) {
      final m = t as Map<String, dynamic>;
      if (m['special'] == true) specials.add(m['id'] as int);
    }

    return MoonshineTokenizer._(pieces, specials);
  }

  /// Ids the greedy loop must never emit as text.
  bool isSpecial(int id) => _specialIds.contains(id);

  String decode(Iterable<int> ids) {
    // Accumulate bytes, not characters: a `<0xNN>` run is only valid UTF-8 once
    // fused, so decoding piece by piece would corrupt every CJK/Arabic glyph.
    final bytes = <int>[];
    for (final id in ids) {
      if (isSpecial(id) || id < 0 || id >= _pieces.length) continue;
      final piece = _pieces[id];
      final m = _byteToken.firstMatch(piece);
      if (m != null) {
        bytes.add(int.parse(m.group(1)!, radix: 16));
      } else {
        bytes.addAll(utf8.encode(piece.replaceAll('▁', ' ')));
      }
    }
    return utf8.decode(bytes, allowMalformed: true).trim();
  }
}
