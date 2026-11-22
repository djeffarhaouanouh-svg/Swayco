import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import '../widgets/tap_pad.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:country_flags/country_flags.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show RealtimeChannel, Supabase;

import '../config/app_config.dart';
import '../services/analytics.dart';
import '../services/attribution.dart';
import '../services/app_strings.dart';
import '../services/activity_signal.dart';
import '../services/swayco_sounds.dart';
import '../services/auth_service.dart';
import '../services/egress_api.dart';
import '../swayco/asr/apple_stt_channel.dart';
import '../swayco/asr/asr_service.dart';
import '../services/audio_controller.dart';
import '../services/call_audio.dart';
import '../services/call_alert.dart';
import '../services/incoming_call_api.dart';
import '../services/local_notifications.dart';
import '../services/ios_callkit.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/permission_priming.dart';
import '../services/profile_api.dart';
import '../swayco/speech/speech_service.dart';
import '../swayco/wire_compat.dart';
import '../services/debug_overlay.dart';
import '../services/device_id.dart';
import '../services/supabase_service.dart' show isSupabaseReady;
import '../services/translation_api.dart';
import '../services/user_prefs.dart';
import '../theme/swayco_theme.dart';
import '../swayco/realtime_translation_port.dart';
import '../swayco/translation_route.dart';
import '../widgets/call_loader.dart';
import '../widgets/popup_kit.dart';
import '../widgets/pressable.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/translation_step_caption.dart';
import '../widgets/swayco_dialog.dart';
import '../widgets/swayco_popups_extra.dart';
import '../widgets/swayco_wordmark.dart';

/// The connecting-splash ("sas") mark, decoded at boot and pinned for the
/// process lifetime.
///
/// [Image] only paints once its decode has finished, so the splash used to
/// open on an empty column and the logo popped in a frame or two later.
/// Resolving the stream at startup moves that decode into the boot, where
/// there is nothing to be late for; holding the listener keeps [ImageCache]
/// from evicting it once the user has scrolled a few hundred Discover
/// photos — a precache alone does not survive that.
class CallSplashImage {
  const CallSplashImage._();

  static const provider = AssetImage('assets/icon-saas.png');

  static ImageStream? _stream;

  /// Idempotent — safe to call from more than one boot path. Needs no
  /// [BuildContext] and nothing awaits it: the decode lands long before a
  /// call can start.
  static void warm() {
    if (_stream != null) return;
    _stream = provider.resolve(ImageConfiguration.empty)
      ..addListener(
        ImageStreamListener(
          (_, _) {},
          onError: (e, _) => debugPrint('call splash precache failed: $e'),
        ),
      );
  }
}

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
    this.startWithCamera = true,
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

  /// Dev-only ad-footage recording (LiveKit Egress). Non-null while a
  /// recording is running. Never surfaced to a regular user: the REC button
  /// itself only renders for [_isEgressAdmin], and the backend re-checks the
  /// caller's Supabase email regardless.
  String? _egressId;
  DateTime? _egressStartedAt;
  bool _egressBusy = false;
  /// Réponse de la liste d'autorisation DU SERVEUR (`EGRESS_ADMIN_EMAILS`,
  /// plusieurs adresses). Donner l'accès à quelqu'un = ajouter son e-mail dans
  /// Railway : pas de nouvelle version de l'app. Le serveur revérifie de toute
  /// façon à chaque démarrage / arrêt.
  bool _egressAllowedByServer = false;
  bool get _isEgressAdmin {
    if (_egressAllowedByServer) return true;
    final admin = resolvedEgressAdminEmail();
    return admin.isNotEmpty &&
        AuthService.currentEmail.toLowerCase() == admin.toLowerCase();
  }

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
  Duration? _finalDuration;

  /// Wraps the shareable part of the summary card so it can be captured to a
  /// PNG and shared ("partager la page").
  final GlobalKey _shareCardKey = GlobalKey();
  /// Ce qui est DIT, transcrit — chaque device dans sa langue. Les lignes ne
  /// vivent que le temps de l'appel (rien n'est persisté).
  final List<_SpokenTurn> _turns = [];

  /// La saisie de la conversation. Ce qui est tapé part comme une phrase dite :
  /// traduit chez le pair, écrit et lu à voix haute. Rien n'est persisté, ça ne
  /// vit que le temps de l'appel.
  final TextEditingController _chatCtrl = TextEditingController();
  final FocusNode _chatFocus = FocusNode();
  bool _chatSending = false;

  // ── La carte de messages (permanente, en bas) ───────────────────────────
  /// La saisie est dépliée (sinon : un rond crayon).
  bool _composerOpen = false;
  Timer? _composerIdle;

  /// Combien la saisie dépliée reste ouverte sans focus ni geste.
  static const Duration _kComposerIdle = Duration(seconds: 4);

  /// Un tap dans la zone des messages masque l'en-tête de la carte (galet,
  /// statut, drapeau) ; un second le ramène.
  bool _cardHeaderHidden = false;

  /// L'étape du texte d'état (0 « Parle normalement », 1 « Patiente… », 2 « a
  /// reçu ta traduction », 3 « À toi »). Le galet de l'en-tête s'estompe à 1.
  final ValueNotifier<int> _trStep = ValueNotifier<int>(0);

  /// Un tap dans la zone des messages : masque / ramène l'en-tête de la carte.
  void _toggleCardHeader() {
    if (!mounted) return;
    if (_chatFocus.hasFocus) {
      _chatFocus.unfocus();
      return;
    }
    setState(() => _cardHeaderHidden = !_cardHeaderHidden);
  }

  /// Déplie la saisie (le rond crayon touché) et monte le clavier.
  void _openComposer() {
    _composerIdle?.cancel();
    setState(() => _composerOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _composerOpen) _chatFocus.requestFocus();
    });
  }

  /// La saisie se replie d'elle-même : sans focus, sans envoi en cours, après
  /// [_kComposerIdle] sans geste. Un texte resté dans le champ se replie aussi,
  /// mais le rond porte alors un point jaune (brouillon).
  void _armComposerIdle() {
    _composerIdle?.cancel();
    if (!_composerOpen) return;
    _composerIdle = Timer(_kComposerIdle, () {
      if (!mounted || !_composerOpen) return;
      if (_chatFocus.hasFocus || _chatSending) {
        _armComposerIdle();
        return;
      }
      setState(() => _composerOpen = false);
    });
  }

  void _onChatFocusChanged() {
    if (_chatFocus.hasFocus) {
      _composerIdle?.cancel();
    } else {
      _armComposerIdle();
    }
  }

  /// Un panneau est ouvert par-dessus l'appel (langues, son).
  ///
  /// La carte et le rail se rangent simplement DERRIÈRE lui : ni flou de la
  /// vidéo, ni galet qui bouge.
  bool _sheetOpen = false;

  /// Le panneau « Son » est ouvert (la touche du rail est alors blanche).
  bool _audioSheetOpen = false;

  /// Ouvre [body] par-dessus l'appel et remet tout en place à la fermeture —
  /// quelle qu'en soit la manière, y compris un balayage.
  Future<void> _showCallSheet(WidgetBuilder body) {
    // Le rail se ferme à l'ouverture d'un panneau.
    _dockIdleTimer?.cancel();
    setState(() {
      _sheetOpen = true;
      _dockDimmed = true;
    });
    return showModalBottomSheet<void>(
      context: context,
      // L'appel reste sombre en toute apparence : surface figée.
      backgroundColor: const Color(0xFF16161B),
      // Pas de voile : rien ne doit flouter ni assombrir l'écran d'appel.
      barrierColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: body,
    ).whenComplete(() {
      if (!mounted) return;
      setState(() {
        _sheetOpen = false;
        _audioSheetOpen = false;
      });
    });
  }

  /// Le rail de droite est RANGÉ par défaut : il apparaît au tap sur l'écran et
  /// s'efface après [_kDockIdle] sans geste. Rangé, il ne répond plus aux taps.
  bool _dockDimmed = false;
  Timer? _dockIdleTimer;

  /// Le silence au bout duquel le rail disparaît.
  static const Duration _kDockIdle = Duration(seconds: 2);

  /// Un tap sur l'écran, sur le rail : il se rallume et repart pour
  /// [_kDockIdle] de sursis.
  void _wakeDock() {
    _armDockIdle();
    if (_dockDimmed && mounted) setState(() => _dockDimmed = false);
  }

  void _armDockIdle() {
    _dockIdleTimer?.cancel();
    _dockIdleTimer = Timer(_kDockIdle, () {
      if (!mounted || _dockDimmed) return;
      setState(() => _dockDimmed = true);
    });
  }

  /// Le plancher absolu sous lequel rien n'est jamais de la parole.
  ///
  /// Il DÉPEND DE LA PLATEFORME, parce que `media-source.audioLevel` ne vit pas
  /// sur la même échelle des deux côtés :
  ///  • natif, mesuré sur un iPhone 16 — pièce calme ~0.005, voix 0.05 à 0.6,
  ///    donc 0.01 laisse passer la voix et arrête la pièce ;
  ///  • web, mesuré plus tôt — une voix normale n'y vaut que quelques
  ///    millièmes. Y poser 0.01 fermerait la barre pour toujours, d'où le
  ///    plancher d'origine conservé.
  ///
  /// Le vrai seuil reste celui qui suit le bruit de la pièce (voir plus bas) ;
  /// celui-ci n'est là que contre le silence numérique.
  static final double _kVoiceOn = kIsWeb ? 0.001 : 0.01;

  /// Le bruit de la pièce, appris pendant l'appel : il descend vite vers le
  /// silence et ne remonte que lentement, si bien qu'une voix ne le tire pas
  /// vers le haut mais qu'un ventilateur qui démarre finit par y entrer.
  ///
  /// Sans lui, un seuil fixe est soit sourd dans une pièce bruyante, soit
  /// déclenché en permanence par le souffle du micro — c'était le cas : la
  /// barre s'ouvrait au moindre frémissement et ne se refermait plus.
  double _noiseFloor = 0.02;

  /// Combien de mesures d'affilée au-dessus du seuil avant de déclarer que ça
  /// parle. Deux (~500 ms) : un choc sur la table en fait une, pas deux.
  int _hotTicks = 0;

  /// De quoi calibrer sans deviner : le plus haut niveau vu sur les 3 dernières
  /// secondes et le seuil du moment, écrits dans le panneau de debug comme le
  /// fait le VAD. C'est le seul moyen de savoir sur quelle échelle vit
  /// vraiment cette mesure, sur le web comme sur l'appareil.
  double _probePeak = 0;
  int _probeTicks = 0;

  /// Au moins une mesure NEUVE dans la fenêtre courante. Faux = le tampon ne
  /// bouge plus, le pic affiché serait un reste.
  bool _probeFresh = false;

  /// Niveau de MON micro, mesuré ici même — pas au serveur.
  ///
  /// `ActiveSpeakersChangedEvent` dépend du SFU : il n'arrive qu'aux
  /// changements de locuteur, et rien ne garantit qu'il porte notre propre
  /// voix. Les stats de l'émetteur, elles, viennent de la couche WebRTC
  /// locale : `media-source.audioLevel` est la voix telle qu'elle sort du
  /// micro, à la milliseconde, que le serveur suive ou non.
  double _localVoice = 0;

  /// Idem pour la voix d'en face, elle par contre ne peut venir que du serveur.
  double _remoteVoice = 0;
  Timer? _micProbe;

  /// La sonde n'a jamais rien mesuré alors que le micro tournait : sur cette
  /// plateforme, `media-source.audioLevel` n'est pas rempli. On repasse alors
  /// sur la vue du serveur, moins fine mais présente partout.
  ///
  /// Ça existe parce que le champ est standard mais pas garanti : le rapport
  /// natif d'iOS/Android peut l'omettre selon la version de libwebrtc, et un
  /// dock qui ne bouge plus du tout serait pire qu'un dock en retard.
  bool _micProbeDead = false;
  int _micProbeSilentTicks = 0;

  /// La mesure précédente, pour reconnaître une sonde figée (micro coupé) et
  /// cesser d'en nourrir le plancher de bruit.
  double _lastProbeLevel = -1;

  /// Le seuil d'ouverture ne monte jamais au-dessus : une voix normale vaut
  /// 0.05 à 0.6 sur cette échelle, donc au-delà de 0.08 on ne filtrerait plus
  /// le bruit, on refuserait la parole.
  static const double _kVoiceCeiling = 0.08;

  /// ~5 s de micro ouvert sans jamais une seule mesure : la sonde est muette.
  static const int _kMicProbeGiveUp = 7;

  void _startMicProbe(Room room) {
    _micProbe?.cancel();
    _micProbe = Timer.periodic(const Duration(milliseconds: 750), (_) async {
      if (!mounted || _micProbeDead) return;
      LocalAudioTrack? mic;
      for (final pub in room.localParticipant?.audioTrackPublications ??
          const <LocalTrackPublication>[]) {
        final t = pub.track;
        if (t is LocalAudioTrack) {
          mic = t;
          break;
        }
      }
      if (mic == null) return;
      double level = 0;
      try {
        final stats = await mic.getSenderStats();
        level = (stats?.audioSourceStats?.audioLevel ?? 0).toDouble();
      } catch (_) {
        // Une sonde qui échoue ne doit rien casser : on garde l'ancien niveau.
        return;
      }
      if (!mounted) return;
      if (level <= 0) {
        // Micro coupé : c'est normal de ne rien mesurer, on ne compte pas.
        if (_micOn && ++_micProbeSilentTicks >= _kMicProbeGiveUp) {
          _micProbeDead = true;
          DebugOverlay.log(
            'mic probe: no media-source.audioLevel on this platform — '
            'falling back to the server speaker list',
          );
        }
      } else {
        _micProbeSilentTicks = 0;
      }
      final lvl = level.clamp(0.0, 1.0);
      // Micro coupé ou capture relâchée : la sonde relit indéfiniment la même
      // valeur. En la donnant à manger au plancher, celui-ci montait vers elle,
      // le seuil (×4) passait au-dessus de la parole réelle, et plus une seule
      // voix n'ouvrait la barre pour le reste de l'appel. Mesuré : un seuil
      // parti de 0.021 à 0.159 pendant qu'un pic figé restait à 0.104.
      // Une valeur au bit près identique à la précédente n'est pas une mesure.
      final frozen = lvl == _lastProbeLevel;
      _lastProbeLevel = lvl;
      if (!frozen) {
        // Le plancher suit le silence de près et la voix de très loin.
        _noiseFloor = lvl < _noiseFloor
            ? _noiseFloor * 0.7 + lvl * 0.3
            : _noiseFloor * 0.995 + lvl * 0.005;
      }
      // Le plancher de bruit compte quadruple : dans une pièce bruyante il faut
      // dépasser franchement l'ambiance, pas la frôler. Mais il est PLAFONNÉ :
      // au-delà, on n'exige plus « plus fort que la pièce », on devient sourd.
      final threshold =
          math.max(_kVoiceOn, math.min(_noiseFloor * 4, _kVoiceCeiling));
      // Micro coupé, ou sonde figée sur la même valeur : il n'y a PAS de voix.
      // Sans ça, une mesure gelée au-dessus du seuil faisait battre la pastille
      // sans fin — on se met en muet et le bouton continue de vibrer, alors
      // qu'on a précisément demandé le silence.
      final hot = _micOn && !frozen && lvl > threshold;
      if (lvl > _probePeak) _probePeak = lvl;
      if (!frozen) _probeFresh = true;
      if (++_probeTicks % 12 == 0) {
        // Une sonde qui n'a rien mesuré de neuf de toute la fenêtre republiait
        // son dernier pic, à la quatrième décimale près, ligne après ligne :
        // dans un log ça se lit comme une application bloquée, alors que le
        // micro est simplement coupé et que plus rien n'alimente le tampon.
        DebugOverlay.log(
          _probeFresh
              ? 'mic probe: peak over last 3s '
                  '${_probePeak.toStringAsFixed(4)} '
                  '(opens at ${threshold.toStringAsFixed(4)})'
              : 'mic probe: no capture (${_micOn ? "buffer stalled" : "muted"})',
        );
        _probePeak = 0;
        _probeFresh = false;
      }
      _hotTicks = hot ? _hotTicks + 1 : 0;
      // La pastille ne bat que sur de la vraie parole : lui donner le bruit de
      // fond la ferait trembler tout l'appel.
      _localVoice = hot ? lvl : 0.0;
      if (hot) {
        if (lvl > _phrasePeak) _phrasePeak = lvl;
        _phraseSum += lvl;
        _phraseTicks++;
      }
      _publishVoiceLevel();
      // Trois relevés consécutifs (~750 ms) plutôt que deux : une porte qui
      // claque ou un raclement de gorge ne tient pas aussi longtemps.
      // Le panneau ne se rallume plus sur la voix : seul le doigt le rappelle.
      // Ce que la parole allume, c'est la lueur — et elle, elle ne dépend pas
      // de lui.
    });
  }

  /// La pastille bat pour toutes les voix — la mienne comme la sienne.
  void _publishVoiceLevel() {
    final v = _localVoice > _remoteVoice ? _localVoice : _remoteVoice;
    if ((v - _voiceLevel.value).abs() > 0.005) _voiceLevel.value = v;
    // MA voix seule (vraie parole au micro, 0 sinon) : l'explication de la
    // traduction s'en sert pour savoir quand je parle et quand je me tais.
    if ((_localVoice - _myVoiceLevel.value).abs() > 0.005) {
      _myVoiceLevel.value = _localVoice;
    }
  }

  /// Ma voix seule, 0..1 — voir [_publishVoiceLevel].
  final ValueNotifier<double> _myVoiceLevel = ValueNotifier<double>(0);

  /// Niveau de voix courant (0..1), toutes voix humaines confondues : le max
  /// des [Participant.audioLevel] que LiveKit publie à chaque changement de
  /// locuteur actif. C'est ce qui fait *légèrement* bouger la pastille de
  /// traduction — la TTS, elle, la fait bouger fort ([ttsSpeaking]).
  final ValueNotifier<double> _voiceLevel = ValueNotifier<double>(0);

  void _addTurn(_SpokenTurn turn) {
    if (!mounted || turn.text.trim().isEmpty) return;
    // Rien à ouvrir ici : la phrase se montrera d'elle-même au-dessus des
    // touches ([_RestingTurns]), sans rien effacer. C'était l'affaire d'une
    // ouverture automatique de la zone entière, mais celle-ci efface désormais
    // la barre — la première phrase venue emportait les touches sans que
    // personne l'ait demandé. Se DÉPLIER reste au bouton Messages ; PARAÎTRE
    // se fait tout seul.
    //
    // Permanente : la dernière phrase reste affichée, sans délai ni retrait.
    setState(() {
      _turns.add(turn);
      // Un appel long ne doit pas garder la conversation entière en mémoire.
      if (_turns.length > 60) _turns.removeRange(0, _turns.length - 60);
    });
  }

  /// Ce que je TAPE part exactement comme une phrase dite : traduit dans la
  /// langue du pair, publié sur le même canal de données que la voix. Chez lui
  /// ça s'écrit dans la conversation et ça se dit avec la voix du device.
  ///
  /// Ma bulle à moi garde MES mots, pas la traduction — c'est ce que j'ai écrit
  /// que je veux relire, comme pour ma voix.
  Future<void> _sendCaption() async {
    final room = _room;
    final text = _chatCtrl.text.trim();
    if (room == null || text.isEmpty || _chatSending) return;
    setState(() => _chatSending = true);
    // La même cible que la voix : ce que le pair a DEMANDÉ d'entendre, et à
    // défaut la langue de son compte.
    final to = _peerListenLang.isNotEmpty
        ? _peerListenLang
        : _discoverRemoteLang(room);
    // La MÊME route que la voix : /translation/fix, DeepSeek. L'écrit passait
    // par /translation/text, qui est un second fournisseur — et quand celui-là
    // tombe (401 sur son hôte), la phrase arrivait telle quelle chez le pair,
    // dans MA langue, sans que rien ne le signale. Une seule route pour les
    // deux : ce qui traduit la voix traduit l'écrit.
    //
    // Le sexe du pair suit, comme pour la voix : c'est ce qui fait accorder la
    // phrase dans les langues qui marquent le genre.
    var trans = '';
    if (to.isNotEmpty && _mySourceLang.isNotEmpty) {
      final fix = await fetchTranscriptFix(
        text: text,
        from: _mySourceLang,
        to: to,
        peerGender: _peerProfile?.gender,
      );
      if (!fix.unclear) trans = fix.text.trim();
      DebugOverlay.log(
        'typed→$to via ${fix.engine.isEmpty ? "?" : fix.engine} '
        'unclear=${fix.unclear}',
      );
    }
    if (!mounted) return;
    _chatCtrl.clear();
    setState(() => _chatSending = false);
    // Le clavier reste levé : on tape rarement une seule phrase.

    // RIEN ne part sans traduction. Le repli d'avant — publier le texte brut
    // quand la traduction échoue ou que la langue du pair est inconnue —
    // livrait ma langue à quelqu'un qui ne la lit pas, et son téléphone la
    // prononçait par-dessus le marché. Un message illisible n'est pas mieux
    // qu'un message non remis : c'est le même échec, en moins visible.
    //
    // La bulle s'affiche quand même, grisée en italique : la convention existe
    // déjà pour une phrase dite qui n'est pas passée, et elle sert à ça — on
    // relit ce qu'on voulait dire pour le redire.
    var delivered = false;
    if (trans.isNotEmpty) {
      try {
        final payload = jsonEncode({
          _kTypedFlag: true,
          'orig': text,
          'trans': trans,
          'lang': to,
        });
        await room.localParticipant?.publishData(
          Uint8List.fromList(utf8.encode(payload)),
          reliable: true,
          topic: _captionTopic,
        );
        delivered = true;
      } catch (_) {
        // Publication refusée : même sort qu'une traduction manquante.
      }
    }
    _addTurn(_SpokenTurn(mine: true, text: text, delivered: delivered));
    Analytics.track(
      'message_sent',
      props: {'source': 'live', 'type': 'text', 'delivered': delivered},
    );
  }

  /// Mon micro vient de produire une phrase : elle s'affiche chez moi dans ma
  /// langue (le pair, lui, reçoit sa traduction par le canal de données).
  void _onMyTranscript() {
    final line = widget.translation.localTranscript?.value;
    if (line == null) return;
    _trackPhraseLevel(line);
    _addTurn(_SpokenTurn(
      mine: true,
      text: line.text,
      delivered: line.delivered,
    ));
    _trackDeliveryStreak(line);
  }

  // Niveau du micro pendant la phrase en cours (mesure seule, rien n'est affiché) :
  // sert à fixer plus tard un seuil « parle plus fort » sur de vrais chiffres.
  double _phrasePeak = 0;
  double _phraseSum = 0;
  int _phraseTicks = 0;

  void _trackPhraseLevel(SpokenLine line) {
    final peak = _phrasePeak, ticks = _phraseTicks, sum = _phraseSum;
    _phrasePeak = 0;
    _phraseSum = 0;
    _phraseTicks = 0;
    if (ticks == 0 || line.text.trim().isEmpty) return;
    try {
      Analytics.track('voice_level', props: {
        'peak': double.parse(peak.toStringAsFixed(4)),
        'avg': double.parse((sum / ticks).toStringAsFixed(4)),
        'ticks': ticks,
        'chars': line.text.trim().length,
        'delivered': line.delivered,
        'floor': double.parse(_noiseFloor.toStringAsFixed(4)),
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      });
    } catch (_) {}
  }

  /// Suit les phrases dites qui n'arrivent pas jusqu'au pair. Une qui passe —
  /// même un seul mot — remet tout à zéro ; [_kLangCheckThreshold] refus
  /// d'affilée déclenchent, UNE fois par appel, la question « bonne langue ? »
  /// avec le sélecteur de langues à la clé.
  void _trackDeliveryStreak(SpokenLine line) {
    if (line.delivered) {
      _undeliveredStreak = 0;
      return;
    }
    // Un segment vide n'est pas un échec de traduction, juste du silence capté.
    if (line.text.trim().isEmpty) return;
    if (++_undeliveredStreak < _kLangCheckThreshold ||
        _langCheckShown ||
        _sheetOpen ||
        !mounted) {
      return;
    }
    _langCheckShown = true;
    _undeliveredStreak = 0;
    _promptSpokenLanguageCheck();
  }

  bool _micOn = true;
  late bool _camOn = widget.startWithCamera;

  /// La caméra démarre par défaut. Si l'OS refuse la permission caméra, l'appel
  /// continue en audio seul au lieu d'échouer : seul le micro est indispensable.
  late bool _startCam = widget.startWithCamera;
  /// When true, the local self-view fills the screen and the remote feed
  /// lives in the small PiP. Tap either to swap back.
  bool _selfMain = false;
  EventsListener<RoomEvent>? _roomEvents;

  static const String _captionTopic = 'swayco-chat';

  /// Marque un paquet comme une phrase TAPÉE et non dite. Elle emprunte le même
  /// canal que la voix, mais elle ne doit pas nourrir le contexte du moteur de
  /// traduction : on ne répond pas à un message écrit comme à une phrase qu'on
  /// vient d'entendre.
  static const String _kTypedFlag = 'typed';

  /// Data-channel key carrying "the language I want to hear you in". Sent by the
  /// LISTENER, acted on by the SPEAKER — translation runs on the speaker's side.
  static const String _kListenLangKey = 'listenLang';

  /// Data-channel key carrying "translation is on/off". Shared state: either side
  /// can cut it, and both pipelines stop — see [_toggleTranslation].
  static const String _kTranslationOnKey = 'xlateOn';
  final AudioPlayer _ttsPlayer = AudioPlayer();
  final FlutterTts _deviceTts = FlutterTts();
  String _deviceTtsLang = '';

  /// True exactly while a translation is being SPOKEN, whichever engine speaks
  /// it — the premium voice or the device (`flutter_tts`) one.
  ///
  /// This is NOT [isTranslationPlaying]: that flag is an 800 ms anti-echo gate
  /// that self-clears on a timer whether the voice is still talking or not, and
  /// the mic gate is built on it. This one tracks real playback, from the
  /// engines' own start/complete events, and drives nothing on the audio path —
  /// so wiring it cannot wedge the mic the way a completion-event gate does.
  final ValueNotifier<bool> ttsSpeaking = ValueNotifier<bool>(false);

  /// Ties [ttsSpeaking] to the device engine's own events. `flutter_tts` had no
  /// handlers at all, so nothing knew when an OS voice started or stopped — and
  /// since the in-call language button now speaks through it, that was every
  /// utterance in a language other than the account one.
  void _wireDeviceTtsSignal() {
    _deviceTts.setStartHandler(() => ttsSpeaking.value = true);
    _deviceTts.setCompletionHandler(() => ttsSpeaking.value = false);
    _deviceTts.setCancelHandler(() => ttsSpeaking.value = false);
    _deviceTts.setErrorHandler((_) => ttsSpeaking.value = false);
    // Make speak() resolve when the sentence has FINISHED, not when it starts.
    // Without it the queue below cannot know when to start the next one.
    unawaited(_deviceTts.awaitSpeakCompletion(true));
    // ANDROID : la traduction doit sortir SUR l'appel, pas à côté.
    //
    // Par défaut le moteur Android parle en USAGE_MEDIA (STREAM_MUSIC). Pendant
    // un appel WebRTC l'AudioManager est en MODE_IN_COMMUNICATION, et la sortie
    // média n'est pas sur la route de l'appel : selon le constructeur elle est
    // fortement atténuée, ou pas jouée du tout. La phrase est bien synthétisée,
    // le moteur annonce même sa fin — et personne ne l'entend.
    //
    // USAGE_ASSISTANCE_NAVIGATION_GUIDANCE est l'usage prévu pour être entendu
    // PENDANT un appel (c'est celui de la voix du GPS), et c'est le seul que le
    // plugin expose.
    unawaited(_applyAndroidTtsRouting());
  }

  /// Pose l'usage audio Android, et le REPOSE avant chaque phrase.
  ///
  /// Côté natif, l'attribut est posé sur l'instance `TextToSpeech` courante. Or
  /// le plugin en reconstruit une silencieusement dès que sa liaison de service
  /// est tombée (`ismServiceConnectionUsable` faux dans `speak`), et la neuve
  /// repart sur l'usage par défaut. Posé une seule fois au démarrage de l'écran,
  /// l'attribut se perdait donc à la première reconstruction, et la voix
  /// redevenait inaudible pour tout le reste de l'appel sans que rien ne change
  /// visiblement.
  ///
  /// Le coût est un passage de canal par phrase, quelques-unes par minute, et
  /// l'opération est idempotente. Gardé pour Android : ailleurs la méthode
  /// n'existe pas côté natif et remonte un MissingPluginException.
  Future<void> _applyAndroidTtsRouting() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _deviceTts.setAudioAttributesForNavigation();
    } catch (e) {
      DebugOverlay.log('tts audio attrs failed: $e');
    }
  }

  /// Translations are SPOKEN one after another, never on top of each other.
  ///
  /// Every speak used to be preceded by `_deviceTts.stop()`, to clear whatever
  /// was queued. When the peer sent two translations a few seconds apart — which
  /// they do, one per phrase — the second one cut the first off mid-sentence. The
  /// user heard "Merci, il est tôt ici donc…" and then silence: nothing was lost
  /// in transit, the player killed it.
  Future<void> _ttsQueue = Future.value();

  /// Bumped by "cut translation" and by leaving the call. An utterance whose
  /// generation is stale is dropped instead of spoken — otherwise the queue would
  /// keep reciting sentences the user has just asked to stop hearing.
  int _ttsGeneration = 0;

  /// Le pair est-il en train de parler, là, maintenant ?
  bool get _peerTalking => _remoteVoice > _kVoiceOn;

  /// Combien de silence CONTINU il faut pour le croire arrêté. En dessous, on
  /// démarre entre deux mots — une respiration suffirait à ouvrir la porte.
  static const Duration _kPeerSilenceHold = Duration(milliseconds: 400);

  /// Le plafond de l'attente. Quelqu'un qui ne s'arrête jamais ne doit pas
  /// pouvoir repousser sa traduction indéfiniment : passé ce délai on parle
  /// par-dessus, ce qui est mauvais, mais moins qu'une traduction qui n'arrive
  /// jamais. C'est aussi le filet contre un niveau resté bloqué en haut :
  /// LiveKit ne publie un niveau qu'aux changements de locuteur actif, donc
  /// rien ne garantit qu'il redescende.
  static const Duration _kPeerSilenceMaxWait = Duration(seconds: 5);

  /// Attendre qu'il ait fini sa phrase.
  ///
  /// Sans ça, une phrase envoyée à la première vraie pause — celle qui sépare
  /// deux propositions, pas celle qui finit un tour de parole — déclenche la
  /// traduction pendant qu'il enchaîne. Le ducking coupe alors sa voix EN
  /// PLEIN MILIEU : à l'oreille l'appel s'interrompt brutalement, et on croit
  /// que ça ne marche plus.
  ///
  /// Superposer les deux voix plutôt que couper ne règle rien — deux voix
  /// simultanées ne se comprennent ni l'une ni l'autre. La seule sortie est
  /// d'attendre.
  Future<void> _awaitPeerSilence() async {
    if (!_peerTalking) return;
    final deadline = DateTime.now().add(_kPeerSilenceMaxWait);
    var quietSince = DateTime.now();
    while (mounted) {
      final now = DateTime.now();
      if (_peerTalking) {
        quietSince = now;
      } else if (now.difference(quietSince) >= _kPeerSilenceHold) {
        return;
      }
      if (now.isAfter(deadline)) {
        DebugOverlay.log('tts: peer still talking after cap — speaking over');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  /// Combien de temps on accepte d'attendre une synthèse avant de renoncer.
  ///
  /// Ce n'est PAS un réglage de confort : mesurée, la synthèse rend la main en
  /// 25 à 75 ms. C'est le filet contre un moteur qui se serait bloqué — sans
  /// lui, l'attente n'a aucune borne et toute la traduction de l'appel reste
  /// coincée derrière une phrase qui ne viendra jamais. Dix secondes, c'est
  /// cent fois le temps normal : on n'y arrive que si quelque chose est cassé.
  static const Duration _kSynthCap = Duration(seconds: 10);

  /// Speak [text] after everything already queued. Never interrupts.
  ///
  /// UNE SEULE VOIX, toujours la même. Il y a eu un temps où on basculait sur
  /// celle du système dès qu'une phrase attendait, pour rattraper le retard :
  /// c'était nécessaire quand la synthèse mettait dix secondes, et c'est devenu
  /// absurde depuis qu'elle en met quarante millisecondes. Ça ne faisait plus
  /// que changer la voix du pair au milieu d'une conversation — onze fois en
  /// quatre-vingt-dix secondes sur l'appel de référence. On prête une identité
  /// à une voix ; elle ne doit pas bouger.
  ///
  /// Le repli ne sert donc plus qu'aux cas où il n'y a rien d'autre à faire :
  /// aucune voix embarquée pour cette langue, bundle pas encore téléchargé, ou
  /// synthèse qui n'a rien rendu. Aucun de ces cas ne change de voix EN COURS
  /// de conversation — ils valent pour tout l'appel.
  ///
  /// La SYNTHÈSE démarre ici, pas quand la file arrivera à cette phrase. Elle
  /// tourne donc pendant que la précédente se lit ET pendant qu'on attend que
  /// le pair se taise — deux attentes qu'on ne payait jusqu'ici qu'à la suite,
  /// et c'est ce qui rend les 40 ms possibles.
  ///
  /// [onVoiceStart] : appelé UNE fois, au moment où la voix démarre. Le texte de
  /// la traduction s'y écrit, pour qu'on le lise EN MÊME TEMPS qu'on l'entend :
  /// il s'écrivait dès l'arrivée du message, et la voix, derrière la file et
  /// l'attente du silence du pair, venait plusieurs secondes après — ce qui
  /// ressemblait à une panne. Il est aussi appelé si la phrase est abandonnée
  /// (traduction coupée, appel quitté) et, au pire, après [_kTextHoldCap] : le
  /// texte ne reste jamais caché.
  Future<void> _enqueueSpeak(String text, String lang,
      {VoidCallback? onVoiceStart}) {
    final generation = _ttsGeneration;
    final enqueuedAt = DateTime.now();
    var revealed = false;
    Timer? holdCap;
    void reveal({required bool capped}) {
      if (revealed) return;
      revealed = true;
      holdCap?.cancel();
      if (onVoiceStart == null) return;
      // Combien de temps la voix a fait attendre le texte : la mesure du
      // décalage que les gens voient, pour décider quoi en faire.
      try {
        Analytics.track('translation_voice_wait', props: {
          'ms': DateTime.now().difference(enqueuedAt).inMilliseconds,
          'capped': capped,
        });
      } catch (_) {}
      onVoiceStart();
    }

    if (onVoiceStart != null) {
      holdCap = Timer(_kTextHoldCap, () => reveal(capped: true));
    }
    final Future<String?>? synth = _premiumReadyFor(lang)
        ? SpeechService.instance.synthesise(text: text, languageCode: lang)
        : null;
    _ttsQueue = _ttsQueue.then((_) async {
      if (!mounted || generation != _ttsGeneration) {
        reveal(capped: false);
        return;
      }
      await _awaitPeerSilence();
      // Couper la traduction PENDANT l'attente doit la faire tomber : sans ce
      // second contrôle, elle se dirait quand même à la fin du silence.
      if (!mounted || generation != _ttsGeneration) {
        reveal(capped: false);
        return;
      }
      // La voix part : le texte s'écrit maintenant.
      reveal(capped: false);
      if (synth == null) {
        await _speakOsVoice(text, lang);
        return;
      }
      final path = await synth.timeout(_kSynthCap, onTimeout: () {
        DebugOverlay.log('tts: synthesis over ${_kSynthCap.inSeconds}s — OS voice');
        return null;
      });
      await _speakPremium(path, text, lang);
    }).catchError((Object e) {
      DebugOverlay.log('tts queue error: $e');
      reveal(capped: false);
    });
    return _ttsQueue;
  }

  /// Le plus longtemps que le texte d'une traduction attend le début de sa voix
  /// avant de s'écrire quand même. Plus long que l'attente du silence du pair
  /// ([_kPeerSilenceMaxWait], 5 s) pour ne pas couper court à un décalage
  /// normal, mais borné : une file bloquée ne doit pas cacher le texte.
  static const Duration _kTextHoldCap = Duration(seconds: 7);

  /// Premium on-device voice, but ONLY for the one language whose bundle is
  /// already installed — the account language, downloaded at boot. A language
  /// picked mid-call is never loaded (a live call can't wait on a 110 MB
  /// download), so it falls straight through to the OS voice. That is the whole
  /// "one downloadable language, everything else flutter_tts" rule.
  ///
  /// Match the voice to the SPEAKER (the peer): a woman's line comes out in a
  /// woman's voice. The gender rides on the peer's profile, already loaded for
  /// the call — no need to send it over the wire. A language with no gender
  /// pair, or an unknown gender, just uses whatever voice is loaded.
  bool _premiumReadyFor(String lang) =>
      // Le commutateur vit dans [SpeechService] : c'est lui qui ferme aussi les
      // téléchargements, et deux interrupteurs pour une seule lampe finissent
      // toujours par diverger.
      SpeechService.enabled &&
      !kIsWeb &&
      SpeechService.instance
          .isLoadedFor(lang, gender: _peerProfile?.gender ?? '');

  /// The OS voice. The timeout is the queue's safety net: flutter_tts can return
  /// without ever playing (a missing voice, a browser that suspended
  /// speechSynthesis), and then the completion event never comes — which would
  /// wedge every translation behind it for the rest of the call.
  /// Combien de temps on laisse à une phrase avant de considérer qu'elle ne
  /// jouera jamais.
  ///
  /// À la LONGUEUR du texte, plus un forfait — pas 20 secondes pour tout le
  /// monde. Vingt secondes, c'était le temps qu'il faut à la plus longue
  /// phrase imaginable ; une phrase de quatre mots qui reste muette bloquait
  /// donc la file vingt secondes, et la suivante repartait pour vingt
  /// secondes derrière elle. Trois mots morts coûtent maintenant six secondes.
  ///
  /// Le plafond reste : une phrase très longue garde ses vingt secondes.
  Duration _speakCap(String text) {
    final ms = 2500 + text.length * 110;
    return Duration(milliseconds: ms > 20000 ? 20000 : ms);
  }

  /// ANDROID : le moteur se VERROUILLE sur une phrase dont la fin ne s'annonce
  /// jamais, et il ne le dit pas.
  ///
  /// `flutter_tts` arme un drapeau `speaking` à chaque `speak()` attendu (c'est
  /// [awaitSpeakCompletion], qu'on veut pour enchaîner les phrases) et ne le
  /// désarme que sur un événement DU MOTEUR — onDone, onStop, onError. Une
  /// phrase qui ne rend aucun des trois laisse donc le drapeau armé pour de
  /// bon, et le plugin répond ensuite `0` à TOUS les `speak()` suivants,
  /// immédiatement, sans rien jouer et sans lever d'erreur. Une seule fin
  /// manquée rend la traduction muette pour tout le reste de l'appel : « la
  /// voix passe une fois, puis plus rien ».
  ///
  /// iOS n'a pas ce garde — le plugin y réarme à chaque phrase — et c'est
  /// exactement pourquoi iOS ↔ iOS n'a jamais montré la panne.
  ///
  /// [_unlockDeviceTts] est le seul moyen de désarmer le drapeau : côté natif,
  /// `stop()` remet `speaking = false`. On le passe sur les deux sorties
  /// anormales — le garde-fou de temps, et le `0` de refus. Dans ce second cas
  /// la phrase est REDITE : le refus n'a rien joué, il n'y a rien à couper.
  Future<void> _speakOsVoice(String text, String lang) async {
    // La liste des voix peut être partielle. Si elle ne connaît pas la langue,
    // on interroge le moteur lui-même avant de renoncer — voir [_probeVoiceTag].
    var tag = _voiceTagFor(lang);
    if (tag.isEmpty) tag = await _probeVoiceTag(lang);
    var fallbackVoice = false;
    if (tag.isEmpty) {
      tag = _anyAvailableVoiceTag();
      fallbackVoice = tag.isNotEmpty;
    }
    // Le volume est sur LA MÊME ligne que la phrase, à dessein : c'est un
    // réglage PERSISTÉ, propre à ce téléphone, et un zéro qui y traîne rend la
    // voix inaudible sur ce téléphone-là seulement. Deux Android côte à côte, le
    // même build, l'un parle et l'autre est muet — sans ce chiffre dans la même
    // ligne, rien ne permet de le voir.
    DebugOverlay.log('speak lang=$lang '
        '(voice $tag${fallbackVoice ? " — PAR DÉFAUT, pas la bonne langue" : ""}) '
        'vol=${_audio.translatedVolume.toStringAsFixed(2)} text="$text"');
    markTranslationPlaying(textLength: text.length);
    try {
      if (tag.isNotEmpty && tag != _deviceTtsLang) {
        try {
          await _deviceTts.setLanguage(tag);
          _deviceTtsLang = tag;
        } catch (_) {}
      }
      await _applyAndroidTtsRouting();
      await _applyTranslatedVolumeToDeviceTts();
      // Mobile Chrome auto-pauses speechSynthesis after a stretch of inactivity;
      // speak() then plays nothing and fires no event.
      resumeSpeechSynthesisIfPaused();
      final res = await _deviceTts.speak(text).timeout(_speakCap(text));
      if (res == 0) {
        DebugOverlay.log('speak REFUSED (engine still marked speaking) — '
            'unlocking and saying it again');
        await _unlockDeviceTts();
        final retry = await _deviceTts.speak(text).timeout(_speakCap(text));
        DebugOverlay.log('speak retry → $retry');
        if (retry == 0) await _unlockDeviceTts();
      } else {
        DebugOverlay.log('speak done');
      }
    } catch (e) {
      // Le garde-fou a sauté : ou la phrase joue encore et on la coupe (elle
      // dépasse déjà largement sa durée estimée), ou elle n'a jamais joué et
      // c'est le verrou qu'on lève. Ne rien faire ici, c'était perdre la voix
      // pour le reste de l'appel.
      DebugOverlay.log('speak FAILED: $e — unlocking the engine');
      await _unlockDeviceTts();
    } finally {
      markTranslationDone();
    }
  }

  /// Désarme le drapeau `speaking` du plugin — voir [_speakOsVoice]. Silencieux :
  /// un `stop()` qui échoue ne doit pas remonter dans la file de parole.
  Future<void> _unlockDeviceTts() async {
    try {
      await _deviceTts.stop();
    } catch (e) {
      DebugOverlay.log('tts stop failed: $e');
    }
    ttsSpeaking.value = false;
  }

  /// Play the WAV the premium voice already synthesised, and hold the queue
  /// until it has finished being heard.
  ///
  /// The synthesis happened at enqueue time — that is the whole point, it is
  /// the slow half. [wavPath] is null when it produced nothing (no engine, an
  /// error): we fall back to the OS voice rather than skip the sentence.
  ///
  /// Ducking starts HERE, not before, because here is where sound starts. It
  /// used to be armed before synthesising, which on this model cut the peer's
  /// real voice for ten seconds with nothing coming out of the speaker.
  ///
  /// The wait for the end is CAPPED, and that matters as much as the wait: a
  /// playback that never announces its end would wedge every remaining
  /// translation of the call behind it. Subscribe before playing — a short clip
  /// can finish before the await returns.
  Future<void> _speakPremium(String? wavPath, String text, String lang) async {
    if (wavPath == null) {
      DebugOverlay.log('premium synthesis empty — OS voice');
      await _speakOsVoice(text, lang);
      return;
    }
    final speech = SpeechService.instance;
    DebugOverlay.log('speak lang=$lang (premium voice) text="$text"');
    try {
      final done = speech.onPlaybackComplete.first;
      await speech.playFile(wavPath);
      DebugOverlay.log('speak started (premium)');
      markTranslationPlaying(textLength: text.length);
      ttsSpeaking.value = true;
      unawaited(done
          .timeout(const Duration(seconds: 15))
          .then((_) => markTranslationDone())
          .catchError((_) {/* the gate's safety timer reopens the mic */})
          .whenComplete(() => ttsSpeaking.value = false));
      await done.timeout(const Duration(seconds: 15));
      DebugOverlay.log('speak done (premium)');
    } on TimeoutException {
      // Rien n'a joué, ou la fin ne s'est jamais annoncée. On rend la main :
      // la suite de l'appel ne doit pas rester coincée derrière.
      DebugOverlay.log('premium speak: no completion within 15s — moving on');
    } catch (e) {
      ttsSpeaking.value = false;
      markTranslationDone();
      DebugOverlay.log('premium speak FAILED: $e');
    }
  }

  /// Drop everything still waiting to be spoken, and silence what is playing.
  /// Used by "cut translation" and on leaving the call — the only two places a
  /// translation is genuinely no longer wanted.
  void _cancelQueuedSpeech() {
    _ttsGeneration++;
    unawaited(_deviceTts.stop());
    if (!kIsWeb) unawaited(SpeechService.instance.stop());
    ttsSpeaking.value = false;
    markTranslationDone();
  }

  /// Base code → the FULL tag the OS actually knows (`ja` → `ja-JP`).
  ///
  /// iOS resolves a voice with `AVSpeechSynthesisVoice(language:)`, which wants
  /// the region: hand it a bare `ja` and it finds nothing, returns nil, and the
  /// system quietly falls back to its default voice — so the Japanese translation
  /// was being read out in French. Speak through the tag the device gave us, not
  /// the base code we derived from it.
  Map<String, String> _deviceVoiceTags = const {};

  /// TOUS les tags de voix de l'appareil, par langue de base (`pt` → [`pt-BR`,
  /// `pt-PT`]). [_deviceVoiceTags] n'en garde qu'un par langue ; celui-ci sert
  /// quand l'appel demande une région précise (`pt-PT`, `pt-BR`).
  Map<String, List<String>> _deviceVoiceAll = const {};

  /// Ask the OS which languages it can speak. `getLanguages` returns BCP-47 tags
  /// (`fr-FR`, `en-US`, …); the picker works in base codes.
  /// Les régions qu'on veut voir gagner quand l'appareil en propose plusieurs
  /// pour une même langue.
  ///
  /// `getLanguages` NE rend PAS un ordre de préférence, contrairement à ce
  /// qu'on croyait : sur iPhone, l'anglais sortait en `en-ZA`, et toutes les
  /// traductions se lisaient avec l'accent sud-africain. Ce sont les régions
  /// les plus neutres à l'oreille d'un non-anglophone qui passent devant.
  ///
  /// La première présente sur l'appareil gagne ; si aucune ne l'est, on retombe
  /// sur ce que la liste donnait — mieux vaut un accent inattendu que pas de
  /// voix du tout.
  static const Map<String, List<String>> _preferredVoiceRegions = {
    'en': ['en-US', 'en-GB'],
  };

  /// ISO 639-2 (trois lettres) → ISO 639-1 (deux lettres).
  ///
  /// Les moteurs de synthèse ne parlent pas tous le même dialecte de BCP-47.
  /// iOS et celui de Google énumèrent `en-US`, `fr-FR`. Celui de Samsung
  /// (`com.samsung.SMT`) énumère `eng-default`, `fra-default`,
  /// `por-x-lvariant-f00` : trois lettres, et une pseudo-variante. Notre
  /// extraction prenait le morceau avant le tiret, obtenait `eng`, et cherchait
  /// `en` — d'où le fameux « 7 langs (en=—) » sur un téléphone qui a
  /// évidemment l'anglais. La liste n'était pas incomplète, elle était écrite
  /// dans un autre alphabet.
  ///
  /// Les VINGT premières lignes sont les langues à deux codes à trois lettres,
  /// un « bibliographique » et un « terminologique » selon la norme. Les deux
  /// désignent la même langue et un moteur peut rendre l'un ou l'autre, donc
  /// les deux sont ici. Le français et le chinois en font partie, et ce sont
  /// deux des langues de l'app.
  static const Map<String, String> _iso6392to1 = {
    'alb': 'sq', 'sqi': 'sq',
    'arm': 'hy', 'hye': 'hy',
    'baq': 'eu', 'eus': 'eu',
    'bur': 'my', 'mya': 'my',
    'chi': 'zh', 'zho': 'zh',
    'cze': 'cs', 'ces': 'cs',
    'dut': 'nl', 'nld': 'nl',
    'fre': 'fr', 'fra': 'fr',
    'geo': 'ka', 'kat': 'ka',
    'ger': 'de', 'deu': 'de',
    'gre': 'el', 'ell': 'el',
    'ice': 'is', 'isl': 'is',
    'mac': 'mk', 'mkd': 'mk',
    'mao': 'mi', 'mri': 'mi',
    'may': 'ms', 'msa': 'ms',
    'per': 'fa', 'fas': 'fa',
    'rum': 'ro', 'ron': 'ro',
    'slo': 'sk', 'slk': 'sk',
    'tib': 'bo', 'bod': 'bo',
    'wel': 'cy', 'cym': 'cy',
    // Un seul code à trois lettres pour les autres.
    'eng': 'en', 'spa': 'es', 'ita': 'it', 'por': 'pt', 'rus': 'ru',
    'ara': 'ar', 'jpn': 'ja', 'kor': 'ko', 'hin': 'hi', 'pol': 'pl',
    'tur': 'tr', 'ukr': 'uk', 'swe': 'sv', 'dan': 'da', 'fin': 'fi',
    'nor': 'no', 'nob': 'nb', 'nno': 'nn', 'tha': 'th', 'ind': 'id',
    'vie': 'vi', 'heb': 'he', 'hun': 'hu', 'hrv': 'hr', 'cat': 'ca',
    'bul': 'bg', 'srp': 'sr', 'slv': 'sl', 'est': 'et', 'lav': 'lv',
    'lit': 'lt', 'ben': 'bn', 'tam': 'ta', 'tel': 'te', 'mar': 'mr',
    'urd': 'ur', 'guj': 'gu', 'kan': 'kn', 'mal': 'ml', 'pan': 'pa',
    'swa': 'sw', 'afr': 'af', 'tgl': 'tl', 'fil': 'fil',
  };

  /// Ramène n'importe quel tag de moteur à un couple (langue, tag utilisable).
  ///
  /// Null quand la chaîne n'est pas une langue reconnaissable : mieux vaut
  /// ignorer une entrée que remplir la table d'une clé qui ne sera jamais
  /// cherchée.
  ///
  /// Le tag rendu est celui qu'on passera à `setLanguage`, et il doit donc être
  /// du BCP-47 que l'OS sait résoudre. D'où les deux cas :
  ///
  ///  * langue à DEUX lettres — le tag est déjà canonique, on le garde entier,
  ///    région comprise. C'est le cas d'iOS et de Google, et la région compte :
  ///    `AVSpeechSynthesisVoice(language:)` rend nil sur un code nu.
  ///  * langue à TROIS lettres — ni `eng-default` ni `eng-USA` ne sont du
  ///    BCP-47 résoluble. On garde la région si elle fait deux lettres, sinon
  ///    on prend la région canonique de la langue ([_defaultVoiceRegion]), qui
  ///    est exactement le tag que le moteur Samsung a confirmé connaître.
  static (String, String)? _normaliseVoiceTag(String raw) {
    var s = raw.trim().replaceAll('_', '-');
    if (s.isEmpty) return null;
    // Java émet l'extension privée `-x-lvariant-…` pour toute variante que
    // BCP-47 refuse : c'est ce qui produit `por-x-lvariant-f00`. Rien après
    // `-x-` ne parle de la langue.
    final x = s.toLowerCase().indexOf('-x-');
    if (x > 0) s = s.substring(0, x);
    final parts = s.split('-').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    final lang = parts.first.toLowerCase();
    if (!RegExp(r'^[a-z]{2,3}$').hasMatch(lang)) return null;
    if (lang.length == 2) return (lang, s);
    final base = _iso6392to1[lang];
    if (base == null) return null;
    final region = parts.length > 1 ? parts[1].toUpperCase() : '';
    if (RegExp(r'^[A-Z]{2}$').hasMatch(region)) return (base, '$base-$region');
    return (base, _defaultVoiceRegion[base] ?? base);
  }

  /// Un chargement de la liste est déjà en vol : on n'en lance pas un second.
  bool _loadingVoiceLangs = false;

  /// Combien de fois on redemande la liste quand elle revient VIDE, et à quel
  /// rythme. Environ trois secondes en tout — largement de quoi couvrir la
  /// latence de `voiceschanged`, et borné pour qu'un appareil réellement sans
  /// voix n'interroge pas le moteur pour l'éternité.
  static const int _kVoiceLoadTries = 6;
  static const Duration _kVoiceLoadGap = Duration(milliseconds: 500);

  /// Demande la liste des voix, et REDEMANDE tant qu'elle revient vide.
  ///
  /// Elle n'était demandée qu'une fois. Sur le WEB c'est une course perdue
  /// d'avance une fois sur deux : `speechSynthesis.getVoices()` rend un tableau
  /// VIDE au premier appel et ne se remplit qu'à l'événement `voiceschanged`,
  /// quelques centaines de millisecondes plus tard. Le device qui perdait la
  /// course gardait donc une liste vide pour tout l'appel — et [_voiceTagFor]
  /// renvoyant '' pour chaque langue, `setLanguage` n'était jamais appelé,
  /// `speak()` ne jouait rien, n'émettait aucun événement, et chaque phrase
  /// mourait sur le garde-fou. Deux téléphones, le même code, l'un parlait et
  /// l'autre était muet.
  ///
  /// Ça ne change rien au natif, où la liste arrive pleine du premier coup :
  /// une seconde tentative n'a lieu QUE si la première n'a rien rendu.
  Future<void> _loadDeviceVoiceLangs({int attempt = 1}) async {
    if (_loadingVoiceLangs && attempt == 1) return;
    _loadingVoiceLangs = true;
    try {
      final ok = await _readDeviceVoiceLangs();
      if (ok || !mounted) return;
      if (attempt >= _kVoiceLoadTries) {
        DebugOverlay.log('device voices: still none after $attempt tries');
        return;
      }
      await Future<void>.delayed(_kVoiceLoadGap);
      if (!mounted) return;
      return _loadDeviceVoiceLangs(attempt: attempt + 1);
    } finally {
      if (attempt == 1) _loadingVoiceLangs = false;
    }
  }

  /// Une tentative. Rend `true` quand la liste a été retenue.
  Future<bool> _readDeviceVoiceLangs() async {
    try {
      final raw = await _deviceTts.getLanguages;
      if (raw is! List) return false;
      final tags = <String, String>{};
      final all = <String, List<String>>{};
      for (final t in raw) {
        if (t == null) continue;
        // Normalisé, et pas découpé au premier tiret : voir [_normaliseVoiceTag]
        // pour les trois dialectes de BCP-47 que les moteurs rendent.
        final norm = _normaliseVoiceTag(t.toString());
        if (norm == null) continue;
        final (base, tag) = norm;
        (all[base] ??= <String>[]).add(tag);
        tags.putIfAbsent(base, () => tag);
      }
      // Les préférées passent devant ce que la liste avait donné.
      _preferredVoiceRegions.forEach((base, wanted) {
        final have = all[base];
        if (have == null) return;
        for (final w in wanted) {
          final hit = have.firstWhere(
            (t) => t.toLowerCase().replaceAll('_', '-') == w.toLowerCase(),
            orElse: () => '',
          );
          if (hit.isNotEmpty) {
            tags[base] = hit;
            return;
          }
        }
      });
      if (!mounted) return false;
      if (tags.isEmpty) {
        // Journalisé, et pas seulement en debugPrint : c'est l'absence de
        // cette information qui rendait la panne indéchiffrable — un log
        // d'appel entier sans une seule ligne sur les voix.
        DebugOverlay.log('device voices: none yet');
        return false;
      }
      // La LISTE, et plus seulement son compte. Un appel réel a rendu
      // « 7 langs (en=—) » : sept langues, sans l'anglais, sur un moteur système
      // que rien ne nommait. Sans les tags écrits noir sur blanc ET le nom du
      // moteur, impossible de trancher entre « cette voix n'est pas installée »
      // et « ce n'est pas le bon moteur qui répond ».
      final listed = tags.entries.map((e) => e.value).toList()..sort();
      DebugOverlay.log(
        'device voices: ${tags.length} langs — ${listed.join(", ")}',
      );
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        unawaited(_logAndroidTtsEngine());
      }
      setState(() {
        _deviceVoiceTags = tags;
        _deviceVoiceAll = all;
      });
      return true;
    } catch (e) {
      DebugOverlay.log('device voices: getLanguages failed: $e');
      debugPrint('[speech] getLanguages failed: $e');
      return false;
    }
  }

  /// La région à essayer pour chacune des langues de l'app quand la liste des
  /// voix ne mentionne pas la langue. `Locale` veut la région : un `en` nu ne
  /// résout rien, `en-US` oui.
  static const Map<String, String> _defaultVoiceRegion = {
    'fr': 'fr-FR', 'en': 'en-US', 'es': 'es-ES', 'it': 'it-IT',
    'pt': 'pt-BR', 'nl': 'nl-NL', 'ar': 'ar-SA', 'ru': 'ru-RU',
    'zh': 'zh-CN', 'ko': 'ko-KR', 'de': 'de-DE', 'ja': 'ja-JP',
  };

  /// Demander AU MOTEUR si une langue existe, au lieu de croire son inventaire.
  ///
  /// `getLanguages` peut rendre une liste PARTIELLE quand le moteur vient de
  /// démarrer, et notre relance ne se déclenchait que sur une liste VIDE. Une
  /// liste courte était donc prise pour définitive et gelée pour tout l'appel :
  /// [_voiceTagFor] rendait '' à chaque phrase, `setLanguage` n'était jamais
  /// appelé, et le moteur lisait un texte anglais avec la voix qu'il avait —
  /// c'est-à-dire rien, sans le moindre événement. Journal d'un vrai appel :
  /// « device voices: 7 langs (en=—) », sur un téléphone qui sait évidemment
  /// dire l'anglais. Sept, ce n'était pas l'inventaire du téléphone, c'était ce
  /// que le moteur avait eu le temps d'énumérer.
  ///
  /// `isLanguageAvailable` interroge le moteur sur UN tag précis, sans passer
  /// par l'énumération. C'est cette réponse-là qui fait foi.
  Future<String> _probeVoiceTag(String lang) async {
    final base = lang.toLowerCase().split(RegExp(r'[-_]')).first;
    if (base.isEmpty) return '';
    final candidates = <String>[
      if (lang.contains('-') || lang.contains('_')) lang.replaceAll('_', '-'),
      ...?_preferredVoiceRegions[base],
      if (_defaultVoiceRegion[base] != null) _defaultVoiceRegion[base]!,
      base,
    ];
    for (final tag in candidates) {
      try {
        if (await _deviceTts.isLanguageAvailable(tag) == true) {
          DebugOverlay.log('tts: le moteur confirme "$tag", absent de sa liste');
          // Retenu : une phrase ne doit pas repayer l'interrogation du moteur,
          // et les suivantes trouveront le tag par le chemin normal.
          if (mounted) {
            setState(() =>
                _deviceVoiceTags = {..._deviceVoiceTags, base: tag});
          }
          return tag;
        }
      } catch (_) {
        // Un moteur qui refuse la question n'invalide pas les autres tags.
      }
    }
    DebugOverlay.log('tts: le moteur ne connaît aucun tag pour "$base"');
    return '';
  }

  /// À défaut de la bonne langue, une langue que le moteur a VRAIMENT.
  ///
  /// « Garder la voix en place » supposait qu'il y en ait une de valide en
  /// place. Rien ne le garantit : le plugin ne pose la langue par défaut du
  /// moteur que si elle est disponible, donc le moteur peut tourner sans aucune
  /// langue posée — et `speak()` ne rend alors rien du tout, sans le moindre
  /// événement. C'est le silence complet observé sur un Android, pendant que le
  /// même code parlait sur iPhone.
  ///
  /// Une voix française qui lit de l'anglais s'entend mal. Elle s'entend, et
  /// c'est tout l'écart avec le silence : on sait que la traduction est
  /// arrivée, on la comprend de travers au pire, et le bouton de langue reste à
  /// portée pour corriger. Le tag vient de la liste du moteur, donc
  /// `setLanguage` ne peut pas le refuser.
  ///
  /// Ma propre langue d'abord : c'est celle que ce téléphone a le plus de
  /// chances d'avoir installée, et l'accent le moins surprenant pour celui qui
  /// le tient.
  String _anyAvailableVoiceTag() {
    if (_deviceVoiceTags.isEmpty) return '';
    return _deviceVoiceTags[_baseLang(_mySourceLang)] ??
        _deviceVoiceTags.values.first;
  }

  /// QUEL moteur de synthèse répond, et lesquels sont installés.
  ///
  /// Android en accepte plusieurs, et celui par défaut n'est pas forcément le
  /// mieux fourni : un moteur constructeur à sept langues peut être devant
  /// celui de Google, qui en a des dizaines. Tant que la ligne n'existait pas,
  /// « pas de voix pour l'anglais » ne disait pas s'il fallait installer une
  /// voix ou changer de moteur. Android seulement, la méthode n'existe pas
  /// ailleurs.
  Future<void> _logAndroidTtsEngine() async {
    try {
      final def = await _deviceTts.getDefaultEngine;
      final all = await _deviceTts.getEngines;
      final list = all is List ? all.join(", ") : '$all';
      DebugOverlay.log('tts engine=$def — installés: $list');
    } catch (e) {
      DebugOverlay.log('tts engine: lecture impossible ($e)');
    }
  }

  /// Le tag à donner à flutter_tts pour [lang] — celui de l'appareil (`ja-JP`)
  /// quand on le connaît, VIDE sinon.
  ///
  /// Vide et pas le code nu, qui était pire que rien : sur le web,
  /// `speechSynthesis` reçoit un `fr` qu'il ne sait pas résoudre, ne joue rien
  /// et **n'émet aucun événement** — la phrase attendait alors les vingt
  /// secondes du garde-fou, et la suivante repartait pour vingt secondes. Sur
  /// iOS c'est le même piège : `AVSpeechSynthesisVoice(language:)` veut la
  /// région, rend nil sur un code nu, et le système lit dans sa langue par
  /// défaut sans le dire.
  ///
  /// Vide, l'appelant ne change pas de langue et laisse le moteur parler avec
  /// la voix qu'il a. L'accent sera peut-être faux ; au moins ça sort du
  /// haut-parleur, et la file avance.
  String _voiceTagFor(String lang) {
    final base = lang.toLowerCase().split(RegExp(r'[-_]')).first;
    if (_deviceVoiceTags.isEmpty) {
      // Toujours rien : les tentatives du démarrage ont pu toutes tomber avant
      // que le navigateur ne remplisse sa liste. On redemande — trop tard pour
      // CETTE phrase, à temps pour la suivante. Sans ce rattrapage, un appel
      // mal démarré restait muet jusqu'au bout.
      DebugOverlay.log('no voice list yet — asking again');
      unawaited(_loadDeviceVoiceLangs());
      return '';
    }
    // Une région demandée (pt-PT, pt-BR) : SA voix si l'appareil l'a — la ligne
    // « Português (Portugal) » parle alors avec une voix du Portugal.
    if (lang.contains(RegExp(r'[-_]'))) {
      final want = lang.toLowerCase().replaceAll('_', '-');
      for (final t in _deviceVoiceAll[base] ?? const <String>[]) {
        if (t.toLowerCase().replaceAll('_', '-') == want) return t;
      }
    }
    final tag = _deviceVoiceTags[base];
    if (tag == null) {
      DebugOverlay.log('no device voice for "$base" — keeping current voice');
    }
    return tag ?? '';
  }

  /// Whether WE want to hear the peer translated. Toggle via
  /// [_toggleTranslation]; purely our own ear — the peer keeps hearing us
  /// translated unless they cut it on their side.
  bool _translationEnabled = true;

  /// Whether the PEER wants to hear us translated. False once they cut it on
  /// their side, and then our pipeline stops — we are the one who translates our
  /// voice into their language. Assumed true until they say otherwise (a peer on
  /// an older build never sends the key).
  bool _peerWantsTranslation = true;

  /// The target BCP-47 the translation pipeline is currently attached with, so
  /// we only re-attach when it actually changes.
  String _attachedTargetLang = '';

  /// Same, for the source: a source-only change leaves the target untouched, so
  /// without this the re-attach would be short-circuited and the input language
  /// button would do nothing.
  String _attachedSourceLang = '';

  /// The language this phone TRANSCRIBES its own mic in. Starts at the account
  /// language and is changeable mid-call via the input language button.
  ///
  /// Unlike [_myOutputLang] this is a purely local concern — the peer never
  /// needs to know it, because we ship them translated text, not audio. What it
  /// costs is a pipeline restart: `attachToRoom` tears the mic streamer down and
  /// the on-device engine reloads with the new `language:` (no download — the
  /// universal model covers every language in [supportedLanguages]).
  late String _mySourceLang = widget.mySourceLang;

  /// The language the local user currently *hears* the remote translated into.
  /// Starts at the user's own language; changeable mid-call via the language
  /// button.
  ///
  /// Translation happens on the SPEAKER's side — this phone transcribes its own
  /// mic, translates into the language the *peer* wants, and ships the text over
  /// the data channel for the peer to speak. So changing this does nothing
  /// locally: it is broadcast to the peer ([_kListenLangKey]), and it is THEIR
  /// pipeline that starts translating into it. The only local effect is which
  /// voice speaks the text they send back.
  late String _myOutputLang = widget.mySourceLang;

  /// The language the REMOTE user wants to hear us in — i.e. our translation
  /// target. Defaults to their account language (read from their LiveKit
  /// metadata) and is overridden the moment they tap their own language button.
  String _peerListenLang = '';

  /// The output language we last announced to the peer, so a re-announce on
  /// their (re)connect doesn't republish on every metadata event.
  String _announcedOutputLang = '';
  bool _refreshingTranslation = false;
  /// Set when an event arrives while a refresh is in flight; we re-run once
  /// the in-flight call completes so the latest state is reflected.
  bool _refreshPending = false;

  late final AudioController _audio = AudioController(translation: widget.translation);
  bool _lastTranslationSpeaking = false;
  /// Accumulates real translation-live time (runs only while the live engine
  /// pipeline is live). Reported as `translation_ms` on the call_ended
  /// analytics event so the admin can cost the live engine against actual
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
  /// Guards [_onDeclinedByCallee] / [_onRingTimeout] so we pop / snackbar at
  /// most once.
  bool _declinedHandled = false;

  /// Caller-only ring timeout. The decline signal is a best-effort realtime
  /// broadcast — the web build frequently misses it, and a powered-off callee
  /// can't send it at all — so without this the caller could ring into an
  /// empty room forever. Armed only for direct friend rings (an
  /// [outgoingCallId]); guest-invite waits have no timeout.
  Timer? _ringTimeout;

  /// When the LiveKit room finished connecting â€” null until then. Used
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
    _syncTranslationSpeaking();
    _syncUsageMeter();
  }

  /// Duck the peer's real voice for exactly the window a translation is
  /// audible, from EITHER source. Ducked, not silenced: it stays present
  /// underneath — see [AudioController]'s note on the level.
  ///
  /// [RealtimeTranslationPort.translationSpeaking] only ever covers the cloud
  /// mp3 player, so on the local-TTS path — the default on mobile — nothing was
  /// ducking anything: the peer kept talking underneath their own translation
  /// and the two voices piled up. [ttsSpeaking] is the missing half.
  ///
  /// Nothing upstream is touched: the peer keeps speaking, keeps transcribing
  /// and keeps sending; we only stop *playing* their voice out of this speaker,
  /// and our own mic goes on capturing.
  void _syncTranslationSpeaking() {
    final speaking = ttsSpeaking.value || widget.translation.translationSpeaking;
    if (speaking == _lastTranslationSpeaking) return;
    _lastTranslationSpeaking = speaking;
    _audio.onTranslationSpeaking(speaking);
    // La traduction se dit à voix haute : ça fait monter la lueur, pas le
    // panneau. Lui ne revient qu'au doigt.
  }

  /// Track real translation-live time for cost analytics. Starts while the
  /// live pipeline is connected and translating; stops while waiting /
  /// connecting / idle.
  void _syncUsageMeter() {
    final live = widget.translation.translationFeedbackPhase ==
        TranslationFeedbackPhase.live;
    if (live) {
      _translationLive.start();
    } else {
      _translationLive.stop();
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
        // We translate for the PEER, so the target is what the peer asked to
        // hear ([_peerListenLang], set by their language button) and otherwise
        // their account language from metadata.
        final target = _peerListenLang.isNotEmpty
            ? _peerListenLang
            : _discoverRemoteLang(room);
        // A metadata update can momentarily report no language for a peer that
        // is still in the room (observed: `attach src=en tgt=`). Re-attaching on
        // that gives an unconfigured route, which tears the pipeline down and
        // never brings it back. Keep the last known language instead.
        if (target.isEmpty &&
            _attachedTargetLang.isNotEmpty &&
            room.remoteParticipants.isNotEmpty) {
          DebugOverlay.log(
              'translation: ignoring empty remote lang, keeping $_attachedTargetLang');
          continue;
        }
        // The peer may have joined after we picked a language — re-announce so
        // they translate into it rather than into our account language.
        _announceOutputLang(room);
        if (target == _attachedTargetLang &&
            _mySourceLang == _attachedSourceLang) {
          continue;
        }
        _attachedTargetLang = target;
        _attachedSourceLang = _mySourceLang;
        final route = TranslationRoute(
          // Our mic, our real spoken language — never the language we listen in.
          sourceBcp47: _mySourceLang,
          targetBcp47: target,
        );
        await widget.translation.attachToRoom(room, route: route);
        // Pre-warm the TTS engine: setLanguage loads the voice, then a
        // zero-volume silent speak forces the browser to initialise the
        // synthesis pipeline so the first real translation plays instantly.
        if (_myOutputLang.isNotEmpty && kIsWeb) {
          unawaited(() async {
            try {
              final warmTag = _voiceTagFor(_myOutputLang);
              if (warmTag.isNotEmpty) {
                await _deviceTts.setLanguage(warmTag);
              }
              await _deviceTts.setVolume(0.0);
              await _deviceTts.speak(' ');
              await _deviceTts.stop();
              await _deviceTts.setVolume(1.0);
            } catch (_) {}
          }());
        } else if (_myOutputLang.isNotEmpty) {
          final preTag = _voiceTagFor(_myOutputLang);
          if (preTag.isNotEmpty) {
            unawaited(_deviceTts.setLanguage(preTag).catchError((_) {}));
          }
        }
      } while (_refreshPending && mounted);
    } finally {
      _refreshingTranslation = false;
    }
  }

  /// Poll-rebind translation until the remote's spoken language is known.
  /// Covers the second-joiner case: a peer already in the room when we connect
  /// emits no ParticipantConnectedEvent, and their JWT metadata (which carries
  /// their language) can hydrate a beat after connect — so the first bind ran
  /// blind (remote lang unknown) and nothing retried. That's the "only one
  /// side hears the translation" bug.
  Future<void> _rebindUntilRemoteLangKnown(Room room) async {
    for (var i = 0; i < 12; i++) {
      if (!mounted) return;
      if (_discoverRemoteLang(room).isNotEmpty) {
        await _refreshTranslationBinding(room);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  /// Déjà dit pendant cet appel : le bandeau ne revient pas à chaque phrase.
  bool _sttRefusalShown = false;

  /// Phrases dites d'affilée que la traduction n'a pas pu rendre — la route de
  /// réparation les a refusées (`unclear`), elles ne sont jamais parties chez le
  /// pair. Une seule phrase, ou un seul mot, qui PASSE remet le compteur à zéro.
  /// Trois d'affilée, c'est presque toujours la langue d'envoi qui n'est pas
  /// celle qu'on parle : le recogniser tourne sur la mauvaise et ne rend que du
  /// charabia.
  int _undeliveredStreak = 0;

  /// Combien d'échecs consécutifs avant de demander si la langue est la bonne.
  static const int _kLangCheckThreshold = 3;

  /// Déjà proposé pendant cet appel : on ne redemande pas à chaque phrase.
  bool _langCheckShown = false;

  /// Le système a refusé la reconnaissance vocale. On le dit UNE fois, en clair
  /// et longuement — c'est la moitié de la fonctionnalité qui vient de tomber,
  /// et l'utilisateur n'a aucun autre moyen de le savoir : sa voix part bien,
  /// simplement plus rien ne la transcrit.
  void _onSttRefused() {
    final key = AsrService.osRefusedKey.value;
    if (key == null || _sttRefusalShown || !mounted) return;
    _sttRefusalShown = true;
    // Une VRAIE pop-up, pas un bandeau. Le SnackBar se posait au bas de
    // l'écran, exactement là où flotte la barre d'appel : recouvert, il
    // n'apparaissait que comme un rectangle vide qu'on prend pour un bug.
    // Ici c'est la moitié de l'appel qui vient de tomber — ça mérite qu'on
    // s'arrête dessus et qu'on le referme d'un geste conscient.
    //
    // Reporté d'une frame : ce signal peut arriver depuis initState, et on
    // n'ouvre pas de dialogue pendant une construction.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showSwaycoNotice(
        context: context,
        icon: Icons.mic_off_rounded,
        message: AppStrings.t(key),
        buttonLabel: AppStrings.t('tip_got_it'),
        danger: true,
      );
    });
  }

  /// Trois phrases dites d'affilée qui ne sont pas passées. La cause la plus
  /// probable, et la seule sur laquelle l'utilisateur peut agir : la langue
  /// d'envoi n'est pas celle qu'il parle. On le demande franchement, une seule
  /// fois par appel ; « Changer la langue » ouvre le même sélecteur que la
  /// pastille.
  void _promptSpokenLanguageCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showSwaycoNotice(
        context: context,
        icon: Icons.translate_rounded,
        message: AppStrings.t('call_lang_check_q'),
        buttonLabel: AppStrings.t('call_lang_check_change'),
        secondaryLabel: AppStrings.t('call_lang_check_keep'),
      ).then((change) {
        if (change == true && mounted) _openLanguagePairSheet();
      });
    });
  }

  @override
  void initState() {
    super.initState();
    ActivitySignal.setCall(true);
    widget.translation.localTranscript?.addListener(_onMyTranscript);
    Analytics.track('screen_view', props: {'screen': 'live'});
    // Zone messages : côté choisi, démonstration déjà vue, repli de la saisie.
    _chatFocus.addListener(_onChatFocusChanged);
    // Le bouton REC : autorisé par la liste du serveur (en plus de l'e-mail
    // compilé). Silencieux en cas d'erreur : le bouton reste simplement caché.
    unawaited(EgressApi.checkAllowed().then((ok) {
      if (ok && mounted) setState(() => _egressAllowedByServer = true);
    }));
    _start();
    // Hold the connecting splash for a minimum of 5s so it is actually
    // readable even when the room connects almost instantly.
    _splashTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _minSplashDone = true);
    });
    unawaited(_loadPeerProfile());
    unawaited(_loadMyAvatar());
    // Le système peut refuser de transcrire (Siri / Dictée coupés) : sans ce
    // fil, la panne serait totalement muette côté utilisateur.
    AsrService.osRefusedKey.addListener(_onSttRefused);
    _onSttRefused();
    _wireDeviceTtsSignal();
    ttsSpeaking.addListener(_syncTranslationSpeaking);
    unawaited(_loadDeviceVoiceLangs());
    // L'écran reste allumé tant que l'appel dure : sans ça, le téléphone se met
    // en veille au bout de quelques secondes sans toucher, alors qu'on parle.
    unawaited(_keepScreenOn(true));
    _wakeDock();
    // Caller waiting for pickup: listen for the callee declining so we
    // can close this screen instead of ringing into an empty room.
    final callId = widget.outgoingCallId;
    if (widget.isCaller) {
      if (callId != null && callId.isNotEmpty) {
        _declineChannel = IncomingCallApi.subscribeDecline(
          callId: callId,
          onDeclined: _onDeclinedByCallee,
        );
      }
      // Safety net for the lost-broadcast / powered-off-callee cases above:
      // leave the waiting room after the ring window if nobody joined.
      //
      // Armed even WITHOUT a call id. That id comes from the `incoming_calls`
      // insert, and when that insert fails nobody is being rung at all — which
      // is exactly when the caller must not be left listening to a dial tone
      // forever. The one case that needs the timeout most was the one case
      // that used to skip it.
      _ringTimeout = Timer(const Duration(seconds: 25), _onRingTimeout);
    }
  }

  /// Ring window elapsed with no one joining — the callee declined (and the
  /// broadcast was lost), their phone was off, or they simply didn't answer.
  /// Same teardown as a decline, with a "no answer" message.
  void _onRingTimeout() {
    if (_declinedHandled || _hadRemote || !mounted) return;
    _declinedHandled = true;
    CallAlert.stop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.t('call_no_answer'))),
    );
    unawaited(_hangUp());
  }

  /// Best-effort fetch of the peer's profile (PDP + language) for the
  /// "call ended" summary card. Silent on any failure — the card just falls
  /// back to an initial-letter avatar and no flag.
  /// MA photo pour mes bulles : elle était passée vide partout (une chaîne vide),
  /// donc mes phrases n'avaient jamais que mon initiale — « la photo ne se
  /// remplit pas ». Lecture silencieuse : sans réseau, l'initiale reste.
  String _myAvatarUrl = '';

  Future<void> _loadMyAvatar() async {
    if (!isSupabaseReady) return;
    try {
      final id = await DeviceId.getOrCreate();
      if (id.isEmpty) return;
      final me = await ProfileApi.fetchById(id);
      final url = me?.bestAvatarUrl ?? '';
      if (mounted && url.isNotEmpty && url != _myAvatarUrl) {
        setState(() => _myAvatarUrl = url);
      }
    } catch (_) {}
  }

  Future<void> _loadPeerProfile() async {
    final id = widget.peerId;
    if (id == null || id.isEmpty) return;
    try {
      final p = await ProfileApi.fetchById(id);
      if (mounted && p != null) {
        setState(() => _peerProfile = p);
        // Same gender, second use: the translator needs it to agree on the
        // person we are talking TO. Japanese marks no gender, so "あなたは新しい
        // 方ですか" is otherwise rendered "tu es nouveau/nouvelle ici ?" — and the
        // TTS reads the slash out loud.
        widget.translation.peerGender = p.gender;
        // Both halves of my language's voice were fetched at boot; now that the
        // peer's gender is known, configure the matching one so the very first
        // translation already speaks in the right voice. From disk — no
        // download, and it no-ops when the gender is already the loaded one.
        if (!kIsWeb && _myOutputLang.isNotEmpty && p.gender.isNotEmpty) {
          unawaited(SpeechService.instance.ensureLanguageInstalled(
            _myOutputLang,
            gender: p.gender,
          ));
        }
      }
    } catch (_) {
      // Offline / not found — summary degrades gracefully.
    }
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

  Future<void> _start() async {
    // Pre-permission priming: the mic is essential to a call, so we never
    // fire the OS prompt cold. Explain why first; if the user declines the
    // rationale we abort without burning the one-shot iOS prompt.
    if (!(await Permission.microphone.status).isGranted) {
      if (!mounted) return;
      final ok = await PermissionPriming.show(
        context,
        icon: Icons.mic_rounded,
        title: AppStrings.t('mic_prime_title'),
        body: AppStrings.t('mic_prime_body'),
        confirmLabel: AppStrings.t('mic_prime_enable'),
      );
      if (!ok) {
        if (mounted) {
          setState(() {
            _connecting = false;
            _connectError = AppStrings.t('call_perm_required');
          });
        }
        return;
      }
    }
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
    if (_startCam) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        // Caméra refusée : on appelle quand même, sans image.
        _startCam = false;
        if (mounted) setState(() => _camOn = false);
      }
    }

    // iOS only: speech recognition is what actually translates a voice — a
    // call running without it would connect and carry raw untranslated
    // audio, which defeats the app's one job. So unlike the Apple STT probe
    // in AsrService (silent fallback to on-device Whisper), THIS path is a
    // hard gate: refuse and the call never connects, same as the mic above.
    // Android has no equivalent OS permission for its native recogniser
    // (just a device-capability check), so it keeps the Whisper fallback —
    // this block is iOS-only on purpose.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      var speechAuth = await AppleSttChannel.instance.authStatus();
      // notDetermined is the ONLY state where requestAuth() actually shows
      // Apple's own dialog — iOS spends that prompt once per install. Once
      // the answer is denied/restricted, calling requestAuth() again is a
      // silent no-op (returns denied instantly, nothing on screen): tapping
      // "Allow" in OUR sheet would look broken because there's no real OS
      // dialog left to trigger. The only way back at that point is the
      // Settings app, so already-denied gets a different sheet that deep
      // links there instead of re-asking — same split as NotifEnableFlow.
      if (speechAuth == AppleSttAuth.notDetermined) {
        if (!mounted) return;
        final ok = await PermissionPriming.show(
          context,
          icon: Icons.record_voice_over_rounded,
          title: AppStrings.t('speech_prime_title'),
          body: AppStrings.t('speech_prime_body'),
          confirmLabel: AppStrings.t('speech_prime_enable'),
        );
        if (!ok) {
          if (mounted) {
            setState(() {
              _connecting = false;
              _connectError = AppStrings.t('call_perm_required_speech');
            });
          }
          return;
        }
        speechAuth = await AppleSttChannel.instance.requestAuth();
      } else if (speechAuth != AppleSttAuth.authorized) {
        if (!mounted) return;
        final ok = await PermissionPriming.show(
          context,
          icon: Icons.record_voice_over_rounded,
          title: AppStrings.t('speech_prime_title'),
          body: AppStrings.t('speech_prime_settings_body'),
          confirmLabel: AppStrings.t('notif_prime_open_settings'),
        );
        if (ok) await openAppSettings();
        if (mounted) {
          setState(() {
            _connecting = false;
            _connectError = AppStrings.t('call_perm_required_speech');
          });
        }
        return;
      }
      if (speechAuth != AppleSttAuth.authorized) {
        setState(() {
          _connecting = false;
          _connectError = AppStrings.t('call_perm_required_speech');
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

    // Vidéo allégée (chauffe) : même qualité qu'avant, mais un seul
    // encodage (pas de simulcast : appel 1-à-1) et dynacast/adaptiveStream pour
    // ne plus encoder ni décoder ce que personne ne regarde. AUCUNE option
    // audio ici : l'audio reste celui du Room() nu, qui est le réglage éprouvé.
    final room = Room(
      roomOptions: const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        // 540p/30 fps, ~1 Mb/s : quasi indiscernable du 720p sur un écran de
        // téléphone, mais bien moins de pixels à encoder/décoder (chauffe).
        defaultCameraCaptureOptions: CameraCaptureOptions(
          params: VideoParametersPresets.h540_169,
        ),
        defaultVideoPublishOptions: VideoPublishOptions(
          simulcast: false,
          videoEncoding: VideoEncoding(maxBitrate: 1000 * 1000, maxFramerate: 30),
        ),
      ),
    );
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
      await room.localParticipant?.setCameraEnabled(_startCam);
      // EC on, NS OFF, AGC OFF — each flag's own reason is on its line below.
      // The oldest of the three: the translation pipeline plays a second audio
      // stream on the speakers that EC doesn't fully account for, so any
      // captured leak goes back into LiveKit. AGC then amplifies that leak each
      // loop and the feedback runs away to infinity. Without AGC the captured
      // leak stays below its source and decays naturally.
      await room.localParticipant?.setMicrophoneEnabled(
        true,
        audioCaptureOptions: const AudioCaptureOptions(
          echoCancellation: true,
          // Noise suppression OFF, and the reason is not the noise: livekit
          // sends `voiceIsolation` as a COPY of this flag
          // ({'voiceIsolation': noiseSuppression} in AudioCaptureOptions), so
          // leaving it on silently ran Apple's Voice Isolation over every
          // captured word. That is what the peer heard as a hollow, reverberant
          // "in a room" voice: the algorithm rebuilds the speech instead of
          // carrying it. There is no way to keep one and drop the other through
          // this API. Echo cancellation is untouched.
          noiseSuppression: false,
          // AGC OFF, and this time the reason is the line right above it.
          //
          // It was turned back on to make the voice "flat and settled" like a
          // normal call app, on the grounds that the leak it used to amplify
          // (the second capture) no longer exists. That part was true. What it
          // missed is what the line above had just introduced: with noise
          // suppression off, the room tone stays IN the signal — the commit that
          // did it said so, and accepted it. AGC's job is to pull quiet things
          // up, and between two words the quiet thing is now exactly that room
          // tone and the reverberant tail of the previous word. So it levels the
          // voice and lifts the room with it, and the peer hears the resonance
          // the noise-suppression fix had just removed.
          //
          // The two are individually reasonable and cannot both be on. The voice
          // sounding REAL wins over the voice sounding LEVELLED: a slightly
          // swelling voice is still the caller's, a reverberant one is not.
          //
          // If a levelled voice is wanted back, it has to come from somewhere
          // that does not touch the noise floor — a compressor on the captured
          // stream with a gate under it, not the capture chain's own AGC.
          autoGainControl: false,
        ),
      );
      // First attach with whatever remote-lang we already know (often nothing
      // yet). Refreshed dynamically as participants join / metadata arrives.
      await _refreshTranslationBinding(room);
      room.addListener(_onRoomChanged);
      _startMicProbe(room);
      _roomEvents = room.createListener()
        ..on<TrackSubscribedEvent>((_) {
          // The peer's audio (and the participant metadata carrying their
          // language) is now here — (re)bind translation in case the remote
          // language wasn't known at connect time.
          unawaited(_refreshTranslationBinding(room));
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
        // Qui parle, et à quel volume — la liste arrive triée, le plus fort en
        // tête. Sert uniquement à animer la pastille de traduction : aucune
        // décision audio ne s'appuie dessus.
        ..on<ActiveSpeakersChangedEvent>((e) {
          // Ma voix est mesurée en local (voir [_startMicProbe]) ; ici on ne
          // retient que celle d'en face — sauf si la sonde locale s'est
          // révélée muette sur cette plateforme, auquel cas le serveur
          // redevient notre seule source pour les deux voix.
          var loudest = 0.0;
          for (final p in e.speakers) {
            if (p is LocalParticipant) {
              if (_micProbeDead && p.audioLevel > _kVoiceOn) {
                _localVoice = p.audioLevel.clamp(0.0, 1.0);
              }
              continue;
            }
            if (p.audioLevel > loudest) loudest = p.audioLevel;
          }
          _remoteVoice = loudest.clamp(0.0, 1.0);
          // Là non plus, aucun réveil : la voix nourrit [_voiceLevel], donc la
          // lueur. Le panneau, lui, attend le doigt.
          _publishVoiceLevel();
        })
        // In-call typed-chat messages from the peer.
        ..on<DataReceivedEvent>(_onCaptionData)
        ..on<ParticipantConnectedEvent>((_) {
          // First remote joining = call answered â†’ silence the caller's
          // dial tone (no-op on native via the stub).
          CallAlert.stop();
          if (!_hadRemote) _playCallConnected();
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
        if (!_hadRemote) _playCallConnected();
        _hadRemote = true;
        // Peer was already here when we joined → no ParticipantConnectedEvent
        // fires for us, so keep re-binding until their language is known.
        unawaited(_rebindUntilRemoteLangKnown(room));
      }
      // La visio démarre sur le haut-parleur (on tient le téléphone devant
      // soi), l'appel normal sur l'écouteur. Un casque branché prime sur les
      // deux, au niveau de l'OS.
      await _audio.bind(room, video: _startCam);
      // Au départ aussi : sur iPhone un appel vidéo peut très bien démarrer sur le
      // haut-parleur de lui-même, et sans relance la voix traduite y reste muette
      // jusqu'au premier changement de route (voir [_reprimeDeviceTts]). Un
      // instant d'attente : la route a besoin de se poser.
      Future<void>.delayed(const Duration(milliseconds: 700), () {
        if (mounted) unawaited(_reprimeDeviceTts('call start'));
      });
      widget.translation.translationListenable?.addListener(_onTranslationStateChanged);
      // Reset the global mic-mute flag — it persists across re-attaches.
      setSendMuted(false);
      if (mounted) {
        setState(() {
          _room = room;
          _connecting = false;
          _micOn = true;
          _camOn = _startCam;
          _composerOpen = false;
        });
      }
      _connectedAt = DateTime.now();
      Analytics.track(
        'call_started',
        roomName: widget.roomName,
        langFrom: _mySourceLang,
        langTo: _attachedTargetLang,
        props: {'kind': _callKind},
      );
      Attribution.logCallStarted(_callKind);
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

  /// Whether the peer has muted their mic. Their mute disables the LiveKit audio
  /// track, which reaches us as a muted publication (and a `TrackMutedEvent`
  /// that already rebuilds this screen). Camera tracks are ignored — only the
  /// mic counts as "muted".
  bool _peerMicMuted(Room room) {
    final peer = _primaryRemote(room);
    if (peer == null) return false;
    for (final pub in peer.audioTrackPublications) {
      if (pub.muted) return true;
    }
    return false;
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

  /// Les deux personnes sont là : le contexte audio des sons suit celui de
  /// WebRTC pour ne pas couper le micro, puis un petit son de connexion.
  void _playCallConnected() {
    SwaycoSounds.callActive = true;
    HapticFeedback.mediumImpact();
  }

  Future<void> _toggleMic() async {
    final room = _room;
    if (room == null) return;
    final next = !_micOn;
    // Le bouton bascule TOUT DE SUITE, et la couche audio suit.
    //
    // `setMicrophoneEnabled` traverse WebRTC et prend le temps qu'elle prend ;
    // attendre son retour pour redessiner faisait un bouton qui répond après
    // coup — sur un mute, c'est la seule chose qu'on regarde. Le flag d'envoi
    // part avec le dessin : ce qui est dit après l'appui ne doit plus sortir,
    // même si la piste n'est pas encore coupée en dessous.
    setSendMuted(!next);
    if (next) {
      // Unmuting: immediately clear the TTS gate so SEND resumes at once.
      // Without this, a TTS that started while the mic was muted would keep
      // blocking SEND until its timer fires (up to 15 s).
      markTranslationDone();
    } else {
      // On coupe : plus rien ne sortira d'ici, et la pastille s'arrête net.
      _hotTicks = 0;
      _localVoice = 0;
      _publishVoiceLevel();
    }
    if (mounted) setState(() => _micOn = next);
    await room.localParticipant?.setMicrophoneEnabled(next);
  }

  /// Data channel packet from the peer: local-TTS native or streamed web path,
  /// plus the peer's listening-language announcements.
  void _onCaptionData(DataReceivedEvent e) {
    if (e.topic != _captionTopic) return;
    try {
      final m = jsonDecode(utf8.decode(e.data)) as Map<String, dynamic>;
      // The peer tapped their language button: they want to hear us in this
      // language from now on, so it becomes our translation target. A peer on an
      // older build never sends this and keeps being served their account
      // language from metadata.
      final listen = m[_kListenLangKey]?.toString() ?? '';
      if (listen.isNotEmpty) {
        DebugOverlay.log('peer listens in $listen');
        if (listen != _peerListenLang) {
          _peerListenLang = listen;
          final room = _room;
          if (room != null) unawaited(_refreshTranslationBinding(room));
        }
        return;
      }
      // The peer cut (or restored) translation on THEIR side: stop translating
      // for them. Our own ear is not affected.
      final xlateOn = m[_kTranslationOnKey];
      if (xlateOn is bool) {
        DebugOverlay.log('peer wants translation: $xlateOn');
        unawaited(_applyPeerWantsTranslation(xlateOn));
        return;
      }
      // Une phrase TAPÉE par le pair : elle s'écrit dans la conversation et se
      // dit avec la voix du device, comme une phrase parlée. Traitée avant le
      // cas de la voix, sinon le drapeau de TTS locale l'avalerait.
      if (m[_kTypedFlag] == true) {
        final trans = m['trans']?.toString() ?? '';
        final lang = m['lang']?.toString() ?? '';
        DebugOverlay.log('caption typed trans="$trans" lang=$lang');
        if (trans.isEmpty) return;
        final turn = _SpokenTurn(mine: false, text: trans);
        // Le même interrupteur que pour la voix : couper la traduction, c'est
        // en couper LE SON — la phrase s'écrit toujours. Avec le son, elle
        // s'écrit quand la voix démarre (voir [_enqueueSpeak]).
        if (_translationEnabled) {
          unawaited(_enqueueSpeak(trans, lang, onVoiceStart: () => _addTurn(turn)));
        } else {
          _addTurn(turn);
        }
        return;
      }
      if (m[kLocalTtsFlag] == true || m[kLegacyLocalTtsFlag] == true) {
        final trans = m['trans']?.toString() ?? '';
        final lang = m['lang']?.toString() ?? '';
        DebugOverlay.log('caption localTts trans="$trans" lang=$lang web=$kIsWeb');
        // Their ORIGINAL rides along next to the translation and was, until now,
        // dropped on the floor. Keep it: our own next sentence is translated in
        // its own request, so without this it has no idea what it replies to —
        // and reusing their exact wording keeps terms consistent both ways.
        widget.translation.notePeerUtterance(m['orig']?.toString() ?? '');
        final turn = _SpokenTurn(mine: false, text: trans);
        // Avec le son, la phrase s'écrit AU MOMENT où la voix démarre, pas à
        // l'arrivée du message : sinon le texte précède la voix de plusieurs
        // secondes (file d'attente, silence du pair) et on croit à une panne.
        // Son coupé : la phrase s'écrit tout de suite, elle ne se dit pas.
        if (trans.isNotEmpty && _translationEnabled) {
          unawaited(_enqueueSpeak(trans, lang, onVoiceStart: () => _addTurn(turn)));
        } else {
          _addTurn(turn);
        }
        return;
      }
      if (m['voiceOnly'] == true) {
        _addTurn(_SpokenTurn(mine: false, text: m['trans']?.toString() ?? ''));
        final audioB64 = m['audio']?.toString() ?? '';
        DebugOverlay.log('caption voiceOnly audio=${audioB64.length}b web=$kIsWeb');
        // On web: play via <audio> element so browser AEC can cancel the echo.
        // On native: audioplayers handles it.
        if (audioB64.isNotEmpty && _translationEnabled) {
          unawaited(_playTranslatedAudio(audioB64));
        }
        return;
      }
    } catch (_) {}
  }

  /// Cut translation FOR ME — the peer is free to keep hearing theirs.
  ///
  /// Each side owns its own ear. But translation runs on the SPEAKER's side, so
  /// "I don't want to hear translations" is not something we can honour alone:
  /// it is a request to the peer to stop translating *for us*. Same shape as the
  /// language button — sent by the listener, acted on by the speaker.
  ///
  /// Our own pipeline keeps running: we go on translating our voice for the
  /// peer, who still hears us translated unless THEY cut it on their side.
  /// Couper la traduction, c'est en couper LE SON — rien d'autre.
  ///
  /// La chaîne continue de tourner exactement comme avant : le pair traduit
  /// toujours, les phrases arrivent toujours et s'écrivent toujours dans la
  /// conversation. Seule la voix se tait. Rien n'est annoncé au pair non plus :
  /// ce qu'on entend chez soi ne le regarde pas, et lui couper sa traduction à
  /// distance rendait le retour en arrière lent (il fallait qu'il redémarre son
  /// moteur). Ici, reprendre est instantané : on remet le son.
  Future<void> _toggleTranslation() async {
    final want = !_translationEnabled;
    setState(() => _translationEnabled = want);
    if (!want) {
      // La phrase en cours de lecture s'arrête avec le reste : on a demandé le
      // silence, pas «le silence après celle-ci».
      _cancelQueuedSpeech();
    }
  }

  /// The peer asked us to stop (or resume) translating for them: it is OUR
  /// pipeline that has to stop, since we are the one who translates our own
  /// voice into their language. What we hear is untouched.
  Future<void> _applyPeerWantsTranslation(bool wants) async {
    if (wants == _peerWantsTranslation) return;
    _peerWantsTranslation = wants;
    final room = _room;
    if (room == null) return;
    if (wants) {
      // _attachedTargetLang still holds the route we tore down; clear it or the
      // "nothing changed" early-out would skip the re-attach entirely.
      _attachedTargetLang = '';
      await _refreshTranslationBinding(room);
    } else {
      await widget.translation.detach();
    }
  }

  /// Play base64 mp3 (cloud TTS) forwarded by the sender over the data channel.
  Future<void> _playTranslatedAudio(String audioB64) async {
    try {
      final bytes = base64Decode(audioB64);
      if (bytes.isEmpty || !mounted) return;
      // On web, play through the gesture-unlocked element (WebKit autoplay).
      if (kIsWeb) {
        final ok = await playTranslatedMp3(bytes);
        debugPrint('[sway-rt] web play ok=$ok ${bytes.length}b');
        if (ok) return;
      }
      await _ttsPlayer.stop();
      await _ttsPlayer.play(BytesSource(bytes));
      debugPrint('[sway-rt] played cloud audio ${bytes.length}b');
    } catch (e) {
      debugPrint('[sway-rt] play cloud audio FAILED: $e');
    }
  }

  // NB : la voix de l'appareil (`flutter_tts`) se dit par [_enqueueSpeak].
  // `ttsSpeaking` est piloté par les événements de début / fin de flutter_tts ;
  // son speak() peut revenir sans rien jouer (voix absente), donc aucune fin
  // n'est garantie — c'est le minuteur de sûreté de la porte du micro qui le
  // rouvre, jamais un événement attendu.

  /// The "translated voice volume" slider used to reach only the audioplayers
  /// element that plays a cloud mp3 — a path neither the device voice nor the
  /// old on-device one ever took, so the slider silently did nothing. Now that every
  /// translation is spoken by flutter_tts, the volume has to be handed to it,
  /// before each utterance (the engine forgets it across a stop()).
  Future<void> _applyTranslatedVolumeToDeviceTts() async {
    final v = _audio.translatedVolume.clamp(0.0, 1.0);
    // Logged because this setting is persisted: a slider left at zero during an
    // earlier call silences every translation in every call after it, and until
    // this volume was actually wired to the engine, a stored zero was harmless —
    // so a zero can be sitting in prefs from before it meant anything.
    if (v < 0.05) {
      DebugOverlay.log('translated volume is ${v.toStringAsFixed(2)} — '
          'the voice will be inaudible (check the in-call volume slider)');
    }
    try {
      await _deviceTts.setVolume(v);
    } catch (_) {}
  }

  /// Loudspeaker ⇄ earpiece. Calls now START on the loudspeaker with every volume
  /// at maximum (AudioController.bind). The earpiece stays one tap away: against
  /// the ear the loudspeaker cannot reach the mic, so no feedback loop. A
  /// plugged-in headset still wins over both — `_applySpeaker` refuses to
  /// override the OS.
  Future<void> _toggleSpeaker() async {
    await _audio.setSpeakerOn(!_audio.speakerOn);
    if (mounted) setState(() {});
    // Changer de route reconfigure la session audio sous les pieds du moteur de
    // voix : on le relance, sinon il « parle » dans le vide (voir
    // [_reprimeDeviceTts]).
    unawaited(_reprimeDeviceTts('route change'));
  }

  /// RELANCE de la voix de l'appareil après un changement de route (écouteur ⇄
  /// haut-parleur). Constaté sur iPhone : passé sur le haut-parleur, le moteur
  /// de synthèse répondait « 1 » (phrase jouée) sans qu'on entende rien — la
  /// session audio de WebRTC avait changé sous lui (même famille de panne que le
  /// silence du build 203, voir swayco_sounds.dart). On l'arrête, on lui fait
  /// oublier sa langue, on ré-arme l'attente de fin de phrase, puis on rejoue
  /// une phrase muette pour qu'il reprenne la session telle qu'elle est
  /// maintenant. Avec cette relance, la voix joue sur le haut-parleur (testé).
  /// Sans effet sur l'appel lui-même ; ignoré si une phrase est en cours.
  Future<void> _reprimeDeviceTts(String why) async {
    if (kIsWeb || ttsSpeaking.value) return;
    DebugOverlay.log('tts reprime ($why)');
    try {
      await _deviceTts.stop();
      _deviceTtsLang = '';
      await _deviceTts.awaitSpeakCompletion(true);
      final tag = _voiceTagFor(_myOutputLang);
      if (tag.isNotEmpty) {
        await _deviceTts.setLanguage(tag);
        _deviceTtsLang = tag;
      }
      await _deviceTts.setVolume(0.0);
      await _deviceTts.speak(' ').timeout(const Duration(seconds: 2));
      await _deviceTts.stop();
      await _applyTranslatedVolumeToDeviceTts();
      DebugOverlay.log('tts reprime done');
    } catch (e) {
      DebugOverlay.log('tts reprime failed: $e');
      try {
        await _deviceTts.stop();
        await _applyTranslatedVolumeToDeviceTts();
      } catch (_) {}
    }
  }

  /// La caméra qui filme est l'ARRIÈRE (sinon l'avant, celle de départ).
  bool _camFacingBack = false;

  /// Un retournement est en cours. Sans ce verrou, taper plusieurs fois de suite
  /// relançait la capture (stop → getUserMedia → replaceTrack) PAR-DESSUS la
  /// précédente : les redémarrages se marchaient dessus et la caméra restait
  /// bloquée.
  bool _flipBusy = false;

  /// Retourner la caméra, avant / arrière.
  ///
  /// LiveKit expose l'échange sur la piste elle-même, pas sur le participant :
  /// on va chercher la piste vidéo locale publiée et on lui demande de
  /// basculer. Sans piste — caméra coupée, ou pas encore publiée — il n'y a
  /// rien à retourner et on ne fait rien plutôt que de lever.
  Future<void> _flipCamera() async {
    if (_flipBusy) return;
    final room = _room;
    if (room == null) return;
    final track = _localVideo(room);
    if (track is! LocalVideoTrack) {
      DebugOverlay.log('flip camera: no local video track');
      return;
    }
    // Ce que dit la piste fait foi ; à défaut, notre propre mémoire.
    final opts = track.currentOptions;
    final facingBack = opts is CameraCaptureOptions
        ? opts.cameraPosition == CameraPosition.back
        : _camFacingBack;
    final next = facingBack ? CameraPosition.front : CameraPosition.back;
    _flipBusy = true;
    try {
      await track.setCameraPosition(next);
      if (mounted) {
        setState(() => _camFacingBack = next == CameraPosition.back);
      }
    } catch (e) {
      DebugOverlay.log('flip camera failed: $e');
    } finally {
      _flipBusy = false;
    }
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

  /// Dev-only: starts/stops the LiveKit Egress recording of this call
  /// (both participants' video + audio, for ad footage). Gated by
  /// [_isEgressAdmin] at the call site; the backend re-checks independently.
  Future<void> _toggleEgress() async {
    if (_egressBusy) return;
    final room = _room;
    if (room == null) return;
    setState(() => _egressBusy = true);
    try {
      if (_egressId == null) {
        final id = await EgressApi.start(room.name ?? widget.roomName);
        // Une trace de chaque démarrage : sans elle, un enregistrement qui ne
        // sort jamais ne laisse rien à examiner.
        Analytics.track('rec_start', props: {
          'ok': id != null,
          'egress': id ?? '',
          'room': room.name ?? widget.roomName,
        });
        if (id != null) _egressStartedAt = DateTime.now();
        if (mounted) setState(() => _egressId = id);
        if (id != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('● Enregistrement démarré'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        if (id == null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Egress: échec du démarrage')),
          );
        }
      } else {
        // Un second toucher juste après le premier ARRÊTAIT l'enregistrement
        // avant qu'il ait écrit quoi que ce soit (LiveKit le marque « ABORTED »,
        // 2 s, sans fichier) : le bouton passe à STOP dès le départ, et le doigt
        // y retombe. Pendant les premières secondes, on ignore l'arrêt.
        final startedAt = _egressStartedAt;
        if (startedAt != null &&
            DateTime.now().difference(startedAt) < const Duration(seconds: 8)) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Enregistrement en cours — attends quelques secondes avant STOP'),
                duration: Duration(seconds: 2),
              ),
            );
          }
          return;
        }
        final id = _egressId!;
        final ok = await EgressApi.stop(id);
        Analytics.track('rec_stop', props: {
          'ok': ok,
          'egress': id,
          'how': 'button',
        });
        if (mounted) setState(() => _egressId = null);
        if (!ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Egress: échec de l\'arrêt')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _egressBusy = false);
    }
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
    _audioSheetOpen = true;
    unawaited(_showCallSheet(
      (ctx) => _AudioSettingsSheet(
        controller: _audio,
        translationOn: _translationEnabled,
        onToggleTranslation: () => unawaited(_toggleTranslation()),
      ),
    ));
  }

  /// Les deux langues de l'appel, dans un seul panneau : à gauche celle que je
  /// parle, à droite celle que j'entends. Une roue par question, un drapeau à
  /// la fois — rien à lire, on fait défiler jusqu'au bon.
  void _openLanguagePairSheet() {
    // Le panneau n'a pas de bouton de validation : on note ce que les roues
    // désignent, et on applique quand il se referme — peu importe comment il a
    // été refermé. Appliquer à chaque cran relancerait le recogniser, ou
    // annoncerait une langue au pair, pour des langues qu'on ne fait que
    // survoler.
    var spoken = _mySourceLang;
    var heard = _myOutputLang;
    unawaited(_showCallSheet(
      (ctx) => _LanguagePairSheet(
        spokenCode: _mySourceLang,
        heardCode: _myOutputLang,
        onChanged: (s, h) {
          spoken = s;
          heard = h;
        },
      ),
    ).whenComplete(() {
      if (!mounted) return;
      // Deux chemins bien distincts : la langue parlée relance notre
      // recogniser, celle qu'on entend est annoncée au pair.
      if (_baseLang(spoken) != _baseLang(_mySourceLang)) {
        unawaited(_changeSpokenLanguage(spoken));
      }
      if (_baseLang(heard) != _baseLang(_myOutputLang)) {
        unawaited(_changeOutputLanguage(heard));
      }
    }));
  }


  /// `fr-FR` et `fr` sont la même langue : comparer les tags bruts ferait
  /// repartir le pipeline pour rien.
  static String _baseLang(String code) =>
      code.split('-').first.toLowerCase();

  /// Change la langue que mon micro est censé entendre. Purement local : le
  /// pair reçoit du texte déjà traduit, il n'a rien à savoir. Ce que ça coûte,
  /// c'est un redémarrage du pipeline — [_refreshTranslationBinding] compare à
  /// [_attachedSourceLang] et relance le recogniser sur la nouvelle langue.
  Future<void> _changeSpokenLanguage(String code) async {
    if (code.isEmpty || code == _mySourceLang) return;
    setState(() => _mySourceLang = code);

    // Le prochain appel repart sur ce choix, comme après le gate d'entrée —
    // sans toucher au «ne plus me demander» déjà exprimé.
    final saved = await UserPrefs.loadCallSpokenLang();
    await UserPrefs.saveCallSpokenLang(code, dontAsk: saved.dontAsk);

    final room = _room;
    if (room != null) await _refreshTranslationBinding(room);
  }

  /// Change the language the local user hears the remote translated into.
  ///
  /// Our own pipeline is untouched — we keep transcribing our mic in our real
  /// spoken language and translating for the peer. What changes is on THEIR
  /// phone: [_announceOutputLang] tells them to translate into [code], and their
  /// [_onCaptionData] re-binds their route to it. All we do locally is point the
  /// device voice at the new language — nothing is downloaded: the language is
  /// picked mid-call, so it has to speak now, not after a 60 MB bundle lands.
  Future<void> _changeOutputLanguage(String code) async {
    if (code.isEmpty || code == _myOutputLang) return;
    setState(() => _myOutputLang = code);

    final room = _room;
    if (room != null) _announceOutputLang(room);

    // Par le résolveur, pas le code brut : c'est ici que le `fr` nu du log
    // était poussé, et flutter_tts restait ensuite bloqué dessus.
    final tag = _voiceTagFor(code);
    if (tag.isNotEmpty) {
      _deviceTtsLang = tag;
      unawaited(_deviceTts.setLanguage(tag).catchError((_) {}));
    }
  }


  /// Tell the peer which language to translate into for us.
  ///
  /// Idempotent: only publishes when the announced value actually changed, so
  /// the re-announce on every participant/metadata event costs nothing.
  void _announceOutputLang(Room room) {
    if (_myOutputLang.isEmpty || _myOutputLang == _announcedOutputLang) return;
    if (room.remoteParticipants.isEmpty) return;
    _announcedOutputLang = _myOutputLang;
    DebugOverlay.log('announce listenLang=$_myOutputLang');
    unawaited(room.localParticipant
        ?.publishData(
          Uint8List.fromList(
            utf8.encode(jsonEncode({_kListenLangKey: _myOutputLang})),
          ),
          reliable: true,
          topic: _captionTopic,
        )
        .catchError((_) {}));
  }

  Future<void> _hangUp() async {
    // Dev-only ad-footage recording left running: stop it so it doesn't
    // keep billing/uploading after the call screen is gone. Best-effort,
    // never blocks hang-up.
    final egressId = _egressId;
    if (egressId != null) {
      _egressId = null;
      unawaited(EgressApi.stop(egressId).then((ok) {
        Analytics.track('rec_stop', props: {
          'ok': ok,
          'egress': egressId,
          'how': 'hangup',
        });
      }));
    }
    // EN PREMIER : iOS doit savoir tout de suite que l'appel est fini.
    //
    // CallKit n'était démonté qu'au retour de `nav.push`, dans root_shell —
    // c'est-à-dire quand l'ÉCRAN se referme. Or un appel qui a été connecté ne
    // referme pas son écran : il laisse la carte noire de fin d'appel, et elle
    // reste tant qu'on ne l'a pas quittée. Entre les deux, iOS croit toujours
    // être en communication : le journal des appels a compté neuf minutes pour
    // un appel de deux, et la session audio du système restait retenue tout ce
    // temps.
    //
    // Raccrocher et fermer l'écran sont deux choses différentes ; c'est la
    // première que le téléphone doit connaître, et à l'instant où elle arrive.
    // Avant les démontages qui suivent, aussi : ils sont bornés à cinq secondes
    // chacun et peuvent traîner, iOS n'a pas à les attendre.
    unawaited(IosCallKit.endAll());
    // Le pendant Android : là-bas la sonnerie n'est pas CallKit mais une
    // notification `ongoing` — que l'utilisateur ne peut donc PAS balayer.
    // Elle n'est effacée que sur le chemin où l'app est vivante et ouvre sa
    // propre modale ; sur tous les autres elle survit à l'appel. Sans
    // conséquence si rien n'est affiché, et déjà neutralisée sur le web.
    unawaited(LocalNotifications.cancelIncomingCall());
    // Caller giving up before the callee ever joined: tell their device to
    // stop ringing NOW (symmetric to the callee's decline broadcast), else
    // their phone rings on until a local ~30 s timeout. Covers manual
    // hang-up while waiting, ring-timeout, and the already-declined case
    // (harmless there — the callee is already gone).
    final outId = widget.outgoingCallId;
    if (widget.isCaller && !_hadRemote && outId != null && outId.isNotEmpty) {
      unawaited(IncomingCallApi.broadcastCancel(callId: outId));
      // App-killed filet: a VoIP "cancel" push so the callee's CallKit ring
      // stops even when their app isn't running to hear the realtime cancel.
      final callee = widget.peerId ?? '';
      if (callee.isNotEmpty) {
        unawaited(
          IncomingCallApi.notifyCancel(calleeId: callee, callId: outId),
        );
        // ... et il lui reste une notification « Appel manque » avec ta photo.
        unawaited(
          IncomingCallApi.notifyMissed(
            calleeId: callee,
            callerId: AuthService.currentUserId,
          ),
        );
      }
    }
    // Bounded: on iOS a WebRTC/CallKit teardown can hang (same class of
    // unbounded-await bug already fixed on the join path) — without a
    // timeout here, the user gets stuck on a spinner and has to force-quit
    // the app to get back in. Best-effort cleanup; the UI always recovers.
    try {
      await widget.translation.detach().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[hangup] translation.detach timed out/failed: $e');
    }
    try {
      await _roomEvents?.dispose().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[hangup] roomEvents.dispose timed out/failed: $e');
    }
    _roomEvents = null;
    final r = _room;
    _room = null;
    if (r != null) {
      r.removeListener(_onRoomChanged);
      try {
        await r.disconnect().timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint('[hangup] room.disconnect timed out/failed: $e');
      }
      try {
        await r.dispose().timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint('[hangup] room.dispose timed out/failed: $e');
      }
    }
    // Summary card only if a peer actually joined. The caller connects to
    // LiveKit while still ringing ([_connectedAt] is set), so using that
    // alone left them stuck on the "call ended" page after a decline /
    // no-answer / hang-up-while-waiting.
    final startedAt = _connectedAt;
    if (_hadRemote && startedAt != null && mounted) {
      _finalDuration = DateTime.now().difference(startedAt);
      setState(() => _ended = true);
      unawaited(_prepareEndedCard());
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  // ── Fin d'appel 15a : drapeau flouté en fond ──────────────────────────────

  /// Image du drapeau du pays du pair, chargée (precacheImage) avant
  /// d'autoriser le partage : sans elle le PNG partagé n'aurait que le dégradé.
  ImageProvider? _endedFlag;

  /// Faux tant que le drapeau charge : le bouton Partager attend.
  bool _endedReady = false;

  /// Pays à dominante blanche : on ajoute un voile bleu nuit en haut pour que
  /// le logo et la croix restent lisibles.
  static const Set<String> _lightFlags = {'jp', 'kr', 'ca', 'fi'};

  /// Lance le chargement du drapeau du pays du pair (flagcdn, code ISO).
  Future<void> _prepareEndedCard() async {
    final iso = countryIso2For(_peerProfile?.country ?? '').toLowerCase();
    if (iso.isNotEmpty) {
      final provider = NetworkImage('https://flagcdn.com/w1280/$iso.png');
      try {
        await precacheImage(provider, context);
        if (!mounted) return;
        setState(() => _endedFlag = provider);
      } catch (e) {
        debugPrint('[call-ended] flag precache failed: $e');
      }
    }
    if (mounted) setState(() => _endedReady = true);
  }

  /// Capture la carte (le RepaintBoundary) en PNG et ouvre la feuille de
  /// partage du système. La croix et le bouton Partager n'y sont pas.
  Future<void> _shareEndedCard() async {
    if (!_endedReady) return;
    final boundary = _shareCardKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return;
    final box = context.findRenderObject() as RenderBox?;
    try {
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              data.buffer.asUint8List(),
              mimeType: 'image/png',
              name: 'swayco-call.png',
            ),
          ],
          fileNameOverrides: const ['swayco-call.png'],
          sharePositionOrigin:
              box != null ? box.localToGlobal(Offset.zero) & box.size : null,
        ),
      );
    } catch (e) {
      // Feuille fermée ou partage indisponible : rien à faire.
      debugPrint('[call-ended] share failed: $e');
    }
  }

  /// Deux chiffres au minimum (trois au-delà de 99).
  String _two(int n) => n.toString().padLeft(2, '0');

  /// Une case du compteur : chiffres + libellé dessous. [hot] = la case des
  /// secondes, en jaune.
  Widget _counterBox(String value, String unit, {bool hot = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 82,
          height: 80,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: hot ? SC.accent : Colors.white.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: hot ? SC.accent : Colors.white.withValues(alpha: 0.35),
              width: 1.2,
            ),
          ),
          child: Text(
            value,
            maxLines: 1,
            style: GoogleFonts.dmSans(
              fontSize: 40,
              fontWeight: FontWeight.w800,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
              color: hot ? SC.onAccent : Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          unit,
          style: GoogleFonts.ibmPlexMono(
            fontSize: 11,
            letterSpacing: 2,
            color: Colors.white.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }

  /// Le fond de la carte : dégradé de marque, drapeau flouté, voile bleu.
  Widget _endedBackground(String iso) {
    const s = 1.3; // saturation
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final flag = _endedFlag;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Base : sécurité si le drapeau ne charge pas, et couleur des bords.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-0.34, -0.94),
              end: Alignment(0.34, 0.94),
              colors: [SC.brandBlueDeep, SC.brandBlue, SC.brandCyan],
              stops: [0, 0.52, 1],
            ),
          ),
        ),
        // 2. Le drapeau, flouté (calculé une seule fois : écran statique).
        if (flag != null)
          Positioned(
            left: -60,
            top: -60,
            right: -60,
            bottom: -60,
            child: RepaintBoundary(
              child: Opacity(
                opacity: 0.7,
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(
                    sigmaX: 36,
                    sigmaY: 36,
                    tileMode: TileMode.decal,
                  ),
                  child: ColorFiltered(
                    colorFilter: const ColorFilter.matrix(<double>[
                      (1 - s) * lr + s, (1 - s) * lg, (1 - s) * lb, 0, 0,
                      (1 - s) * lr, (1 - s) * lg + s, (1 - s) * lb, 0, 0,
                      (1 - s) * lr, (1 - s) * lg, (1 - s) * lb + s, 0, 0,
                      0, 0, 0, 1, 0,
                    ]),
                    child: Image(
                      image: flag,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        // 3. Voile bleu.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x731F5EFF), Color(0x592B7FFF), Color(0x991F5EFF)],
              stops: [0, 0.5, 1],
            ),
          ),
        ),
        // Drapeau à dominante blanche : voile bleu nuit en haut (logo, croix).
        if (flag != null && _lightFlags.contains(iso))
          const Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 260,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x9904123A), Color(0x0004123A)],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Carte « appel terminé » (15a) : le drapeau du pays du pair, flouté, en
  /// fond ; sa photo, son prénom + drapeau, la durée en trois cases. Tout ce
  /// qui est dans le RepaintBoundary part dans le PNG partagé ; la croix et
  /// « Partager » restent dehors.
  Widget _buildEndedSummary(BuildContext context) {
    final profile = _peerProfile;
    final name = (profile?.displayName.trim().isNotEmpty ?? false)
        ? profile!.displayName.trim()
        : AppStrings.t('profile_anonymous');
    final firstName = name.split(RegExp(r'\s+')).first;
    final lang = profile?.language.trim() ?? '';
    final iso = countryIso2For(profile?.country ?? '').toLowerCase();
    // Country flag once the peer's country is known (the spoken language
    // doesn't always match the country); language flag otherwise.
    final flagEmoji = countryFlagFor(profile?.country ?? '') ??
        (lang.isEmpty ? null : findLanguageByCode(lang)?.flag) ??
        '';
    final dur = _finalDuration ?? Duration.zero;
    final hh = _two(dur.inHours);
    final mm = _two(dur.inMinutes % 60);
    final ss = _two(dur.inSeconds % 60);
    final nameStyle = popupDisplay(
      fontSize: 28,
      letterSpacing: -1.1,
      color: Colors.white,
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // La carte partagée : fond plein écran, sous la barre d'état aussi.
          Positioned.fill(
            child: RepaintBoundary(
              key: _shareCardKey,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _endedBackground(iso),
                  SafeArea(
                    child: Stack(
                      children: [
                        // Logo : « swayc » blanc + « ø » jaune.
                        const Positioned(
                          top: 12,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: SwaycoWordmark(
                              fontSize: 29,
                              letterSpacing: 0.5,
                              oColor: SC.accent,
                            ),
                          ),
                        ),
                        Align(
                          alignment: const Alignment(0, -0.35),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.call_end_rounded,
                                    size: 18,
                                    color: Color(0xD9FFFFFF),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    AppStrings.t('call_ended_label')
                                        .toUpperCase(),
                                    style: GoogleFonts.ibmPlexMono(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: 2.5,
                                      color: Colors.white.withValues(
                                        alpha: 0.85,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              // Photo : bordure blanche de 5, ombre bleu nuit.
                              Container(
                                width: 150,
                                height: 150,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF04123A)
                                          .withValues(alpha: 0.5),
                                      blurRadius: 50,
                                      spreadRadius: -12,
                                      offset: const Offset(0, 24),
                                    ),
                                  ],
                                ),
                                child: ClipOval(
                                  child: ProfileAvatar(
                                    displayName: name,
                                    avatarUrl: profile?.avatarUrl,
                                    fallbackUrl: profile?.fallbackPhotoUrl,
                                    size: 140,
                                    popular: (profile?.isPro ?? false) || (profile?.isPlus ?? false),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 18),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 24),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        firstName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: nameStyle,
                                      ),
                                    ),
                                    if (_endedFlag != null) ...[
                                      const SizedBox(width: 12),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(5),
                                        child: Image(
                                          image: _endedFlag!,
                                          width: 36,
                                          height: 24,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ] else if (flagEmoji.isNotEmpty) ...[
                                      const SizedBox(width: 12),
                                      Text(
                                        flagEmoji,
                                        style: const TextStyle(fontSize: 26),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(height: 26),
                              // Durée : H · MIN · S en cases.
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _counterBox(
                                    hh,
                                    AppStrings.t('call_unit_h'),
                                  ),
                                  _counterColon(),
                                  _counterBox(
                                    mm,
                                    AppStrings.t('call_unit_min'),
                                  ),
                                  _counterColon(),
                                  _counterBox(
                                    ss,
                                    AppStrings.t('call_unit_s'),
                                    hot: true,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Hors capture : la croix (en haut à gauche) et « Partager ».
          SafeArea(
            child: SizedBox.expand(
              child: Stack(
                children: [
                  Positioned(
                    top: 4,
                    left: 4,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.4),
                            width: 1.2,
                          ),
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 24,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 20,
                    bottom: 38,
                    child: Opacity(
                      opacity: _endedReady ? 1 : 0.5,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _shareEndedCard,
                        child: Container(
                          height: 56,
                          padding: const EdgeInsets.fromLTRB(18, 0, 22, 0),
                          decoration: BoxDecoration(
                            color: SC.accent,
                            borderRadius: BorderRadius.circular(999),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF04123A)
                                    .withValues(alpha: 0.25),
                                blurRadius: 28,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.ios_share,
                                size: 22,
                                color: SC.onAccent,
                              ),
                              const SizedBox(width: 9),
                              Text(
                                AppStrings.t('call_share'),
                                style: popupDisplay(
                                  fontSize: 15,
                                  color: SC.onAccent,
                                ),
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
        ],
      ),
    );
  }

  /// Le « : » entre deux cases, aligné sur les chiffres (pas sur les libellés).
  Widget _counterColon() => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: SizedBox(
          height: 80,
          child: Center(
            child: Text(
              ':',
              style: TextStyle(
                color: Colors.white,
                fontSize: 34,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
        ),
      );

  Future<void> _confirmLeave() async {
    final leave = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('call_leave_q'),
      body: AppStrings.t('call_leave_body'),
      confirmLabel: AppStrings.t('call_leave'),
      cancelLabel: AppStrings.t('call_stay'),
      icon: Icons.call_end_rounded,
    );
    if (leave == true && mounted) await _hangUp();
  }

  @override
  void dispose() {
    ActivitySignal.setCall(false);
    SwaycoSounds.callActive = false;
    widget.translation.localTranscript?.removeListener(_onMyTranscript);
    AsrService.osRefusedKey.removeListener(_onSttRefused);
    _chatCtrl.dispose();
    _chatFocus.removeListener(_onChatFocusChanged);
    _chatFocus.dispose();
    _splashTimer?.cancel();
    _ringTimeout?.cancel();
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
        langFrom: _mySourceLang,
        langTo: _attachedTargetLang,
        props: {
          'kind': _callKind,
          'duration_ms': durMs,
          // Real translation-live time â€” drives the live engine cost
          // estimate in the admin dashboard.
          'translation_ms': _translationLive.elapsed.inMilliseconds,
        },
      );
      Attribution.logCallEnded(_callKind, durMs);
    }
    widget.translation.translationListenable?.removeListener(_onTranslationStateChanged);
    // L'appel est fini : l'écran peut de nouveau se mettre en veille.
    unawaited(_keepScreenOn(false));
    _audio.dispose();
    unawaited(_ttsPlayer.dispose());
    _cancelQueuedSpeech();
    ttsSpeaking.removeListener(_syncTranslationSpeaking);
    ttsSpeaking.dispose();
    _voiceLevel.dispose();
    _myVoiceLevel.dispose();
    _composerIdle?.cancel();
    _dockIdleTimer?.cancel();
    _trStep.dispose();
    _micProbe?.cancel();
    final declineCh = _declineChannel;
    _declineChannel = null;
    if (declineCh != null) {
      unawaited(Supabase.instance.client.removeChannel(declineCh));
    }
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

  Future<void> _keepScreenOn(bool on) async {
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {
      // Pas de wakelock disponible (plateforme, test) : l'appel continue.
    }
  }

  // ── Le rail de droite et la carte de messages ─────────────────────────────

  /// Le rail : haut-parleur, caméra, micro, réglage du son, puis raccrocher
  /// (et REC pour l'admin). Posé à droite, JUSTE sous la vignette caméra. Rangé
  /// par défaut : il apparaît au tap sur l'écran et s'efface après 2 s sans
  /// geste ; rangé, il ne répond plus aux taps.
  Widget _buildCallRail(BuildContext context) {
    final visible = !_dockDimmed && !_sheetOpen;
    // La vignette : top = paddingTop + 40, hauteur 176 ; 12 px d'air dessous.
    final top = MediaQuery.paddingOf(context).top + 40 + 176 + 12;
    const gap = SizedBox(height: 12);
    return Positioned(
      key: const ValueKey('call_rail'),
      right: 20,
      top: top,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeInOut,
          opacity: visible ? 1 : 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Blanc plein = ce qu'on veut voir d'un coup d'œil : le
              // haut-parleur ACTIF, la caméra et le micro COUPÉS.
              _RailButton(
                label: AppStrings.t(
                  _audio.speakerOn ? 'call_speaker' : 'call_earpiece',
                ),
                icon: _audio.speakerOn
                    ? Icons.volume_up_rounded
                    : Icons.phone_in_talk_rounded,
                active: _audio.speakerOn,
                onTap: () {
                  _wakeDock();
                  _toggleSpeaker();
                },
              ),
              gap,
              _RailButton(
                label: AppStrings.t(_camOn ? 'call_camera' : 'call_video_off'),
                icon: _camOn
                    ? Icons.videocam_rounded
                    : Icons.videocam_off_rounded,
                active: !_camOn,
                onTap: () {
                  _wakeDock();
                  _toggleCam();
                },
              ),
              gap,
              _RailButton(
                label: AppStrings.t(_micOn ? 'call_mic' : 'call_mute'),
                icon: _micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                active: !_micOn,
                onTap: () {
                  _wakeDock();
                  _toggleMic();
                },
              ),
              gap,
              // Ouvre un panneau : blanc pendant qu'il est ouvert.
              _RailButton(
                label: AppStrings.t('call_audio'),
                icon: Icons.tune_rounded,
                active: _audioSheetOpen,
                onTap: _openAudioSheet,
              ),
              gap,
              // Raccrocher : gardé tel quel (rouge, même action qu'avant). Il
              // n'a plus sa rangée du bas ; il suit le rail en attendant la
              // décision.
              _RailButton(
                label: AppStrings.t('call_end'),
                icon: Icons.call_end_rounded,
                fill: const Color(0xFFE53935),
                onTap: _hangUp,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Le bouton REC (admin seulement), posé À CÔTÉ du rail, à sa gauche, au
  /// niveau de sa première touche : il suit le rail (même fondu, même rangement).
  Widget _buildCallRec(BuildContext context) {
    final visible = !_dockDimmed && !_sheetOpen;
    final top = MediaQuery.paddingOf(context).top + 40 + 176 + 12;
    return Positioned(
      key: const ValueKey('call_rec'),
      // Le rail : right 20 + 48 de large ; 12 d'air.
      right: 20 + _RailButton.size + 12,
      top: top,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeInOut,
          opacity: visible ? 1 : 0,
          child: _RailButton(
            label: _egressId == null ? 'REC' : 'STOP',
            icon: Icons.fiber_manual_record,
            active: _egressId != null,
            // Pas de toucher « muet » : pendant le démarrage, on le DIT (sinon
            // on croit que rien ne s'est passé et on re-touche — ce qui
            // arrêtait tout).
            onTap: _egressBusy
                ? () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Enregistrement en cours de démarrage…'),
                        duration: Duration(seconds: 2),
                      ),
                    )
                : () {
                    _wakeDock();
                    _toggleEgress();
                  },
          ),
        ),
      ),
    );
  }

  /// Le galet de l'en-tête : 30 px, sans ondes, NON cliquable. Réduit par une
  /// transformation (son encombrement est kSize × 1,9) et posé dans une boîte
  /// de 30 px. Il s'estompe à l'étape 2 du texte d'état (« Patiente… »).
  Widget _cardOrb() {
    const double size = 30;
    return ValueListenableBuilder<int>(
      valueListenable: _trStep,
      builder: (context, step, child) => AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: step == 1 ? 0.55 : 1,
        child: child,
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: IgnorePointer(
          child: OverflowBox(
            minWidth: TranslationOrb.box,
            maxWidth: TranslationOrb.box,
            minHeight: TranslationOrb.box,
            maxHeight: TranslationOrb.box,
            child: Transform.scale(
              scale: size / TranslationOrb.kSize,
              child: TranslationOrb(
                ripples: false,
                on: _translationEnabled,
                micOn: _micOn,
                ttsSpeaking: ttsSpeaking,
                voiceLevel: _voiceLevel,
                onTap: () {},
                onLongPress: () {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Le statut : les 4 étapes de la traduction (TranslationStepCaption), sans
  /// pastille noire. Coupée, la traduction le DIT.
  Widget _cardStatus(String peerFirstName) {
    if (!_translationEnabled) {
      return Text(
        AppStrings.t('call_translation_paused'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.65),
          fontSize: 14,
          fontWeight: FontWeight.w800,
          shadows: const [Shadow(color: Colors.black, blurRadius: 8)],
        ),
      );
    }
    return TranslationStepCaption(
      bare: true,
      peerName: peerFirstName,
      myVoice: _myVoiceLevel,
      myLines: widget.translation.localTranscript,
      onStep: (s) => _trStep.value = s,
    );
  }

  /// La pastille de langue : le drapeau rond de la langue d'écoute + un chevron.
  /// Un tap ouvre le panneau des langues.
  Widget _cardLangPill() {
    final code = findCallLanguageByCode(
          _myOutputLang.isNotEmpty
              ? _myOutputLang
              : AppStrings.currentBcp47.value,
        )?.countryCode ??
        '';
    return Semantics(
      label: AppStrings.t('call_language'),
      button: true,
      child: Pressable(
        bounce: true,
        onTap: _openLanguagePairSheet,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (code.isNotEmpty)
                ClipOval(
                  child: CountryFlag.fromCountryCode(
                    code,
                    theme: const ImageTheme(
                      width: 22,
                      height: 22,
                      shape: Circle(),
                    ),
                  ),
                )
              else
                const Icon(Icons.translate_rounded, size: 18, color: Colors.white),
              const SizedBox(width: 4),
              const Icon(Icons.unfold_more_rounded, size: 18, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }

  /// La carte de messages, PERMANENTE : toujours en bas, jamais rangée avec le
  /// rail. En-tête (galet + statut + drapeau), deux messages au plus, crayon.
  Widget _buildCallCard(
    BuildContext context, {
    required String peerFirstName,
  }) {
    final mq = MediaQuery.of(context);
    final kb = mq.viewInsets.bottom;
    final sb = mq.viewPadding.bottom;
    // 28 de marge ; clavier levé, la carte se pose juste au-dessus de lui.
    final bottom = kb > 0 ? math.max(0.0, kb - sb) + 12 : 28.0;
    final showHeader = !_composerOpen && !_cardHeaderHidden;
    return Positioned(
      key: const ValueKey('call_card'),
      left: 14,
      right: 14,
      bottom: bottom,
      child: _CallCard(
        showHeader: showHeader,
        composerOpen: _composerOpen,
        header: Row(
          children: [
            // Le galet reste toujours dans l'en-tête de la carte, caméra
            // coupée comprise (fond noir + prénom au-dessus).
            _cardOrb(),
            const SizedBox(width: 10),
            Expanded(child: _cardStatus(peerFirstName)),
            const SizedBox(width: 8),
            _cardLangPill(),
          ],
        ),
        messages: _CardMessages(
          key: const ValueKey('card_msgs'),
          turns: _turns,
          myName: widget.displayName,
          myAvatarUrl: _myAvatarUrl,
          peerName: _peerProfile?.displayName ?? '',
          peerAvatarUrl: _peerProfile?.bestAvatarUrl ?? '',
          holdFade: _composerOpen,
          reservePencil: !_composerOpen,
          onTapZone: _toggleCardHeader,
        ),
        // Clé stable, position stable : ne JAMAIS re-mapper le champ de
        // saisie, le clavier y perdrait le focus (b2f3293).
        composer: _ComposerPill(
          key: const ValueKey('call_composer'),
          controller: _chatCtrl,
          focusNode: _chatFocus,
          sending: _chatSending,
          onSend: _sendCaption,
          open: _composerOpen,
          onOpen: () {
            _wakeDock();
            _openComposer();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_ended) return _buildEndedSummary(context);

    if (_connectError != null) {
      return Scaffold(
        backgroundColor: SC.dBg,
        appBar: AppBar(
          backgroundColor: SC.dBg,
          foregroundColor: SC.dTextPrimary,
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
                  style: TextStyle(color: SC.dTextMuted, height: 1.4),
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
      // spinner during LiveKit's handshake felt clinical — hence the app's
      // splash image, and a one-liner under it. Keeps the spinner so the
      // user still has motion feedback that something is happening. Held
      // for >= 5s (see _minSplashDone) et sur le fond de l'app, comme
      // partout ailleurs.
      //
      // Ces cinq secondes sont le seul moment où on a l'attention de
      // quelqu'un qui n'a encore rien à faire. La ligne y parlait de
      // décompte de crédits, à une époque où l'appel se payait — l'appel est
      // gratuit depuis, et elle occupait la meilleure place de l'écran pour
      // ne plus rien dire. Elle sert maintenant à ce qui améliore vraiment
      // l'appel qui commence : la façon de parler.
      return const CallLoader(logo: CallSplashImage.provider);
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

    return Stack(
      fit: StackFit.expand,
      children: [
    PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _confirmLeave();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: SC.dBg,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: SC.dBg,
          // Don't shrink the video when the keyboard opens — keep it full
          // screen; only the chat composer lifts above the keyboard (it adds
          // viewInsets.bottom itself).
          resizeToAvoidBottomInset: false,
          body: Builder(
            builder: (context) {
              // Pin the bottom safe-area inset so it stays CONSTANT when the
              // keyboard opens — otherwise MediaQuery.padding.bottom collapses
              // to 0, the right-side control rail's SafeArea shrinks, and the
              // buttons jump down. The composer reads viewInsets directly, so
              // it still lifts above the keyboard.
              final mq = MediaQuery.of(context);
              return MediaQuery(
                data: mq.copyWith(
                  padding: mq.padding.copyWith(bottom: mq.viewPadding.bottom),
                ),
                child: SafeArea(
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
                      mirrorMode: _camFacingBack
                          ? VideoViewMirrorMode.off
                          : VideoViewMirrorMode.mirror,
                    ),
                  )
                else if (_selfMain && remoteCount > 0)
                  // Self-main but local cam off â†’ still let the user tap to
                  // swap back to the remote. Show the local user's first
                  // name as placeholder.
                  GestureDetector(
                    onTap: () => setState(() => _selfMain = false),
                    child: _CameraOffTile(
                      label: localFirstName,
                      muted: !_micOn,
                    ),
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
                  _CameraOffTile(
                    label: peerFirstName,
                    muted: _peerMicMuted(room),
                  )
                else
                  Container(
                    color: SC.dMenu,
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
                // Le panneau effacé : l'écran ENTIER le rappelle. C'est ce qui
                // permet de le laisser disparaître complètement — on n'a pas à
                // retrouver une cible, il suffit de toucher n'importe où. Ce
                // premier tap ne fait QUE rallumer : il n'échange pas les deux
                // images au passage.
                //
                // Posé SOUS la vignette caméra : un tap sur elle (échanger les
                // images) ou sur son bouton « retourner la caméra » doit TOUJOURS
                // l'atteindre, rail rangé ou non. Une couche plein écran posée
                // par-dessus l'avalait — c'était le « je tape 10 fois, ça ne
                // retourne pas ».
                if (_dockDimmed || _composerOpen)
                  Positioned.fill(
                    key: const ValueKey('dock_wake'),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        // Clavier levé : un tap ailleurs le referme ; sinon il
                        // ne fait QUE rappeler le rail (il n'échange pas les
                        // deux images au passage).
                        if (_chatFocus.hasFocus) _chatFocus.unfocus();
                        _wakeDock();
                      },
                    ),
                  ),
                // PiP: shows whichever feed is NOT the main one. Tap to
                // swap. Always rendered when the corresponding party
                // exists, even if their camera is off â€” falls back to a
                // tiny "camera off" tile so the layout doesn't pop.
                if (_pipFeedAvailable(
                    local: local, remote: remote, hasRemote: remoteCount > 0))
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOutCubic,
                    // Toujours en haut à droite : les messages sont en bas, dans
                    // la carte, et le rail se pose juste dessous.
                    top: MediaQuery.paddingOf(context).top + 40,
                    right: 12,
                    width: 118,
                    height: 176,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
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
                                muted: _peerMicMuted(room),
                              );
                            }
                            // Main = remote, PiP = local.
                            if (local != null && _camOn) {
                              return VideoTrackRenderer(
                                local,
                                fit: VideoViewFit.cover,
                                mirrorMode: _camFacingBack
                                    ? VideoViewMirrorMode.off
                                    : VideoViewMirrorMode.mirror,
                              );
                            }
                            return _CameraOffTile(
                              compact: true,
                              label: localFirstName,
                              muted: !_micOn,
                            );
                          }(),
                        ),
                      ),
                          ),
                        ),
                        // Retourner la caméra, dans le coin de sa propre
                        // vignette : c'est SON image qu'on retourne, le bouton
                        // doit être posé dessus. Il déborde à demi du cadre —
                        // d'où le [Clip.none] — pour ne pas manger la vidéo.
                        // Entièrement DANS la vignette (plus à demi dehors) : la
                        // part qui dépassait du cadre ne recevait pas le doigt,
                        // et la cible était petite — dur à viser en appel.
                        Positioned(
                          left: 0,
                          bottom: 0,
                          child: _PipFlipButton(onTap: _flipCamera),
                        ),
                      ],
                    ),
                  ),
                // Dégradé noir au bas de l'écran : le texte de la carte se lit
                // sur n'importe quelle image.
                Positioned(
                  key: const ValueKey('call_bottom_scrim'),
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: 380,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.6),
                          ],
                        ),
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
                // Le rail (4 boutons + raccrocher) et la carte de messages.
                // Clés stables : un voisin inséré / retiré ne doit jamais
                // re-mapper le champ de saisie (b2f3293).
                _buildCallRail(context),
                if (_isEgressAdmin) _buildCallRec(context),
                _buildCallCard(
                  context,
                  peerFirstName: peerFirstName ?? '',
                ),
                // Brand watermark — top-centre, always on top of whatever
                // call layout is showing (full-screen, PiP, split…).
                Align(
                  alignment: Alignment.topCenter,
                  child: IgnorePointer(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      // Les messages rangés en haut prennent sa place : le logo
                      // s'efface pendant qu'ils sont là, et revient ensuite.
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 250),
                        opacity: 0.7,
                        child: SwaycoWordmark(
                          fontSize: 29,
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
                );
              },
            ),
          ),
        ),
    ),
      ],
    );
  }

}

/// Une touche ronde du rail : 48, icône pleine de 24. Repos : blanc 10 %,
/// bordure blanche 26 %, icône blanche. Actif : blanc plein, icône noire. PAS de
/// flou, PAS de verre.
class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.fill,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool active;

  /// Une couleur de fond propre (raccrocher), icône blanche.
  final Color? fill;

  static const double size = 48;

  @override
  Widget build(BuildContext context) {
    final Color bg = fill ??
        (active ? Colors.white : Colors.white.withValues(alpha: 0.10));
    return Semantics(
      label: label,
      button: true,
      toggled: active,
      child: Pressable(
        bounce: true,
        onTap: onTap,
        child: AnimatedContainer(
          // Court exprès : c'est un interrupteur, pas une transition.
          duration: const Duration(milliseconds: 90),
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: bg,
            border: Border.all(
              color: Colors.white
                  .withValues(alpha: (fill != null || active) ? 0 : 0.26),
            ),
          ),
          child: Icon(
            icon,
            size: 24,
            color: (fill != null || !active) ? Colors.white : Colors.black,
            // Au repos le rond est presque transparent : sur une image très
            // claire l'icône blanche se perdrait. Une ombre douce la détache
            // sans changer le style (rien sur le blanc plein ni le rouge).
            shadows: (fill == null && !active)
                ? [
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.55),
                      blurRadius: 6,
                    ),
                  ]
                : null,
          ),
        ),
      ),
    );
  }
}

/// La carte de l'appel : coins 28, bordure blanche 26 %, fond blanc 8 %. PAS de
/// BackdropFilter (un flou refait à chaque image vidéo chauffait le GPU).
///
/// Ancrée en bas : elle grandit vers le haut quand la saisie se déroule. Le
/// champ de saisie (ou son crayon) est posé dans un [Stack] à une place FIXE de
/// l'arbre — jamais re-mappé, sinon le clavier y perdrait le focus.
class _CallCard extends StatelessWidget {
  const _CallCard({
    required this.header,
    required this.showHeader,
    required this.messages,
    required this.composer,
    required this.composerOpen,
  });

  final Widget header;
  final bool showHeader;
  final Widget messages;
  final Widget composer;
  final bool composerOpen;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.26)),
      ),
      child: Stack(
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: Padding(
              // La saisie déroulée prend 46 + 12 sous les messages.
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                18,
                18 + (composerOpen ? 58.0 : 0.0),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showHeader) ...[
                    KeyedSubtree(
                      key: const ValueKey('card_header'),
                      child: header,
                    ),
                    const SizedBox(height: 12),
                  ],
                  messages,
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: composerOpen ? 16 : 12,
            bottom: composerOpen ? 16 : 12,
            height: 46,
            child: Align(alignment: Alignment.centerRight, child: composer),
          ),
        ],
      ),
    );
  }
}

/// Les messages de la carte : DEUX au plus, jamais plus. Photo ronde de 26, texte
/// de 16 px (graisse 600). Le plus récent en blanc plein, le précédent à ~70 %.
/// Au-delà de deux, une pastille « N plus tôt ».
///
/// Atténuation (gardée de l'ancien bloc) : 5 s sans geste ni nouveau message,
/// l'avant-dernier passe à 35 % — sauf les DEUX premiers de l'appel et pendant la
/// saisie. Un tap sur la zone, ou un nouveau message, le réveille.
class _CardMessages extends StatefulWidget {
  const _CardMessages({
    super.key,
    required this.turns,
    required this.myName,
    required this.myAvatarUrl,
    required this.peerName,
    required this.peerAvatarUrl,
    required this.holdFade,
    required this.reservePencil,
    required this.onTapZone,
  });

  final List<_SpokenTurn> turns;
  final String myName;
  final String myAvatarUrl;
  final String peerName;
  final String peerAvatarUrl;

  /// La saisie est dépliée : pas d'atténuation.
  final bool holdFade;

  /// Chaque ligne laisse 46 px à droite pour le crayon.
  final bool reservePencil;

  /// Un tap sur les messages : masque / ramène l'en-tête de la carte.
  final VoidCallback onTapZone;

  @override
  State<_CardMessages> createState() => _CardMessagesState();
}

class _CardMessagesState extends State<_CardMessages> {
  static const _yellow = Color(0xFFF4FF1F);
  static const Duration _fadeAfter = Duration(seconds: 5);
  static const int _neverFade = 2;

  Timer? _fadeTimer;
  bool _faded = false;
  int _seenLen = 0;

  void _armFade() {
    _fadeTimer?.cancel();
    if (widget.holdFade) return;
    _fadeTimer = Timer(_fadeAfter, () {
      if (mounted) setState(() => _faded = true);
    });
  }

  void _wake() {
    if (_faded) setState(() => _faded = false);
    _armFade();
  }

  @override
  void initState() {
    super.initState();
    _seenLen = widget.turns.length;
    _armFade();
  }

  @override
  void didUpdateWidget(covariant _CardMessages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.turns.length != _seenLen) {
      _seenLen = widget.turns.length;
      _wake();
    }
    if (widget.holdFade != oldWidget.holdFade) {
      if (widget.holdFade) {
        _fadeTimer?.cancel();
        if (_faded) setState(() => _faded = false);
      } else {
        _armFade();
      }
    }
  }

  @override
  void dispose() {
    _fadeTimer?.cancel();
    super.dispose();
  }

  Widget _row(_SpokenTurn turn, int idx, bool newest) {
    final name = turn.mine ? widget.myName : widget.peerName;
    final avatarUrl = turn.mine ? widget.myAvatarUrl : widget.peerAvatarUrl;
    final dim = _faded && idx == widget.turns.length - 2 && idx >= _neverFade;
    final double alpha = newest ? 1.0 : (dim ? 0.35 : 0.7);
    return AnimatedOpacity(
      duration: Duration(milliseconds: _faded ? 600 : 200),
      curve: Curves.easeOut,
      opacity: turn.delivered ? 1 : 0.5,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Liseré blanc 50 % : la photo se détache de la vidéo derrière.
          Container(
            padding: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.5),
            ),
            child: ProfileAvatar(
              displayName: name,
              avatarUrl: avatarUrl.isEmpty ? null : avatarUrl,
              size: 23,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                turn.text,
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: alpha),
                  fontSize: 16,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  fontStyle:
                      turn.delivered ? FontStyle.normal : FontStyle.italic,
                  shadows: [
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.55),
                      blurRadius: 8,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final turns = widget.turns;
    final from = turns.length > 2 ? turns.length - 2 : 0;
    final earlier = from;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Atténuées : le tap les réveille au lieu de masquer l'en-tête.
      onTap: () {
        if (_faded) {
          _wake();
        } else {
          widget.onTapZone();
        }
      },
      child: ConstrainedBox(
        // Même vide, la zone garde la place du crayon.
        constraints: const BoxConstraints(minHeight: 44),
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.only(right: widget.reservePencil ? 46 : 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (earlier > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    height: 24,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.keyboard_arrow_up_rounded,
                          size: 16,
                          color: _yellow,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          AppStrings.t('call_earlier', args: {'n': '$earlier'}),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              for (var i = from; i < turns.length; i++) ...[
                if (i > from) const SizedBox(height: 10),
                _row(turns[i], i, i == turns.length - 1),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Un tour de parole : ce qu'une des deux personnes vient de dire, déjà dans
/// la langue de CE device (ma phrase telle que je l'ai dite ; celle du pair
/// telle qu'elle m'arrive traduite).
class _SpokenTurn {
  _SpokenTurn({required this.mine, required this.text, this.delivered = true});
  final bool mine;
  final String text;

  /// Mine only: heard, but the peer never got it. Drawn dimmed.
  final bool delivered;
}

/// La saisie de l'appel, REPLIÉE en rond crayon : un tap la déplie en champ
/// (250 ms), le clavier monte. Elle se replie seule (voir l'écran d'appel) ;
/// un texte resté dans le champ se signale alors par un point jaune.
///
/// Le champ reste dans l'arbre même replié ([Visibility] garde son état) : le
/// retirer puis le remettre re-mapperait ses voisins, et le clavier y perdrait
/// son focus — c'est le bug de b2f3293.
class _ComposerPill extends StatefulWidget {
  const _ComposerPill({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onSend,
    required this.open,
    required this.onOpen,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final Future<void> Function() onSend;
  final bool open;
  final VoidCallback onOpen;

  @override
  State<_ComposerPill> createState() => _ComposerPillState();
}

class _ComposerPillState extends State<_ComposerPill>
    with SingleTickerProviderStateMixin {
  static const _yellow = Color(0xFFF4FF1F);

  /// Le rond apparaît avec un petit dépassement, ~0,45 s après l'ouverture.
  late final AnimationController _appear = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    _delay = Timer(const Duration(milliseconds: 450), () {
      if (mounted) _appear.forward();
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    _appear.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final full = c.maxWidth.isFinite ? c.maxWidth : 300.0;
        return ScaleTransition(
          scale: CurvedAnimation(
            parent: _appear,
            curve: Curves.easeOutBack,
          ).drive(Tween(begin: 0.5, end: 1.0)),
          child: FadeTransition(
            opacity: _appear,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              // Fermé : rond de 40 (même style que les touches du rail). Ouvert :
              // champ de 46, bordure jaune de 1,5, fond blanc 8 %.
              width: widget.open ? full : 40,
              height: widget.open ? 46 : 40,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(23),
                child: _Frost(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white
                          .withValues(alpha: widget.open ? 0.08 : 0.10),
                      borderRadius: BorderRadius.circular(23),
                      border: Border.all(
                        color: widget.open
                            ? _yellow
                            : Colors.white.withValues(alpha: 0.26),
                        width: widget.open ? 1.5 : 1,
                      ),
                    ),
                    child: Stack(
                      children: [
                        Visibility(
                          visible: widget.open,
                          maintainState: true,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 0, 7, 0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: widget.controller,
                                    focusNode: widget.focusNode,
                                    maxLines: 1,
                                    textCapitalization:
                                        TextCapitalization.sentences,
                                    textInputAction: TextInputAction.send,
                                    cursorColor: SC.accent,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                    ),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      filled: false,
                                      hintText: AppStrings.t('call_chat_hint'),
                                      hintStyle: TextStyle(
                                        color:
                                            Colors.white.withValues(alpha: 0.6),
                                        fontSize: 14,
                                      ),
                                      // Aucun liseré, y compris au focus : le
                                      // thème de l'app en pose un jaune sur les
                                      // champs, il ne doit pas cerner celui-ci.
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      disabledBorder: InputBorder.none,
                                      errorBorder: InputBorder.none,
                                      focusedErrorBorder: InputBorder.none,
                                      contentPadding:
                                          const EdgeInsets.fromLTRB(8, 8, 0, 8),
                                    ),
                                    onSubmitted: (_) => widget.onSend(),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                PadTap(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: widget.sending ? null : widget.onSend,
                                  child: Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      // Jaune ; grisé pendant l'envoi — un
                                      // second tap enverrait deux fois.
                                      color: widget.sending
                                          ? Colors.white24
                                          : _yellow,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.arrow_upward_rounded,
                                      color: Colors.black,
                                      size: 20,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (!widget.open)
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: widget.onOpen,
                              child: ValueListenableBuilder<TextEditingValue>(
                                valueListenable: widget.controller,
                                builder: (_, v, _) => Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    const Icon(
                                      Icons.edit,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                    // Un brouillon attend dans le champ.
                                    if (v.text.trim().isNotEmpty)
                                      Positioned(
                                        top: 7,
                                        right: 7,
                                        child: Container(
                                          width: 8,
                                          height: 8,
                                          decoration: const BoxDecoration(
                                            color: _yellow,
                                            shape: BoxShape.circle,
                                          ),
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
            ),
          ),
        );
      },
    );
  }
}


/// Un rond plein de la barre (conversation, raccrocher). Volontairement sans
/// flou : il est posé sur le verre du dock, qui a déjà flouté ce qu'il y a
/// dessous.
/// Le petit rond qui retourne la caméra, posé dans le coin de la vignette de
/// retour. Volontairement plus petit que les touches de la barre : il agit sur
/// la vignette, pas sur l'appel.
class _PipFlipButton extends StatelessWidget {
  const _PipFlipButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: AppStrings.t('call_flip_camera'),
      button: true,
      child: Pressable(
        bounce: true,
        onTap: onTap,
        // La cible déborde du rond visible, comme partout ailleurs : dans un
        // coin de vignette, un doigt tombe rarement au centre.
        child: SizedBox(
          width: 60,
          height: 60,
          child: Center(
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.55),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.35),
                ),
              ),
              child: const Icon(
                Icons.autorenew_rounded,
                color: Colors.white,
                size: 21,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Le galet de traduction : la pièce vivante de l'écran d'appel.
///
/// Peint d'un seul bloc, du fond vers l'avant : deux ondes qui s'échappent, un
/// halo qui respire, l'anneau irisé qui tourne, la bille de verre et son
/// reflet, puis les quatre barres. Tout est dessiné dans UN painter — empiler
/// autant de widgets flous, un par couche, coûterait une passe de composition
/// chacune, sur un écran qui fait déjà tourner une visio.
///
/// Coupée, la traduction le montre par une pierre éteinte : verre dépoli, bord
/// pointillé, un simple triangle de lecture. Rien ne bouge, et les tickers sont
/// arrêtés — pas d'animation qui brûle la batterie pour dire « je ne fais
/// rien ».
class TranslationOrb extends StatefulWidget {
  const TranslationOrb({
    super.key,
    required this.on,
    required this.ttsSpeaking,
    required this.voiceLevel,
    required this.onTap,
    required this.onLongPress,
    required this.micOn,
    this.ripples = true,
  });

  /// La traduction tourne. False = coupée : pierre endormie.
  final bool on;

  /// Le micro capte. Coupé, le galet ne réagit plus à AUCUNE voix : il enflait
  /// encore sur celle d'en face, et un galet qui bouge pendant qu'on est muet
  /// dit exactement le contraire de ce qui se passe — on croit être entendu.
  final bool micOn;

  /// Les ondes qui s'échappent. Coupées quand le galet n'est plus le sujet de
  /// l'écran : sous un panneau, elles vont chercher l'œil pour rien.
  final bool ripples;

  final ValueListenable<bool> ttsSpeaking;
  final ValueListenable<double> voiceLevel;
  final VoidCallback onTap;

  /// Appui long : les deux panneaux de l'appel, côte à côte.
  final VoidCallback onLongPress;

  /// La taille par défaut. Toutes les cotes du dessin sont données pour 130
  /// puis mises à l'échelle, donc ce seul nombre redimensionne l'ensemble sans
  /// rien déformer.
  static const double kSize = 84;

  /// La pierre endormie est plus petite que le galet vivant : couper la
  /// traduction se voit à sa taille avant même qu'on lise l'icône. Même
  /// rapport qu'avant — 104 sur 130.
  static const double dormantRatio = 0.8;

  /// Le triangle de lecture de la pierre endormie, en part de son diamètre
  /// (30 sur 83 quand le galet faisait 104) : il rétrécit avec elle.
  static const double dormantIconRatio = 0.36;

  /// La place réservée AUTOUR du galet. Le halo déborde de 18 px et les ondes
  /// montent jusqu'à 2,4 fois le disque : sans cette marge, elles sont peintes
  /// hors des limites du widget. Ça passe tant qu'aucun ancêtre ne rogne —
  /// c'est une chance, pas une garantie, et ça fausse la mise en page.
  static const double boxFactor = 1.9;

  /// L'encombrement réel du widget.
  static const double box = kSize * boxFactor;

  @override
  State<TranslationOrb> createState() => TranslationOrbState();
}

/// Remplace l'ancien verre dépoli (BackdropFilter) des pastilles posées sur la
/// vidéo : un flou refait à CHAQUE image vidéo faisait chauffer le GPU. Les
/// appelants compensent avec un fond plus opaque.
class _Frost extends StatelessWidget {
  const _Frost({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

class TranslationOrbState extends State<TranslationOrb>
    with TickerProviderStateMixin {
  /// Six mouvements, six périodes sans rapport entre elles (9 s, 5 s, 6,5 s,
  /// 3,8 s, 3,4 s, 1 s). Les faire dériver d'une seule horloge demanderait une
  /// période commune énorme, avec un saut visible à chaque bouclage ; six
  /// contrôleurs sur le même vsync coûtent moins que ce saut.
  late final AnimationController _spin = _ctrl(9000);
  late final AnimationController _spec = _ctrl(5000);
  late final AnimationController _bars = _ctrl(1000);
  late final AnimationController _float = _ctrl(6500);
  late final AnimationController _breathe = _ctrl(3800);

  /// Ces deux-là font l'aller-retour ; les autres tournent en boucle.
  late final List<AnimationController> _swinging = [_float, _breathe];
  late final List<AnimationController> _all = [
    _spin,
    _spec,
    _bars,
    _float,
    _breathe,
  ];

  AnimationController _ctrl(int ms) =>
      AnimationController(vsync: this, duration: Duration(milliseconds: ms));

  /// Deux amplitudes, lissées séparément, parce qu'elles ne disent pas la
  /// même chose :
  ///
  ///   • [_voice] monte quand QUELQU'UN PARLE — ce sont les quatre barres du
  ///     centre qui s'agitent ;
  ///   • [_tts] monte quand la TRADUCTION est dite — ce sont les ondes qui
  ///     partent fort, pendant que les barres reprennent leur rythme normal.
  ///
  /// Le galet dit ainsi d'un coup d'œil qui a la parole : la machine ou nous.
  final ValueNotifier<double> _voice = ValueNotifier<double>(_idleAmp);
  final ValueNotifier<double> _tts = ValueNotifier<double>(_idleAmp);
  double _voiceTarget = _idleAmp;
  double _ttsTarget = _idleAmp;

  /// L'enflure du galet quand ça parle : 1 au repos, [_maxSwell] au plus fort.
  ///
  /// Elle rend la capture VISIBLE — sans elle, un micro coupé ou qui capte mal
  /// ne se remarque qu'à la traduction qui n'arrive pas.
  final ValueNotifier<double> _swell = ValueNotifier<double>(1);
  double _swellTarget = 1;

  /// Le plafond. Un cinquième : assez pour qu'on le voie franchement réagir,
  /// pas au point qu'il vienne manger le visage à chaque phrase.
  static const double _maxSwell = 1.20;

  /// La présence du galet : [_idleOpacity] dans le silence, 1 dès que ça
  /// parle. Comme les touches qui s'effacent, mais lui ne va PAS jusqu'à zéro —
  /// c'est la seule chose qui reste à viser quand tout le reste a disparu.
  final ValueNotifier<double> _presence = ValueNotifier<double>(1);
  double _presenceTarget = 1;

  /// Le plancher, le même que celui qu'avait la barre.
  static const double _idleOpacity = 0.22;

  /// Le sursis avant que le galet ne commence à s'effacer.
  ///
  /// Sans lui, il pâlit à la seconde où on se tait — et comme on se tait entre
  /// deux phrases, il a l'air de s'être arrêté d'enregistrer. Les gens se
  /// précipitent alors pour enchaîner, ce qui coupe justement la phrase que la
  /// reconnaissance était en train de fermer. Une seconde et demie couvre les
  /// respirations d'une conversation normale.
  static const Duration _presenceHold = Duration(milliseconds: 1500);

  /// L'instant où le silence a commencé. Null tant que ça parle.
  DateTime? _quietSince;

  /// Le niveau à partir duquel le galet a fini de grossir.
  ///
  /// Bas EXPRÈS. Une voix de conversation normale l'atteint déjà, donc parler
  /// plus fort n'ajoute plus rien de visible. Le galet dit « je t'entends », il
  /// ne dit pas « plus fort » — récompenser le volume ferait crier, et un micro
  /// saturé se transcrit moins bien, pas mieux.
  static const double _swellCeiling = 0.22;

  /// Au repos, les barres ne bougent PAS. C'est le seuil de l'ancienne
  /// pastille, et il vaut mieux que le mien : des barres qui remuent tout le
  /// temps ne disent plus rien quand quelqu'un parle. Elles restent visibles —
  /// c'est le painter qui leur garde une hauteur de repos — simplement figées.
  static const double _idleAmp = 0.0;

  @override
  void initState() {
    super.initState();
    widget.ttsSpeaking.addListener(_retarget);
    widget.voiceLevel.addListener(_retarget);
    _bars.addListener(_tick);
    _syncRunning();
    _retarget();
  }

  @override
  void didUpdateWidget(covariant TranslationOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ttsSpeaking != widget.ttsSpeaking) {
      oldWidget.ttsSpeaking.removeListener(_retarget);
      widget.ttsSpeaking.addListener(_retarget);
    }
    if (oldWidget.voiceLevel != widget.voiceLevel) {
      oldWidget.voiceLevel.removeListener(_retarget);
      widget.voiceLevel.addListener(_retarget);
    }
    if (oldWidget.on != widget.on) _syncRunning();
    // Le micro vient de se couper : le galet doit retomber tout de suite, pas
    // attendre le prochain changement de niveau — muet, il n'en viendra plus.
    if (oldWidget.micOn != widget.micOn) _retarget();
  }

  /// Endormie, la pierre ne bouge pas : on arrête les six tickers plutôt que de
  /// repeindre soixante fois par seconde une image identique.
  void _syncRunning() {
    for (final c in _all) {
      if (!widget.on) {
        c.stop();
      } else if (!c.isAnimating) {
        if (_swinging.contains(c)) {
          c.repeat(reverse: true);
        } else {
          c.repeat();
        }
      }
    }
  }

  void _retarget() {
    final speaking = widget.ttsSpeaking.value;
    final voice = widget.micOn && widget.voiceLevel.value > 0.02;
    // Pendant la traduction, la voix humaine ne doit pas emballer les barres :
    // c'est le tour de la machine, et deux choses qui s'agitent en même temps
    // ne désignent plus personne.
    _voiceTarget = (voice && !speaking) ? 1.0 : _idleAmp;
    _ttsTarget = speaking ? 1.0 : _idleAmp;
    // La traduction ne fait pas enfler le galet : c'est la voix HUMAINE qu'on
    // renvoie à qui parle, pas le travail de la machine.
    final level = (speaking || !widget.micOn)
        ? 0.0
        : (widget.voiceLevel.value / _swellCeiling).clamp(0.0, 1.0);
    _swellTarget = 1 + (_maxSwell - 1) * level;
    // Il revient pour TOUT son, la traduction comprise : c'est lui qui montre
    // qu'elle est en train d'être dite. S'effacer pendant qu'elle parle
    // reviendrait à cacher le seul témoin du travail en cours.
    final live = voice || speaking;
    _presenceTarget = live ? 1.0 : _idleOpacity;
    // Le compte à rebours repart de zéro à chaque son : c'est le silence
    // CONTINU qui efface le galet, pas un blanc entre deux mots.
    _quietSince = live ? null : (_quietSince ?? DateTime.now());
  }

  void _tick() {
    // L'enflure suit plus vite que les barres : elle doit coller à la voix,
    // pas la traîner.
    final swell = _swell.value + (_swellTarget - _swell.value) * 0.22;
    if ((swell - _swell.value).abs() > 0.001) _swell.value = swell;
    // La présence revient VITE et s'en va lentement : on ne doit pas rater le
    // début d'une phrase, et un galet qui clignote entre deux mots serait pire
    // que pas de retour du tout.
    final rising = _presenceTarget > _presence.value;
    final quiet = _quietSince;
    // Et elle ne commence à retomber qu'après le sursis. Monter, en revanche,
    // n'attend jamais.
    if (!rising &&
        quiet != null &&
        DateTime.now().difference(quiet) < _presenceHold) {
      // On tient. Rien à faire.
    } else {
      final rate = rising ? 0.35 : 0.06;
      final pres = _presence.value + (_presenceTarget - _presence.value) * rate;
      if ((pres - _presence.value).abs() > 0.001) _presence.value = pres;
    }
    for (final pair in [(_voice, _voiceTarget), (_tts, _ttsTarget)]) {
      final n = pair.$1;
      final next = n.value + (pair.$2 - n.value) * 0.12;
      if ((next - n.value).abs() > 0.001) n.value = next;
    }
  }

  @override
  void dispose() {
    widget.ttsSpeaking.removeListener(_retarget);
    widget.voiceLevel.removeListener(_retarget);
    _bars.removeListener(_tick);
    for (final c in _all) {
      c.dispose();
    }
    _voice.dispose();
    _tts.dispose();
    _swell.dispose();
    _presence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: AppStrings.t(
        widget.on ? 'call_translation_cut' : 'call_translation_resume',
      ),
      button: true,
      toggled: widget.on,
      child: Pressable(
        bounce: true,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: SizedBox(
          width: TranslationOrb.box,
          height: TranslationOrb.box,
          child: widget.on ? _live() : _dormant(),
        ),
      ),
    );
  }

  /// La pierre endormie ne s'efface JAMAIS, elle. Rien ne la ferait revenir :
  /// la traduction coupée, il n'y a plus ni voix ni lecture pour la rallumer,
  /// et un galet à 0,22 qu'on ne peut plus réveiller serait un bouton perdu.
  Widget _live() {
    return AnimatedBuilder(
      animation: Listenable.merge([..._all, _voice, _tts, _swell, _presence]),
      builder: (context, _) => Opacity(
        // PAS quand un panneau est ouvert : le galet y sert d'en-tête, il doit
        // être franc même si personne ne parle. [ripples] vaut faux dans ce
        // cas-là et nulle part ailleurs.
        opacity: widget.ripples ? _presence.value : 1.0,
        child: Transform.scale(
        // Une transformation, pas une taille qui change : la boîte garde ses
        // dimensions, donc rien autour ne bouge quand le galet respire.
        scale: _swell.value,
        // RepaintBoundary : le galet s'anime en continu, il ne doit pas
        // entraîner le repaint de la vidéo autour.
        child: RepaintBoundary(
        child: CustomPaint(
        painter: _OrbPainter(
          spin: _spin.value,
          spec: _spec.value,
          // Les courbes du CSS : `ease-out` sur les ondes, `ease-in-out` sur
          // la lévitation et la respiration. Un contrôleur rend une rampe
          // droite — sans ça, l'onde part trop lentement et la lévitation
          // rebondit sèchement en haut et en bas.
          // Plus d'ondes : ni pendant la traduction vocale, ni jamais (chauffe).
          ripple: 0,
          bars: _bars.value,
          float: Curves.easeInOut.transform(_float.value),
          breathe: Curves.easeInOut.transform(_breathe.value),
          amp: _voice.value,
          waveAmp: 0,
          // Le painter sait déjà se taire : poser une icône au centre à la
          // place des barres — la « pierre réduite » de la maquette — ne
          // demandera que de passer false ici et un Icon en enfant.
          showBars: true,
        ),
        ),
        ),
        ),
      ),
    );
  }

  /// La pierre endormie : du verre dépoli, un bord pointillé, un triangle de
  /// lecture. Le flou vient d'un [BackdropFilter] et pas du painter — un
  /// painter ne peut pas flouter ce qu'il y a DERRIÈRE lui.
  Widget _dormant() {
    return Center(
      child: SizedBox(
        width: TranslationOrb.kSize * TranslationOrb.dormantRatio,
        height: TranslationOrb.kSize * TranslationOrb.dormantRatio,
        child: ClipOval(
          child: _Frost(
            child: CustomPaint(
              painter: const _DormantOrbPainter(),
              child: Center(
                child: Icon(
                  Icons.play_arrow_rounded,
                  size: TranslationOrb.kSize *
                      TranslationOrb.dormantRatio *
                      TranslationOrb.dormantIconRatio,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Le bord pointillé de la pierre endormie. Flutter n'a pas de style pointillé
/// sur un cercle : on pose les tirets à la main.
class _DormantOrbPainter extends CustomPainter {
  const _DormantOrbPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    canvas.drawCircle(
      c,
      r,
      Paint()..color = Colors.white.withValues(alpha: 0.10),
    );
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.34);
    // Des tirets d'environ 6 px séparés de 5 : assez serrés pour lire un
    // cercle, assez espacés pour lire « en pause ».
    const dash = 6.0, gap = 5.0;
    final circumference = 2 * math.pi * (r - 0.5);
    final count = (circumference / (dash + gap)).floor();
    if (count <= 0) return;
    final step = 2 * math.pi / count;
    final arc = step * dash / (dash + gap);
    for (var i = 0; i < count; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r - 0.5),
        i * step,
        arc,
        false,
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_DormantOrbPainter old) => false;
}

/// Le galet vivant, peint du fond vers l'avant.
class _OrbPainter extends CustomPainter {
  const _OrbPainter({
    required this.spin,
    required this.spec,
    required this.ripple,
    required this.bars,
    required this.float,
    required this.breathe,
    required this.amp,
    required this.waveAmp,
    required this.showBars,
  });

  /// Chacune de 0 à 1 : la phase de son propre mouvement.
  final double spin;
  final double spec;
  final double ripple;
  final double bars;
  final double float;
  final double breathe;

  /// L'amplitude des barres : elle monte quand quelqu'un parle.
  final double amp;

  /// Celle des ondes : elle monte quand la traduction est dite.
  final double waveAmp;

  /// Faux quand une icône occupe le centre à leur place.
  final bool showBars;

  /// Les sept teintes de l'anneau. La dernière reprend la première : c'est ce
  /// qui permet à la roue de boucler sans couture.
  static const List<Color> _ring = [
    Color(0xFFFF0080),
    Color(0xFFFF8C00),
    Color(0xFFFFEF00),
    Color(0xFF00FF87),
    Color(0xFF00BFFF),
    Color(0xFF7C3AED),
    Color(0xFFFF0080),
  ];

  static const Color _violet = Color(0xFF7C3AED);
  static const Color _teal = Color(0xFF00FF87);
  static const Color _blue = Color(0xFF00BFFF);

  @override
  void paint(Canvas canvas, Size size) {
    // La toile fait [boxFactor] fois le galet : la marge est là pour le halo et
    // les ondes. Le galet, lui, se dessine au CENTRE, à sa taille propre.
    // k rapporte les cotes, toutes données pour un galet de 130, à la taille
    // réelle ; r est le rayon du galet dans la toile élargie.
    final k = size.width / (TranslationOrb.boxFactor * 130);
    final r = 130 * k / 2;

    // Le flottement : tout le galet monte de 13 px et redescend.
    final c = Offset(size.width / 2, size.height / 2 - 13 * k * float);

    // 1. Les deux ondes. La seconde est décalée d'une demi-période — d'où le
    //    modulo : une seule horloge sert aux deux.
    // Quatre ondes plutôt que deux, décalées d'un quart de tour chacune : il en
    // part une deux fois plus souvent, et il y en a toujours deux ou trois en
    // vol. Deux seulement laissaient un trou entre chaque départ, et une
    // traduction longue avait l'air de s'essouffler.
    //
    // Les couleurs alternent, comme les deux d'origine.
    for (var i = 0; i < 4; i++) {
      _wave(
        canvas,
        c,
        r,
        (ripple + i * 0.25) % 1.0,
        i.isEven ? _violet : _teal,
        (i.isEven ? 0.5 : 0.45) * waveAmp,
      );
    }

    // 2. Le halo qui respire, débordant de 18 px.
    final grow = 0.97 + 0.06 * breathe;
    final haloR = (r + 18 * k) * grow;
    final haloFade = 0.5 + 0.5 * breathe;
    canvas.drawCircle(
      c,
      haloR,
      Paint()
        ..shader = ui.Gradient.radial(c, haloR, [
          _violet.withValues(alpha: 0.42 * haloFade),
          _teal.withValues(alpha: 0.16 * haloFade),
          _teal.withValues(alpha: 0.0),
        ], [
          0.0,
          0.56,
          0.74,
        ])
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 11 * k),
    );

    // 3. L'anneau irisé qui tourne, flouté : c'est lui qui donne la couleur.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = SweepGradient(
          colors: _ring,
          transform: GradientRotation(spin * 2 * math.pi),
        ).createShader(Rect.fromCircle(center: c, radius: r))
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 9 * k),
    );

    // 4. La bille de verre, rentrée de 9 px. Sa lumière vient d'en haut à
    //    gauche — c'est ce point de fuite qui la fait lire comme une sphère et
    //    non comme un disque.
    final gr = r - 9 * k;
    final light = Offset(c.dx - gr * 0.32, c.dy - gr * 0.48);
    canvas.drawCircle(
      c,
      gr,
      Paint()
        ..shader = ui.Gradient.radial(light, gr * 1.5, [
          Colors.white.withValues(alpha: 0.95),
          Colors.white.withValues(alpha: 0.30),
          Colors.white.withValues(alpha: 0.05),
          Colors.white.withValues(alpha: 0.13),
        ], [
          0.0,
          0.26,
          0.54,
          1.0,
        ]),
    );

    // 5. Les deux ombres portées INTÉRIEURES de la maquette :
    //
    //      inset 0   2px 22px rgba(255,255,255,0.55)
    //      inset 0 -14px 32px rgba(122,162,255,0.35)
    //
    //    Une ombre intérieure suit le BORD de la forme, décalé et flouté — pas
    //    un disque posé au milieu. Je les avais faites en gros disques flous
    //    décalés vers le haut et vers le bas : ça donnait une tache dont la
    //    courbure se lisait comme un cercle en travers de la bille, au lieu
    //    d'une lumière accrochée au pourtour.
    //
    //    Un trait épais et flou le long du bord, décalé du même offset, rend
    //    ce que fait le navigateur : le rognage à la bille supprime la moitié
    //    extérieure du trait, il ne reste que la lueur intérieure, plus forte
    //    du côté d'où vient le décalage.
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: gr)));
    canvas.drawCircle(
      c.translate(0, 2 * k),
      gr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 22 * k
        ..color = Colors.white.withValues(alpha: 0.55)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 11 * k),
    );
    canvas.drawCircle(
      c.translate(0, -14 * k),
      gr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 32 * k
        ..color = _blue.withValues(alpha: 0.35)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 16 * k),
    );
    canvas.restore();

    // 6. Le reflet qui tourne : un arc clair sur le pourtour de la bille.
    //
    //    Son bord INTÉRIEUR est fondu, pas coupé. La maquette le masque par un
    //    dégradé qui passe de transparent à opaque entre 68 % et 72 % du rayon
    //    — quatre pour cent de transition. Un trait net à la place dessinait un
    //    cercle blanc parfaitement lisible à l'intérieur de la bille, là où il
    //    ne devrait y avoir qu'une lumière qui s'éteint.
    //
    //    Le flou adoucit les deux bords ; le rognage à la bille rend au bord
    //    extérieur la netteté qu'il doit garder — il se confond avec le bord du
    //    verre, donc il ne se lit pas comme un trait.
    final ringR = gr * 0.85;
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: gr)));
    canvas.drawCircle(
      c,
      ringR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = gr * 0.34
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, gr * 0.09)
        ..shader = SweepGradient(
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0.7),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.5, 1.0],
          transform: GradientRotation(
            spec * 2 * math.pi + 210 * math.pi / 180,
          ),
        ).createShader(Rect.fromCircle(center: c, radius: ringR)),
    );
    canvas.restore();

    // 7. Les quatre barres. Chacune part avec un retard propre — c'est ce
    //    décalage qui fait une vague plutôt qu'un clignotement à l'unisson.
    if (!showBars) return;
    const heights = [12.0, 22.0, 30.0, 18.0];
    const delays = [0.0, 0.12, 0.24, 0.36];
    final barW = 3.5 * k;
    final gap = 4 * k;
    final totalW = barW * 4 + gap * 3;
    var x = c.dx - totalW / 2 + barW / 2;
    final white = Paint()..color = Colors.white.withValues(alpha: 0.95);
    for (var i = 0; i < 4; i++) {
      final phase = (bars - delays[i]) % 1.0;
      // Un aller-retour sur le cycle : 0,35 → 1 → 0,35.
      final swing = 0.35 + 0.65 * (1 - (2 * phase - 1).abs());
      // Une hauteur de repos FIXE, plus une part qui suit la voix. Multiplier
      // la hauteur entière par l'amplitude faisait disparaître les barres dans
      // le silence ; ici elles restent posées et cessent seulement de bouger.
      final h = heights[i] * k * (0.4 + 0.6 * swing * amp);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x, c.dy), width: barW, height: h),
          Radius.circular(2 * k),
        ),
        white,
      );
      x += barW + gap;
    }
  }

  /// Une onde : un cercle fin qui s'élargit jusqu'à 2,4 fois le galet en
  /// s'effaçant.
  void _wave(
    Canvas canvas,
    Offset c,
    double r,
    double t,
    Color color,
    double from,
  ) {
    canvas.drawCircle(
      c,
      r * (1 + 1.4 * t),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: from * (1 - t)),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.spin != spin ||
      old.spec != spec ||
      old.ripple != ripple ||
      old.bars != bars ||
      old.float != float ||
      old.breathe != breathe ||
      old.amp != amp ||
      old.waveAmp != waveAmp ||
      old.showBars != showBars;
}

/// Les deux langues de l'appel dans un seul panneau : « Langue que je parle »
/// à gauche, « Langue que j'entends » à droite, séparées par la flèche à deux
/// têtes qui dit que l'une va vers l'autre.
///
/// Une seule question par colonne, un seul drapeau affiché : on fait défiler la
/// roue jusqu'à celui qu'on veut. Rien n'est appliqué tant qu'on n'a pas
/// enregistré — chaque cran de la roue relancerait sinon le recogniser, ou
/// annoncerait une langue au pair, pour rien.
class _LanguagePairSheet extends StatelessWidget {
  const _LanguagePairSheet({
    required this.spokenCode,
    required this.heardCode,
    required this.onChanged,
  });

  final String spokenCode;
  final String heardCode;

  /// Base language codes the device can actually speak (from flutter_tts
  /// `getLanguages`). Both wheels only list these so the user cannot pick a
  /// language with no OS voice.

  /// Appelé à chaque cran des roues. Rien n'est appliqué ici : c'est l'écran
  /// d'appel qui le fera quand le panneau se refermera.
  final void Function(String spoken, String heard) onChanged;

  @override
  Widget build(BuildContext context) {
    // Ni flou ni galet ici : les deux appartiennent à l'écran d'appel, qui
    // floute sa vidéo SOUS le galet et le fait remonter. Un panneau qui
    // portait son propre galet en dessinait forcément un second, avec ses
    // propres tickers et un état à tenir d'accord avec le premier.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetHandle(),
            _LanguageWheels(
              spokenCode: spokenCode,
              heardCode: heardCode,
              onChanged: onChanged,
            ),
            const SizedBox(height: 18),
            // Le panneau s'appliquait déjà en se refermant, quel qu'ait été le
            // geste. Ce bouton ne fait donc que refermer — mais il dit qu'on a
            // fini, ce qu'un panneau qu'on fait glisser ne dit jamais vraiment.
            SizedBox(
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(AppStrings.t('save')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// La poignée de tous les panneaux d'appel.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 18),
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// Les deux langues de l'appel : « Moi » à gauche, « Traduction » à droite,
/// séparées par la flèche à deux têtes qui dit que l'une va vers l'autre.
///
/// Une seule question par colonne, un seul drapeau affiché : on fait défiler la
/// roue jusqu'à celui qu'on veut. Rien n'est appliqué en direct — chaque cran
/// relancerait sinon le recogniser, ou annoncerait une langue au pair, pour des
/// drapeaux qu'on ne fait que survoler.
///
/// Les deux roues listent LES TROIS langues de l'app, toujours les mêmes.
class _LanguageWheels extends StatefulWidget {
  const _LanguageWheels({
    required this.spokenCode,
    required this.heardCode,
    required this.onChanged,
    this.compact = false,
  });

  final String spokenCode;
  final String heardCode;
  final void Function(String spoken, String heard) onChanged;

  /// Serré : les deux roues partagent le panneau avec les réglages de son.
  final bool compact;

  @override
  State<_LanguageWheels> createState() => _LanguageWheelsState();
}

class _LanguageWheelsState extends State<_LanguageWheels> {
  /// Le catalogue de l'app, tel quel : français, anglais, japonais.
  ///
  /// Les roues croisaient ça avec les voix TTS de l'appareil, pour ne pas
  /// laisser choisir une langue que flutter_tts ne saurait pas prononcer. En
  /// pratique ce croisement ne pouvait que RETIRER : un navigateur sans voix
  /// japonaise faisait disparaître le japonais des deux roues, et l'app n'avait
  /// plus que deux langues à offrir — sur un produit qui en annonce trois, ça
  /// se lit comme une panne, pas comme une précaution.
  ///
  /// Ce qui manque quand la voix manque, c'est la VOIX : la traduction, elle,
  /// se fait dans le nuage et arrive écrite quoi qu'il arrive. Une phrase lue
  /// avec un accent qui n'est pas le bon vaut mieux qu'une langue absente du
  /// menu sans une ligne d'explication.
  late final List<AppLanguage> _langs = callLanguages;
  late int _spoken = _indexOf(_langs, widget.spokenCode);
  late int _heard = _indexOf(_langs, widget.heardCode);

  void _report() => widget.onChanged(
        _langs[_spoken].code,
        _langs[_heard].code,
      );

  /// Une langue hors catalogue (ou vide) retombe sur la première : la roue doit
  /// toujours montrer quelque chose.
  static int _indexOf(List<AppLanguage> langs, String code) {
    // Le portugais a deux lignes régionales (pt-PT, pt-BR) : un `pt` nu prend
    // celle de l'interface active.
    final wanted = callLanguageCode(code).toLowerCase();
    var i = langs.indexWhere((l) => l.code.toLowerCase() == wanted);
    if (i < 0) {
      final base = code.split(RegExp(r'[-_]')).first.toLowerCase();
      i = langs.indexWhere((l) => l.code.toLowerCase() == base);
    }
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _FlagWheel(
            title: AppStrings.t('call_lang_me'),
            icon: Icons.mic_rounded,
            languages: _langs,
            index: _spoken,
            compact: widget.compact,
            onChanged: (i) {
              setState(() => _spoken = i);
              _report();
            },
          ),
        ),
        // La flèche à deux têtes : ce qui se dit d'un côté ressort de l'autre.
        // Posée à la hauteur des roues, pas des titres.
        Padding(
          padding: const EdgeInsets.only(top: 58),
          child: Icon(
            Icons.swap_horiz_rounded,
            size: widget.compact ? 16 : 22,
            color: Colors.white.withValues(alpha: 0.55),
          ),
        ),
        Expanded(
          child: _FlagWheel(
            title: AppStrings.t('call_lang_translation'),
            icon: Icons.hearing_rounded,
            languages: _langs,
            index: _heard,
            compact: widget.compact,
            onChanged: (i) {
              setState(() => _heard = i);
              _report();
            },
          ),
        ),
      ],
    );
  }
}

/// Une roue de drapeaux : sa question au-dessus, un drapeau dans la fenêtre, le
/// nom de la langue en dessous. Les voisins restent visibles du coin de l'œil,
/// couchés par la perspective — c'est ce qui donne envie de faire défiler.
class _FlagWheel extends StatefulWidget {
  const _FlagWheel({
    required this.title,
    required this.icon,
    required this.languages,
    required this.index,
    required this.onChanged,
    this.compact = false,
  });

  final String title;

  /// Ce que fait cette colonne : ma voix qui entre, la traduction qui sort.
  final IconData icon;

  /// Langues proposées dans cette roue (déjà filtrées voix OS si besoin).
  final List<AppLanguage> languages;
  final int index;
  final ValueChanged<int> onChanged;

  /// Serré : la roue partage la largeur avec les réglages de son.
  final bool compact;

  @override
  State<_FlagWheel> createState() => _FlagWheelState();
}

class _FlagWheelState extends State<_FlagWheel> {
  late final FixedExtentScrollController _ctrl =
      FixedExtentScrollController(initialItem: widget.index);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final langs = widget.languages;
    final safeIndex = widget.index.clamp(0, langs.isEmpty ? 0 : langs.length - 1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(widget.icon, size: 13, color: SC.dTextMuted),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                widget.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: TextStyle(
                  color: SC.dTextMuted,
                  fontSize: 12,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          height: widget.compact ? 70 : 84,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: ListWheelScrollView.useDelegate(
            controller: _ctrl,
            itemExtent: widget.compact ? 46 : 56,
            diameterRatio: 1.1,
            perspective: 0.006,
            physics: const FixedExtentScrollPhysics(),
            onSelectedItemChanged: widget.onChanged,
            childDelegate: ListWheelChildBuilderDelegate(
              childCount: langs.length,
              // Sur le téléphone, l'emoji drapeau du système : c'est celui que
              // l'utilisateur voit partout ailleurs sur son appareil. Le web n'a
              // pas ce luxe — sous Windows le glyphe n'existe pas et Chrome
              // écrirait «FR» — alors là, on dessine le SVG rond.
              builder: (ctx, i) => Center(
                child: kIsWeb
                    ? CountryFlag.fromCountryCode(
                        langs[i].countryCode,
                        theme: ImageTheme(
                          width: widget.compact ? 32 : 40,
                          height: widget.compact ? 32 : 40,
                          shape: const Circle(),
                        ),
                      )
                    : Text(
                        langs[i].flag,
                        style: TextStyle(fontSize: widget.compact ? 30 : 38),
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          langs.isEmpty ? '' : langs[safeIndex].label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: SC.dTextPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// In-call audio panel — just the sliders: mic level, translation volume and
/// original-voice volume. (The ducking toggle + speaker/earpiece route were
/// dropped on request.)
class _AudioSettingsSheet extends StatefulWidget {
  const _AudioSettingsSheet({
    required this.controller,
    required this.translationOn,
    required this.onToggleTranslation,
  });

  final AudioController controller;

  /// La traduction tourne à l'ouverture du panneau (interrupteur coché). Le
  /// galet n'est plus cliquable : couper / reprendre la traduction se fait ici.
  final bool translationOn;
  final VoidCallback onToggleTranslation;

  @override
  State<_AudioSettingsSheet> createState() => _AudioSettingsSheetState();
}

class _AudioSettingsSheetState extends State<_AudioSettingsSheet> {
  late bool _on = widget.translationOn;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetHandle(),
            _AudioControls(controller: widget.controller),
            const SizedBox(height: 6),
            // Couper la traduction : l'interrupteur est coché tant qu'elle
            // tourne ; le décocher la coupe (et le recocher la reprend).
            Row(
              children: [
                Expanded(
                  child: _SheetLabel(
                    icon: Icons.translate_rounded,
                    text: AppStrings.t('call_lang_translation'),
                  ),
                ),
                Switch(
                  value: _on,
                  activeThumbColor: Colors.black,
                  activeTrackColor: SC.accent,
                  onChanged: (v) {
                    setState(() => _on = v);
                    widget.onToggleTranslation();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Les deux volumes de l'appel : la vraie voix d'abord, sa traduction ensuite —
/// l'ordre dans lequel les deux arrivent à l'oreille. Le réglage s'entend
/// pendant qu'on le bouge ; rien à valider.
class _AudioControls extends StatelessWidget {
  const _AudioControls({required this.controller});

  final AudioController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SheetLabel(
              icon: Icons.mic_rounded,
              text: AppStrings.t('call_original_volume'),
            ),
            Slider(
              value: controller.originalVolume.clamp(0.0, 1.0).toDouble(),
              onChanged: controller.setOriginalVolume,
              activeColor: SC.accent,
              inactiveColor: Colors.white24,
            ),
            const SizedBox(height: 6),
            _SheetLabel(
              icon: Icons.hearing_rounded,
              text: AppStrings.t('call_translation_volume'),
            ),
            Slider(
              value: controller.translatedVolume.clamp(0.0, 1.0).toDouble(),
              onChanged: controller.setTranslatedVolume,
              activeColor: SC.accent,
              inactiveColor: Colors.white24,
            ),
          ],
        );
      },
    );
  }
}

/// Le libellé d'un réglage : son icône, puis son nom.
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
          Icon(icon, size: 18, color: SC.dTextMuted),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: SC.dTextPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraOffTile extends StatelessWidget {
  const _CameraOffTile({
    this.label,
    this.compact = false,
    this.muted = false,
    this.shift = 0,
  });

  final String? label;
  final bool compact;

  /// Décalage vertical (dp, négatif = vers le haut) du groupe icône + prénom
  /// quand le bas de l'écran se remplit (v4). Animé : le fond noir, lui, ne
  /// bouge pas.
  final double shift;

  /// This participant's mic is off. Both sides render it — a peer's mute
  /// arrives as a LiveKit `TrackMutedEvent`, our own from `_micOn` — so each
  /// caller can see who has gone silent.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final fontSize = compact ? 13.0 : 24.0;
    final iconSize = compact ? 28.0 : 56.0;
    final hasLabel = label != null && label!.isNotEmpty;
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: shift),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        builder: (_, dy, child) =>
            Transform.translate(offset: Offset(0, dy), child: child),
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (muted) ...[
                    Icon(
                      Icons.mic_off_rounded,
                      size: fontSize + 2,
                      color: const Color(0xFFFF3B30),
                    ),
                    SizedBox(width: compact ? 4 : 6),
                  ],
                  Flexible(
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
              ),
            ),
          ],
        ],
      ),
      ),
    );
  }
}
