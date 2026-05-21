import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/audio_controller.dart';
import '../services/auth_service.dart';
import '../services/call_alert.dart';
import '../services/languages.dart';
import '../services/profile_api.dart';
import '../services/usage_tracker.dart';
import '../theme/whatsapp_call_theme.dart';
import '../translation/realtime_translation_port.dart';
import '../translation/translation_route.dart';
import '../widgets/translation_feedback_ribbon.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.wsUrl,
    required this.jwt,
    required this.roomName,
    required this.displayName,
    required this.mySourceLang,
    required this.translation,
    this.inviteShareText,
  });

  final String wsUrl;
  final String jwt;
  final String roomName;
  final String displayName;
  /// The local user's spoken language (BCP-47). The remote participant's
  /// language is read live from their LiveKit metadata.
  final String mySourceLang;
  final RealtimeTranslationPort translation;
  /// When set, the empty-room "waiting" placeholder shows a button that
  /// re-opens the share sheet with this text — used by the host of a
  /// guest-invite call so they can resend the link while waiting.
  final String? inviteShareText;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Room? _room;
  String? _connectError;
  bool _connecting = true;
  bool _micOn = true;
  bool _camOn = true;
  /// When true, the local self-view fills the screen and the remote feed
  /// lives in the small PiP. Tap either to swap back.
  bool _selfMain = false;
  EventsListener<RoomEvent>? _roomEvents;

  /// The remote BCP-47 we have attached the translation pipeline with, so we
  /// only re-attach when it actually changes.
  String _attachedRemoteLang = '';
  /// The local output language the pipeline is currently attached with —
  /// tracked alongside [_attachedRemoteLang] so a mid-call language change
  /// also triggers a re-attach.
  String _attachedMyLang = '';
  /// The language the local user currently *hears* the remote translated
  /// into. Starts at the user's own language; changeable mid-call via the
  /// language button. Local-only — it is never written to LiveKit
  /// metadata, so the remote participant is completely unaffected.
  late String _myOutputLang = widget.mySourceLang;
  bool _refreshingTranslation = false;
  /// Set when an event arrives while a refresh is in flight; we re-run once
  /// the in-flight call completes so the latest state is reflected.
  bool _refreshPending = false;

  late final AudioController _audio = AudioController(translation: widget.translation);
  bool _lastTranslationSpeaking = false;
  /// Set to true the first time any RemoteParticipant joins the room.
  /// Used by the ParticipantDisconnectedEvent handler to distinguish
  /// "caller waiting alone before pickup" (empty + !_hadRemote → keep
  /// the room open) from "peer just left a 1:1 call" (empty +
  /// _hadRemote → auto-hangup so we don't burn credits on a ghost room).
  bool _hadRemote = false;

  /// When the LiveKit room finished connecting — null until then. Used
  /// to emit the analytics `call_ended` duration from [dispose] (which
  /// always runs, whatever the exit path: hang-up, peer-left, back nav).
  DateTime? _connectedAt;

  /// `guest` / `live` / `friend`, inferred from the room-name prefix the
  /// backend mints. Tags every call analytics event.
  String get _callKind {
    final n = widget.roomName;
    if (n.startsWith('guest-')) return 'guest';
    if (n.startsWith('live-')) return 'live';
    return 'friend';
  }

  void _onTranslationStateChanged() {
    // Duck the original remote audio for the exact window the translated
    // audio is playing, so the translation is clearly audible over it.
    final speaking = widget.translation.translationSpeaking;
    if (speaking != _lastTranslationSpeaking) {
      _lastTranslationSpeaking = speaking;
      _audio.onTranslationSpeaking(speaking);
    }
  }

  void _onRoomChanged() {
    if (mounted) setState(() {});
  }

  /// Parse `participant.metadata` (set as JSON in the JWT) and return the
  /// remote's `sourceLang` if present. Returns empty string on any failure.
  String _remoteLangFromMetadata(Participant p) {
    final raw = p.metadata?.trim() ?? '';
    if (raw.isEmpty) return '';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final v = decoded['sourceLang'];
        if (v is String) return v.trim();
      }
    } catch (e) {
      debugPrint('CallScreen: failed to parse remote metadata: $e');
    }
    return '';
  }

  /// Returns the first remote participant whose metadata carries a sourceLang.
  String _discoverRemoteLang(Room room) {
    for (final p in room.remoteParticipants.values) {
      final lang = _remoteLangFromMetadata(p);
      if (lang.isNotEmpty) return lang;
    }
    return '';
  }

  /// Re-attach the translation pipeline whenever the remote's language
  /// becomes known or changes. With an empty remote language the route is
  /// not configured and the pipeline stays idle. Serialized so concurrent
  /// participant / metadata events do not race the pipeline's own teardown.
  Future<void> _refreshTranslationBinding(Room room) async {
    if (_refreshingTranslation) {
      _refreshPending = true;
      return;
    }
    _refreshingTranslation = true;
    try {
      do {
        _refreshPending = false;
        final remoteLang = _discoverRemoteLang(room);
        // Re-attach when the remote's language OR my chosen output
        // language changed since the last bind.
        if (remoteLang == _attachedRemoteLang &&
            _myOutputLang == _attachedMyLang) {
          continue;
        }
        _attachedRemoteLang = remoteLang;
        _attachedMyLang = _myOutputLang;
        final route = TranslationRoute(
          sourceBcp47: _myOutputLang,
          targetBcp47: remoteLang,
        );
        await widget.translation.attachToRoom(room, route: route);
      } while (_refreshPending && mounted);
    } finally {
      _refreshingTranslation = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _start();
    unawaited(_initUsageTracking());
    UsageTracker.creditsExhausted.addListener(_onCreditsExhausted);
  }

  /// Pull the user's current credit balance and start the call timer. The
  /// call itself runs regardless — we just decide whether translation is
  /// allowed on top.
  Future<void> _initUsageTracking() async {
    final uid = AuthService.currentUserId;
    if (uid.isEmpty) return;
    final p = await ProfileApi.fetchById(uid);
    if (!mounted || p == null) return;
    UsageTracker.start(userId: uid, initialCredits: p.creditsSeconds);
    if (UsageTracker.isDisabled) return;
    if (p.creditsSeconds <= 0) {
      // Already empty before the call started — kill translation now.
      await widget.translation.detach();
    }
  }

  /// Triggered when credits hit 0 mid-call. We detach the translation
  /// pipeline so the OpenAI session stops billing, but leave the LiveKit
  /// connection alone so people can keep talking (untranslated).
  void _onCreditsExhausted() {
    if (!UsageTracker.creditsExhausted.value) return;
    unawaited(widget.translation.detach());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.t('credits_exhausted_banner')),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  Future<void> _start() async {
    final cam = await Permission.camera.request();
    final mic = await Permission.microphone.request();
    if (!cam.isGranted || !mic.isGranted) {
      setState(() {
        _connecting = false;
        _connectError = 'Camera and microphone permission are required to join the call.';
      });
      return;
    }

    final room = Room();
    try {
      await room.connect(widget.wsUrl, widget.jwt);
      // For the callee, the caller is already in the room at connect
      // time → ParticipantConnectedEvent never fires for them and our
      // `_hadRemote` flag would otherwise stay false, defeating the
      // "auto-hangup when peer leaves" logic. Seed the flag from the
      // initial participant snapshot.
      if (room.remoteParticipants.isNotEmpty) {
        _hadRemote = true;
      }
      await room.localParticipant?.setCameraEnabled(true);
      // EC + NS on, AGC OFF. Rationale: the translation pipeline plays
      // a second audio stream on the speakers that the browser's EC
      // doesn't fully account for, so any captured leak goes back into
      // LiveKit. AGC then amplifies that leak each loop and the
      // feedback runs away to infinity. Without AGC the captured leak
      // stays below its source and decays naturally.
      await room.localParticipant?.setMicrophoneEnabled(
        true,
        audioCaptureOptions: const AudioCaptureOptions(
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: false,
        ),
      );
      // First attach with whatever remote-lang we already know (often nothing
      // yet). Refreshed dynamically as participants join / metadata arrives.
      await _refreshTranslationBinding(room);
      room.addListener(_onRoomChanged);
      _roomEvents = room.createListener()
        ..on<TrackSubscribedEvent>((_) {
          if (mounted) setState(() {});
        })
        ..on<TrackUnsubscribedEvent>((_) {
          if (mounted) setState(() {});
        })
        ..on<LocalTrackPublishedEvent>((_) {
          if (mounted) setState(() {});
        })
        // Turning a camera on/off mutes/unmutes its track. Rebuild so the
        // camera-off tile replaces the frozen last frame (and vice versa).
        ..on<TrackMutedEvent>((_) {
          if (mounted) setState(() {});
        })
        ..on<TrackUnmutedEvent>((_) {
          if (mounted) setState(() {});
        })
        ..on<ParticipantConnectedEvent>((_) {
          // First remote joining = call answered → silence the caller's
          // dial tone (no-op on native via the stub).
          CallAlert.stop();
          _hadRemote = true;
          unawaited(_refreshTranslationBinding(room));
          if (mounted) setState(() {});
        })
        ..on<ParticipantDisconnectedEvent>((_) {
          unawaited(_refreshTranslationBinding(room));
          if (mounted) setState(() {});
          // 1:1 calls only — if we had a peer and they just left,
          // there's no reason to keep the room (or our credit meter)
          // running. Auto-hangup so the caller doesn't burn minutes
          // sitting alone in an empty room.
          if (_hadRemote && room.remoteParticipants.isEmpty && mounted) {
            unawaited(_hangUp());
          }
        })
        ..on<ParticipantMetadataUpdatedEvent>((_) {
          unawaited(_refreshTranslationBinding(room));
          if (mounted) setState(() {});
        });
      // A participant may have joined in the window between connect() and
      // this listener being attached — very likely in live calls where
      // both peers join at once, and the slow translation setup above
      // widens the window. That ParticipantConnectedEvent would be missed,
      // leaving _hadRemote false and defeating the auto-hangup when the
      // peer later leaves. Re-seed from the current snapshot so both sides
      // are sent back to the live screen when either one ends the call.
      if (room.remoteParticipants.isNotEmpty) {
        _hadRemote = true;
      }
      await _audio.bind(room);
      widget.translation.translationListenable?.addListener(_onTranslationStateChanged);
      if (mounted) {
        setState(() {
          _room = room;
          _connecting = false;
          _micOn = true;
          _camOn = true;
        });
      }
      _connectedAt = DateTime.now();
      Analytics.track(
        'call_started',
        roomName: widget.roomName,
        langFrom: widget.mySourceLang,
        langTo: _attachedRemoteLang,
        props: {'kind': _callKind},
      );
    } catch (e) {
      await room.disconnect();
      Analytics.track(
        'call_failed',
        roomName: widget.roomName,
        props: {'kind': _callKind, 'message': e.toString()},
      );
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectError = e.toString();
        });
      }
    }
  }

  RemoteParticipant? _primaryRemote(Room room) {
    final it = room.remoteParticipants.values.iterator;
    if (!it.moveNext()) return null;
    return it.current;
  }

  String _remoteDisplayName(RemoteParticipant? p) {
    if (p == null) return '';
    final n = p.name.trim();
    if (n.isNotEmpty) return n;
    final id = p.identity;
    if (id.length > 14) return '${id.substring(0, 14)}…';
    return id;
  }

  /// Whether we should draw the small PiP at all. We always show it as
  /// long as a participant exists on the side that PiP would represent,
  /// even when their camera is off — the cell falls back to an avatar
  /// placeholder so the layout doesn't collapse mid-call.
  bool _pipFeedAvailable({
    VideoTrack? local,
    VideoTrack? remote,
    bool hasRemote = false,
  }) {
    if (_selfMain) return hasRemote;
    return true; // local participant always exists when call is up
  }

  VideoTrack? _remoteVideo(Room room) {
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        // A muted publication means the participant turned their camera
        // off — LiveKit mutes the track instead of unpublishing it. Treat
        // it as "no video" so the camera-off tile shows instead of a
        // frozen / black VideoTrackRenderer.
        if (pub.muted) continue;
        final t = pub.track;
        if (t != null) return t;
      }
    }
    return null;
  }

  VideoTrack? _localVideo(Room room) {
    final lp = room.localParticipant;
    if (lp == null) return null;
    for (final pub in lp.videoTrackPublications) {
      if (pub.muted) continue;
      final t = pub.track;
      if (t != null) return t;
    }
    return null;
  }

  Future<void> _toggleMic() async {
    final room = _room;
    if (room == null) return;
    final next = !_micOn;
    await room.localParticipant?.setMicrophoneEnabled(next);
    if (mounted) setState(() => _micOn = next);
  }

  Future<void> _toggleCam() async {
    final room = _room;
    if (room == null) return;
    final next = !_camOn;
    await room.localParticipant?.setCameraEnabled(next);
    if (mounted) setState(() => _camOn = next);
  }

  /// Re-open the OS share sheet with the guest-invite link. Only reachable
  /// from the waiting-room placeholder when [CallScreen.inviteShareText] is
  /// set (host side of a guest-invite call).
  Future<void> _shareInviteLink() async {
    final text = widget.inviteShareText;
    if (text == null) return;
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: text,
          sharePositionOrigin: box != null
              ? box.localToGlobal(Offset.zero) & box.size
              : null,
        ),
      );
    } catch (_) {
      // Sheet dismissed or sharing unavailable — nothing to do.
    }
  }

  void _openAudioSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: WhatsAppCallTheme.bar,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => _AudioSettingsSheet(controller: _audio),
    );
  }

  void _openLanguageSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: WhatsAppCallTheme.bar,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => _OutputLanguageSheet(
        currentCode: _myOutputLang,
        onSelected: (code) {
          Navigator.of(ctx).pop();
          _changeOutputLanguage(code);
        },
      ),
    );
  }

  /// Change the language the local user hears the remote translated into.
  /// Local-only: it rebuilds our incoming translation pipeline with a new
  /// output language. The remote participant is not affected — we never
  /// touch our LiveKit metadata, so they keep translating our speech from
  /// our real spoken language.
  Future<void> _changeOutputLanguage(String code) async {
    if (code.isEmpty || code == _myOutputLang) return;
    setState(() => _myOutputLang = code);
    final room = _room;
    if (room != null) {
      await _refreshTranslationBinding(room);
    }
  }

  Future<void> _hangUp() async {
    await widget.translation.detach();
    await _roomEvents?.dispose();
    _roomEvents = null;
    final r = _room;
    _room = null;
    if (r != null) {
      r.removeListener(_onRoomChanged);
      await r.disconnect();
      await r.dispose();
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WhatsAppCallTheme.bar,
        title: const Text('Leave call?', style: TextStyle(color: WhatsAppCallTheme.strongText)),
        content: const Text(
          'You will disconnect from this room.',
          style: TextStyle(color: WhatsAppCallTheme.subtleText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: WhatsAppCallTheme.danger),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) await _hangUp();
  }

  @override
  void dispose() {
    // call_ended is emitted here, not in _hangUp(), because dispose()
    // runs on every exit path (hang-up, peer-left auto-hangup, system
    // back) — so the call is counted exactly once with its duration.
    final startedAt = _connectedAt;
    if (startedAt != null) {
      Analytics.track(
        'call_ended',
        roomName: widget.roomName,
        langFrom: widget.mySourceLang,
        langTo: _attachedRemoteLang,
        props: {
          'kind': _callKind,
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
        },
      );
    }
    widget.translation.translationListenable?.removeListener(_onTranslationStateChanged);
    _audio.dispose();
    UsageTracker.creditsExhausted.removeListener(_onCreditsExhausted);
    // Flush whatever seconds were used since the last tick before tearing
    // everything down. Fire-and-forget — disposing a State must be sync.
    unawaited(UsageTracker.stop());
    final ev = _roomEvents;
    _roomEvents = null;
    if (ev != null) unawaited(ev.dispose());
    final r = _room;
    _room = null;
    if (r != null) {
      r.removeListener(_onRoomChanged);
      unawaited(() async {
        await widget.translation.detach();
        await r.disconnect();
        await r.dispose();
      }());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_connectError != null) {
      return Scaffold(
        backgroundColor: WhatsAppCallTheme.scaffold,
        appBar: AppBar(
          backgroundColor: WhatsAppCallTheme.scaffold,
          foregroundColor: WhatsAppCallTheme.strongText,
          title: const Text('Could not join'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 48, color: WhatsAppCallTheme.danger.withValues(alpha: 0.9)),
                const SizedBox(height: 16),
                Text(
                  _connectError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: WhatsAppCallTheme.subtleText, height: 1.4),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Go back'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_connecting || _room == null) {
      return Scaffold(
        backgroundColor: WhatsAppCallTheme.scaffold,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                height: 40,
                width: 40,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: WhatsAppCallTheme.accent,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Connecting to ${widget.roomName}…',
                style: const TextStyle(
                  color: WhatsAppCallTheme.subtleText,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final room = _room!;
    final remote = _remoteVideo(room);
    final local = _localVideo(room);
    final remoteCount = room.remoteParticipants.length;
    final peer = _primaryRemote(room);
    final peerName = _remoteDisplayName(peer);
    final peerFirstName =
        peerName.isEmpty ? null : peerName.split(' ').first;
    final localFirstName = widget.displayName.trim().isEmpty
        ? null
        : widget.displayName.trim().split(' ').first;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _confirmLeave();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.black,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Main view priority:
                //   1. Remote video, if the remote has a published camera.
                //   2. "Camera off" placeholder for the remote (their tile
                //      stays visible, audio keeps flowing).
                //   3. Self-main local video when explicitly swapped.
                //   4. Local "camera off" placeholder when self-main + cam off.
                //   5. Empty-room placeholder if no remote yet.
                if (_selfMain && local != null && _camOn)
                  GestureDetector(
                    onTap: remoteCount > 0
                        ? () => setState(() => _selfMain = false)
                        : null,
                    child: VideoTrackRenderer(
                      local,
                      fit: VideoViewFit.cover,
                      mirrorMode: VideoViewMirrorMode.mirror,
                    ),
                  )
                else if (_selfMain && remoteCount > 0)
                  // Self-main but local cam off → still let the user tap to
                  // swap back to the remote. Show the local user's first
                  // name as placeholder.
                  GestureDetector(
                    onTap: () => setState(() => _selfMain = false),
                    child: _CameraOffTile(label: localFirstName),
                  )
                else if (remote != null)
                  VideoTrackRenderer(
                    remote,
                    fit: VideoViewFit.cover,
                    mirrorMode: VideoViewMirrorMode.off,
                  )
                else if (remoteCount > 0)
                  // Remote is connected but has their camera off — keep the
                  // tile visible, the call (audio + translation) is still up.
                  _CameraOffTile(label: peerFirstName)
                else
                  Container(
                    color: WhatsAppCallTheme.surface,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person, size: 80, color: Colors.white.withValues(alpha: 0.28)),
                        const SizedBox(height: 14),
                        Text(
                          'Waiting for the other person…',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.78),
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Share the same room name on another device.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 13,
                          ),
                        ),
                        if (widget.inviteShareText != null) ...[
                          const SizedBox(height: 22),
                          FilledButton.icon(
                            onPressed: _shareInviteLink,
                            icon: const Icon(Icons.ios_share_rounded, size: 18),
                            label: Text(AppStrings.t('call_share_invite')),
                          ),
                        ],
                      ],
                    ),
                  ),
                if (widget.translation.translationListenable != null)
                  Positioned(
                    left: 10,
                    right: 10,
                    top: MediaQuery.paddingOf(context).top + 12,
                    child: ListenableBuilder(
                      listenable: widget.translation.translationListenable!,
                      builder: (context, _) {
                        return TranslationFeedbackRibbon(
                          phase: widget.translation.translationFeedbackPhase,
                          remoteHot: widget.translation.translationRemoteVoiceHot,
                          remoteParticipantCount: remoteCount,
                        );
                      },
                    ),
                  ),
                // PiP: shows whichever feed is NOT the main one. Tap to
                // swap. Always rendered when the corresponding party
                // exists, even if their camera is off — falls back to a
                // tiny "camera off" tile so the layout doesn't pop.
                if (_pipFeedAvailable(
                    local: local, remote: remote, hasRemote: remoteCount > 0))
                  Positioned(
                    top: MediaQuery.paddingOf(context).top + 52,
                    right: 12,
                    width: 118,
                    height: 176,
                    child: GestureDetector(
                      onTap: () => setState(() => _selfMain = !_selfMain),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white30, width: 1.5),
                            color: Colors.black,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.45),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: () {
                            // PiP shows the "not main" side.
                            if (_selfMain) {
                              // Main = local, PiP = remote.
                              if (remote != null) {
                                return VideoTrackRenderer(
                                  remote,
                                  fit: VideoViewFit.cover,
                                  mirrorMode: VideoViewMirrorMode.off,
                                );
                              }
                              return _CameraOffTile(
                                compact: true,
                                label: peerFirstName,
                              );
                            }
                            // Main = remote, PiP = local.
                            if (local != null && _camOn) {
                              return VideoTrackRenderer(
                                local,
                                fit: VideoViewFit.cover,
                                mirrorMode: VideoViewMirrorMode.mirror,
                              );
                            }
                            return _CameraOffTile(
                              compact: true,
                              label: localFirstName,
                            );
                          }(),
                        ),
                      ),
                    ),
                  ),
                if (widget.translation.translationListenable != null)
                  ListenableBuilder(
                    listenable: widget.translation.translationListenable!,
                    builder: (context, _) {
                      final overlay = widget.translation.buildTranslationAudioOverlay();
                      return overlay ?? const SizedBox.shrink();
                    },
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: EdgeInsets.fromLTRB(16, 28, 16, 16 + MediaQuery.paddingOf(context).bottom),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.82),
                          Colors.black.withValues(alpha: 0),
                        ],
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _RoundCallButton(
                          icon: _micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                          label: _micOn ? 'Mute' : 'Unmute',
                          background: WhatsAppCallTheme.bar,
                          onTap: _toggleMic,
                        ),
                        // Live broadcasts keep the camera on — no toggle.
                        if (_callKind != 'live')
                          _RoundCallButton(
                            icon: _camOn
                                ? Icons.videocam_rounded
                                : Icons.videocam_off_rounded,
                            label: _camOn ? 'Video' : 'Off',
                            background: WhatsAppCallTheme.bar,
                            onTap: _toggleCam,
                          ),
                        _RoundCallButton(
                          icon: Icons.tune_rounded,
                          label: 'Audio',
                          background: WhatsAppCallTheme.bar,
                          onTap: _openAudioSheet,
                        ),
                        _RoundCallButton(
                          icon: Icons.translate,
                          label: 'Langue',
                          background: WhatsAppCallTheme.bar,
                          onTap: _openLanguageSheet,
                        ),
                        _RoundCallButton(
                          icon: Icons.call_end_rounded,
                          label: 'End',
                          background: WhatsAppCallTheme.danger,
                          onTap: _hangUp,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

}

class _RoundCallButton extends StatelessWidget {
  const _RoundCallButton({
    required this.icon,
    required this.label,
    required this.background,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color background;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: background,
          shape: const CircleBorder(),
          elevation: 3,
          shadowColor: Colors.black54,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.88), fontSize: 11),
        ),
      ],
    );
  }
}

class _AudioSettingsSheet extends StatelessWidget {
  const _AudioSettingsSheet({required this.controller});

  final AudioController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Text(
                  'Audio',
                  style: TextStyle(
                    color: WhatsAppCallTheme.strongText,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                _MicLevelStrip(level: controller.micLevel),
                const SizedBox(height: 18),
                const _SheetLabel(
                  icon: Icons.record_voice_over_rounded,
                  text: 'Volume de la traduction',
                ),
                Slider(
                  value: controller.translatedVolume,
                  onChanged: (v) => controller.setTranslatedVolume(v),
                  activeColor: WhatsAppCallTheme.accent,
                  inactiveColor: Colors.white24,
                ),
                const SizedBox(height: 6),
                const _SheetLabel(
                  icon: Icons.person_outline_rounded,
                  text: 'Volume voix originale',
                ),
                Slider(
                  value: controller.originalVolume,
                  onChanged: (v) => controller.setOriginalVolume(v),
                  activeColor: WhatsAppCallTheme.accent,
                  inactiveColor: Colors.white24,
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: controller.duckingEnabled,
                  onChanged: controller.setDuckingEnabled,
                  activeTrackColor: WhatsAppCallTheme.accent,
                  title: const Text(
                    'Baisser la voix d’origine',
                    style: TextStyle(color: WhatsAppCallTheme.strongText, fontSize: 15),
                  ),
                  subtitle: Text(
                    controller.isDucking
                        ? 'Active maintenant — traduction en cours'
                        : 'Baisse l’original quand la traduction parle',
                    style: const TextStyle(color: WhatsAppCallTheme.subtleText, fontSize: 12),
                  ),
                ),
                const SizedBox(height: 6),
                _RouteRow(controller: controller),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Bottom sheet to change the language the local user hears the remote
/// translated into. Picking a language only re-routes our own incoming
/// translation pipeline — the remote side is untouched.
class _OutputLanguageSheet extends StatelessWidget {
  const _OutputLanguageSheet({
    required this.currentCode,
    required this.onSelected,
  });

  final String currentCode;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final current = findLanguageByCode(currentCode)?.code ?? '';
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'Langue que j’entends',
              style: TextStyle(
                color: WhatsAppCallTheme.strongText,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Change la langue dans laquelle tu entends l’autre '
              'personne. Ça ne change rien pour elle.',
              style: TextStyle(
                color: WhatsAppCallTheme.subtleText,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final lang in supportedLanguages)
                    _LanguageRow(
                      lang: lang,
                      selected: lang.code == current,
                      onTap: () => onSelected(lang.code),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LanguageRow extends StatelessWidget {
  const _LanguageRow({
    required this.lang,
    required this.selected,
    required this.onTap,
  });

  final AppLanguage lang;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Row(
            children: [
              Text(lang.flag, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  lang.label,
                  style: TextStyle(
                    color: WhatsAppCallTheme.strongText,
                    fontSize: 15,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (selected)
                const Icon(Icons.check_rounded,
                    color: WhatsAppCallTheme.accent, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetLabel extends StatelessWidget {
  const _SheetLabel({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: WhatsAppCallTheme.subtleText),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(color: WhatsAppCallTheme.strongText, fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _MicLevelStrip extends StatelessWidget {
  const _MicLevelStrip({required this.level});
  final double level;

  @override
  Widget build(BuildContext context) {
    final clamped = level.clamp(0.0, 1.0).toDouble();
    return Row(
      children: [
        const Icon(Icons.mic_rounded, size: 16, color: WhatsAppCallTheme.subtleText),
        const SizedBox(width: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: clamped,
              minHeight: 6,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(
                clamped > 0.85 ? WhatsAppCallTheme.danger : WhatsAppCallTheme.accent,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RouteRow extends StatelessWidget {
  const _RouteRow({required this.controller});
  final AudioController controller;

  @override
  Widget build(BuildContext context) {
    final route = controller.route;
    final external = route == AudioRoute.wiredHeadset || route == AudioRoute.bluetooth;
    final routeLabel = switch (route) {
      AudioRoute.bluetooth => 'Bluetooth',
      AudioRoute.wiredHeadset => 'Casque',
      AudioRoute.speaker => 'Haut-parleur',
      AudioRoute.earpiece => 'Écouteur',
    };
    final routeIcon = switch (route) {
      AudioRoute.bluetooth => Icons.bluetooth_audio_rounded,
      AudioRoute.wiredHeadset => Icons.headphones_rounded,
      AudioRoute.speaker => Icons.volume_up_rounded,
      AudioRoute.earpiece => Icons.phone_in_talk_rounded,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SheetLabel(icon: Icons.speaker_phone_rounded, text: 'Sortie audio'),
        Row(
          children: [
            Icon(routeIcon, color: WhatsAppCallTheme.strongText),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                routeLabel,
                style: const TextStyle(color: WhatsAppCallTheme.strongText, fontSize: 14),
              ),
            ),
            Switch.adaptive(
              value: controller.speakerOn,
              onChanged: external ? null : controller.setSpeakerOn,
              activeTrackColor: WhatsAppCallTheme.accent,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            external
                ? 'Sortie gérée par votre appareil tant qu’un casque ou Bluetooth est connecté.'
                : 'Active le haut-parleur ou repasse à l’écouteur.',
            style: const TextStyle(color: WhatsAppCallTheme.subtleText, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// Placeholder rendered in place of a video feed when the participant's
/// camera is off (or the local user has theirs off in a self-main view).
/// The call audio + translation keep running underneath; this just keeps
/// the visual cell from collapsing when video drops mid-call.
class _CameraOffTile extends StatelessWidget {
  const _CameraOffTile({this.label, this.compact = false});

  final String? label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final fontSize = compact ? 13.0 : 24.0;
    final iconSize = compact ? 28.0 : 56.0;
    final hasLabel = label != null && label!.isNotEmpty;
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.videocam_off_rounded,
            size: iconSize,
            color: Colors.white.withValues(alpha: 0.35),
          ),
          if (hasLabel) ...[
            SizedBox(height: compact ? 6 : 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                label!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
