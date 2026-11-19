import 'package:flutter/material.dart';
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

/// Le « + » jaune de l'en-tête (rond de 40 px, lueur jaune légère).
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
                color: _kYellow.withValues(alpha: 0.35),
                blurRadius: 14,
                spreadRadius: -2,
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
  });

  final String name;
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
    if (m != null && lastAuthor.isNotEmpty) preview = '$lastAuthor : $preview';
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
              GroupAvatar(members: members, size: 52),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16.5,
                        height: 1.2,
                        fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
                        color: unread ? SC.textPrimary : SC.textSecondary,
                      ),
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
                  if (m != null)
                    Text(
                      _hm(m.createdAt),
                      style: TextStyle(color: SC.textMuted, fontSize: 12),
                    ),
                  if (unread) ...[
                    const SizedBox(height: 6),
                    Container(
                      constraints: const BoxConstraints(minWidth: 20),
                      height: 20,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: SC.accent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        unreadCount > 99 ? '99+' : '$unreadCount',
                        style: const TextStyle(
                          color: SC.bgDeep,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          height: 1,
                        ),
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

/// La conversation « Swayco » épinglée en première ligne : l'icône de l'app,
/// la pastille jaune « Équipe », une épingle, un léger fond bleu.
class OfficialChatRow extends StatelessWidget {
  const OfficialChatRow({
    super.key,
    required this.last,
    required this.unreadCount,
    required this.onTap,
    this.welcome = false,
  });

  final OfficialPost? last;
  final int unreadCount;
  final VoidCallback onTap;

  /// Jamais ouvert (ou rien d'autre que le guide) : l'aperçu est le mot de
  /// bienvenue.
  final bool welcome;

  @override
  Widget build(BuildContext context) {
    final unread = unreadCount > 0;
    final preview = (welcome || last == null)
        ? AppStrings.t('official_guide_welcome')
        : (last!.title.isNotEmpty ? last!.title : last!.body);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Material(
        color: const Color(0xFF1F5EFF).withValues(alpha: SC.light ? 0.08 : 0.14),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
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
                              fontWeight: FontWeight.w700,
                              color: SC.textPrimary,
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
                          color: unread ? SC.textPrimary : SC.textMuted,
                          fontWeight:
                              unread ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Icon(Icons.push_pin_rounded,
                        size: 15, color: SC.textMuted),
                    if (unread) ...[
                      const SizedBox(height: 6),
                      Container(
                        constraints: const BoxConstraints(minWidth: 20),
                        height: 20,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: SC.accent,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '$unreadCount',
                          style: const TextStyle(
                            color: SC.bgDeep,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// « Invite tes amis sur Swayco » : sous la dernière conversation. Carte de
/// rayon 20, fond blanc 7 %, bordure blanche 12 %, bouton jaune « Partager ».
class InviteFriendsCard extends StatelessWidget {
  const InviteFriendsCard({super.key, required this.onShare});

  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final base = SC.light ? _kNavy : Colors.white;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        decoration: BoxDecoration(
          color: base.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: base.withValues(alpha: 0.12)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppStrings.t('invite_friends_title'),
                    style: TextStyle(
                      color: SC.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    AppStrings.t('invite_friends_sub'),
                    style: TextStyle(color: SC.textMuted, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: onShare,
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: _kYellow,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.ios_share_rounded,
                        size: 17, color: _kNavy),
                    const SizedBox(width: 6),
                    Text(
                      AppStrings.t('invite_friends_cta'),
                      style: const TextStyle(
                        color: _kNavy,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
