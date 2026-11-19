import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// La vignette d'une vidéo dans une bulle du chat : une tuile sombre avec un
/// bouton lecture. Elle n'ouvre rien elle-même — le fil lui met son geste
/// (toucher = lire, appui long = réactions), comme pour une photo.
///
/// Pas d'image extraite de la vidéo : ça demanderait de la télécharger pour
/// chaque bulle visible. La lecture ne démarre qu'au toucher.
class ChatVideoTile extends StatelessWidget {
  const ChatVideoTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 200,
        height: 140,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1B2250), Color(0xFF0B0E22)],
          ),
        ),
        child: Center(
          child: Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.18),
              border: Border.all(color: Colors.white54, width: 1.5),
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 34,
            ),
          ),
        ),
      ),
    );
  }
}

/// Ouvre la vidéo [url] en plein écran et la lance.
Future<void> showChatVideo(BuildContext context, String url) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _ChatVideoScreen(url: url),
    ),
  );
}

class _ChatVideoScreen extends StatefulWidget {
  const _ChatVideoScreen({required this.url});

  final String url;

  @override
  State<_ChatVideoScreen> createState() => _ChatVideoScreenState();
}

class _ChatVideoScreenState extends State<_ChatVideoScreen> {
  late final VideoPlayerController _ctrl;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _ctrl.addListener(_onTick);
    _ctrl.initialize().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
      _ctrl.play();
    }).catchError((Object _) {
      if (mounted) setState(() => _failed = true);
    });
  }

  void _onTick() {
    // Rafraîchit le bouton lecture / pause quand la vidéo se termine.
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTick);
    _ctrl.dispose();
    super.dispose();
  }

  void _toggle() {
    if (!_ready) return;
    if (_ctrl.value.isPlaying) {
      _ctrl.pause();
    } else {
      // Finie : on repart du début.
      if (_ctrl.value.position >= _ctrl.value.duration) {
        _ctrl.seekTo(Duration.zero);
      }
      _ctrl.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final playing = _ready && _ctrl.value.isPlaying;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_failed)
              const Center(
                child: Icon(
                  Icons.error_outline_rounded,
                  color: Colors.white54,
                  size: 48,
                ),
              )
            else if (!_ready)
              const Center(
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              )
            else
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggle,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _ctrl.value.aspectRatio,
                    child: VideoPlayer(_ctrl),
                  ),
                ),
              ),
            // Le bouton lecture réapparaît quand la vidéo est en pause.
            if (_ready && !playing)
              IgnorePointer(
                child: Center(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.45),
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 48,
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 8,
              left: 8,
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            if (_ready)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: VideoProgressIndicator(
                  _ctrl,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: Colors.white,
                    bufferedColor: Colors.white30,
                    backgroundColor: Colors.white12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
