import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_strings.dart';
import '../services/friendly_error.dart';
import '../services/nav_tab.dart';
import '../services/profile_api.dart';
import '../services/voice_intro_api.dart';
import '../services/voice_recorder.dart';
import '../theme/swayco_theme.dart';
import 'info_bento.dart' show InfoGlassFrame;
import 'voice_intro_player.dart';

/// Ma bio, sur ma page profil : un texte court OU une présentation vocale. Tant
/// qu'un audio existe, c'est lui que les autres voient.
class MyBioCard extends StatefulWidget {
  const MyBioCard({
    super.key,
    required this.profile,
    required this.onSaveText,
    required this.onVoiceChanged,
    required this.confirm,
  });

  final RemoteProfile? profile;
  final Future<void> Function(String) onSaveText;

  /// L'audio a été enregistré ou retiré : relire le profil.
  final Future<void> Function() onVoiceChanged;

  /// La pop-up de confirmation de l'app (titre, texte, bouton).
  final Future<bool> Function(String title, String body, String action) confirm;

  @override
  State<MyBioCard> createState() => _MyBioCardState();
}

class _MyBioCardState extends State<MyBioCard> {
  /// `null` : pas encore choisi, on suit le profil.
  bool? _audioTab;
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _recorder = VoiceRecorder(maxMs: kVoiceIntroMaxMs);
  bool _busy = false;
  bool _savingText = false;

  String get _bio => widget.profile?.bio.trim() ?? '';
  bool get _hasVoice => widget.profile?.hasVoiceIntro ?? false;
  bool get _onAudio => _audioTab ?? _hasVoice;

  @override
  void initState() {
    super.initState();
    _text.text = _bio;
    _focus.addListener(_onFocus);
    _recorder.onLimit = () => unawaited(_finishRecording());
    NavTab.index.addListener(_onTab);
  }

  @override
  void didUpdateWidget(MyBioCard old) {
    super.didUpdateWidget(old);
    final before = old.profile?.bio.trim() ?? '';
    if (before != _bio && !_focus.hasFocus) _text.text = _bio;
  }

  @override
  void dispose() {
    NavTab.index.removeListener(_onTab);
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _text.dispose();
    _recorder.dispose();
    super.dispose();
  }

  /// On quitte l'onglet : rien ne continue à enregistrer.
  void _onTab() {
    if (NavTab.index.value != NavTab.profile) {
      unawaited(_recorder.cancel());
      VoiceIntroPlayer.stopActive();
    }
  }

  void _onFocus() {
    if (!_focus.hasFocus) unawaited(_saveText());
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveText() async {
    final value = _text.text.trim();
    if (value == _bio || _savingText) return;
    _savingText = true;
    try {
      // Écrire un texte, c'est le choisir à la place de l'audio.
      if (_hasVoice && value.isNotEmpty) {
        final replace = await widget.confirm(
          AppStrings.t('voice_intro_replace_title'),
          AppStrings.t('voice_intro_delete_body'),
          AppStrings.t('voice_intro_replace_ok'),
        );
        if (!replace) {
          _text.text = _bio;
          return;
        }
        VoiceIntroPlayer.stopActive();
        await VoiceIntroApi.delete();
      }
      await widget.onSaveText(value);
      await widget.onVoiceChanged();
    } catch (e) {
      _say(friendlyError(e));
    } finally {
      _savingText = false;
    }
  }

  Future<void> _startRecording() async {
    if (_busy || _recorder.active) return;
    VoiceIntroPlayer.stopActive();
    HapticFeedback.mediumImpact();
    final result = await _recorder.start();
    if (!mounted) return;
    if (result == VoiceStart.started) {
      _recorder.lock();
    } else {
      _say(AppStrings.t(result == VoiceStart.denied
          ? 'voice_mic_denied'
          : 'login_err_generic'));
    }
  }

  Future<void> _finishRecording() async {
    if (_busy || !_recorder.active) return;
    setState(() => _busy = true);
    HapticFeedback.lightImpact();
    try {
      final recording = await _recorder.finish();
      if (recording == null) {
        _say(AppStrings.t('voice_intro_too_short'));
        return;
      }
      await VoiceIntroApi.save(
        recording,
        lang: widget.profile?.language ?? '',
      );
      await widget.onVoiceChanged();
      _say(AppStrings.t('voice_intro_saved'));
    } catch (e) {
      _say(friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final ok = await widget.confirm(
      AppStrings.t('voice_intro_delete_title'),
      AppStrings.t('voice_intro_delete_body'),
      AppStrings.t('voice_intro_delete'),
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      VoiceIntroPlayer.stopActive();
      await VoiceIntroApi.delete();
      await widget.onVoiceChanged();
    } catch (e) {
      _say(friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InfoGlassFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Tab(
                icon: Icons.edit_rounded,
                label: AppStrings.t('voice_intro_tab_text'),
                selected: !_onAudio,
                onTap: () {
                  if (_recorder.active) return;
                  setState(() => _audioTab = false);
                },
              ),
              const SizedBox(width: 8),
              _Tab(
                icon: Icons.mic_rounded,
                label: AppStrings.t('voice_intro_tab_audio'),
                selected: _onAudio,
                onTap: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  setState(() => _audioTab = true);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_onAudio) _audio() else _written(),
        ],
      ),
    );
  }

  Widget _written() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _text,
          focusNode: _focus,
          maxLength: profileBioMaxLength,
          minLines: 2,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.done,
          cursorColor: SC.accentFg,
          onSubmitted: (_) => _focus.unfocus(),
          style: TextStyle(color: SC.textPrimary, fontSize: 15, height: 1.4),
          decoration: InputDecoration(
            isDense: true,
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            hintText: AppStrings.t('profile_bio_placeholder'),
            hintStyle: TextStyle(color: SC.textMuted, fontSize: 15),
            counterStyle: TextStyle(color: SC.textMuted, fontSize: 11),
          ),
        ),
        if (_hasVoice) _note(AppStrings.t('voice_intro_audio_shown')),
      ],
    );
  }

  Widget _audio() {
    if (_busy) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: CircularProgressIndicator(
            color: SC.accentFg,
            strokeWidth: 2,
          ),
        ),
      );
    }
    return ListenableBuilder(
      listenable: _recorder,
      builder: (context, _) {
        if (_recorder.active) return _recording();
        final p = widget.profile;
        if (p != null && p.hasVoiceIntro) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              VoiceIntroPlayer(
                url: p.voiceIntroUrl,
                durationMs: p.voiceIntroDurationMs,
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: TextButton.icon(
                      onPressed: _startRecording,
                      icon: Icon(Icons.mic_rounded,
                          size: 18, color: SC.accentFg),
                      label: Text(
                        AppStrings.t('voice_intro_redo'),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: SC.accentFg),
                      ),
                    ),
                  ),
                  Flexible(
                    child: TextButton.icon(
                      onPressed: _delete,
                      icon: const Icon(Icons.delete_outline,
                          size: 18, color: Color(0xFFE53935)),
                      label: Text(
                        AppStrings.t('voice_intro_delete'),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xFFE53935)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        }
        return Column(
          children: [
            _RoundButton(
              icon: Icons.mic_rounded,
              color: SC.accent,
              iconColor: SC.onAccent,
              label: AppStrings.t('voice_intro_record'),
              onTap: _startRecording,
            ),
            const SizedBox(height: 8),
            _note(AppStrings.t('voice_intro_prompt',
                args: {'s': '${kVoiceIntroMaxMs ~/ 1000}'})),
          ],
        );
      },
    );
  }

  Widget _recording() {
    final elapsed = _recorder.elapsed.inMilliseconds.clamp(0, kVoiceIntroMaxMs);
    String clock(int ms) =>
        '0:${(ms ~/ 1000).toString().padLeft(2, '0')}';
    final levels = _recorder.levels;
    return Column(
      children: [
        SizedBox(
          height: 32,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 28; i++)
                Container(
                  width: 3,
                  height: 4 +
                      26 *
                          (i < levels.length
                              ? levels[levels.length - 1 - i]
                              : 0),
                  margin: const EdgeInsets.symmetric(horizontal: 1.5),
                  decoration: BoxDecoration(
                    color: SC.accentFg,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${clock(elapsed)} / ${clock(kVoiceIntroMaxMs)}',
          style: TextStyle(
            color: SC.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: elapsed / kVoiceIntroMaxMs,
            minHeight: 4,
            color: const Color(0xFFE53935),
            backgroundColor: SC.textMuted.withValues(alpha: 0.2),
          ),
        ),
        const SizedBox(height: 12),
        _RoundButton(
          icon: Icons.stop_rounded,
          color: const Color(0xFFE53935),
          iconColor: Colors.white,
          label: AppStrings.t('voice_intro_stop'),
          onTap: _finishRecording,
        ),
        const SizedBox(height: 8),
        _note(AppStrings.t('voice_intro_stop')),
      ],
    );
  }

  Widget _note(String text) => Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: SC.textMuted, fontSize: 12, height: 1.35),
      );
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? SC.onAccent : SC.textPrimary;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 38,
          decoration: BoxDecoration(
            color: selected ? SC.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(
              color: selected
                  ? SC.accent
                  : SC.textMuted.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: fg),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
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

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.color,
    required this.iconColor,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final Color iconColor;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 62,
          height: 62,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          child: Icon(icon, size: 30, color: iconColor),
        ),
      ),
    );
  }
}
