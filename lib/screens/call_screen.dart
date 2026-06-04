import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show RealtimeChannel, Supabase;

import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/audio_controller.dart';
import '../services/auth_service.dart';
import '../services/call_alert.dart';
import '../services/device_id.dart';
import '../services/incoming_call_api.dart';
import '../services/languages.dart';
import '../services/profile_api.dart';
import '../services/translation_api.dart';
import '../services/usage_tracker.dart';
import '../theme/swayco_theme.dart';
import '../translation/realtime_translation_port.dart';
import '../translation/translation_route.dart';
import '../widgets/profile_avatar.dart';

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
    this.isCaller = false,
    this.outgoingCallId,
    this.startWithCamera = false,
    this.peerId,
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
  /// re-opens the share sheet with this text â€” used by the host of a
  /// guest-invite call so they can resend the link while waiting.
  final String? inviteShareText;

  /// True when the local user initiated this call (dialled out, created
  /// the room or the guest-invite link). Drives the "caller pays"
  /// billing rule: a paying subscriber on the receiving end of a call
  /// is never debited — the cost is borne by whoever started the
  /// session, or by the free side if it's a free-vs-paying mix. Free
  /// users are always debited regardless of which side they are on, so
  /// this flag only affects paying users.
  final bool isCaller;

  /// Caller-only: the `incoming_calls` row id of the ring we sent. When
  /// set, the waiting screen listens for the callee declining and closes
  /// itself instead of ringing into an empty room. Null for the callee
  /// and for guest/live calls that have no ring row.
  final String? outgoingCallId;

  /// Start the call with the local camera ON (a "video" call). When false
  /// the call starts audio-only — the camera stays off and isn't even
  /// requested until the user taps the in-call camera toggle.
  final bool startWithCamera;

  /// Device id of the person on the other end (caller for the callee, callee
  /// for the caller). Used purely to fetch their profile for the "call ended"
  /// summary card (PDP + flag). Null for guest/live calls with no known peer.
  final String? peerId;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Room? _room;
  String? _connectError;
  bool _connecting = true;

  /// Keep the connecting splash on screen for at least this long — LiveKit
  /// often connects in well under a second, so the splash used to flash by
  /// before the caller could read it. Flips true after the timer below.
  bool _minSplashDone = false;
  Timer? _splashTimer;

  /// Once a connected call ends, we swap to a black "call ended" summary card
  /// (peer PDP + flag + duration) instead of popping straight back. These hold
  /// the data that card needs.
  bool _ended = false;
  RemoteProfile? _peerProfile;
  // My own profile (PDP) — used for the avatars on my in-call chat captions.
  RemoteProfile? _myProfile;
  Duration? _finalDuration;

  /// Wraps the shareable part of the summary card so it can be captured to a
  /// PNG and shared ("partager la page").
  final GlobalKey _shareCardKey = GlobalKey();
  bool _micOn = true;
  late bool _camOn = widget.startWithCamera;
  /// When true, the local self-view fills the screen and the remote feed
  /// lives in the small PiP. Tap either to swap back.
  bool _selfMain = false;
  EventsListener<RoomEvent>? _roomEvents;

  // ── In-call text chat (typed). What I type is translated into the peer's
  // language and sent over the LiveKit data channel; on their side it shows
  // as a caption AND is read aloud (OpenAI TTS via the backend). Ephemeral —
  // nothing is persisted.
  static const String _captionTopic = 'swayco-chat';
  final List<({String orig, String trans, bool mine})> _captions = [];
  final TextEditingController _chatCtrl = TextEditingController();
  final FocusNode _chatFocus = FocusNode();
  final AudioPlayer _ttsPlayer = AudioPlayer();
  bool _chatTranslate = true;
  bool _chatSending = false;

  /// The remote BCP-47 we have attached the translation pipeline with, so we
  /// only re-attach when it actually changes.
  String _attachedRemoteLang = '';
  /// The local output language the pipeline is currently attached with â€”
  /// tracked alongside [_attachedRemoteLang] so a mid-call language change
  /// also triggers a re-attach.
  String _attachedMyLang = '';
  /// The language the local user currently *hears* the remote translated
  /// into. Starts at the user's own language; changeable mid-call via the
  /// language button. Local-only â€” it is never written to LiveKit
  /// metadata, so the remote participant is completely unaffected.
  late String _myOutputLang = widget.mySourceLang;
  bool _refreshingTranslation = false;
  /// Set when an event arrives while a refresh is in flight; we re-run once
  /// the in-flight call completes so the latest state is reflected.
  bool _refreshPending = false;

  late final AudioController _audio = AudioController(translation: widget.translation);
  bool _lastTranslationSpeaking = false;
  /// Accumulates real translation-live time (runs only while the OpenAI
  /// pipeline is live). Reported as `translation_ms` on the call_ended
  /// analytics event so the admin can cost OpenAI Realtime against actual
  /// translation time rather than whole-call time.
  final Stopwatch _translationLive = Stopwatch();
  /// Set to true the first time any RemoteParticipant joins the room.
  /// Used by the ParticipantDisconnectedEvent handler to distinguish
  /// "caller waiting alone before pickup" (empty + !_hadRemote â†’ keep
  /// the room open) from "peer just left a 1:1 call" (empty +
  /// _hadRemote â†’ auto-hangup so we don't burn credits on a ghost room).
  bool _hadRemote = false;

  /// Caller-only: realtime channel that listens for the callee declining
  /// our ring so the waiting screen can close. Null for the callee and
  /// for calls with no ring row. Removed on teardown.
  RealtimeChannel? _declineChannel;
  /// Guards [_onDeclinedByCallee] so we pop / snackbar at most once.
  bool _declinedHandled = false;

  /// When the LiveKit room finished connecting â€” null until then. Used
  /// to emit the analytics `call_ended` duration from [dispose] (which
  /// always runs, whatever the exit path: hang-up, peer-left, back nav).
  DateTime? _connectedAt;

  /// Guard against showing the invite-friends popup twice in the same
  /// call session — fires once on the credits-exhaustion edge AND once
  /// at init time when credits were already 0 at call start (the
  /// notifier was already `true` from a previous call, so addListener
  /// won't re-fire on the second set-to-true).
  bool _inviteDialogShown = false;

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
    _syncUsageMeter();
  }

  /// Translation credits should only burn while the OpenAI pipeline is
  /// actually live â€” not for the whole call. Pause the meter while
  /// waiting for the peer / connecting / idle, resume it once OpenAI is
  /// connected and translating.
  void _syncUsageMeter() {
    final live = widget.translation.translationFeedbackPhase ==
        TranslationFeedbackPhase.live;
    // The stopwatch tracks real translation time for the cost analytics â€”
    // kept running even when UsageTracker is disabled (test mode).
    if (live) {
      _translationLive.start();
    } else {
      _translationLive.stop();
    }
    if (UsageTracker.isDisabled) return;
    if (live) {
      UsageTracker.resume();
    } else {
      UsageTracker.pause();
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
    // Hold the connecting splash for a minimum of 5s so it is actually
    // readable even when the room connects almost instantly.
    _splashTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _minSplashDone = true);
    });
    unawaited(_loadPeerProfile());
    unawaited(_loadMyProfile());
    unawaited(_initUsageTracking());
    UsageTracker.creditsExhausted.addListener(_onCreditsExhausted);
    // Caller waiting for pickup: listen for the callee declining so we
    // can close this screen instead of ringing into an empty room.
    final callId = widget.outgoingCallId;
    if (widget.isCaller && callId != null && callId.isNotEmpty) {
      _declineChannel = IncomingCallApi.subscribeDecline(
        callId: callId,
        onDeclined: _onDeclinedByCallee,
      );
    }
  }

  /// Best-effort fetch of the peer's profile (PDP + language) for the
  /// "call ended" summary card. Silent on any failure — the card just falls
  /// back to an initial-letter avatar and no flag.
  Future<void> _loadPeerProfile() async {
    final id = widget.peerId;
    if (id == null || id.isEmpty) return;
    try {
      final p = await ProfileApi.fetchById(id);
      if (mounted && p != null) setState(() => _peerProfile = p);
    } catch (_) {
      // Offline / not found — summary degrades gracefully.
    }
  }

  /// Best-effort fetch of my own profile (PDP) for the avatar on my in-call
  /// chat captions. Silent on failure — falls back to an initial-letter tile.
  Future<void> _loadMyProfile() async {
    try {
      final id = await DeviceId.getOrCreate();
      final p = await ProfileApi.fetchById(id);
      if (mounted && p != null) setState(() => _myProfile = p);
    } catch (_) {}
  }

  /// The callee declined our ring. As long as they haven't actually
  /// joined yet ([_hadRemote] still false), stop waiting: silence the
  /// dial tone, tell the user, and close the call screen.
  void _onDeclinedByCallee() {
    if (_declinedHandled || _hadRemote || !mounted) return;
    _declinedHandled = true;
    CallAlert.stop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.t('call_declined'))),
    );
    unawaited(_hangUp());
  }

  /// Pull the user's current credit balance and start the call timer. The
  /// call itself runs regardless â€” we just decide whether translation is
  /// allowed on top.
  Future<void> _initUsageTracking() async {
    final uid = AuthService.currentUserId;
    if (uid.isEmpty) return;
    final p = await ProfileApi.fetchById(uid);
    if (!mounted || p == null) return;
    // "Caller pays" rule: a paying subscriber who is not the caller of
    // this session is never debited. Their abonnement covers it. Free
    // users fall through and are always debited (free vs free → both
    // sides pay; free vs paying → only the free side pays).
    if (p.isPro && !widget.isCaller) {
      debugPrint(
        '[usage] paying callee — skipping tracker '
        '(tier=${p.subscriptionTier})',
      );
      return;
    }
    UsageTracker.start(userId: uid, initialCredits: p.creditsSeconds);
    if (UsageTracker.isDisabled) return;
    // Don't bill the whole call â€” only while translation is live. Set the
    // meter to whatever the pipeline's state is right now.
    _syncUsageMeter();
    if (p.creditsSeconds <= 0) {
      // Already empty before the call started â€” kill translation now,
      // and surface the invite-friends popup directly (the
      // `creditsExhausted` listener won't fire because the notifier
      // was already `true` from a prior session, so no value change).
      await widget.translation.detach();
      if (mounted && !_inviteDialogShown) {
        unawaited(_showInviteFriendsDialog());
      }
    }
  }

  /// Triggered when credits hit 0 mid-call. We detach the translation
  /// pipeline so the OpenAI session stops billing, but leave the LiveKit
  /// connection alone so people can keep talking (untranslated). Then
  /// surface the "Invite 3 amis = +30 min" dialog so the user has a
  /// concrete way to earn more time without forcing them to upgrade.
  void _onCreditsExhausted() {
    if (!UsageTracker.creditsExhausted.value) return;
    unawaited(widget.translation.detach());
    if (!mounted) return;
    if (_inviteDialogShown) return;
    unawaited(_showInviteFriendsDialog());
  }

  /// Modal shown when the user runs out of credits — explains the bonus
  /// and offers to open the OS share sheet with their personal referral
  /// link. Best-effort: a missing profile / referral_code falls back to
  /// the generic `https://www.swayco.fr` URL so the share still works.
  Future<void> _showInviteFriendsDialog() async {
    _inviteDialogShown = true;
    final uid = AuthService.currentUserId;
    String code = '';
    int referrals = 0;
    if (uid.isNotEmpty) {
      final p = await ProfileApi.fetchById(uid);
      code = p?.referralCode ?? '';
      referrals = await ProfileApi.countReferrals(uid);
    }
    if (!mounted) return;
    final progress = referrals % 3;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        // Match the _TipDialog surface (root_shell.dart) — SC.bg would
        // bleed the popup into the mesh background, so we anchor to the
        // same near-black the post-onboarding tips use.
        backgroundColor: const Color(0xFF0A0A0A),
        insetPadding: const EdgeInsets.symmetric(horizontal: 36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: SC.accent.withValues(alpha: 0.15),
                ),
                child: const Icon(
                  Icons.group_add_rounded,
                  color: SC.accent,
                  size: 44,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                AppStrings.t('invite_bonus_title'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                AppStrings.t('invite_bonus_body'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14.5,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                AppStrings.t(
                  'invite_bonus_progress',
                  args: {'count': '$progress', 'total': '3'},
                ),
                style: const TextStyle(
                  color: SC.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: SC.accent,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _shareReferral(code);
                  },
                  child: Text(AppStrings.t('invite_bonus_share_cta')),
                ),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(
                  AppStrings.t('invite_bonus_later'),
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _shareReferral(String code) async {
    final box = context.findRenderObject() as RenderBox?;
    final link = code.isEmpty
        ? 'https://www.swayco.fr'
        : 'https://www.swayco.fr/?ref=$code';
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: AppStrings.t('invite_share_text', args: {'link': link}),
          subject: AppStrings.t('invite_friend'),
          sharePositionOrigin: box != null
              ? box.localToGlobal(Offset.zero) & box.size
              : null,
        ),
      );
    } catch (_) {
      // User cancelled or sharing unavailable.
    }
  }

  Future<void> _start() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      setState(() {
        _connecting = false;
        _connectError = AppStrings.t('call_perm_required');
      });
      return;
    }
    // Camera permission is only needed for a video call. Audio calls never
    // touch the camera (it can still be turned on later from the in-call
    // toggle, which requests permission then).
    if (widget.startWithCamera) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        setState(() {
          _connecting = false;
          _connectError = AppStrings.t('call_perm_required');
        });
        return;
      }
    }

    // Android 12+ requires BLUETOOTH_CONNECT at runtime before in-call
    // audio can be routed to a Bluetooth headset. Ask once here, but
    // never block the call on it â€” a refused grant just keeps audio on
    // the speaker/earpiece. No-op on iOS / web (the OS auto-routes).
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await Permission.bluetoothConnect.request();
    }

    final room = Room();
    try {
      await room.connect(widget.wsUrl, widget.jwt);
      // For the callee, the caller is already in the room at connect
      // time â†’ ParticipantConnectedEvent never fires for them and our
      // `_hadRemote` flag would otherwise stay false, defeating the
      // "auto-hangup when peer leaves" logic. Seed the flag from the
      // initial participant snapshot.
      if (room.remoteParticipants.isNotEmpty) {
        _hadRemote = true;
      }
      await room.localParticipant?.setCameraEnabled(widget.startWithCamera);
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
        // In-call typed-chat messages from the peer.
        ..on<DataReceivedEvent>(_onCaptionData)
        ..on<ParticipantConnectedEvent>((_) {
          // First remote joining = call answered â†’ silence the caller's
          // dial tone (no-op on native via the stub).
          CallAlert.stop();
          _hadRemote = true;
          unawaited(_refreshTranslationBinding(room));
          if (mounted) setState(() {});
        })
        ..on<ParticipantDisconnectedEvent>((_) {
          unawaited(_refreshTranslationBinding(room));
          if (mounted) setState(() {});
          // 1:1 calls only â€” if we had a peer and they just left,
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
      // this listener being attached â€” very likely in live calls where
      // both peers join at once, and the slow translation setup above
      // widens the window. That ParticipantConnectedEvent would be missed,
      // leaving _hadRemote false and defeating the auto-hangup when the
      // peer later leaves. Re-seed from the current snapshot so both sides
      // are sent back to the live screen when either one ends the call.
      if (room.remoteParticipants.isNotEmpty) {
        _hadRemote = true;
      }
      await _audio.bind(room);
      // Call audio plays through the loudspeaker (AudioController's default);
      // users route to earphones/AirPods themselves at the OS level.
      widget.translation.translationListenable?.addListener(_onTranslationStateChanged);
      if (mounted) {
        setState(() {
          _room = room;
          _connecting = false;
          _micOn = true;
          _camOn = widget.startWithCamera;
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
    if (id.length > 14) return '${id.substring(0, 14)}â€¦';
    return id;
  }

  /// Whether we should draw the small PiP at all. We always show it as
  /// long as a participant exists on the side that PiP would represent,
  /// even when their camera is off â€” the cell falls back to an avatar
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
        // off â€” LiveKit mutes the track instead of unpublishing it. Treat
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

  // ── In-call typed chat ────────────────────────────────────────────────

  /// Type → translate into the peer's language → show my bubble → publish
  /// to the peer over the data channel (they see the translation and hear it).
  Future<void> _sendCaption() async {
    final room = _room;
    final text = _chatCtrl.text.trim();
    if (room == null || text.isEmpty || _chatSending) return;
    setState(() => _chatSending = true);
    final to = _discoverRemoteLang(room); // peer's spoken language ('' if unknown)
    var trans = text;
    if (_chatTranslate && to.isNotEmpty) {
      trans = await fetchTextTranslation(
        text: text,
        to: to,
        from: widget.mySourceLang,
      );
    }
    if (!mounted) return;
    setState(() {
      _captions.add((orig: text, trans: trans, mine: true));
      _chatCtrl.clear();
      _chatSending = false;
    });
    try {
      final payload = jsonEncode({'orig': text, 'trans': trans, 'lang': to});
      await room.localParticipant?.publishData(
        Uint8List.fromList(utf8.encode(payload)),
        reliable: true,
        topic: _captionTopic,
      );
    } catch (_) {
      // Best-effort — the message still shows on my side.
    }
  }

  /// A typed message arrived from the peer: show it (original + translation
  /// in my language) and read the translation aloud via OpenAI TTS.
  void _onCaptionData(DataReceivedEvent e) {
    if (e.topic != _captionTopic) return;
    try {
      final m = jsonDecode(utf8.decode(e.data)) as Map<String, dynamic>;
      final orig = m['orig']?.toString() ?? '';
      final trans = m['trans']?.toString() ?? '';
      final lang = m['lang']?.toString() ?? '';
      if (orig.isEmpty && trans.isEmpty) return;
      if (mounted) {
        setState(() => _captions.add((orig: orig, trans: trans, mine: false)));
      }
      if (trans.isNotEmpty) unawaited(_speak(trans, lang));
    } catch (_) {
      // Ignore malformed packets / other topics.
    }
  }

  /// OpenAI TTS (gpt-4o-mini-tts via the backend) for an incoming message.
  Future<void> _speak(String text, String lang) async {
    try {
      final bytes = await fetchSpeech(text: text, lang: lang);
      if (bytes == null || !mounted) return;
      await _ttsPlayer.stop();
      await _ttsPlayer.play(BytesSource(bytes));
    } catch (_) {
      // TTS is best-effort — silence on failure (e.g. backend /tts missing).
    }
  }

  /// The in-call chat composer: translate toggle + text field + send.
  Widget _buildChatComposer() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
      ),
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
      child: Row(
        children: [
          // Translate on/off — when on, the message is translated into the
          // peer's language before it's sent.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _chatTranslate = !_chatTranslate),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                Icons.translate,
                size: 20,
                color: _chatTranslate
                    ? SC.accent
                    : Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _chatCtrl,
              focusNode: _chatFocus,
              minLines: 1,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              cursorColor: SC.accent,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                hintText: AppStrings.t('composer_message_hint'),
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 14,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
              onSubmitted: (_) => _sendCaption(),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _chatSending ? null : _sendCaption,
            child: Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                color: SC.accent,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.arrow_upward_rounded,
                color: Colors.white,
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleCam() async {
    final room = _room;
    if (room == null) return;
    final next = !_camOn;
    // Audio calls don't request camera permission upfront, so the first
    // time the user turns the camera on we ask for it here.
    if (next) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppStrings.t('call_perm_required'))),
          );
        }
        return;
      }
    }
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
      // Sheet dismissed or sharing unavailable â€” nothing to do.
    }
  }

  void _openAudioSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0E0E0E),
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
      backgroundColor: const Color(0xFF0E0E0E),
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
  /// output language. The remote participant is not affected â€” we never
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
    // If the call actually connected, show the black "call ended" summary
    // (PDP + flag + minutes + share) instead of popping straight back. A call
    // that never connected (declined / unanswered) just closes.
    final startedAt = _connectedAt;
    if (startedAt != null && mounted) {
      _finalDuration = DateTime.now().difference(startedAt);
      unawaited(UsageTracker.stop());
      setState(() => _ended = true);
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  String _formatCallDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    if (m <= 0) return '$s s';
    return '$m min ${s.toString().padLeft(2, '0')} s';
  }

  /// Capture the summary card to a PNG and hand it to the OS share sheet —
  /// "partager la page". Best-effort: a capture / share failure is swallowed.
  Future<void> _shareSummary() async {
    try {
      final obj = _shareCardKey.currentContext?.findRenderObject();
      if (obj is! RenderRepaintBoundary) return;
      final image = await obj.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return;
      final data = bytes.buffer.asUint8List();
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(data, name: 'swayco-call.png', mimeType: 'image/png'),
          ],
          sharePositionOrigin: box != null
              ? box.localToGlobal(Offset.zero) & box.size
              : null,
        ),
      );
    } catch (_) {
      // Sheet dismissed / capture unavailable — nothing to do.
    }
  }

  /// Black "call ended" card: the peer's PDP + flag, the minutes spent, a
  /// share button bottom-right and the swayco logo dead-centre at the bottom.
  Widget _buildEndedSummary(BuildContext context) {
    final profile = _peerProfile;
    final name = (profile?.displayName.trim().isNotEmpty ?? false)
        ? profile!.displayName.trim()
        : AppStrings.t('profile_anonymous');
    final firstName = name.split(RegExp(r'\s+')).first;
    final lang = profile?.language.trim() ?? '';
    final appLang = lang.isEmpty ? null : findLanguageByCode(lang);
    final dur = _finalDuration ?? Duration.zero;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      body: SafeArea(
        child: Stack(
          children: [
            // The shareable card (everything captured into the PNG).
            Positioned.fill(
              child: RepaintBoundary(
                key: _shareCardKey,
                child: Container(
                  color: const Color(0xFF0E0E0E),
                  child: Stack(
                    children: [
                      // Peer PDP, then the first name aligned on the same row
                      // as the flag, a touch above centre.
                      Align(
                        alignment: const Alignment(0, -0.18),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ProfileAvatar(
                              displayName: name,
                              avatarUrl: profile?.avatarUrl,
                              avatarColorHex: profile?.avatarColor,
                              size: 132,
                            ),
                            const SizedBox(height: 20),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (appLang != null) ...[
                                    Text(appLang.flag,
                                        style: const TextStyle(fontSize: 30)),
                                    const SizedBox(width: 12),
                                  ],
                                  Flexible(
                                    child: Text(
                                      firstName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 24,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Minutes spent — just above the logo.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 78,
                        child: Column(
                          children: [
                            const Icon(Icons.schedule_rounded,
                                color: SC.accent, size: 22),
                            const SizedBox(height: 6),
                            Text(
                              _formatCallDuration(dur),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Brand icon — dead bottom-centre.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 22,
                        child: Center(
                          child: Image.asset(
                            'assets/icon-fg-transparent.png',
                            height: 52,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Close — kept OUT of the captured card.
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 26),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            // Share the card — bottom-right, also out of the capture.
            Positioned(
              right: 20,
              bottom: 66,
              child: Material(
                color: SC.accent,
                shape: const CircleBorder(),
                elevation: 3,
                shadowColor: Colors.black54,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _shareSummary,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    // Curved "forward/share" arrow: a horizontally mirrored
                    // reply glyph so it points up to the right.
                    child: Transform.flip(
                      flipX: true,
                      child: const Icon(Icons.reply_rounded,
                          color: Colors.white, size: 24),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SC.bubbleIn,
        title: Text(AppStrings.t('call_leave_q'),
            style: const TextStyle(color: SC.textPrimary)),
        content: Text(
          AppStrings.t('call_leave_body'),
          style: const TextStyle(color: SC.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.t('call_stay')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE53935)),
            child: Text(AppStrings.t('call_leave')),
          ),
        ],
      ),
    );
    if (leave == true && mounted) await _hangUp();
  }

  @override
  void dispose() {
    _splashTimer?.cancel();
    // call_ended is emitted here, not in _hangUp(), because dispose()
    // runs on every exit path (hang-up, peer-left auto-hangup, system
    // back) â€” so the call is counted exactly once with its duration.
    final startedAt = _connectedAt;
    if (startedAt != null) {
      // Prefer the duration captured when the call ended — otherwise time
      // spent reading the summary card would inflate the analytics figure.
      final durMs = (_finalDuration ?? DateTime.now().difference(startedAt))
          .inMilliseconds;
      Analytics.track(
        'call_ended',
        roomName: widget.roomName,
        langFrom: widget.mySourceLang,
        langTo: _attachedRemoteLang,
        props: {
          'kind': _callKind,
          'duration_ms': durMs,
          // Real translation-live time â€” drives the OpenAI Realtime cost
          // estimate in the admin dashboard.
          'translation_ms': _translationLive.elapsed.inMilliseconds,
        },
      );
    }
    widget.translation.translationListenable?.removeListener(_onTranslationStateChanged);
    _audio.dispose();
    _chatCtrl.dispose();
    _chatFocus.dispose();
    unawaited(_ttsPlayer.dispose());
    UsageTracker.creditsExhausted.removeListener(_onCreditsExhausted);
    final declineCh = _declineChannel;
    _declineChannel = null;
    if (declineCh != null) {
      unawaited(Supabase.instance.client.removeChannel(declineCh));
    }
    // Flush whatever seconds were used since the last tick before tearing
    // everything down. Fire-and-forget â€” disposing a State must be sync.
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
    if (_ended) return _buildEndedSummary(context);

    if (_connectError != null) {
      return Scaffold(
        backgroundColor: SC.bg,
        appBar: AppBar(
          backgroundColor: SC.bg,
          foregroundColor: SC.textPrimary,
          title: Text(AppStrings.t('call_could_not_join')),
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
                Icon(Icons.error_outline, size: 48, color: const Color(0xFFE53935).withValues(alpha: 0.9)),
                const SizedBox(height: 16),
                Text(
                  _connectError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: SC.textMuted, height: 1.4),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(AppStrings.t('call_go_back')),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_connecting || _room == null || !_minSplashDone) {
      // Splash-style connecting state. Showing the room name + a bare
      // spinner during LiveKit's handshake felt clinical and gave the
      // caller no signal about the credit deduction â€” switch to the
      // app's splash image with a single one-liner hint clarifying
      // that only the caller's monthly credits are debited (the peer
      // listens free). Keeps the spinner so the user still has motion
      // feedback that something is happening. Held for >= 5s (see
      // _minSplashDone) and on the app's black, to match the logo.
      return Scaffold(
        backgroundColor: const Color(0xFF0E0E0E),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
            child: Column(
              children: [
                // Bigger top flex than the bottom spacer below lifts the
                // spinner + text block up off the bottom edge.
                Expanded(
                  flex: 6,
                  child: Center(
                    child: Image.asset(
                      'assets/test-splashscreen.png',
                      width: 220,
                      height: 220,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(
                  height: 28,
                  width: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: SC.accent,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  AppStrings.t('call_connecting_short'),
                  style: const TextStyle(
                    color: SC.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  AppStrings.t('call_connecting_caller_pays'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: SC.textMuted,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const Expanded(flex: 2, child: SizedBox()),
              ],
            ),
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
                  // Self-main but local cam off â†’ still let the user tap to
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
                  // Remote is connected but has their camera off â€” keep the
                  // tile visible, the call (audio + translation) is still up.
                  _CameraOffTile(label: peerFirstName)
                else
                  Container(
                    color: SC.bubbleIn,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person, size: 80, color: Colors.white.withValues(alpha: 0.28)),
                        const SizedBox(height: 14),
                        Text(
                          AppStrings.t('call_waiting_title'),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.78),
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          AppStrings.t('call_waiting_body'),
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
                // PiP: shows whichever feed is NOT the main one. Tap to
                // swap. Always rendered when the corresponding party
                // exists, even if their camera is off â€” falls back to a
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
                // In-call typed chat: recent caption bubbles + the composer,
                // bottom-left so they clear the control rail on the right.
                // Lifts with the keyboard.
                Positioned(
                  left: 8,
                  right: 84,
                  bottom: MediaQuery.viewInsetsOf(context).bottom +
                      MediaQuery.paddingOf(context).bottom +
                      12,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final c in _captions.length > 4
                          ? _captions.sublist(_captions.length - 4)
                          : _captions)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _CaptionBubble(
                            orig: c.orig,
                            trans: c.trans,
                            // My PDP for my lines, the peer's for theirs.
                            name: c.mine
                                ? (_myProfile?.displayName ?? widget.displayName)
                                : (_peerProfile?.displayName ?? ''),
                            avatarUrl: c.mine
                                ? (_myProfile?.avatarUrl ?? '')
                                : (_peerProfile?.avatarUrl ?? ''),
                            avatarColor: c.mine
                                ? (_myProfile?.avatarColor ?? '')
                                : (_peerProfile?.avatarColor ?? ''),
                          ),
                        ),
                      const SizedBox(height: 4),
                      _buildChatComposer(),
                    ],
                  ),
                ),
                // Controls as a vertical rail anchored to the BOTTOM-RIGHT, so
                // they grow upward from the bottom and never reach the PiP
                // self-view in the top-right corner.
                Positioned(
                  right: 12,
                  bottom: 0,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _RoundCallButton(
                            icon: _micOn
                                ? Icons.mic_rounded
                                : Icons.mic_off_rounded,
                            label: _micOn
                                ? AppStrings.t('call_mute')
                                : AppStrings.t('call_unmute'),
                            background: SC.accent,
                            onTap: _toggleMic,
                          ),
                          const SizedBox(height: 12),
                          // Live broadcasts keep the camera on — no toggle.
                          if (_callKind != 'live') ...[
                            _RoundCallButton(
                              icon: _camOn
                                  ? Icons.videocam_rounded
                                  : Icons.videocam_off_rounded,
                              label: _camOn
                                  ? AppStrings.t('call_video')
                                  : AppStrings.t('call_video_off'),
                              background: SC.accent,
                              onTap: _toggleCam,
                            ),
                            const SizedBox(height: 12),
                          ],
                          _RoundCallButton(
                            icon: Icons.tune_rounded,
                            label: AppStrings.t('call_audio'),
                            background: SC.accent,
                            onTap: _openAudioSheet,
                          ),
                          const SizedBox(height: 12),
                          _RoundCallButton(
                            icon: Icons.translate,
                            label: AppStrings.t('call_language'),
                            background: SC.accent,
                            onTap: _openLanguageSheet,
                          ),
                          const SizedBox(height: 12),
                          _RoundCallButton(
                            icon: Icons.call_end_rounded,
                            label: AppStrings.t('call_end'),
                            background: const Color(0xFFE53935),
                            onTap: _hangUp,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Brand watermark — top-centre, always on top of whatever
                // call layout is showing (full-screen, PiP, split…).
                Align(
                  alignment: Alignment.topCenter,
                  child: IgnorePointer(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'swayco.ai',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 25,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                          shadows: [
                            Shadow(
                              color: Colors.black.withValues(alpha: 0.6),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                      ),
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

/// One in-call typed-chat caption: the sender's PDP, then a translucent
/// bubble with the original line (bold) and its translation underneath
/// (italic). Always avatar-left, like the design reference.
class _CaptionBubble extends StatelessWidget {
  const _CaptionBubble({
    required this.orig,
    required this.trans,
    required this.name,
    required this.avatarUrl,
    required this.avatarColor,
  });

  final String orig;
  final String trans;
  final String name;
  final String avatarUrl;
  final String avatarColor;

  @override
  Widget build(BuildContext context) {
    // Soft shadow so white text stays readable on the (now transparent)
    // bubble over the video.
    const shadows = [Shadow(color: Colors.black, blurRadius: 6)];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ProfileAvatar(
          displayName: name,
          avatarUrl: avatarUrl,
          avatarColorHex: avatarColor,
          size: 30,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              // Transparent — just enough to lift the text off the video.
              color: Colors.black.withValues(alpha: 0.30),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  orig,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    shadows: shadows,
                  ),
                ),
                if (trans.isNotEmpty && trans != orig) ...[
                  const SizedBox(height: 3),
                  Text(
                    trans,
                    style: const TextStyle(
                      color: Color(0xCCFFFFFF),
                      fontSize: 14,
                      fontStyle: FontStyle.italic,
                      shadows: shadows,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Bottom sheet to change the language the local user hears the remote
/// translated into. Picking a language only re-routes our own incoming
/// translation pipeline â€” the remote side is untouched.
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
            Text(
              AppStrings.t('call_output_language_title'),
              style: const TextStyle(
                color: SC.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              AppStrings.t('call_output_language_hint'),
              style: const TextStyle(
                color: SC.textMuted,
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
                    color: SC.textPrimary,
                    fontSize: 15,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (selected)
                const Icon(Icons.check_rounded,
                    color: SC.accent, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// In-call audio panel — just the sliders: mic level, translation volume and
/// original-voice volume. (The ducking toggle + speaker/earpiece route were
/// dropped on request.)
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
                Text(
                  AppStrings.t('call_audio'),
                  style: const TextStyle(
                    color: SC.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                _MicLevelStrip(level: controller.micLevel),
                const SizedBox(height: 18),
                _SheetLabel(
                  icon: Icons.record_voice_over_rounded,
                  text: AppStrings.t('call_translation_volume'),
                ),
                Slider(
                  value: controller.translatedVolume,
                  onChanged: (v) => controller.setTranslatedVolume(v),
                  activeColor: SC.accent,
                  inactiveColor: Colors.white24,
                ),
                const SizedBox(height: 6),
                _SheetLabel(
                  icon: Icons.person_outline_rounded,
                  text: AppStrings.t('call_original_volume'),
                ),
                Slider(
                  value: controller.originalVolume,
                  onChanged: (v) => controller.setOriginalVolume(v),
                  activeColor: SC.accent,
                  inactiveColor: Colors.white24,
                ),
              ],
            );
          },
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
          Icon(icon, size: 18, color: SC.textMuted),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
                color: SC.textPrimary, fontSize: 14, fontWeight: FontWeight.w600),
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
        const Icon(Icons.mic_rounded, size: 16, color: SC.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: clamped,
              minHeight: 6,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(
                clamped > 0.85 ? const Color(0xFFE53935) : SC.accent,
              ),
            ),
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
