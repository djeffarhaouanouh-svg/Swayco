import 'dart:math';

import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../services/app_strings.dart';
import '../widgets/spoken_language_gate.dart';
import '../services/device_id.dart';
import '../services/friendship_api.dart';
import '../services/languages.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../services/call_audio.dart';
import '../services/token_api.dart';
import '../services/user_prefs.dart';
import '../theme/swayco_theme.dart';
import '../swayco/realtime_translation_port.dart';
import 'call_screen.dart';
import 'onboarding_screen.dart';

/// "Appel" tab â€” instead of a manual room-name + name form, this lists the
/// user's accepted friends. Tapping a row starts the call directly with a
/// deterministic room name derived from the two device ids, so both sides
/// land on the same LiveKit room without ever typing it.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key, this.translation = const NoOpRealtimeTranslation()});

  final RealtimeTranslationPort translation;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> with WidgetsBindingObserver {
  String _myId = '';
  String _myName = '';
  String _mySourceLang = '';
  List<RemoteProfile> _friends = const [];
  bool _loading = true;
  /// Which peer.id is currently being dialed (UI lock to prevent double-tap).
  String? _dialingPeerId;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _bootstrap();
    }
  }

  Future<void> _bootstrap() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final id = await DeviceId.getOrCreate();
      final profile = await UserPrefs.loadProfile();
      List<RemoteProfile> friends = const [];
      if (isSupabaseReady) {
        friends = (await FriendshipApi.fetchMatches(id)).toList()
          ..sort((a, b) =>
              a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      }
      if (!mounted) return;
      setState(() {
        _myId = id;
        _myName = profile?.firstName.trim() ?? '';
        _mySourceLang = profile?.sourceLang.trim() ?? '';
        _friends = friends;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Erreur de chargement : $e';
        _loading = false;
      });
    }
  }

  Future<void> _openProfileEditor() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => OnboardingScreen(
          editing: true,
          onCompleted: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
    await _bootstrap();
  }

  String _newIdentity() {
    final r = Random();
    return 'u${DateTime.now().millisecondsSinceEpoch}${r.nextInt(999999)}';
  }

  /// Deterministic LiveKit room name derived from the two device ids. Kept
  /// short to satisfy the backend's 3-64 char limit on room names. The 12
  /// hex chars per side give ~10^14 unique pairs â€” plenty.
  String _roomNameFor(String otherId) {
    final a = _myId.replaceAll('-', '');
    final b = otherId.replaceAll('-', '');
    final aShort = a.substring(0, a.length.clamp(0, 12));
    final bShort = b.substring(0, b.length.clamp(0, 12));
    final pair = [aShort, bShort]..sort();
    return 'call-${pair[0]}-${pair[1]}';
  }

  Future<void> _startCallWith(RemoteProfile peer) async {
    armCallAudio();       // unlock web <audio> element (WebKit gesture)
    armSpeechSynthesis(); // unlock speechSynthesis / FlutterTts (iOS Safari)
    if (_dialingPeerId != null) return;
    if (_myName.isEmpty || _mySourceLang.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('join_error_lang'))),
      );
      return;
    }
    setState(() {
      _dialingPeerId = peer.id;
      _error = null;
    });
    try {
      // Which language will be spoken — minted into the token, which tells the
      // peer what to translate FROM.
      final spokenLang = await resolveSpokenLanguage(preselect: _mySourceLang);
      if (!mounted) return;

      final room = _roomNameFor(peer.id);
      final token = await fetchLiveKitToken(
        roomName: room,
        identity: _newIdentity(),
        displayName: _myName,
        sourceLang: spokenLang,
      );
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => CallScreen(
            wsUrl: token.url,
            jwt: token.token,
            roomName: token.roomName,
            displayName: _myName,
            mySourceLang: spokenLang,
            translation: widget.translation,
            isCaller: true,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _dialingPeerId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final apiBase = displayTokenApiBase();
    final myLang = findLanguageByCode(_mySourceLang);

    return Scaffold(
      backgroundColor: SC.bg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _WhatsAppCallHeader(
            apiBase: apiBase,
            onEditProfile: _openProfileEditor,
          ),
          _MyProfileStrip(name: _myName, lang: myLang, onEdit: _openProfileEditor),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _error!,
                style: const TextStyle(
                  color: Color(0xFFFFAB91),
                  height: 1.35,
                  fontSize: 13,
                ),
              ),
            ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: SC.accent),
      );
    }
    if (!isSupabaseReady) {
      return const _CenteredHint(
        icon: Icons.cloud_off,
        title: 'Supabase non configurÃ©',
        body: 'L\'appel automatique a besoin de la liste d\'amis. '
            'Configure Supabase pour activer cet onglet.',
      );
    }
    if (_friends.isEmpty) {
      return const _CenteredHint(
        icon: Icons.people_outline,
        title: 'Aucun ami Ã  appeler',
        body: 'Va dans l\'onglet Recherche pour trouver quelqu\'un par son '
            'prÃ©nom, puis envoie-lui une demande d\'ami. Une fois acceptÃ©e, '
            'il apparaÃ®tra ici et tu pourras le rappeler en un tap.',
      );
    }
    return RefreshIndicator(
      color: SC.accent,
      backgroundColor: SC.menu,
      onRefresh: _bootstrap,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _friends.length,
        separatorBuilder: (_, _) => const Divider(
          height: 1,
          color: Color(0xFF1F2C34),
          indent: 76,
        ),
        itemBuilder: (ctx, i) {
          final p = _friends[i];
          return _CallableFriendRow(
            profile: p,
            dialing: _dialingPeerId == p.id,
            anyDialing: _dialingPeerId != null,
            onCall: () => _startCallWith(p),
          );
        },
      ),
    );
  }
}

class _CallableFriendRow extends StatelessWidget {
  const _CallableFriendRow({
    required this.profile,
    required this.dialing,
    required this.anyDialing,
    required this.onCall,
  });

  final RemoteProfile profile;
  final bool dialing;
  final bool anyDialing;
  final VoidCallback onCall;

  @override
  Widget build(BuildContext context) {
    final lang = findLanguageByCode(profile.language);
    final name = profile.displayName.isNotEmpty
        ? profile.displayName
        : (profile.handle.isNotEmpty ? '@${profile.handle}' : 'Sans nom');
    final initial = name.isNotEmpty ? name.characters.first.toUpperCase() : '?';

    final disabled = anyDialing && !dialing;

    return InkWell(
      onTap: disabled ? null : onCall,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: SC.accentDeep,
              ),
              child: Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: const TextStyle(
                      color: SC.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  if (lang != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      '${lang.flag}  ${lang.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: const TextStyle(
                        color: SC.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: SC.accent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: disabled ? null : onCall,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: dialing
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(
                          Icons.videocam_rounded,
                          color: Colors.white,
                          size: 22,
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

class _MyProfileStrip extends StatelessWidget {
  const _MyProfileStrip({
    required this.name,
    required this.lang,
    required this.onEdit,
  });

  final String name;
  final AppLanguage? lang;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: SC.menu,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Text(
            lang?.flag ?? 'ðŸŒ',
            style: const TextStyle(fontSize: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name.isEmpty ? 'Sans nom' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: SC.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  lang != null
                      ? AppStrings.t('join_speak', args: {'lang': lang!.label})
                      : AppStrings.t('join_no_lang'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: SC.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onEdit,
            tooltip: AppStrings.t('join_edit_profile'),
            icon: const Icon(Icons.edit_outlined, color: SC.textMuted),
          ),
        ],
      ),
    );
  }
}

class _CenteredHint extends StatelessWidget {
  const _CenteredHint({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: SC.menu,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: SC.textMuted, size: 34),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SC.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SC.textMuted,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WhatsAppCallHeader extends StatelessWidget {
  const _WhatsAppCallHeader({
    required this.apiBase,
    this.onEditProfile,
  });

  final String apiBase;
  final VoidCallback? onEditProfile;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SC.bg,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.videocam, color: Colors.white, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppStrings.t('join_header_title'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                        Text(
                          AppStrings.t('join_header_subtitle'),
                          style: const TextStyle(
                            color: Color(0xFFB8E0D8),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onEditProfile != null)
                    IconButton(
                      onPressed: onEditProfile,
                      tooltip: AppStrings.t('join_header_profile_tooltip'),
                      icon: Icon(
                        Icons.manage_accounts_outlined,
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
