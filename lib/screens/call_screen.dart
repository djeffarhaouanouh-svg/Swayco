import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:audioplayers/audioplayers.dart';
import 'package:country_flags/country_flags.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show RealtimeChannel, Supabase;

import '../services/analytics.dart';
import '../services/app_strings.dart';
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
import '../services/translation_api.dart';
import '../services/user_prefs.dart';
import '../theme/swayco_theme.dart';
import '../swayco/realtime_translation_port.dart';
import '../swayco/translation_route.dart';
import '../widgets/glass_panel.dart';
import '../widgets/pressable.dart';
import '../widgets/profile_avatar.dart';

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
  Duration? _finalDuration;

  /// Wraps the shareable part of the summary card so it can be captured to a
  /// PNG and shared ("partager la page").
  final GlobalKey _shareCardKey = GlobalKey();
  /// The blue control rail is folded away behind the chevron until the user
  /// asks for it — the video stays clean. Hang up is never hidden.
  bool _controlsOpen = false;
  /// Ce qui est DIT, transcrit — chaque device dans sa langue. Les lignes ne
  /// vivent que le temps de l'appel (rien n'est persisté).
  final List<_SpokenTurn> _turns = [];

  /// La zone est dépliée : les deux derniers tours et la saisie, tout le reste
  /// de l'appel s'efface le temps qu'elle est là.
  bool _turnsOpen = false;

  /// La saisie de la conversation. Ce qui est tapé part comme une phrase dite :
  /// traduit chez le pair, écrit et lu à voix haute. Rien n'est persisté, ça ne
  /// vit que le temps de l'appel.
  final TextEditingController _chatCtrl = TextEditingController();
  final FocusNode _chatFocus = FocusNode();
  bool _chatSending = false;

  /// Les phrases au repos sont retirées parce que le temps a passé. La
  /// prochaine phrase les ramène — [_addTurn] remet ça à faux.
  bool _turnsHidden = false;

  /// Les phrases au repos ont été retirées À LA MAIN, et elles restent parties.
  ///
  /// Le silence et le doigt ne disent pas la même chose. Personne n'a parlé
  /// depuis dix secondes : le sous-titre n'a plus rien à montrer, la phrase
  /// suivante le rappelle et c'est bien. Mais quelqu'un qui TOUCHE pour s'en
  /// débarrasser en pleine conversation dit « je ne veux plus de ça » — et lui
  /// remettre une bulle à chaque phrase, alors que l'autre est justement en
  /// train de parler, c'est refuser de l'entendre.
  ///
  /// Ça ne se lève qu'à la touche Messages : redemander la conversation, c'est
  /// le seul geste qui dise le contraire du premier.
  bool _turnsMuted = false;

  /// Ce que les phrases au repos restent à l'écran quand plus rien n'arrive.
  ///
  /// Un sous-titre s'efface : posé pour toujours sur un appel vidéo, il ne se
  /// referme jamais et finit par recouvrir le visage qu'on est venu voir. Dix
  /// secondes, c'est le temps de relire la dernière phrase et pas plus — le
  /// fil complet est à un tap, il n'est jamais perdu.
  static const Duration _kRestTtl = Duration(seconds: 10);
  Timer? _restTimer;

  /// Le temps a passé : on retire, et la phrase suivante ramènera tout.
  void _hideTurns() {
    _restTimer?.cancel();
    if (_turnsHidden || !mounted) return;
    setState(() => _turnsHidden = true);
  }

  /// Un doigt les a retirées : elles ne reviennent plus d'elles-mêmes.
  void _muteTurns() {
    _restTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _turnsHidden = true;
      _turnsMuted = true;
    });
  }

  /// Referme la conversation ET le clavier, et emporte les phrases au repos
  /// avec. Les trois vont ensemble : un tap qui ne ferme que le panneau laisse
  /// les bulles derrière, et l'écran a l'air de ne jamais se rendre — c'est
  /// exactement ce qu'on reprochait à la version d'avant.
  ///
  /// Et c'est un geste, donc ça fait taire pour de bon : refermer le panneau
  /// puis se voir rendre une bulle à la phrase suivante, c'est ne pas avoir été
  /// écouté.
  void _closeTurns() {
    _chatFocus.unfocus();
    _restTimer?.cancel();
    if (!mounted) return;
    if (!_turnsOpen && _turnsMuted) return;
    setState(() {
      _turnsOpen = false;
      _turnsHidden = true;
      _turnsMuted = true;
    });
  }

  /// Un panneau est ouvert par-dessus l'appel (langues, son, réglages).
  ///
  /// Ce n'est pas une affaire de panneau des langues : le galet doit remonter
  /// et la vidéo se flouter pour N'IMPORTE lequel, sinon chaque panneau se
  /// comporte à sa façon — l'un recouvrait le galet, l'autre le remplaçait par
  /// un second.
  bool _sheetOpen = false;

  /// Ouvre [body] par-dessus l'appel en faisant remonter le galet et flouter la
  /// vidéo, et remet tout en place à la fermeture — quelle qu'en soit la
  /// manière, y compris un balayage.
  Future<void> _showCallSheet(WidgetBuilder body) {
    setState(() => _sheetOpen = true);
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: SC.bg,
      // Pas de voile : c'est l'écran d'appel qui floute, sous le galet. Un
      // voile par-dessus le flouterait lui aussi.
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
        // Et le rail avec : c'est lui qui a ouvert ce panneau, le laisser
        // déplié obligeait à un second geste pour revenir à l'appel.
        _controlsOpen = false;
        _turnsOpen = false;
      });
    });
  }

  /// Plus personne ne parle : le dock s'efface presque entièrement et il ne
  /// reste que la pastille, comme la pilule de Gemini qui se replie en pastille.
  /// Un tap n'importe où dessus le ramène.
  bool _dockDimmed = false;
  Timer? _dockIdleTimer;

  /// Le silence au bout duquel le dock disparaît.
  static const Duration _kDockIdle = Duration(seconds: 2);

  /// Quelque chose vient de se passer (une voix, une phrase, un tap) : le dock
  /// se rallume et repart pour [_kDockIdle] de sursis.
  void _wakeDock() {
    _dockIdleTimer?.cancel();
    _dockIdleTimer = Timer(_kDockIdle, () {
      if (!mounted || _dockDimmed) return;
      // On ne s'efface pas sous les doigts de quelqu'un qui s'en sert : le
      // sursis est simplement reconduit, sinon la veille ne reviendrait jamais.
      if (_turnsOpen || _controlsOpen) {
        _wakeDock();
        return;
      }
      setState(() => _dockDimmed = true);
    });
    if (_dockDimmed && mounted) setState(() => _dockDimmed = false);
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
  static const int _kMicProbeGiveUp = 20;

  void _startMicProbe(Room room) {
    _micProbe?.cancel();
    _micProbe = Timer.periodic(const Duration(milliseconds: 250), (_) async {
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
  }

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
    // Et repart pour dix secondes : chaque phrase relance le sursis, une
    // conversation suivie garde donc ses sous-titres, un silence les rend.
    //
    // Sauf si on les a fait taire à la main : ce refus-là vaut pour l'appel, et
    // la phrase suivante n'a pas à revenir dessus.
    if (!_turnsMuted) {
      _turnsHidden = false;
      _restTimer?.cancel();
      _restTimer = Timer(_kRestTtl, _hideTurns);
    }
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
    _addTurn(_SpokenTurn(
      mine: true,
      text: line.text,
      delivered: line.delivered,
    ));
  }

  bool _micOn = true;
  late bool _camOn = widget.startWithCamera;
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
  Future<void> _enqueueSpeak(String text, String lang) {
    final generation = _ttsGeneration;
    final Future<String?>? synth = _premiumReadyFor(lang)
        ? SpeechService.instance.synthesise(text: text, languageCode: lang)
        : null;
    _ttsQueue = _ttsQueue.then((_) async {
      if (!mounted || generation != _ttsGeneration) return;
      await _awaitPeerSilence();
      // Couper la traduction PENDANT l'attente doit la faire tomber : sans ce
      // second contrôle, elle se dirait quand même à la fin du silence.
      if (!mounted || generation != _ttsGeneration) return;
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
    });
    return _ttsQueue;
  }

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

  Future<void> _speakOsVoice(String text, String lang) async {
    final tag = _voiceTagFor(lang);
    DebugOverlay.log('speak lang=$lang (voice $tag) text="$text"');
    markTranslationPlaying(textLength: text.length);
    try {
      if (tag.isNotEmpty && tag != _deviceTtsLang) {
        try {
          await _deviceTts.setLanguage(tag);
          _deviceTtsLang = tag;
        } catch (_) {}
      }
      await _applyTranslatedVolumeToDeviceTts();
      // Mobile Chrome auto-pauses speechSynthesis after a stretch of inactivity;
      // speak() then plays nothing and fires no event.
      resumeSpeechSynthesisIfPaused();
      await _deviceTts.speak(text).timeout(_speakCap(text));
      DebugOverlay.log('speak done');
    } catch (e) {
      DebugOverlay.log('speak FAILED: $e');
    } finally {
      markTranslationDone();
    }
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
        final full = t.toString().trim();
        if (full.isEmpty) continue;
        final base = full.toLowerCase().split(RegExp(r'[-_]')).first;
        if (base.isEmpty) continue;
        (all[base] ??= <String>[]).add(full);
        tags.putIfAbsent(base, () => full);
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
      // La région retenue pour l'anglais est écrite : c'est celle qu'on a vue
      // partir en `en-ZA` sans qu'aucune ligne ne dise pourquoi.
      DebugOverlay.log(
        'device voices: ${tags.length} langs (en=${tags['en'] ?? '—'})',
      );
      setState(() => _deviceVoiceTags = tags);
      return true;
    } catch (e) {
      DebugOverlay.log('device voices: getLanguages failed: $e');
      debugPrint('[speech] getLanguages failed: $e');
      return false;
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
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: SC.menu,
          // Material 3 reteinte toute surface élevée avec la couleur primaire :
          // le gris du menu virait au bleu cyan. On coupe la teinte.
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          icon: const Icon(
            Icons.mic_off_rounded,
            color: Color(0xFFE53935),
            size: 34,
          ),
          content: Text(
            AppStrings.t(key),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: SC.textPrimary,
              fontSize: 15,
              height: 1.45,
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          actions: [
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(AppStrings.t('tip_got_it')),
              ),
            ),
          ],
        ),
      );
    });
  }

  @override
  void initState() {
    super.initState();
    widget.translation.localTranscript?.addListener(_onMyTranscript);
    Analytics.track('screen_view', props: {'screen': 'live'});
    _start();
    // Hold the connecting splash for a minimum of 5s so it is actually
    // readable even when the room connects almost instantly.
    _splashTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _minSplashDone = true);
    });
    unawaited(_loadPeerProfile());
    // Le système peut refuser de transcrire (Siri / Dictée coupés) : sans ce
    // fil, la panne serait totalement muette côté utilisateur.
    AsrService.osRefusedKey.addListener(_onSttRefused);
    _onSttRefused();
    _wireDeviceTtsSignal();
    ttsSpeaking.addListener(_syncTranslationSpeaking);
    unawaited(_loadDeviceVoiceLangs());
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
        // Peer was already here when we joined → no ParticipantConnectedEvent
        // fires for us, so keep re-binding until their language is known.
        unawaited(_rebindUntilRemoteLangKnown(room));
      }
      // La visio démarre sur le haut-parleur (on tient le téléphone devant
      // soi), l'appel normal sur l'écouteur. Un casque branché prime sur les
      // deux, au niveau de l'OS.
      await _audio.bind(room, video: widget.startWithCamera);
      widget.translation.translationListenable?.addListener(_onTranslationStateChanged);
      // Reset the global mic-mute flag — it persists across re-attaches.
      setSendMuted(false);
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
        langFrom: _mySourceLang,
        langTo: _attachedTargetLang,
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
        _addTurn(_SpokenTurn(mine: false, text: trans));
        // Le même interrupteur que pour la voix : couper la traduction, c'est
        // en couper LE SON — la phrase s'écrit toujours.
        if (_translationEnabled) {
          if (kIsWeb) {
            unawaited(_speakDeviceTts(trans, lang));
          } else {
            unawaited(_playWithLocalTts(trans, lang));
          }
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
        _addTurn(_SpokenTurn(mine: false, text: trans));
        // Son coupé : la phrase s'écrit, elle ne se dit pas.
        if (trans.isNotEmpty && _translationEnabled) {
          if (kIsWeb) {
            unawaited(_speakDeviceTts(trans, lang));
          } else {
            unawaited(_playWithLocalTts(trans, lang));
          }
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

  /// Speak [text] with the device's own OS voice (`flutter_tts`).
  ///
  /// The premium on-device voice, when one is loaded for this language; downloaded
  /// per language (~60–110 MB a bundle) and kept in sync with a catalogue. That
  /// whole machinery is gone: the phone already ships dozens of languages, they
  /// need no download, and they start speaking instantly. `ttsSpeaking` is now
  /// driven entirely by flutter_tts's own start/completion handlers.
  ///
  /// flutter_tts's speak() can return without playing (missing voice), so no
  /// completion event is ever guaranteed — the mic gate's own safety timer is
  /// what reopens the mic, never an awaited event.
  Future<void> _playWithLocalTts(String text, String lang) =>
      _enqueueSpeak(text, lang);

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

  Future<void> _speakDeviceTts(String text, String lang) =>
      _enqueueSpeak(text, lang);

  /// Loudspeaker ⇄ earpiece. Calls start on the earpiece (see AudioController's
  /// default): against the ear the loudspeaker cannot reach the mic, so the
  /// feedback loop that makes a call howl has no path to close. A plugged-in
  /// headset still wins over both — `_applySpeaker` refuses to override the OS.
  Future<void> _toggleSpeaker() async {
    await _audio.setSpeakerOn(!_audio.speakerOn);
    if (mounted) setState(() {});
  }

  /// Retourner la caméra, avant / arrière.
  ///
  /// LiveKit expose l'échange sur la piste elle-même, pas sur le participant :
  /// on va chercher la piste vidéo locale publiée et on lui demande de
  /// basculer. Sans piste — caméra coupée, ou pas encore publiée — il n'y a
  /// rien à retourner et on ne fait rien plutôt que de lever.
  Future<void> _flipCamera() async {
    final room = _room;
    if (room == null) return;
    final track = _localVideo(room);
    if (track is! LocalVideoTrack) return;
    try {
      await track.setCameraPosition(
        track.currentOptions is CameraCaptureOptions &&
                (track.currentOptions as CameraCaptureOptions).cameraPosition ==
                    CameraPosition.front
            ? CameraPosition.back
            : CameraPosition.front,
      );
    } catch (e) {
      DebugOverlay.log('flip camera failed: $e');
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
    unawaited(_showCallSheet((ctx) => _AudioSettingsSheet(controller: _audio)));
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

  /// Les deux panneaux de l'appel d'un coup — le son à gauche, les langues à
  /// droite. C'est l'appui long sur la pastille qui l'ouvre : le geste rapide
  /// reste réservé à couper la traduction.
  void _openCallSettingsSheet() {
    var spoken = _mySourceLang;
    var heard = _myOutputLang;
    unawaited(_showCallSheet(
      (ctx) => _CallSettingsSheet(
        controller: _audio,
        spokenCode: _mySourceLang,
        heardCode: _myOutputLang,
        onLanguagesChanged: (sp, hd) {
          spoken = sp;
          heard = hd;
        },
      ),
    ).whenComplete(() {
      if (!mounted) return;
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

  /// Black "call ended" card: the peer's PDP + flag, the minutes spent, a
  /// share button bottom-right and the swayco logo dead-centre at the bottom.
  Widget _buildEndedSummary(BuildContext context) {
    final profile = _peerProfile;
    final name = (profile?.displayName.trim().isNotEmpty ?? false)
        ? profile!.displayName.trim()
        : AppStrings.t('profile_anonymous');
    final firstName = name.split(RegExp(r'\s+')).first;
    final lang = profile?.language.trim() ?? '';
    // Country flag once the peer has set a location (the spoken language
    // doesn't always match the country); language flag otherwise.
    final flagEmoji = ((profile?.city.trim().isNotEmpty ?? false)
            ? countryFlagFor(profile?.country ?? '')
            : null) ??
        (lang.isEmpty ? null : findLanguageByCode(lang)?.flag) ??
        '';
    final dur = _finalDuration ?? Duration.zero;

    return Scaffold(
      backgroundColor: SC.bg,
      body: SafeArea(
        child: Stack(
          children: [
            // The shareable card (everything captured into the PNG).
            Positioned.fill(
              child: RepaintBoundary(
                key: _shareCardKey,
                child: Container(
                  color: SC.bg,
                  child: Stack(
                    children: [
                      // Brand wordmark — top-centre, like the in-call screen.
                      const Positioned(
                        top: 12,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: 'swayc'),
                                TextSpan(
                                  text: 'ø',
                                  style: TextStyle(color: SC.accent),
                                ),
                              ],
                            ),
                            style: TextStyle(
                              color: Colors.white,
                              fontFamily: SC.brandFont,
                              fontSize: 29,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                              shadows: [
                                Shadow(color: Colors.black54, blurRadius: 8),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // Peer PDP + first name + call duration, grouped in the
                      // upper area (the duration sits right under the name and
                      // is the biggest figure on the card).
                      Align(
                        alignment: const Alignment(0, -0.42),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ProfileAvatar(
                              displayName: name,
                              avatarUrl: profile?.avatarUrl,
                              size: 132,
                            ),
                            const SizedBox(height: 20),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
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
                                  if (flagEmoji.isNotEmpty) ...[
                                    const SizedBox(width: 12),
                                    Text(flagEmoji,
                                        style: const TextStyle(fontSize: 30)),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 26),
                            // Call duration — enlarged, just under the name.
                            const Icon(Icons.schedule_rounded,
                                color: SC.accent, size: 30),
                            const SizedBox(height: 8),
                            Text(
                              _formatCallDuration(dur),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 34,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Close — top-left, kept OUT of the captured card.
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                // 32 : c'est la seule sortie de cette page, et elle est posée
                // dans un coin sur du noir, sans rien autour pour la désigner.
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 32),
                onPressed: () => Navigator.of(context).pop(),
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
        backgroundColor: SC.menu,
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
    widget.translation.localTranscript?.removeListener(_onMyTranscript);
    AsrService.osRefusedKey.removeListener(_onSttRefused);
    _chatCtrl.dispose();
    _chatFocus.dispose();
    _restTimer?.cancel();
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
    }
    widget.translation.translationListenable?.removeListener(_onTranslationStateChanged);
    _audio.dispose();
    unawaited(_ttsPlayer.dispose());
    _cancelQueuedSpeech();
    ttsSpeaking.removeListener(_syncTranslationSpeaking);
    ttsSpeaking.dispose();
    _voiceLevel.dispose();
    _dockIdleTimer?.cancel();
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
      return Scaffold(
        backgroundColor: SC.bg,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
            child: Column(
              children: [
                // Logo, then the spinner + hint kept close just beneath it
                // (centred together as a tight group, not spread apart).
                const Spacer(flex: 5),
                // Same provider CallSplashImage warmed at boot, so this
                // paints on the splash's very first frame instead of a
                // beat later. 278 rather than 210: the mark only fills
                // 59% of its own canvas, so at 210 it would render a
                // third smaller than the logo it replaces.
                const Image(
                  image: CallSplashImage.provider,
                  width: 278,
                  height: 278,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 22),
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
                  AppStrings.t('call_connecting_tip'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: SC.textMuted,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const Spacer(flex: 6),
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
          systemNavigationBarColor: SC.bg,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: SC.bg,
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
                      mirrorMode: VideoViewMirrorMode.mirror,
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
                    color: SC.menu,
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
                                mirrorMode: VideoViewMirrorMode.mirror,
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
                        Positioned(
                          right: -6,
                          bottom: -6,
                          child: _PipFlipButton(onTap: _flipCamera),
                        ),
                      ],
                    ),
                  ),
                // Conversation dépliée : un tap n'importe où ailleurs la
                // referme. La couche est posée par-dessus la vidéo, donc ce
                // tap-là ne fait QUE fermer — il n'échange pas les deux
                // images au passage.
                if (_turnsOpen)
                  Positioned.fill(
                    key: const ValueKey('turns_dismiss'),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _closeTurns,
                    ),
                  ),
                // Le panneau effacé : l'écran ENTIER le rappelle. C'est ce qui
                // permet de le laisser disparaître complètement — on n'a pas à
                // retrouver une cible, il suffit de toucher n'importe où. Ce
                // premier tap ne fait QUE rallumer : il n'échange pas les deux
                // images au passage.
                if (_dockDimmed && !_turnsOpen)
                  Positioned.fill(
                    key: const ValueKey('dock_wake'),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _wakeDock,
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
                // Le galet, bas dans l'écran mais pas au ras des touches : ses
                // ondes montent jusqu'à 2,4 fois son disque, et si elles
                // atteignaient les réglages dépliés on ne saurait plus ce qui
                // appartient à quoi. 0,68 le pose sous le milieu en laissant
                // cette marge.
                //
                // Posé au-dessus de la couche qui rallume la barre — sinon un
                // tap dessus se contenterait de la réveiller au lieu de couper
                // la traduction.
                // Un panneau s'ouvre : la vidéo se floute SOUS le galet, qui
                // reste net. Le flou appartient à l'écran et pas au panneau —
                // posé dans le panneau, il aurait flouté le galet avec le
                // reste, et il aurait fallu en dessiner un second par-dessus.
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: _sheetOpen ? 22 : 0),
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  builder: (context, blur, _) => blur < 0.4
                      // Rien à flouter : pas de BackdropFilter du tout. À
                      // sigma nul il coûte encore une passe de composition
                      // pendant tout l'appel.
                      ? const SizedBox.shrink()
                      : Positioned.fill(
                          child: IgnorePointer(
                            child: BackdropFilter(
                              filter: ui.ImageFilter.blur(
                                sigmaX: blur,
                                sigmaY: blur,
                              ),
                              child: ColoredBox(
                                color: Colors.black
                                    .withValues(alpha: 0.35 * blur / 22),
                              ),
                            ),
                          ),
                        ),
                ),
                // Le galet REMONTE au-dessus du panneau et rétrécit, il ne
                // disparaît pas pour être remplacé ailleurs. Un seul objet,
                // un seul jeu de tickers, et le trajet se voit.
                LayoutBuilder(
                  builder: (context, box) {
                    // La conversation est un bloc au ras du bas dont on connaît
                    // la hauteur ; le galet se pose JUSTE au-dessus. Calculé
                    // plutôt que réglé à la main : le clavier fait monter la
                    // zone, et une valeur fixe le laisserait dessous.
                    final lift = _SpokenTurnsPanel.zoneHeight +
                        MediaQuery.of(context).viewInsets.bottom +
                        16 + // le rembourrage bas de la colonne
                        46; // la moitié du galet réduit, plus un peu d'air
                    final turnsY = box.maxHeight <= 0
                        ? 0.0
                        : (1 - 2 * lift / box.maxHeight).clamp(-0.9, 0.9);
                    return AnimatedAlign(
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  // Il remonte d'un cran à chaque chose qui s'ouvre, et
                  // redescend tout en bas quand il ne reste que l'appel. Les
                  // cas sont testés du plus haut au plus bas : un panneau
                  // recouvre le rail, qui recouvre la conversation.
                  alignment: _sheetOpen
                      ? const Alignment(0, -0.52)
                      : _turnsOpen
                          ? Alignment(0, turnsY.toDouble())
                          : _controlsOpen
                              ? const Alignment(0, 0.34)
                              // Rien de déplié : ses ondes atteignent les
                              // touches et c'est très bien, elles passent
                              // derrière.
                              : const Alignment(0, 0.80),
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOutCubic,
                    // 56 sur 65 : la même réduction que la maquette, obtenue
                    // par une transformation plutôt qu'en repeignant le galet
                    // à chaque image d'une taille qui change. La conversation
                    // le réduit pareil : sous elle il n'est plus le sujet.
                    scale: (_sheetOpen || _turnsOpen)
                        ? 56 / _TranslationOrb.kSize
                        : 1,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _TranslationOrb(
                          // Sous un panneau, les ondes iraient chercher l'œil
                          // pour rien.
                          ripples: !_sheetOpen,
                          on: _translationEnabled,
                          micOn: _micOn,
                          ttsSpeaking: ttsSpeaking,
                          voiceLevel: _voiceLevel,
                          onTap: _toggleTranslation,
                          onLongPress: _openCallSettingsSheet,
                        ),
                        // Coupée, la traduction le DIT. La pierre éteinte et
                        // son triangle suffisent à qui connaît déjà le galet ;
                        // pour tous les autres, un appel qui cesse de traduire
                        // sans un mot ressemble à une panne.
                        //
                        // Hors du [Pressable] : ce n'est qu'une étiquette, elle
                        // ne doit pas voler le tap destiné à reprendre.
                        if (!_translationEnabled)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              AppStrings.t('call_translation_paused'),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.65),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.4,
                                shadows: const [
                                  Shadow(color: Colors.black, blurRadius: 8),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                    );
                  },
                ),
                // Le dock : une barre de verre posée en bas, qui flotte
                // au-dessus de la vidéo. Ce qui se déplie — conversation et
                // réglages — pousse vers le HAUT, au-dessus d'elle ; la barre,
                // elle, ne bouge jamais.
                Positioned(
                  key: const ValueKey('call_controls'),
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      // Presque rien sur les côtés. C'était 40 — la largeur de
                      // la barre de nav de l'app — du temps où la rangée était
                      // un panneau de verre qu'il fallait cadrer. Sans panneau,
                      // ces 40 ne cadraient plus rien : ils empêchaient
                      // seulement les touches d'atteindre les bords, quel que
                      // soit le rembourrage qu'on mettait à l'intérieur.
                      //
                      // Le clavier pousse la colonne entière vers le haut :
                      // c'est le seul endroit où la saisie peut monter, le
                      // Scaffold ayant [resizeToAvoidBottomInset] à false pour
                      // que la vidéo, elle, ne bouge pas.
                      padding: EdgeInsets.fromLTRB(
                        12,
                        0,
                        12,
                        16 + MediaQuery.of(context).viewInsets.bottom,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // 1. La conversation. Deux états, tous deux rangés À
                          // GAUCHE sur 82 % de la largeur — c'est une marge de
                          // page, pas un panneau centré : le visage reste
                          // visible à côté.
                          //
                          //  • AU REPOS : les derniers tours se posent
                          //    AU-DESSUS DES TOUCHES, sans en-tête ni saisie.
                          //    Une phrase paraît d'elle-même dès qu'elle est
                          //    dite — c'est ce qui fait découvrir qu'il y a une
                          //    conversation — et les touches ne bougent pas.
                          //    Elle s'efface seule au bout de dix secondes, ou
                          //    au premier doigt posé dessus.
                          //  • OUVERTE par la touche Messages : elle prend
                          //    l'écran, la barre s'efface et la saisie apparaît.
                          AnimatedSize(
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.bottomLeft,
                            child: (!_turnsOpen &&
                                    (_turns.isEmpty || _turnsHidden))
                                ? const SizedBox(width: double.infinity)
                                : Align(
                                    alignment: Alignment.centerLeft,
                                    child: FractionallySizedBox(
                                      widthFactor: 0.82,
                                      // Sans ça la boîte se centre dans la
                                      // largeur qu'on lui laisse : elle
                                      // occuperait 82 % au MILIEU de l'écran
                                      // au lieu de se ranger sur le bord.
                                      alignment: Alignment.centerLeft,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 10,
                                        ),
                                        child: _turnsOpen
                                            ? _SpokenTurnsPanel(
                                                turns: _turns,
                                                myName: widget.displayName,
                                                myAvatarUrl: '',
                                                peerName: _peerProfile
                                                        ?.displayName ??
                                                    '',
                                                peerAvatarUrl:
                                                    _peerProfile?.avatarUrl ??
                                                        '',
                                                onToggle: _closeTurns,
                                                chatController: _chatCtrl,
                                                chatFocus: _chatFocus,
                                                sending: _chatSending,
                                                onSend: _sendCaption,
                                              )
                                            : _RestingTurns(
                                                turns: _turns,
                                                myName: widget.displayName,
                                                myAvatarUrl: '',
                                                peerName: _peerProfile
                                                        ?.displayName ??
                                                    '',
                                                peerAvatarUrl:
                                                    _peerProfile?.avatarUrl ??
                                                        '',
                                                // Le tap sur une phrase la
                                                // RETIRE, il n'ouvre pas la
                                                // zone. L'inverse faisait un
                                                // cercle dont on ne sortait
                                                // pas : on touchait la bulle,
                                                // la zone s'ouvrait, on
                                                // touchait ailleurs pour la
                                                // fermer, la bulle revenait —
                                                // et l'écran ne se rendait
                                                // jamais. Ouvrir reste
                                                // l'affaire de la touche
                                                // Messages, et d'elle seule —
                                                // qui est aussi le seul geste
                                                // qui les fait revenir.
                                                onTap: _muteTurns,
                                              ),
                                      ),
                                    ),
                                  ),
                          ),
                          // 2. Les réglages, dépliés par le chevron.
                          AnimatedSize(
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.bottomCenter,
                            child: !_controlsOpen
                                ? const SizedBox(width: double.infinity)
                                : Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      0,
                                      12,
                                      10,
                                    ),
                                    // Étalés, pas groupés au milieu : la même
                                    // règle que la rangée du bas, sinon les
                                    // deux ne se répondent pas.
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceEvenly,
                                      children: [
                                        // La conversation descend ici et le
                                        // haut-parleur monte dans la barre :
                                        // on change de sortie audio en pleine
                                        // phrase, on relit le texte plus
                                        // posément.
                                        _RoundCallButton(
                                          icon: Icons.sms_rounded,
                                          label:
                                              AppStrings.t('messages_title'),
                                          active: _turnsOpen,
                                          // L'anneau cyan : c'est le bouton
                                          // qu'on cherche en ouvrant le rail.
                                          ring: true,
                                          onTap: () {
                                            _wakeDock();
                                            if (_turnsOpen) {
                                              // Referme comme un tap sur
                                              // l'écran : la zone ET les
                                              // bulles au repos, sinon la
                                              // touche rendrait la barre en
                                              // laissant les phrases derrière.
                                              _closeTurns();
                                              return;
                                            }
                                            setState(() {
                                              _turnsOpen = true;
                                              // Les phrases masquées
                                              // reparaissent avec la zone :
                                              // c'est le fil qu'on demande.
                                              // Et ça lève le silence qu'un
                                              // tap avait posé — redemander la
                                              // conversation est le seul geste
                                              // qui dise le contraire.
                                              _turnsHidden = false;
                                              _turnsMuted = false;
                                              _restTimer?.cancel();
                                              // Le rail se replie en même
                                              // temps : les deux se déplient
                                              // au MÊME endroit, l'un sur
                                              // l'autre, et la conversation a
                                              // besoin de toute la hauteur. Le
                                              // bouton qu'on vient de toucher
                                              // disparaît avec — c'est
                                              // justement ce qu'on veut, il a
                                              // fait son office.
                                              _controlsOpen = false;
                                            });
                                          },
                                        ),
                                        // Les langues reviennent ici : la barre
                                        // du bas porte désormais le micro et
                                        // la caméra à leur place, et sans ce
                                        // retour le sélecteur de langues ne
                                        // serait plus atteignable nulle part.
                                        _RoundCallButton(
                                          icon: Icons.translate_rounded,
                                          // Le drapeau de la langue qu'on
                                          // ENTEND — celle que cette touche
                                          // sert à changer. Repli sur la langue
                                          // du compte tant que rien n'a été
                                          // choisi.
                                          flagCountry: findLanguageByCode(
                                                _myOutputLang.isNotEmpty
                                                    ? _myOutputLang
                                                    : AppStrings
                                                        .currentBcp47.value,
                                              )?.countryCode ??
                                              '',
                                          label:
                                              AppStrings.t('call_language'),
                                          onTap: _openLanguagePairSheet,
                                        ),
                                        // Ils ouvrent un panneau, ils ne
                                        // basculent rien : jamais d'état
                                        // blanc, et le même verre que les
                                        // autres.
                                        _RoundCallButton(
                                          icon: Icons.tune_rounded,
                                          label: AppStrings.t('call_audio'),
                                          onTap: _openAudioSheet,
                                        ),
                                      ],
                                    ),
                                  ),
                          ),
                          // 3. La barre elle-même — effacée tant que la
                          // conversation est ouverte. Elle et la saisie se
                          // disputent le bas de l'écran, et c'est la saisie
                          // qu'on est venu chercher ; le tap qui referme la
                          // ramène. La place dans la colonne est gardée (une
                          // boîte vide) : retirer un enfant re-mappe ses
                          // voisins, et le champ de saisie y perdrait son
                          // focus — c'est le bug de b2f3293.
                          if (_turnsOpen)
                            const SizedBox(width: double.infinity)
                          else
                          // En veille, la rangée ne se contente plus de
                          // s'effacer : elle REND SA PLACE. Elle passait à
                          // l'opacité zéro en gardant toute sa hauteur, et les
                          // phrases restaient suspendues au-dessus d'une bande
                          // vide — on voyait le trou, pas la vidéo. Sa hauteur
                          // se replie donc avec elle, sur la même durée et la
                          // même courbe que son fondu, et les bulles
                          // descendent d'autant.
                          //
                          // La cible qui la rallume ne se perd pas au passage :
                          // c'est la couche plein écran [dock_wake] qui
                          // l'attrape, pas la rangée elle-même.
                          TweenAnimationBuilder<double>(
                            tween: Tween<double>(
                              begin: 1,
                              end: _dockDimmed ? 0 : 1,
                            ),
                            duration: const Duration(milliseconds: 450),
                            curve: Curves.easeInOut,
                            builder: (context, f, child) => ClipRect(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                heightFactor: f,
                                child: child,
                              ),
                            ),
                            child: _CallDock(
                            camOn: _camOn,
                            micOn: _micOn,
                            speakerOn: _audio.speakerOn,
                            ttsSpeaking: ttsSpeaking,
                            voiceLevel: _voiceLevel,
                            controlsOpen: _controlsOpen,
                            dimmed: _dockDimmed,
                            onWake: _wakeDock,
                            onToggleCam: () {
                              _wakeDock();
                              _toggleCam();
                            },
                            onToggleMic: () {
                              _wakeDock();
                              _toggleMic();
                            },
                            onToggleSpeaker: () {
                              _wakeDock();
                              _toggleSpeaker();
                            },
                            onHangUp: _hangUp,
                            onToggleControls: () {
                              _wakeDock();
                              setState(() {
                                _controlsOpen = !_controlsOpen;
                                // Et dans l'autre sens aussi : les réglages et
                                // la conversation se disputent la même bande
                                // au-dessus de la barre. Un seul des deux à la
                                // fois, quel que soit celui qu'on ouvre.
                                if (_controlsOpen) _turnsOpen = false;
                              });
                            },
                            ),
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
                      child: Opacity(
                        opacity: 0.7,
                        child: Text.rich(
                          const TextSpan(
                            children: [
                              TextSpan(text: 'swayc'),
                              TextSpan(
                                text: 'ø',
                                style: TextStyle(color: SC.accent),
                              ),
                            ],
                          ),
                          style: TextStyle(
                            color: Colors.white,
                            fontFamily: SC.brandFont,
                            fontSize: 29,
                            fontWeight: FontWeight.w700,
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
                ),
              ],
            ),
                  ),
                );
              },
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

/// Les derniers tours AU REPOS : posés au-dessus des touches, sans rien
/// effacer. C'est ce qui fait découvrir la conversation — une phrase paraît
/// d'elle-même dès qu'elle est dite, et le tap dessus la retire.
///
/// PAS de saisie ici : au repos c'est une notification, pas une conversation.
/// Elle vient s'y poser d'elle-même, par-dessus l'appel et sans qu'on ait rien
/// demandé — y mettre un champ de texte, c'est réclamer une réponse à quelqu'un
/// qui regardait un visage. Écrire est un geste qu'on choisit : il appartient
/// au panneau qu'on ouvre.
///
/// Ça remplace l'ouverture automatique d'avant : la zone entière s'ouvrait
/// toute seule à la première phrase, ce qui, maintenant qu'elle efface la
/// barre, emportait les touches sans que personne l'ait demandé. Ici la phrase
/// se montre, et rien d'autre ne bouge.
class _RestingTurns extends StatelessWidget {
  const _RestingTurns({
    required this.turns,
    required this.onTap,
    required this.myName,
    required this.myAvatarUrl,
    required this.peerName,
    required this.peerAvatarUrl,
  });

  final List<_SpokenTurn> turns;
  final VoidCallback onTap;
  final String myName;
  final String myAvatarUrl;
  final String peerName;
  final String peerAvatarUrl;

  /// Deux, comme dans la zone ouverte. Au repos on ne fait pas défiler : ce
  /// qui dépasse n'est pas montré, il attend qu'on ouvre.
  static const int _kRestCount = 2;

  /// Et deux lignes chacune. Le compte de bulles ne suffit pas à borner ce que
  /// ça prend : deux phrases longues font huit lignes et le bloc monte jusqu'au
  /// milieu de l'écran. Deux fois deux lignes, c'est une hauteur qu'on connaît
  /// d'avance, quelle que soit la phrase.
  static const int _kRestLines = 2;

  @override
  Widget build(BuildContext context) {
    final shown = turns.length > _kRestCount
        ? turns.sublist(turns.length - _kRestCount)
        : turns;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Le même mot qu'en haut du panneau ouvert, au même endroit : à
          // droite, au-dessus des phrases. Un tap les retire ici comme là, et
          // rien ne le disait — un geste qui ne s'annonce pas n'existe pas.
          // Sans la pastille ni le titre : au repos ce n'est pas un panneau,
          // c'est un sous-titre.
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                AppStrings.t('call_turns_close'),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 10.5,
                  letterSpacing: 0.2,
                  shadows: const [
                    // Posé à même la vidéo, sans le verre d'une bulle
                    // derrière : sur une image claire, ce gris disparaîtrait.
                    Shadow(color: Colors.black, blurRadius: 6),
                  ],
                ),
              ),
            ),
          ),
          for (final turn in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _TurnBubble(
                turn: turn,
                name: turn.mine ? myName : peerName,
                avatarUrl: turn.mine ? myAvatarUrl : peerAvatarUrl,
                maxLines: _kRestLines,
              ),
            ),
        ],
      ),
    );
  }
}

/// La conversation de l'appel, rangée en bas à GAUCHE : les deux derniers tours
/// en bulles de verre, la saisie dessous. On remonte le fil en faisant défiler.
/// Tout le reste de l'appel s'efface le temps qu'elle est là, et un tap
/// n'importe où la referme.
class _SpokenTurnsPanel extends StatefulWidget {
  const _SpokenTurnsPanel({
    required this.turns,
    required this.onToggle,
    required this.myName,
    required this.myAvatarUrl,
    required this.peerName,
    required this.peerAvatarUrl,
    required this.chatController,
    required this.chatFocus,
    required this.sending,
    required this.onSend,
  });

  final List<_SpokenTurn> turns;
  final VoidCallback onToggle;
  final String myName;
  final String myAvatarUrl;
  final String peerName;
  final String peerAvatarUrl;

  /// La saisie. Elle appartient à l'écran d'appel et pas au panneau : le
  /// panneau se démonte à chaque fermeture, ce qui perdrait le texte en cours.
  final TextEditingController chatController;
  final FocusNode chatFocus;
  final bool sending;
  final Future<void> Function() onSend;

  /// La hauteur qu'on laisse aux bulles : DEUX, et la troisième se devine
  /// au-dessus — c'est ce qui invite à faire défiler. Au-delà on ne relit plus,
  /// on subit, et la vidéo est ce qu'on est venu regarder. Les plus anciennes
  /// ne sont pas jetées pour autant : on remonte le fil en faisant défiler.
  ///
  /// 132 et pas 90 : une bulle courte fait 45 avec son air, mais une phrase de
  /// deux lignes en fait 64 — à 90 la seconde aurait été rognée dès qu'elle
  /// dépasse une ligne, ce qui est le cas courant.
  static const double maxHeight = 132;

  /// Ce que la zone occupe en bas de l'écran, bulles pleines : les deux bulles,
  /// l'en-tête, la saisie et l'air entre les trois. C'est ce dont le galet a
  /// besoin pour savoir où se poser sans recouvrir quoi que ce soit.
  static const double zoneHeight = maxHeight + 27 + 8 + 46 + 10;

  @override
  State<_SpokenTurnsPanel> createState() => _SpokenTurnsPanelState();
}

class _SpokenTurnsPanelState extends State<_SpokenTurnsPanel> {
  @override
  Widget build(BuildContext context) {
    final turns = widget.turns;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // L'en-tête : ce que c'est à gauche, comment s'en débarrasser à
        // droite. Le geste de fermeture ne se devine pas — un panneau qui
        // recouvre un visage doit dire lui-même comment on le retire.
        //
        // Le tap de fermeture est posé ICI et pas sur tout le panneau : plus
        // bas il y a un champ de saisie, et un panneau qui se referme quand on
        // touche son propre champ ne se remplirait jamais. Ailleurs sur
        // l'écran, c'est la couche plein écran qui referme.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // La pastille du direct : le même point qu'on met devant un
                    // « en cours » partout ailleurs. C'est elle qui fait lire
                    // « live » plutôt que « journal ».
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(right: 7),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        // Le cyan bleu de l'app, pas le turquoise de l'accent :
                        // plus bleu, moins vert.
                        color: SC.meshCyan,
                      ),
                    ),
                    Text(
                      AppStrings.t('call_turns_title'),
                      style: const TextStyle(
                        color: SC.meshCyan,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
                Text(
                  AppStrings.t('call_turns_close'),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 10.5,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (turns.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(
              maxHeight: _SpokenTurnsPanel.maxHeight,
            ),
            child: ListView.builder(
              // À l'envers : la plus récente en bas, collée à la saisie, et on
              // remonte le temps en faisant défiler. C'est aussi ce qui garde
              // la vue calée sur la dernière quand une phrase arrive.
              reverse: true,
              // Sous la hauteur maximale, la liste épouse ses bulles : une
              // phrase n'occupe pas la place de deux.
              shrinkWrap: true,
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.zero,
              itemCount: turns.length,
              itemBuilder: (ctx, i) {
                final turn = turns[turns.length - 1 - i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _TurnBubble(
                    turn: turn,
                    name: turn.mine ? widget.myName : widget.peerName,
                    avatarUrl:
                        turn.mine ? widget.myAvatarUrl : widget.peerAvatarUrl,
                  ),
                );
              },
            ),
          ),
        // La saisie, sous les bulles : ce qu'on tape part traduit chez le pair
        // et se dit chez lui à voix haute, exactement comme une phrase parlée.
        _ChatComposer(
          controller: widget.chatController,
          focusNode: widget.chatFocus,
          sending: widget.sending,
          onSend: widget.onSend,
        ),
      ],
    );
  }
}

/// La saisie de l'appel : un champ de verre et un rond d'envoi.
///
/// Verre en nuance (GlassPanel), pas la vue native — celle-là avale vraiment
/// les touches. Sans danger ici : le bug du clavier qui retombait n'était pas
/// le verre mais des voisins non clés (b2f3293).
class _ChatComposer extends StatelessWidget {
  const _ChatComposer({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final Future<void> Function() onSend;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      borderRadius: 22,
      color: Colors.black.withValues(alpha: 0.35),
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              minLines: 1,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.send,
              cursorColor: SC.accent,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                hintText: AppStrings.t('call_chat_hint'),
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 14,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.fromLTRB(10, 8, 0, 8),
              ),
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: sending ? null : onSend,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                // Grisé pendant la traduction : la phrase est partie chercher
                // ses mots, un second tap l'enverrait deux fois.
                color: sending ? Colors.white24 : SC.accent,
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
}

/// Une bulle : la PDP de qui parle, du côté de qui parle.
///
/// TOUTES à gauche, les miennes comme les siennes : la conversation n'occupe
/// qu'une colonne sur le bord de l'écran, et une bulle renvoyée à droite y
/// serait à l'étroit pour rien. C'est la PDP qui dit qui a parlé, pas le côté.
class _TurnBubble extends StatelessWidget {
  const _TurnBubble({
    required this.turn,
    required this.name,
    required this.avatarUrl,
    this.maxLines,
  });

  final _SpokenTurn turn;
  final String name;
  final String avatarUrl;

  /// Combien de lignes au plus, au-delà desquelles la phrase se coupe.
  ///
  /// Nul dans le panneau ouvert : on y est venu pour lire, rien n'y est tronqué.
  /// Fixé au repos, où la bulle s'invite sur la vidéo sans qu'on l'ait demandé
  /// et ne doit donc pas pouvoir prendre l'écran. Le compte de bulles y était
  /// bien plafonné, mais pas leur HAUTEUR : deux phrases longues montaient sans
  /// limite, et « deux au maximum » ne veut plus rien dire quand chacune fait
  /// huit lignes.
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final avatar = ProfileAvatar(
      displayName: name,
      avatarUrl: avatarUrl.isEmpty ? null : avatarUrl,
      size: 26,
    );

    // UNE seule teinte, transparente, pour tout le monde : le verre sombre qui
    // était déjà celui du pair. Les miennes étaient teintées d'accent, ce qui
    // faisait deux couleurs sur une colonne qui n'en demande pas — la PDP dit
    // déjà qui parle, et un fond coloré rend surtout la vidéo moins lisible
    // dessous. Posées sur un visage, les bulles doivent le laisser passer :
    // c'est tout ce qu'on leur demande.
    //
    // La plus récente ne se distingue pas non plus : elle passait en blanc
    // plein, ce qui faisait changer de couleur une bulle déjà lue dès que la
    // suivante arrivait.
    final Color fill = Colors.black.withValues(alpha: 0.42);
    final Color ink = Colors.white.withValues(alpha: turn.mine ? 0.92 : 0.78);

    final bubble = Flexible(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.14),
              ),
            ),
            child: Text(
              turn.text,
              maxLines: maxLines,
              // Coupée, la phrase le dit — et la suite n'est pas perdue : elle
              // est entière dans le panneau, à un tap.
              overflow: maxLines == null
                  ? TextOverflow.clip
                  : TextOverflow.ellipsis,
              style: TextStyle(
                // Une phrase que personne n'a reçue s'efface franchement : on
                // doit pouvoir la relire pour la redire, mais on voit d'un
                // coup d'œil qu'elle n'est pas partie.
                color: turn.delivered ? ink : ink.withValues(alpha: 0.4),
                fontSize: 14.5,
                height: 1.3,
                fontWeight: FontWeight.w400,
                fontStyle:
                    turn.delivered ? FontStyle.normal : FontStyle.italic,
              ),
            ),
          ),
        ),
      ),
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [avatar, const SizedBox(width: 8), bubble],
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
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.55),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.35),
                ),
              ),
              child: const Icon(
                Icons.cameraswitch_rounded,
                color: Colors.white,
                size: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// La rangée du bas : cinq touches posées À MÊME la vidéo, sans panneau
/// derrière elles.
///
/// De gauche à droite — la conversation, couper la caméra, le chevron qui
/// déplie les réglages, couper le micro, raccrocher. Le micro et la caméra sont
/// ici et non derrière le chevron : on les coupe en pleine phrase, ça ne se
/// déplie pas.
class _CallDock extends StatelessWidget {
  const _CallDock({
    required this.camOn,
    required this.micOn,
    required this.speakerOn,
    required this.ttsSpeaking,
    required this.voiceLevel,
    required this.controlsOpen,
    required this.dimmed,
    required this.onWake,
    required this.onToggleCam,
    required this.onToggleMic,
    required this.onToggleSpeaker,
    required this.onHangUp,
    required this.onToggleControls,
  });

  /// L'état des deux bascules montées dans la rangée.
  final bool camOn;
  final bool micOn;
  final bool speakerOn;
  final ValueListenable<bool> ttsSpeaking;
  final ValueListenable<double> voiceLevel;
  final bool controlsOpen;

  /// Silence : la rangée s'efface entièrement.
  final bool dimmed;
  final VoidCallback onWake;
  final VoidCallback onToggleCam;
  final VoidCallback onToggleMic;
  final VoidCallback onToggleSpeaker;
  final VoidCallback onHangUp;
  final VoidCallback onToggleControls;

  /// La veille va jusqu'à l'effacement complet. Ce qui devient invisible
  /// devient introuvable, d'ordinaire — ici non : le galet reste posé au
  /// milieu, et un tap N'IMPORTE OÙ sur l'écran ramène la rangée.
  static const double _dimOpacity = 0.0;

  /// Une touche de la rangée : elle s'estompe avec la veille et cesse de
  /// répondre quand la barre est endormie — le premier tap la rallume, il ne
  /// déclenche rien d'autre.
  Widget _live(double live, bool asleep, Widget child) => Opacity(
        opacity: live,
        child: IgnorePointer(ignoring: asleep, child: child),
      );

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: dimmed ? 1 : 0),
      // Plus long et plus mou que les mouvements de la rangée : elle s'en va,
      // elle ne claque pas.
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeInOut,
      builder: (context, dim, _) {
        // 1 en pleine lumière, [_dimOpacity] en veille — jamais moins.
        final live = 1 - (1 - _dimOpacity) * dim;
        return GestureDetector(
          // En veille, la rangée entière devient une seule grande cible qui la
          // rallume : opaque, sinon le tap traverse et personne ne l'attrape.
          behavior:
              dimmed ? HitTestBehavior.opaque : HitTestBehavior.deferToChild,
          onTap: dimmed ? onWake : null,
          // Plus de barre de verre, et plus de lueur autour : les touches sont
          // posées à même la vidéo, sans rien derrière elles.
          child: Padding(
              // Les touches ne touchent pas le bord de l'écran, et elles
              // respirent entre elles : c'est le seul rôle qui restait au
              // panneau.
              // Presque rien sur les côtés : les deux touches extrêmes vont
              // chercher le bord de l'écran. C'est la zone de clic qui les
              // empêche de le toucher vraiment.
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // À GAUCHE : la sortie audio, puis couper la caméra.
                  _live(
                    live,
                    dimmed,
                    _DockKeyButton(
                      icon: speakerOn
                          ? Icons.volume_up_rounded
                          : Icons.phone_in_talk_rounded,
                      // Le texte dit L'ÉTAT COURANT, comme l'icône. Il disait
                      // l'action à faire, ce qui affichait « Écouteur » au
                      // moment précis où le haut-parleur était allumé.
                      label: AppStrings.t(
                        speakerOn ? 'call_speaker' : 'call_earpiece',
                      ),
                      // LE BLANC MARQUE CE QU'ON VEUT VOIR D'UN COUP D'ŒIL.
                      //
                      // Le haut-parleur s'allume quand il est ACTIF ; le micro
                      // et la caméra quand ils sont COUPÉS. Pas de règle
                      // unique, et c'est assumé : d'un appel on veut savoir
                      // « le son sort du haut-parleur » d'un côté, et « on ne
                      // me voit pas, on ne m'entend pas » de l'autre. Ce sont
                      // les trois choses qu'on cherche du regard.
                      //
                      // L'ICÔNE et le TEXTE disent tous deux l'état courant :
                      // micro barré + « Muet », micro plein + « Micro ». Les
                      // trois signaux racontent la même chose.
                      background: speakerOn
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.14),
                      iconColor: speakerOn ? Colors.black : Colors.white,
                      onTap: onToggleSpeaker,
                    ),
                  ),
                  _live(
                    live,
                    dimmed,
                    _DockKeyButton(
                      icon: camOn
                          ? Icons.videocam_rounded
                          : Icons.videocam_off_rounded,
                      label: AppStrings.t(
                        camOn ? 'call_camera' : 'call_video_off',
                      ),
                      // Blanche quand la caméra est COUPÉE, comme le micro.
                      background: camOn
                          ? Colors.white.withValues(alpha: 0.14)
                          : Colors.white,
                      iconColor: camOn ? Colors.white : Colors.black,
                      onTap: onToggleCam,
                    ),
                  ),
                  // AU CENTRE : le chevron qui déplie le reste.
                  _live(
                    live,
                    dimmed,
                    _RailToggleButton(
                      open: controlsOpen,
                      onTap: onToggleControls,
                    ),
                  ),
                  // À DROITE : le micro, puis raccrocher.
                  _live(
                    live,
                    dimmed,
                    _DockKeyButton(
                      icon: micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                      label: AppStrings.t(micOn ? 'call_mic' : 'call_mute'),
                      background: micOn
                          ? Colors.white.withValues(alpha: 0.14)
                          : Colors.white,
                      iconColor: micOn ? Colors.white : Colors.black,
                      onTap: onToggleMic,
                    ),
                  ),
                  _live(
                    live,
                    dimmed,
                    _DockKeyButton(
                      icon: Icons.call_end_rounded,
                      label: AppStrings.t('call_end'),
                      background: const Color(0xFFE53935),
                      onTap: onHangUp,
                    ),
                  ),
                ],
              ),
          ),
        );
      },
    );
  }
}

class _DockKeyButton extends StatelessWidget {
  const _DockKeyButton({
    required this.icon,
    required this.label,
    required this.background,
    required this.onTap,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final Color background;

  /// Null = la touche est là mais n'a rien à ouvrir (aucune phrase encore
  /// dite) : elle ne réagit pas, sans changer d'aspect.
  final VoidCallback? onTap;

  /// Noir quand la touche est engagée et se remplit de blanc.
  final Color? iconColor;

  /// Le rond visible. Agrandi : à 46 il fallait viser.
  static const double size = 56;

  /// La zone qui répond au doigt, plus large que le rond. On visait un cercle
  /// de 46 et on ratait : Apple demande 44 MINIMUM, ce qui ne laisse aucune
  /// marge d'erreur, et un doigt ne tombe pas au pixel. Les 14 px de plus ne
  /// se voient pas — ils se sentent.
  static const double hitSize = 68;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: Pressable(
        bounce: true,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: hitSize,
              height: hitSize,
              child: Center(
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: background,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Icon(
                    icon,
                    color: iconColor ?? Colors.white,
                    size: 24,
                  ),
                ),
              ),
            ),
            // Le titre, comme sur les touches du rail. Il manquait ici et
            // nulle part ailleurs : cinq ronds muets en bas d'un appel se
            // devinent, ils ne se lisent pas.
            //
            // Borné à la largeur de la touche et RÉTRÉCI pour y tenir. En
            // français « Haut-parleur » fait déjà 12 signes, en portugais
            // « Auscultador » 11, en allemand « Nachrichten » 11 : à cinq de
            // front, la rangée débordait dans ces langues-là. Rétréci plutôt
            // que coupé — « Haut-parl… » est pire qu'un mot un peu plus petit.
            SizedBox(
              width: hitSize + 6,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.65),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                    height: 1.1,
                    shadows: const [
                      Shadow(color: Colors.black, blurRadius: 6),
                    ],
                  ),
                ),
              ),
            ),
          ],
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
class _TranslationOrb extends StatefulWidget {
  const _TranslationOrb({
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
  static const double kSize = 104;

  /// La pierre endormie est plus petite que le galet vivant : couper la
  /// traduction se voit à sa taille avant même qu'on lise l'icône. Même
  /// rapport qu'avant — 104 sur 130.
  static const double dormantRatio = 0.8;

  /// La place réservée AUTOUR du galet. Le halo déborde de 18 px et les ondes
  /// montent jusqu'à 2,4 fois le disque : sans cette marge, elles sont peintes
  /// hors des limites du widget. Ça passe tant qu'aucun ancêtre ne rogne —
  /// c'est une chance, pas une garantie, et ça fausse la mise en page.
  static const double boxFactor = 1.9;

  /// L'encombrement réel du widget.
  static const double box = kSize * boxFactor;

  @override
  State<_TranslationOrb> createState() => _TranslationOrbState();
}

class _TranslationOrbState extends State<_TranslationOrb>
    with TickerProviderStateMixin {
  /// Six mouvements, six périodes sans rapport entre elles (9 s, 5 s, 6,5 s,
  /// 3,8 s, 3,4 s, 1 s). Les faire dériver d'une seule horloge demanderait une
  /// période commune énorme, avec un saut visible à chaque bouclage ; six
  /// contrôleurs sur le même vsync coûtent moins que ce saut.
  late final AnimationController _spin = _ctrl(9000);
  late final AnimationController _spec = _ctrl(5000);
  late final AnimationController _ripple = _ctrl(3400);
  late final AnimationController _bars = _ctrl(1000);
  late final AnimationController _float = _ctrl(6500);
  late final AnimationController _breathe = _ctrl(3800);

  /// Ces deux-là font l'aller-retour ; les autres tournent en boucle.
  late final List<AnimationController> _swinging = [_float, _breathe];
  late final List<AnimationController> _all = [
    _spin,
    _spec,
    _ripple,
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
  void didUpdateWidget(covariant _TranslationOrb old) {
    super.didUpdateWidget(old);
    if (old.ttsSpeaking != widget.ttsSpeaking) {
      old.ttsSpeaking.removeListener(_retarget);
      widget.ttsSpeaking.addListener(_retarget);
    }
    if (old.voiceLevel != widget.voiceLevel) {
      old.voiceLevel.removeListener(_retarget);
      widget.voiceLevel.addListener(_retarget);
    }
    if (old.on != widget.on) _syncRunning();
    // Le micro vient de se couper : le galet doit retomber tout de suite, pas
    // attendre le prochain changement de niveau — muet, il n'en viendra plus.
    if (old.micOn != widget.micOn) _retarget();
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
          width: _TranslationOrb.box,
          height: _TranslationOrb.box,
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
        child: CustomPaint(
        painter: _OrbPainter(
          spin: _spin.value,
          spec: _spec.value,
          // Les courbes du CSS : `ease-out` sur les ondes, `ease-in-out` sur
          // la lévitation et la respiration. Un contrôleur rend une rampe
          // droite — sans ça, l'onde part trop lentement et la lévitation
          // rebondit sèchement en haut et en bas.
          ripple: Curves.easeOut.transform(_ripple.value),
          bars: _bars.value,
          float: Curves.easeInOut.transform(_float.value),
          breathe: Curves.easeInOut.transform(_breathe.value),
          amp: _voice.value,
          // Ondes coupées : leur amplitude tombe à zéro, le reste vit.
          waveAmp: widget.ripples ? _tts.value : 0,
          // Le painter sait déjà se taire : poser une icône au centre à la
          // place des barres — la « pierre réduite » de la maquette — ne
          // demandera que de passer false ici et un Icon en enfant.
          showBars: true,
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
        width: _TranslationOrb.kSize * _TranslationOrb.dormantRatio,
        height: _TranslationOrb.kSize * _TranslationOrb.dormantRatio,
        child: ClipOval(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: CustomPaint(
              painter: const _DormantOrbPainter(),
              child: Center(
                child: Icon(
                  Icons.play_arrow_rounded,
                  size: 30,
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
    final k = size.width / (_TranslationOrb.boxFactor * 130);
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

/// The glass chevron that unfolds the blue controls above the dock — the same
/// pill as the one on a Discover card, a size up, and flipped: it points UP to
/// open them (they grow upward) and DOWN to fold them away again.
class _RailToggleButton extends StatelessWidget {
  const _RailToggleButton({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  /// Le bouton lui-même. L'anneau et son halo se peignent dans les quelques
  /// pixels qui restent autour, d'où l'encombrement un peu plus large.
  static const double _size = 42;
  static const double _box = 50;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: _box,
        height: _box,
        child: CustomPaint(
          // L'anneau irisé est PEINT, pas posé en décoration : un dégradé ne
          // rentre pas dans un Border, et un disque dégradé placé dessous se
          // verrait par transparence à travers le verre du bouton. Un trait
          // circulaire n'a pas d'intérieur, donc rien ne traverse.
          painter: _ChevronRimPainter(visible: !open),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              width: _size,
              height: _size,
              decoration: BoxDecoration(
                // Pas de BackdropFilter ici : le bouton est POSÉ sur le dock,
                // qui floute déjà le fond — un second flou ne verrait que du
                // verre et coûterait une passe de plus.
                //
                // Déplié = engagé, donc blanc plein comme les bascules
                // au-dessus : les réglages sont ouverts, et ça se voit sans
                // lire le chevron.
                color:
                    open ? Colors.white : Colors.white.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: AnimatedRotation(
                turns: open ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                child: Icon(
                  Icons.keyboard_arrow_up_rounded,
                  color: open ? Colors.black : Colors.white,
                  size: 26,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// La lueur du chevron : un trait cyan autour du bouton, doublé du même trait
/// flouté qui fait le halo.
///
/// Elle s'efface quand les réglages sont dépliés : le bouton est alors blanc
/// plein, et deux signaux qui disent la même chose se gênent.
class _ChevronRimPainter extends CustomPainter {
  const _ChevronRimPainter({
    required this.visible,
    this.buttonSize = _RailToggleButton._size,
  });

  final bool visible;

  /// Le diamètre du bouton que l'anneau doit cerner. Il ne connaissait que le
  /// chevron ; le bouton des messages porte le même anneau et n'a pas la même
  /// taille.
  final double buttonSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) return;
    final c = Offset(size.width / 2, size.height / 2);
    // Le rayon du bouton, plus un cheveu : le trait court juste à l'extérieur.
    final r = buttonSize / 2 + 1.2;
    // La lueur d'abord : le même anneau, plus épais et flou, dessous.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..color = SC.accent.withValues(alpha: 0.45)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3.5),
    );
    // Puis le trait net.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = SC.accent.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_ChevronRimPainter old) =>
      old.visible != visible || old.buttonSize != buttonSize;
}

/// Un réglage d'appel, au-dessus du dock.
///
/// Les bascules suivent le geste natif (Téléphone / FaceTime d'iOS, WhatsApp) :
/// verre translucide au repos, **blanc plein et icône noire dès que l'état est
/// engagé** — muet, caméra coupée, haut-parleur. L'icône, elle, continue de
/// montrer l'état courant (micro barré quand on est muet) : le remplissage seul
/// est ambigu, on ne se souvient pas de la couleur "de repos" d'un bouton
/// (Nielsen Norman, «State-Switch Controls»). Les deux ensemble se lisent sans
/// rien avoir à retenir.
class _RoundCallButton extends StatelessWidget {
  const _RoundCallButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.ring = false,
    this.flagCountry,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// L'anneau cyan du chevron, autour de ce bouton-ci : il désigne celui qu'on
  /// cherche en premier dans la rangée.
  final bool ring;

  /// Code ISO pays. Non nul, le bouton montre CE DRAPEAU au lieu de [icon] —
  /// on reconnaît une langue à son drapeau bien plus vite qu'à un pictogramme
  /// de traduction, qui est le même pour toutes.
  final String? flagCountry;

  /// L'état que porte ce bouton est engagé. Un bouton qui ouvre un panneau ne
  /// l'est jamais : il garde son verre.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final fill =
        active ? Colors.white : Colors.white.withValues(alpha: 0.14);
    // Le libellé s'écrit sous le bouton. Il existait déjà — il ne servait
    // qu'aux lecteurs d'écran — donc il n'y a rien à traduire de plus : ce sont
    // les mêmes clés, dans les douze langues.
    return Semantics(
      label: label,
      button: true,
      toggled: active,
      child: Pressable(
        bounce: true,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(
              // L'anneau est PEINT autour, pas posé en bordure : un dégradé ne
              // rentre pas dans un Border, et il doit déborder du bouton.
              painter: ring
                  ? const _ChevronRimPainter(
                      visible: true,
                      buttonSize: _DockKeyButton.size,
                    )
                  : null,
              child: // Stable Flutter frosted-glass circle (NOT a platform
                  // view): the native glass flickered under the keyboard.
                  ClipOval(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: AnimatedContainer(
                  // Court exprès : c'est un interrupteur, pas une transition.
                  // Au-delà, le blanc «arrive» au lieu d'être déjà là.
                  duration: const Duration(milliseconds: 90),
                  curve: Curves.easeOut,
                  width: _DockKeyButton.size,
                  height: _DockKeyButton.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fill,
                    border: Border.all(
                      color:
                          Colors.white.withValues(alpha: active ? 0.0 : 0.22),
                    ),
                  ),
                  child: flagCountry == null || flagCountry!.isEmpty
                      ? Icon(
                          icon,
                          color: active ? Colors.black : Colors.white,
                          size: 24,
                        )
                      : ClipOval(
                          child: CountryFlag.fromCountryCode(
                            flagCountry!,
                            theme: const ImageTheme(
                              width: 45,
                              height: 45,
                              shape: Circle(),
                            ),
                          ),
                        ),
                ),
              ),
              ),
            ),
            const SizedBox(height: 6),
            // Même règle qu'en bas : borné, et rétréci s'il le faut.
            SizedBox(
              width: 74,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                // Engagé, le libellé passe au blanc plein comme son bouton :
                // les deux disent la même chose, ils doivent le dire ensemble.
                color: Colors.white.withValues(alpha: active ? 1.0 : 0.6),
                fontSize: 11,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                height: 1.1,
              ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
  late final List<AppLanguage> _langs = supportedLanguages;
  late int _spoken = _indexOf(_langs, widget.spokenCode);
  late int _heard = _indexOf(_langs, widget.heardCode);

  void _report() => widget.onChanged(
        _langs[_spoken].code,
        _langs[_heard].code,
      );

  /// Une langue hors catalogue (ou vide) retombe sur la première : la roue doit
  /// toujours montrer quelque chose.
  static int _indexOf(List<AppLanguage> langs, String code) {
    final base = code.split('-').first.toLowerCase();
    final i = langs.indexWhere((l) => l.code == base);
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

/// Les deux panneaux d'un seul tenant, ouverts par un appui long sur la
/// pastille : le son à gauche, les langues à droite.
class _CallSettingsSheet extends StatelessWidget {
  const _CallSettingsSheet({
    required this.controller,
    required this.spokenCode,
    required this.heardCode,
    required this.onLanguagesChanged,
  });

  final AudioController controller;
  final String spokenCode;
  final String heardCode;
  final void Function(String spoken, String heard) onLanguagesChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetHandle(),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _AudioControls(controller: controller)),
                  // Le trait qui sépare les deux panneaux.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  Expanded(
                    child: _LanguageWheels(
                      spokenCode: spokenCode,
                      heardCode: heardCode,
                              onChanged: onLanguagesChanged,
                      compact: true,
                    ),
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
            Icon(widget.icon, size: 13, color: SC.textMuted),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                widget.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: const TextStyle(
                  color: SC.textMuted,
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
          style: const TextStyle(
            color: SC.textPrimary,
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
class _AudioSettingsSheet extends StatelessWidget {
  const _AudioSettingsSheet({required this.controller});

  final AudioController controller;

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
            _AudioControls(controller: controller),
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
          Icon(icon, size: 18, color: SC.textMuted),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              color: SC.textPrimary,
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
  const _CameraOffTile({this.label, this.compact = false, this.muted = false});

  final String? label;
  final bool compact;

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
    );
  }
}
