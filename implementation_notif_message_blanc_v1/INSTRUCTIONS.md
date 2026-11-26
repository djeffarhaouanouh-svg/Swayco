# Bannière de message dans l'app : version blanche (D)

Dossier à donner tel quel à l'IA qui code. Référence : `reference/Swayco Notif Message Chat 8c.dc.html` (variante **D · Blanc**, en sombre et en clair, posée sur un chat) et `reference/Swayco Notif Message 8c.dc.html` (sur Discover). Ouvrir dans un navigateur.

## Fichier à modifier

`lib/services/message_banner.dart`, classe `_MessageBannerViewState.build`. **Une seule chose change : le fond de la bannière.** Position, animation (220 ms, `easeOutCubic`), durée (5 s), tap, glissement vers le haut, emoji 💬, texte et logique de `MessageBanner.offer` restent identiques.

## Changement

Remplacer le `GlassPanel` (rayon 18, padding 16/12) par un `Container` blanc :

```dart
child: Material(
  type: MaterialType.transparency,
  child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0x1A04123A)), // #04123A à 10 %
      boxShadow: const [
        BoxShadow(color: Color(0x4704123A), blurRadius: 30, offset: Offset(0, 10)), // #04123A à ~28 %
      ],
    ),
    child: Row( /* inchangé : 💬, puis Column(prénom, aperçu) */ ),
  ),
),
```

Couleurs du texte, **fixes** (ne plus utiliser `SC.textPrimary` / `SC.textSecondary`, qui deviennent blancs en mode sombre et seraient illisibles sur du blanc) :

| Élément | Valeur |
|---|---|
| Fond | `#FFFFFF`, **identique en mode clair et en mode sombre** |
| Bordure | 1 px, `#04123A` à 10 % |
| Ombre | flou 30, décalage (0, 10), `#04123A` à 28 % |
| Prénom | `#04123A`, 14 px, `FontWeight.w600`, 1 ligne |
| Aperçu du message | `#04123A` à 70 %, 13 px, 1 ligne, ellipsis |
| Emoji | 💬, 20 px (inchangé) |
| Rayon | 18 (inchangé) |

Le fond blanc est choisi dans les deux modes : en sombre, il ressort nettement sur la photo de Discover ou sur un chat ; en clair, la bordure et l'ombre bleu nuit le détachent du fond `#F6F8FE`.

Retirer l'import `../widgets/glass_panel.dart` s'il n'est plus utilisé dans le fichier. `SC` (import `swayco_theme.dart`) ne sert plus dans ce fichier non plus : le retirer si plus rien ne l'utilise.

## À ne pas toucher

- `_CallAnyoneBanner` et `_NotifBanner` dans `chat_screen.dart` : ce sont d'autres bannières, pas celle-ci.
- La règle « pas de bannière si je lis déjà cette conversation » (`OpenThread.conversationId`).

## Critères de réussite

1. Un message reçu depuis un autre écran ou un autre chat affiche une bannière **blanche**, prénom bleu nuit, aperçu bleu nuit atténué.
2. Même rendu en mode clair et en mode sombre, texte lisible dans les deux.
3. Aucun soulignement jaune de texte (la `Material` transparente reste en place).
4. Le tap ouvre toujours la conversation et le glissement vers le haut ferme la bannière.
