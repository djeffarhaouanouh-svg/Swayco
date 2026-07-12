import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../swayco/asr/asr_service.dart';
import '../theme/swayco_theme.dart';

/// Offers to download the speech model at the END of onboarding, rather than
/// letting it start silently during the user's first call.
///
/// The model (Whisper) is ~357 MB and everything the user says is transcribed on
/// the phone with it. Downloading it mid-call means the first minutes of that
/// call have no translation at all, with nothing on screen explaining why — so
/// the choice, and the wait, belong here where the user can see them.
///
/// Declining is safe: the streamer downloads it on first use anyway. The user
/// simply gets the delay then instead of now.
///
/// Native only — on web there is no on-device model.
Future<void> showSttDownloadDialog(
  BuildContext context, {
  required String langCode,
}) async {
  if (!AsrService.supportsLang(langCode)) return;
  if (await AsrService.isLanguageInstalled(langCode)) return;
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SttDownloadDialog(langCode: langCode),
  );
}

class _SttDownloadDialog extends StatefulWidget {
  const _SttDownloadDialog({required this.langCode});
  final String langCode;

  @override
  State<_SttDownloadDialog> createState() => _SttDownloadDialogState();
}

class _SttDownloadDialogState extends State<_SttDownloadDialog> {
  bool _downloading = false;
  double _progress = 0;
  bool _failed = false;

  Future<void> _start() async {
    setState(() {
      _downloading = true;
      _failed = false;
      _progress = 0;
    });
    try {
      await AsrService.instance.ensureLanguageInstalled(
        widget.langCode,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      // Not fatal — the call path retries on its own. Let the user move on.
      setState(() {
        _downloading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mb = AsrService.downloadSizeMb(widget.langCode);
    final pct = (_progress * 100).clamp(0, 100).toStringAsFixed(0);

    return AlertDialog(
      backgroundColor: const Color(0xFF141414),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        AppStrings.t('stt_dl_title'),
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _failed
                ? AppStrings.t('stt_dl_failed')
                : AppStrings.t('stt_dl_body').replaceAll('{mb}', '$mb'),
            style: const TextStyle(color: Colors.white70, height: 1.35),
          ),
          if (_downloading) ...[
            const SizedBox(height: 20),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progress == 0 ? null : _progress,
                minHeight: 8,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation(SC.accent),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '$pct %',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ],
      ),
      actions: _downloading
          ? const []
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  AppStrings.t('stt_dl_later'),
                  style: const TextStyle(color: Colors.white54),
                ),
              ),
              TextButton(
                onPressed: _start,
                child: Text(
                  AppStrings.t('stt_dl_now'),
                  style: const TextStyle(
                    color: SC.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
    );
  }
}
