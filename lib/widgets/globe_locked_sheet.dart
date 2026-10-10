import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/world_countries.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

String _groupDigits(int n) {
  final lang = AppStrings.currentBcp47.value;
  final sep = switch (lang) {
    'de' || 'es' || 'it' || 'pt' || 'nl' => '.',
    'fr' || 'ru' => ' ',
    _ => ',',
  };
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(sep);
    buf.write(s[i]);
  }
  return buf.toString();
}

/// La feuille « pays pas encore ouvert » : drapeau, « Pas tout à fait prêt »,
/// combien de personnes attendent, et « Me prévenir ». [onJoin] / [onLeave]
/// écrivent la liste d'attente ; la feuille bascule d'elle-même sur l'état
/// « inscrit ».
Future<void> showLockedCountrySheet(
  BuildContext context, {
  required String keyName,
  required String code,
  required int count,
  required bool joined,
  required Future<void> Function() onJoin,
  required Future<void> Function() onLeave,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: PopupTokens.scrim,
    isScrollControlled: true,
    builder: (_) => _LockedSheet(
      keyName: keyName,
      code: code,
      count: count,
      joined: joined,
      onJoin: onJoin,
      onLeave: onLeave,
    ),
  );
}

class _LockedSheet extends StatefulWidget {
  const _LockedSheet({
    required this.keyName,
    required this.code,
    required this.count,
    required this.joined,
    required this.onJoin,
    required this.onLeave,
  });

  final String keyName;
  final String code;
  final int count;
  final bool joined;
  final Future<void> Function() onJoin;
  final Future<void> Function() onLeave;

  @override
  State<_LockedSheet> createState() => _LockedSheetState();
}

class _LockedSheetState extends State<_LockedSheet> {
  late bool _joined = widget.joined;
  late int _count = widget.count;
  bool _busy = false;

  Color get _sheetColor =>
      SC.light ? Colors.white : const Color(0xFF1A2552);

  Future<void> _join() async {
    if (_busy) return;
    HapticFeedback.mediumImpact();
    setState(() => _busy = true);
    await widget.onJoin();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _joined = true;
      _count += 1;
    });
  }

  Future<void> _leave() async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.onLeave();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _joined = false;
      if (_count > 0) _count -= 1;
    });
  }

  Widget _flagAvatar() {
    final flag = Container(
      width: 84,
      height: 84,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: SC.brandGradient,
        boxShadow: const [
          BoxShadow(
            color: Color(0xCC2B7FFF),
            blurRadius: 26,
            spreadRadius: -8,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(shape: BoxShape.circle, color: _sheetColor),
        child: ClipOval(
          child: Image.network(
            'https://flagcdn.com/w160/${widget.code}.png',
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Center(
              child: Text(
                widget.code.toUpperCase(),
                style: popupDisplay(fontSize: 20, color: PopupTokens.ink),
              ),
            ),
          ),
        ),
      ),
    );
    return SizedBox(
      width: 92,
      height: 92,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(left: 0, bottom: 0, child: flag),
          Positioned(
            top: -4,
            right: -4,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: SC.accent,
                border: Border.all(color: _sheetColor, width: 3),
              ),
              child: Icon(
                _joined ? Icons.notifications_active : Icons.lock,
                size: 16,
                color: SC.onAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _closeButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: PopupTokens.ghost,
          border: Border.all(color: PopupTokens.ghostBorder),
        ),
        child: Icon(Icons.close_rounded, size: 20, color: PopupTokens.ink),
      ),
    );
  }

  /// « Pas tout à fait [prêt.] » : le dernier mot sur la pastille jaune.
  Widget _title(String head, String tail) {
    final style = popupDisplay(
      fontSize: 20,
      letterSpacing: -0.6,
      color: PopupTokens.ink,
    );
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: '$head '),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: SC.accent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                tail,
                maxLines: 1,
                softWrap: false,
                style: style.copyWith(color: SC.onAccent),
              ),
            ),
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _wantLine(String name, String art) {
    final body = GoogleFonts.plusJakartaSans(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      height: 1.4,
      color: PopupTokens.textBody,
    );
    if (_count <= 0) {
      return Text(
        AppStrings.t('globe_locked_want_zero'),
        textAlign: TextAlign.center,
        style: body,
      );
    }
    final tpl = AppStrings.t('globe_locked_want').replaceAll('{country}', art);
    final cut = tpl.indexOf('{n}');
    final nStyle = body.copyWith(
      fontWeight: FontWeight.w800,
      color: SC.light ? const Color(0xFF1F5EFF) : SC.accent,
    );
    if (cut < 0) {
      return Text(tpl, textAlign: TextAlign.center, style: body);
    }
    return Text.rich(
      TextSpan(
        style: body,
        children: [
          TextSpan(text: tpl.substring(0, cut)),
          TextSpan(text: _groupDigits(_count), style: nStyle),
          TextSpan(text: tpl.substring(cut + 3)),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _askView(String name, String art) {
    return Column(
      key: const ValueKey('ask'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _flagAvatar(),
        const SizedBox(height: 12),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: popupDisplay(
            fontSize: 26,
            letterSpacing: -1.04,
            color: PopupTokens.ink,
          ),
        ),
        const SizedBox(height: 12),
        _title(
          AppStrings.t('globe_locked_head'),
          AppStrings.t('globe_locked_tail'),
        ),
        const SizedBox(height: 12),
        _wantLine(name, art),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: _busy ? null : _join,
          child: Container(
            height: 56,
            width: double.infinity,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: SC.accent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                AppStrings.t('globe_locked_notify')
                    .replaceAll('{country}', art),
                maxLines: 1,
                style: popupDisplay(fontSize: 14, color: SC.onAccent),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _doneView(String art) {
    final accentOnSheet = SC.light ? const Color(0xFF1F5EFF) : SC.accent;
    return Column(
      key: const ValueKey('done'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _flagAvatar(),
        const SizedBox(height: 12),
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accentOnSheet.withValues(alpha: 0.16),
            border: Border.all(color: accentOnSheet, width: 1.5),
          ),
          child: Icon(
            Icons.notifications_active,
            size: 30,
            color: accentOnSheet,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          AppStrings.t('globe_locked_done'),
          textAlign: TextAlign.center,
          style: popupDisplay(
            fontSize: 20,
            letterSpacing: -0.6,
            color: PopupTokens.ink,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          AppStrings.t('globe_locked_done_sub').replaceAll('{country}', art),
          textAlign: TextAlign.center,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            height: 1.4,
            color: PopupTokens.textBody,
          ),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Container(
            height: 52,
            width: double.infinity,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: PopupTokens.ghost,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: PopupTokens.ghostBorder),
            ),
            child: Text(
              AppStrings.t('globe_locked_back'),
              maxLines: 1,
              style: popupDisplay(fontSize: 14, color: PopupTokens.ink),
            ),
          ),
        ),
        const SizedBox(height: 12),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _busy ? null : _leave,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              AppStrings.t('globe_locked_leave'),
              style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: PopupTokens.ink.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = worldCountryName(widget.keyName);
    final art = worldCountryArticle(widget.keyName);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return PopupSurface(
      sheet: true,
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(24, 12, 24, 20 + bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const PopupHandle(),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _joined ? _doneView(art) : _askView(name, art),
                ),
              ],
            ),
          ),
          Positioned(top: 12, right: 16, child: _closeButton()),
        ],
      ),
    );
  }
}
