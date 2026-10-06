import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/profile_api.dart';
import '../services/special_message_quota.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

/// Feuille « Message spécial » pour un utilisateur NON Pro : montre le message
/// tel que l'autre le recevra, puis propose Pro. Rend `true` au tap sur
/// « Passer à Pro », `null` / `false` pour « Plus tard » ou un balayage.
Future<bool?> showSpecialMessageProSheet(
  BuildContext context, {
  required RemoteProfile peer,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: SC.light ? const Color(0x4D04123A) : const Color(0x9E040A1E),
    builder: (_) => _SpecialMessageProSheet(peer: peer),
  );
}

class _SpecialMessageProSheet extends StatefulWidget {
  const _SpecialMessageProSheet({required this.peer});

  final RemoteProfile peer;

  @override
  State<_SpecialMessageProSheet> createState() =>
      _SpecialMessageProSheetState();
}

class _SpecialMessageProSheetState extends State<_SpecialMessageProSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _ctl.value = 1;
    } else {
      // Rebond leger de la bulle, apres 150 ms.
      Future<void>.delayed(const Duration(milliseconds: 150), () {
        if (mounted) _ctl.forward();
      });
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  String get _firstName {
    final n = widget.peer.displayName.trim();
    return n.isEmpty ? AppStrings.t('incoming_someone') : n.split(RegExp(r'\s+')).first;
  }

  @override
  Widget build(BuildContext context) {
    final ink = PopupTokens.ink;
    final bubble = _ctl.drive(
      CurveTween(curve: const Interval(0, 0.7, curve: Curves.easeOutBack)),
    );
    final titleStyle = popupDisplay(
      fontSize: 23,
      letterSpacing: -0.7,
      height: 1.15,
      color: ink,
    );
    return PopupSurface(
      sheet: true,
      washHeight: 150,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: PopupHandle()),
              const SizedBox(height: 14),
              // ── La bulle d'aperçu ──────────────────────────────────────
              AnimatedBuilder(
                animation: bubble,
                builder: (_, child) => Opacity(
                  opacity: bubble.value.clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(0, 12 * (1 - bubble.value)),
                    child: child,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                  child: Transform.rotate(
                    angle: -2 * 3.141592653589793 / 180,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          padding: const EdgeInsets.fromLTRB(18, 28, 18, 14),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment(-0.3, -1),
                              end: Alignment(0.3, 1),
                              colors: [
                                SC.brandBlueDeep,
                                SC.brandBlue,
                                SC.brandCyan,
                              ],
                            ),
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0xBF2B7FFF),
                                blurRadius: 40,
                                spreadRadius: -16,
                                offset: Offset(0, 18),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                AppStrings.t('dm_preview_text'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  height: 1.4,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                AppStrings.t('special_from_discover'),
                                style: GoogleFonts.ibmPlexMono(
                                  fontSize: 10,
                                  letterSpacing: 0.5,
                                  color: Colors.white.withValues(alpha: 0.9),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          top: -14,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: SC.accent,
                                borderRadius: BorderRadius.circular(999),
                                boxShadow: [
                                  BoxShadow(
                                    color: SC.accent.withValues(alpha: 0.55),
                                    blurRadius: 20,
                                    spreadRadius: -8,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.auto_awesome_rounded,
                                    size: 15,
                                    color: SC.onAccent,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    AppStrings.t('special_label'),
                                    softWrap: false,
                                    style: popupDisplay(
                                      fontSize: 11,
                                      color: SC.onAccent,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // ── Titre : « … sans attendre le [match] » ──────────────────
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                runSpacing: 2,
                children: [
                  Text(
                    AppStrings.t('dm_pitch_title'),
                    textAlign: TextAlign.center,
                    style: titleStyle,
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: SC.accent,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      AppStrings.t('dm_pitch_highlight'),
                      softWrap: false,
                      style: titleStyle.copyWith(color: SC.onAccent),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                AppStrings.t(
                  'dm_pitch_body',
                  args: {
                    'name': _firstName,
                    'n': '${SpecialMessageQuota.total}',
                  },
                ),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: PopupTokens.textBody,
                  fontSize: 14,
                  height: 1.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 14),
              PopupButton(
                label: AppStrings.t('pw_pro_switch'),
                height: 56,
                onPressed: () => Navigator.of(context).pop(true),
              ),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(
                    AppStrings.t('pw_later'),
                    style: TextStyle(
                      color: ink.withValues(alpha: 0.7),
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}