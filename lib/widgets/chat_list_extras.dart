import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';

import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/chat_api.dart';
import '../services/official_api.dart';
import '../services/profile_api.dart';
import '../theme/swayco_theme.dart';
import 'group_avatar.dart';

// Les lignes ajoutées à la liste Messages par le handoff messages_groupes_quiz :
// le « + » jaune (A1), une ligne de groupe (A1), la carte « Invite tes amis »
// (A7) et la conversation épinglée du compte officiel (B, 1a).

const Color _kYellow = Color(0xFFF4FF1F);
const Color _kNavy = Color(0xFF04123A);

/// Ouvre la feuille de partage du téléphone avec le lien de l'app.
Future<void> shareSwayco(BuildContext context) async {
  Analytics.track('invite_friends_share', props: {'source': 'official_guide'});
  final box = context.findRenderObject() as RenderBox?;
  try {
    await SharePlus.instance.share(
      ShareParams(
        text: AppStrings.t(
          'invite_friends_share_text',
          args: {'link': 'https://www.swayco.fr'},
        ),
        sharePositionOrigin:
            box != null ? box.localToGlobal(Offset.zero) & box.size : null,
      ),
    );
  } catch (_) {}
}

String _hm(DateTime dt) {
  final now = DateTime.now();
  if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
  return '${dt.day.toString().padLeft(2, '0')}/'
      '${dt.month.toString().padLeft(2, '0')}';
}

/// Le « + » jaune de l'en-tête (rond de 40 px, lueur jaune très discrète).
class NewGroupButton extends StatelessWidget {
  const NewGroupButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: AppStrings.t('group_new_title'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: _kYellow,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: _kYellow.withValues(alpha: 0.14),
                blurRadius: 8,
                spreadRadius: -3,
              ),
            ],
          ),
          child: const Icon(Icons.add_rounded, color: _kNavy, size: 26),
        ),
      ),
    );
  }
}

/// Une conversation de groupe dans la liste : nom, dernier message précédé du
/// prénom (« Aiko : 😂 »), heure, pastille de non-lus.
class GroupChatRow extends StatelessWidget {
  const GroupChatRow({
    super.key,
    required this.name,
    required this.members,
    required this.lastMessage,
    required this.lastAuthor,
    required this.unreadCount,
    required this.onTap,
    this.photoUrl = '',
    this.memberCount = 0,
  });

  final String name;
  final String photoUrl;

  /// Nombre de membres du groupe (la pastille « 👥 5 »).
  final int memberCount;
  final List<RemoteProfile> members;
  final ChatMessage? lastMessage;

  /// Le prénom de l'auteur du dernier message ('' = moi ou inconnu).
  final String lastAuthor;
  final int unreadCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final unread = unreadCount > 0;
    final m = lastMessage;
    String preview;
    if (m == null) {
      preview = AppStrings.t('group_empty_preview');
    } else if (m.isGroupLeft) {
      final first = m.senderName.trim().split(RegExp(r'\s+')).first;
      preview = AppStrings.t('group_member_left', args: {'name': first});
    } else if (m.isDeleted) {
      preview = AppStrings.t('chat_preview_deleted_peer');
    } else if (m.isVideo) {
      preview = AppStrings.t('push_video');
    } else if (m.isImage) {
      preview = AppStrings.t('push_photo');
    } else if (m.isVoice) {
      preview = AppStrings.t('voice_message');
    } else {
      preview = m.body;
    }
    if (m != null && !m.isGroupLeft && lastAuthor.isNotEmpty) {
      preview = '$lastAuthor : $preview';
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: unread
              ? BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      SC.accent.withValues(alpha: 0.10),
                      SC.accent.withValues(alpha: 0),
                    ],
                  ),
                )
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              GroupAvatar(members: members, size: 52, photoUrl: photoUrl),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16.5,
                              height: 1.2,
                              fontWeight:
                                  unread ? FontWeight.w600 : FontWeight.w500,
                              color: unread ? SC.textPrimary : SC.textSecondary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        // La pastille « 👥 5 » : le nombre de membres.
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: SC.fg.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.group_rounded,
                                  size: 12,
                                  color: SC.fg.withValues(alpha: 0.75)),
                              const SizedBox(width: 3),
                              Text(
                                '${members.length > memberCount ? members.length : memberCount}',
                                style: TextStyle(
                                  color: SC.fg.withValues(alpha: 0.75),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        color: unread ? SC.textPrimary : SC.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // L'heure en mono (jaune quand il y a du nouveau) et la
                  // pastille jaune de 10 px.
                  if (m != null)
                    Text(
                      _hm(m.createdAt),
                      style: GoogleFonts.ibmPlexMono(
                        color: unread
                            ? const Color(0xFFF4FF1F)
                            : SC.fg.withValues(alpha: 0.5),
                        fontSize: 11,
                      ),
                    ),
                  if (unread) ...[
                    const SizedBox(height: 6),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Color(0xFFF4FF1F),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La conversation « Swayco » : une LIGNE de chat comme les autres (pas
/// épinglée, pas une carte). Elle se range par date : elle descend au fil des
/// nouvelles conversations, et remonte quand l'équipe écrit. Icône de l'app en
/// photo ronde, pastille jaune « Équipe », heure en mono jaune et point jaune
/// quand il y a du nouveau, léger fond bleu.
class OfficialChatRow extends StatelessWidget {
  const OfficialChatRow({
    super.key,
    required this.last,
    required this.unreadCount,
    required this.onTap,
    required this.time,
    this.welcome = false,
  });

  final OfficialPost? last;
  final int unreadCount;
  final VoidCallback onTap;

  /// La date qui range la ligne, et qu'elle affiche.
  final DateTime time;

  /// Jamais ouvert (ou rien d'autre que le guide) : l'aperçu est le mot de
  /// bienvenue.
  final bool welcome;

  @override
  Widget build(BuildContext context) {
    final unread = unreadCount > 0;
    final preview = (welcome || last == null)
        ? AppStrings.t('official_guide_welcome')
        : (last!.title.isNotEmpty ? last!.title : last!.body);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: unread
              ? const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0x292B7FFF), Color(0x002B7FFF)],
                  ),
                )
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              // L'icône de l'app en photo de profil, ronde comme les autres.
              ClipOval(
                child: Image.asset(
                  'assets/icon-app.png',
                  width: 52,
                  height: 52,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Swayco',
                          style: TextStyle(
                            fontSize: 16.5,
                            height: 1.2,
                            fontWeight:
                                unread ? FontWeight.w700 : FontWeight.w500,
                            color: unread ? SC.textPrimary : SC.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _kYellow,
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            AppStrings.t('official_team'),
                            style: const TextStyle(
                              color: _kNavy,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        color: unread ? SC.textPrimary : SC.textMuted,
                        fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Colonne de droite à largeur FIXE (comme les autres lignes, qui y
              // mettent l'heure) : sans elle le texte du message courait jusqu'au
              // bord. Pas d'heure ni de date ici : seule la pastille jaune dit
              // qu'il y a du nouveau.
              SizedBox(
                width: 36,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: unread
                      ? Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            color: _kYellow,
                            shape: BoxShape.circle,
                          ),
                        )
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
/// « Invite tes amis » (handoff messages_inviter) : UNE LIGNE à la fin de la
/// liste, comme les autres conversations (pas une carte). Avatar rond au
/// dégradé de la marque avec `group_add`, titre + pastille jaune, sous-titre
/// d'une ligne, bouton jaune « Inviter » à droite. Ni heure ni compteur.
class InviteFriendsCard extends StatelessWidget {
  const InviteFriendsCard({super.key, required this.onShare});

  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Color(0x292B7FFF), Color(0x002B7FFF)],
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1F5EFF), Color(0xFF2B7FFF), Color(0xFF18DDEA)],
                stops: [0, 0.55, 1],
              ),
            ),
            child: const Icon(Icons.group_add_rounded,
                color: Colors.white, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        AppStrings.t('invite_friends_title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: SC.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _kYellow,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0x2604123A),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  AppStrings.t('invite_friends_sub'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF8086A0),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: onShare,
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _kYellow,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                AppStrings.t('invite_friends_cta'),
                style: const TextStyle(
                  color: _kNavy,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}