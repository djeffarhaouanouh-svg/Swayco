import 'package:flutter/material.dart';

import '../services/profile_text_i18n.dart';

/// Shows [text] immediately, then swaps in a translation when the viewer's
/// language differs from [fromLang]. Failures keep the original.
class TranslatedProfileText extends StatefulWidget {
  const TranslatedProfileText({
    super.key,
    required this.text,
    required this.profileId,
    required this.field,
    this.fromLang = '',
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final String profileId;
  final String field;
  final String fromLang;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  State<TranslatedProfileText> createState() => _TranslatedProfileTextState();
}

class _TranslatedProfileTextState extends State<TranslatedProfileText> {
  late String _shown = widget.text;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TranslatedProfileText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.profileId != widget.profileId ||
        oldWidget.field != widget.field ||
        oldWidget.fromLang != widget.fromLang) {
      _shown = widget.text;
      _load();
    }
  }

  Future<void> _load() async {
    final translated = await translateProfileText(
      text: widget.text,
      profileId: widget.profileId,
      field: widget.field,
      fromLang: widget.fromLang,
    );
    if (!mounted || translated == _shown) return;
    setState(() => _shown = translated);
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _shown,
      style: widget.style,
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}
