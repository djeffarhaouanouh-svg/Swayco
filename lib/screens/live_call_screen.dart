import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/device_id.dart';
import '../services/live_lobby_api.dart';
import '../services/profile_api.dart';
import '../services/push_dispatcher.dart';
import '../services/supabase_service.dart';
import '../services/token_api.dart';
import '../services/user_prefs.dart';
import '../theme/whatsapp_call_theme.dart';
import '../translation/realtime_translation_port.dart';
import 'call_screen.dart';

/// The two faces of the "Planète" tab: a self-view + "go live" button, or
/// the black searching screen with the wobbling magnifier.
enum _Stage { idle, searching }

/// Omegle-style live-call tab. Tapping "Déclencher un appel live" drops the
/// user into a matchmaking queue ([LiveLobbyApi]); when a stranger is
/// paired we jump straight into a [CallScreen] LiveKit room.
///
/// [active] is driven by [RootShell] — true only while this is the visible
/// tab. The camera self-view is held *only* when active + idle + the app is
/// foregrounded, so we never keep the camera open behind another tab.
class LiveCallScreen extends StatefulWidget {
  const LiveCallScreen({
    super.key,
    required this.active,
    required this.translation,
  });

  /// Whether this tab is the one currently shown in [RootShell].
  final bool active;
  final RealtimeTranslationPort translation;

  @override
  State<LiveCallScreen> createState() => _LiveCallScreenState();
}

class _LiveCallScreenState extends State<LiveCallScreen>
    with WidgetsBindingObserver {
  _Stage _stage = _Stage.idle;

  // Camera self-view.
  RTCVideoRenderer? _renderer;
  MediaStream? _camStream;
  bool _cameraStarting = false;
  bool _cameraDenied = false;

  String _myId = '';
  int _waitingCount = 0;
  bool _resumed = true;

  // Set true between "tapped the button" and the enqueue round-trip
  // resolving, so a double-tap can't enqueue twice.
  bool _busy = false;
  // Set once we've decided to jump into a call, so the realtime push and
  // the polling backstop can't both fire _goToCall.
  bool _navigating = false;

  RealtimeChannel? _lobbyChannel;
  Timer? _pollTimer;
  Timer? _heartbeatTimer;
  Timer? _counterTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Keep the idle-screen "X cherchent un live" counter fresh.
    _counterTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (widget.active && _stage == _Stage.idle) _refreshCounter();
    });
    _init();
  }

  Future<void> _init() async {
    final id = await DeviceId.getOrCreate();
    if (!mounted) return;
    setState(() => _myId = id);
    _syncCamera();
    _refreshCounter();
  }

  @override
  void didUpdateWidget(covariant LiveCallScreen old) {
    super.didUpdateWidget(old);
    // Tab became (in)visible — acquire / release the camera accordingly.
    if (old.active != widget.active) {
      _syncCamera();
      if (widget.active && _stage == _Stage.idle) _refreshCounter();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    // Never hold the camera while backgrounded.
    _syncCamera();
    // Re-foregrounded mid-search → our queue row may have aged out while
    // the heartbeat timer was throttled. Re-verify and rejoin if needed.
    if (_resumed && _stage == _Stage.searching && !_navigating) {
      unawaited(_resyncSearch());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _counterTimer?.cancel();
    _pollTimer?.cancel();
    _heartbeatTimer?.cancel();
    final ch = _lobbyChannel;
    if (ch != null) {
      unawaited(Supabase.instance.client.removeChannel(ch));
    }
    // Leaving the screen mid-search → drop out of the queue so we don't
    // strand a future joiner in an empty room.
    if (_stage == _Stage.searching && _myId.isNotEmpty) {
      unawaited(LiveLobbyApi.cancel(_myId));
    }
    // Tear the camera down off the State so a late callback can't setState.
    final stream = _camStream;
    final renderer = _renderer;
    _camStream = null;
    _renderer = null;
    unawaited(() async {
      if (stream != null) {
        for (final t in stream.getTracks()) {
          try {
            await t.stop();
          } catch (_) {}
        }
        await stream.dispose();
      }
      if (renderer != null) {
        renderer.srcObject = null;
        await renderer.dispose();
      }
    }());
    super.dispose();
  }

  // ---- Camera self-view -----------------------------------------------

  /// The camera should only be live when this tab is on screen, we're on
  /// the idle (not searching) stage, and the app is foregrounded.
  bool _shouldHaveCamera() =>
      widget.active && _stage == _Stage.idle && _resumed;

  void _syncCamera() {
    if (_shouldHaveCamera()) {
      unawaited(_acquireCamera());
    } else {
      unawaited(_releaseCamera());
    }
  }

  Future<void> _acquireCamera() async {
    if (_camStream != null || _cameraStarting) return;
    _cameraStarting = true;
    try {
      // On native we ask explicitly; on web getUserMedia triggers the
      // browser's own prompt, and permission_handler's camera support is
      // unreliable there — so skip it and let getUserMedia do the asking.
      if (!kIsWeb) {
        final status = await Permission.camera.request();
        if (!status.isGranted) {
          _cameraStarting = false;
          if (mounted) setState(() => _cameraDenied = true);
          return;
        }
      }
      _renderer ??= RTCVideoRenderer();
      await _renderer!.initialize();
      final stream = await navigator.mediaDevices.getUserMedia(
        <String, dynamic>{
          'audio': false,
          'video': {'facingMode': 'user'},
        },
      );
      // The user may have switched tabs / backgrounded the app while
      // getUserMedia was resolving — bail and free the stream.
      if (!mounted || !_shouldHaveCamera()) {
        for (final t in stream.getTracks()) {
          await t.stop();
        }
        await stream.dispose();
        _cameraStarting = false;
        return;
      }
      _camStream = stream;
      _cameraDenied = false;
      _cameraStarting = false;
      if (mounted) setState(() {});
      // Safari won't autoplay a <video> whose srcObject was assigned
      // before the element was attached to the DOM — the preview freezes
      // on its first frame. Assign the stream only once RTCVideoView is
      // mounted (next frame). Harmless on Chrome / native.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _camStream != stream) return;
        _renderer?.srcObject = stream;
      });
    } catch (e) {
      _cameraStarting = false;
      debugPrint('LiveCallScreen: camera acquire failed: $e');
      if (mounted) setState(() => _cameraDenied = true);
    }
  }

  /// Stops the camera stream but keeps [_renderer] around for cheap reuse —
  /// it is only disposed in [dispose].
  Future<void> _releaseCamera() async {
    final stream = _camStream;
    if (stream == null) return;
    _camStream = null;
    for (final t in stream.getTracks()) {
      try {
        await t.stop();
      } catch (_) {}
    }
    await stream.dispose();
    _renderer?.srcObject = null;
    if (mounted) setState(() {});
  }

  // ---- Matchmaking -----------------------------------------------------

  String _newIdentity() {
    final r = Random();
    return 'u${DateTime.now().millisecondsSinceEpoch}${r.nextInt(999999)}';
  }

  Future<void> _refreshCounter() async {
    if (!isSupabaseReady) return;
    final c = await LiveLobbyApi.waitingCount();
    if (mounted) setState(() => _waitingCount = c);
  }

  Future<void> _startSearch() async {
    if (_busy || _myId.isEmpty) return;
    setState(() {
      _busy = true;
      _stage = _Stage.searching;
    });
    // Searching screen is camera-free — free it now.
    _syncCamera();
    try {
      final match = await LiveLobbyApi.enqueue();
      if (!mounted) return;
      if (match.isMatched) {
        await _goToCall(match.roomName!);
        return;
      }
      // Enqueued — wait for a joiner. Realtime is the fast path; the
      // poll timer is the guaranteed backstop.
      _lobbyChannel = LiveLobbyApi.subscribeMyRow(
        myId: _myId,
        onUpdate: _onLobbyUpdate,
      );
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 2500),
        (_) => _pollOnce(),
      );
      _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => LiveLobbyApi.heartbeat(),
      );
      // A match could have landed between the enqueue INSERT and the
      // subscription going live — close that window with one poll.
      unawaited(_pollOnce());
      // Nobody to pair with right now — ask the backend to wake other
      // users with a push. Spam-proof: the server caps this at one push
      // per day per user, plus a global cooldown.
      unawaited(PushDispatcher.broadcastLiveCall());
    } catch (e) {
      if (!mounted) return;
      _showError('Impossible de lancer la recherche : $e');
      _backToIdle();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onLobbyUpdate(LiveMatch m) {
    if (!mounted || _navigating || _stage != _Stage.searching) return;
    if (m.isMatched) unawaited(_goToCall(m.roomName!));
  }

  /// Called when the app is re-foregrounded mid-search. While backgrounded
  /// the heartbeat timer is throttled, so the queue row may have aged out
  /// of the match window and been swept by another caller's housekeeping.
  Future<void> _resyncSearch() async {
    if (_myId.isEmpty) return;
    final m = await LiveLobbyApi.fetchMyRow(_myId);
    if (!mounted || _navigating || _stage != _Stage.searching) return;
    if (m != null && m.isMatched) {
      unawaited(_goToCall(m.roomName!));
      return;
    }
    if (m == null) {
      // Row swept while backgrounded — rejoin the queue.
      try {
        final match = await LiveLobbyApi.enqueue();
        if (!mounted || _navigating || _stage != _Stage.searching) return;
        if (match.isMatched) unawaited(_goToCall(match.roomName!));
      } catch (e) {
        debugPrint('LiveCallScreen: resync enqueue failed: $e');
      }
    } else {
      // Still queued — refresh the row right away.
      unawaited(LiveLobbyApi.heartbeat());
    }
  }

  Future<void> _pollOnce() async {
    if (!mounted ||
        _navigating ||
        _stage != _Stage.searching ||
        _myId.isEmpty) {
      return;
    }
    final m = await LiveLobbyApi.fetchMyRow(_myId);
    if (!mounted || _navigating || _stage != _Stage.searching) return;
    if (m != null && m.isMatched) unawaited(_goToCall(m.roomName!));
  }

  /// Stop the realtime channel + timers (but does NOT leave the queue —
  /// callers decide whether to cancel the row).
  void _teardownSearch() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final ch = _lobbyChannel;
    _lobbyChannel = null;
    if (ch != null) {
      unawaited(Supabase.instance.client.removeChannel(ch));
    }
  }

  Future<void> _cancelSearch() async {
    _teardownSearch();
    await LiveLobbyApi.cancel(_myId);
    if (mounted) _backToIdle();
  }

  void _backToIdle() {
    setState(() => _stage = _Stage.idle);
    _syncCamera();
    _refreshCounter();
  }

  /// A stranger was paired with us — mint a LiveKit token and push the
  /// real call screen.
  Future<void> _goToCall(String roomName) async {
    if (_navigating) return;
    _navigating = true;
    _teardownSearch();
    await _releaseCamera();

    // Resolve my display name + spoken language for the call / translation.
    var name = '';
    var lang = '';
    final local = await UserPrefs.loadProfile();
    name = local?.firstName.trim() ?? '';
    lang = local?.sourceLang.trim() ?? '';
    if ((name.isEmpty || lang.isEmpty) && isSupabaseReady) {
      final remote = await ProfileApi.fetchById(_myId);
      if (remote != null) {
        if (name.isEmpty) name = remote.displayName.trim();
        if (lang.isEmpty) lang = remote.language.trim();
      }
    }

    try {
      final token = await fetchLiveKitToken(
        roomName: roomName,
        identity: _newIdentity(),
        displayName: name,
        sourceLang: lang,
      );
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => CallScreen(
            wsUrl: token.url,
            jwt: token.token,
            roomName: token.roomName,
            displayName: name,
            mySourceLang: lang,
            translation: widget.translation,
          ),
        ),
      );
    } catch (e) {
      if (mounted) _showError('Connexion impossible : $e');
    }
    // Returned from the call (or it failed) — tidy our lobby row and
    // reset the screen.
    unawaited(LiveLobbyApi.cancel(_myId));
    _navigating = false;
    if (mounted) _backToIdle();
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 5)),
    );
  }

  // ---- UI --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: !isSupabaseReady
          ? _buildUnavailable()
          : (_stage == _Stage.searching ? _buildSearching() : _buildIdle()),
    );
  }

  Widget _buildUnavailable() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.public_off, color: WhatsAppCallTheme.subtleText,
                size: 56),
            SizedBox(height: 16),
            Text(
              'Appel live indisponible',
              style: TextStyle(
                color: WhatsAppCallTheme.strongText,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'La mise en relation aléatoire a besoin de Supabase. '
              'Configure-le pour activer cet onglet.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: WhatsAppCallTheme.subtleText,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -- Idle: self-view + "go live" button --------------------------------

  Widget _buildIdle() {
    final topPad = MediaQuery.paddingOf(context).top;
    final navSpace = 66.0 + MediaQuery.paddingOf(context).bottom;

    return Stack(
      fit: StackFit.expand,
      children: [
        _cameraView(),
        // Top scrim — keeps the header legible over a bright self-view.
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 220,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xCC000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
        // Bottom scrim — for the counter + button.
        const Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 340,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xE6000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: topPad + 14,
          left: 20,
          right: 20,
          child: _header(),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: navSpace + 12,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _counterPill(),
              const SizedBox(height: 14),
              _goLiveButton(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header() {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.public, color: Colors.white, size: 26),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Appel aléatoire',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
              Text(
                'Rencontre quelqu\'un au hasard, traduit en direct.',
                style: TextStyle(color: Color(0xFFB8E0D8), fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _counterPill() {
    final count = _waitingCount;
    final hasPeople = count > 0;
    final text = hasPeople
        ? '$count ${count == 1 ? "personne cherche" : "personnes cherchent"} '
            'un live'
        : 'Sois le premier à lancer un live';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hasPeople
                  ? WhatsAppCallTheme.accent
                  : WhatsAppCallTheme.subtleText,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _goLiveButton() {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: _busy ? null : _startSearch,
        icon: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.public, size: 22),
        label: const Text(
          'Déclencher un appel aléatoire',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: WhatsAppCallTheme.accent,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }

  Widget _cameraView() {
    final r = _renderer;
    if (r != null && _camStream != null) {
      return RTCVideoView(
        r,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        mirror: true,
      );
    }
    // Placeholder while the camera warms up, or when it was refused.
    return Container(
      color: const Color(0xFF121212),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _cameraDenied
                ? Icons.videocam_off_rounded
                : Icons.person_rounded,
            size: 76,
            color: Colors.white.withValues(alpha: 0.22),
          ),
          const SizedBox(height: 14),
          if (_cameraDenied) ...[
            const Text(
              'Caméra non autorisée',
              style: TextStyle(
                color: WhatsAppCallTheme.strongText,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Tu peux quand même lancer un appel live.',
              style: TextStyle(
                color: WhatsAppCallTheme.subtleText,
                fontSize: 13,
              ),
            ),
          ] else
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: WhatsAppCallTheme.accent,
              ),
            ),
        ],
      ),
    );
  }

  // -- Searching: black screen + wobbling magnifier ----------------------

  Widget _buildSearching() {
    final navSpace = 66.0 + MediaQuery.paddingOf(context).bottom;
    return Container(
      color: Colors.black,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: navSpace),
          child: Column(
            children: [
              const Spacer(flex: 3),
              const _WobblingMagnifier(),
              const SizedBox(height: 38),
              const Text(
                'Recherche d\'une personne…',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 44),
                child: Text(
                  'On te met en relation avec quelqu\'un, quelque part '
                  'dans le monde 🌍 — traduit en direct.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: WhatsAppCallTheme.subtleText,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ),
              const Spacer(flex: 4),
              OutlinedButton(
                onPressed: _cancelSearch,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.28),
                  ),
                  minimumSize: const Size(160, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                child: const Text(
                  'Annuler',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// The wobbling magnifying glass shown on the searching screen — a search
/// icon that rocks side to side inside a softly pulsing halo.
class _WobblingMagnifier extends StatefulWidget {
  const _WobblingMagnifier();

  @override
  State<_WobblingMagnifier> createState() => _WobblingMagnifierState();
}

class _WobblingMagnifierState extends State<_WobblingMagnifier>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_c.value);
        // Rock between roughly -18° and +18°, breathe the halo gently.
        final angle = -0.32 + 0.64 * t;
        final haloScale = 0.88 + 0.24 * t;
        return SizedBox(
          width: 168,
          height: 168,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: haloScale,
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: WhatsAppCallTheme.accent
                        .withValues(alpha: 0.10),
                  ),
                ),
              ),
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: WhatsAppCallTheme.accent.withValues(alpha: 0.16),
                ),
              ),
              Transform.rotate(
                angle: angle,
                child: const Icon(
                  Icons.search,
                  size: 60,
                  color: WhatsAppCallTheme.accent,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
