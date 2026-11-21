# Messages : rangée de bulles, états d'activité et menu d'appui long

Dossier à donner tel quel à l'IA qui code. Deux maquettes dans `reference/` (ouvrir dans un navigateur) :

- `Swayco Messages Bulles 8c.dc.html` : la rangée de bulles (écran 2 « Éveillés maintenant » = la cible).
- `Swayco Messages Appui Long 8c.dc.html` : le menu qui s'ouvre à l'appui long sur une bulle (3 états).

Les maquettes sont la référence visuelle. Les valeurs ci-dessous en sont tirées.

## Ce que j'ai vérifié dans le repo (lib/screens/chat_screen.dart)

- **Il n'existe PAS de rangée de bulles** sur la page Messages. La page est une `ListView` : bannière notif, `_TopCarousel`, section « messages spéciaux », `_SectionHeader`, puis les lignes (`_FriendChatRow`, `GroupChatRow`, `OfficialChatRow`). La rangée est donc **nouvelle** : à insérer entre `_TopCarousel` et la section des messages (ligne ~1405 / ~1425).
- La présence existe déjà : `isPeerOnline(RemoteProfile)` dans `lib/services/presence_service.dart` (battement 90 s, fenêtre 180 s, règle réciproque `hideOnlineLocal` / `hideOnlineStatus`). `_refreshPresence()` recharge `_friends` par `AppPoll.every`.
- Le long-press d'une **ligne** (`_FriendChatRow._showRowActions`, bottom sheet : sourdine, unmatch, bloquer, signaler, supprimer) **reste inchangé**. Le menu de la maquette est un **nouveau** menu, pour les **bulles** uniquement.
- `TypingSignal` (`lib/services/typing_signal.dart`) est un canal Realtime **par conversation**, rejoint seulement quand le fil est ouvert. Il ne peut donc pas alimenter la rangée tel quel (voir « Signal d'activité »).

## 1. La rangée de bulles

- Hauteur utile : bulle 58 px + 6 px + heure. Scroll horizontal, padding horizontal 18, espace 10 entre bulles.
- Titre de section au même style que `_SectionHeader` : « ÉVEILLÉS MAINTENANT » + compteur jaune `#F4FF1F`.
- **Contenu : uniquement les personnes en ligne** (`isPeerOnline(p) == true`). Pas de section Favoris. Pas de contour autour de la photo (le contour dégradé faisait « story », retiré).
- Bulle : photo ronde 58 px (`fit: cover`, alignement vertical ~25 %), fond de secours `#3A3A40`.
- Drapeau du pays : rond 24 px en bas à droite, décalé de (−4, −3), bordure 2 px de la couleur du fond de page.
- Sous la bulle : l'heure locale de la personne, IBM Plex Mono 11 px, gris 65 %.
- Pas de texte « En ligne il y a… » nulle part dans la liste (retiré à ta demande).

### Ordre : qui passe devant

- Tri : états actifs d'abord, puis par **moment de connexion le plus récent**.
- Quand une personne passe de hors ligne à en ligne (détecté dans `_refreshPresence`, en comparant l'ancien et le nouvel `isPeerOnline`), sa bulle est **insérée en première position**. Les autres glissent d'une place vers la droite.
- Animation : `AnimatedList` (ou `AnimatedPositioned`) : glissement 280 ms `Curves.easeOutCubic`, la nouvelle bulle apparaît en fondu + échelle 0,8 → 1.
- Quand quelqu'un se déconnecte, sa bulle sort (fondu 200 ms) et la file se referme.
- Le délai réel entre « se connecte » et « apparaît » dépend du sondage de `_refreshPresence` : si c'est trop lent, réduire l'intervalle de `AppPoll.every` pour cette page uniquement (la page est dans un `IndexedStack` : le garde `NavTab.index != NavTab.chat` reste en place).

## 2. États d'activité sur la bulle

Une bulle n'affiche qu'**un seul état**. Priorité : **appel > écrit > Discover**.

| État | Badge sur la bulle (24 px, en haut à gauche, décalé de −4/−3) | Texte dans le menu |
|---|---|---|
| Appel | rond `#F4FF1F`, icône `call` pleine 14 px `#04123A` | « Discute avec quelqu'un » |
| Écrit | pilule blanche, 22 px de haut, 3 points `#04123A` de 4 px (décalée de +2/−8 pour ne pas sortir de l'écran) | « Écrit un message » |
| Discover | rond dégradé 135° `#1F5EFF` → `#18DDEA`, icône `visibility` pleine 14 px blanche | « Fait défiler des profils sur Discover » |

Toutes les bordures de badge : 2 px, couleur du fond de page.

### Animations (important)

- **Œil (Discover)** : il s'ouvre et se ferme **en boucle**. Cycle 2,6 s, `ease-in-out` : ouvert de 0 à 38 %, se ferme jusqu'à 50 % (`scaleY` 1 → 0,08), se rouvre à 62 %. L'œil ne se déplace pas de gauche à droite : seulement ouvert / fermé.
- **Points (écrit)** : en **boucle**. Cycle 1,2 s, décalage 0 / 0,18 / 0,36 s entre les trois points. Chaque point monte de 3 px et passe de 35 % à 100 % d'opacité, puis redescend.
- **Téléphone (appel)** : il **ne vibre PAS en illimité**. Il tremble **3 fois** puis s'arrête, immobile. Une secousse = rotation 0 → −16° → +14° → −14° → +12° → −8° → 0 en 1,1 s. Il tremble :
  - quand l'état « appel » **commence** (la bulle vient de passer en appel) ;
  - quand on **ouvre le menu** d'appui long sur une bulle en appel.
  Il ne retremble pas tant que l'état ne change pas. Pas d'ondes autour du téléphone ni de la photo (retirées).
- Si l'écran est ouvert depuis longtemps et que l'état « appel » dure, le téléphone reste simplement immobile.

Exemple Flutter pour le téléphone (un seul contrôleur, 3 secousses, puis arrêt) :

```dart
late final AnimationController _shake = AnimationController(
  vsync: this, duration: const Duration(milliseconds: 3300));

final Animation<double> _angle = TweenSequence<double>([
  for (var i = 0; i < 3; i++) ...[
    TweenSequenceItem(tween: Tween(begin: 0.0, end: -16 * pi / 180), weight: 10),
    TweenSequenceItem(tween: Tween(begin: -16 * pi / 180, end: 14 * pi / 180), weight: 10),
    TweenSequenceItem(tween: Tween(begin: 14 * pi / 180, end: -14 * pi / 180), weight: 10),
    TweenSequenceItem(tween: Tween(begin: -14 * pi / 180, end: 12 * pi / 180), weight: 10),
    TweenSequenceItem(tween: Tween(begin: 12 * pi / 180, end: -8 * pi / 180), weight: 10),
    TweenSequenceItem(tween: Tween(begin: -8 * pi / 180, end: 0.0), weight: 10),
    TweenSequenceItem(tween: ConstantTween(0.0), weight: 4),
  ],
]).animate(_shake);

// au début de l'état « appel », ou à l'ouverture du menu :
_shake.forward(from: 0);
// jamais de .repeat()
```

### Signal d'activité (à créer)

Rien dans le repo ne dit aujourd'hui qui est en appel, qui écrit, qui est sur Discover. Il faut un signal **global** :

- Un canal Supabase Realtime Presence unique (ex. `activity`), où chaque client publie `{ user, activity: 'call' | 'typing' | 'discover' | null, typingTo: <id> }`.
- Qui publie quoi :
  - **call** : `call_screen.dart`, pendant un appel.
  - **typing** : le compositeur d'un fil ouvert (même déclencheur que `TypingSignal.setTyping`). Visible **seulement** par la personne à qui on écrit (`typingTo == mon id`), expire après 7 s sans nouvelles (même règle que `TypingSignal`).
  - **discover** : `DiscoverScreen` visible (onglet actif), `null` en quittant l'onglet ou en passant l'app en arrière-plan.
- **Confidentialité** : si l'utilisateur a masqué son statut (`hideOnlineStatus` / `AppSettings.hideOnlineLocal`), il ne publie aucune activité et ne voit celle de personne (règle réciproque déjà en place dans `isPeerOnline`). À confirmer avec moi : l'état « Discover » est plus intime que « en ligne », on peut le limiter aux contacts / matchs.

## 3. Menu d'appui long sur une bulle

Déclencheur : `onLongPress` sur la bulle. Retour haptique léger (`HapticFeedback.mediumImpact`) à l'ouverture. Ce n'est **pas** un bottom sheet : c'est une superposition plein écran.

1. **Fond** : `BackdropFilter` flou 14 + voile `Color(0xFF060810)` à 62 % d'opacité. Un tap dehors ferme.
2. **Bulle soulevée** : la photo passe à l'échelle **1,5** à sa position d'origine, anneau blanc 2 px (90 %), ombre `0 14 34` noir 55 %. Le drapeau et le badge d'état suivent. Animation d'entrée 180 ms (`easeOutBack`).
3. **Carte** : largeur 300, rayon 26, fond `rgba(32,34,44,0.92)`, bordure 1 px blanc 14 %, ombre `0 24 60` noir 50 %. Placée sous la bulle soulevée (≈ 40 px sous son bord bas), à gauche = marge de 18. Entrée : fondu + glissement de 8 px.
   - **En-tête** : prénom en Unbounded 800 / 17 px ; dessous `Ville · heure` en IBM Plex Mono 11 px, la ville en gris 65 % et **l'heure en orange `#FF9F43`** (même orange que l'en-tête du chat).
   - **Pastille d'état** sous le nom (**ce que la personne fait**) : même couleur que le badge (jaune / blanc / dégradé bleu), hauteur 30, texte 13 px, 800. Textes exacts : voir tableau ci-dessus. Pas de pastille si la personne n'a aucun état actif.
   - **Actions** (icônes blanches 22 px, texte blanc 15 px / 700, séparées par un filet blanc 8 %, 14 px de padding vertical) :
     1. Envoyer un message → `_openThread(p)`
     2. Appeler → lance l'appel (même chemin que le bouton d'appel du fil)
     3. Voir le profil → `_viewProfile(p)`
     4. Mettre en sourdine → `MutedCalls.setMuted(p.id, !isMuted)` (libellé « Réactiver » si déjà en sourdine)
     5. Bloquer ou signaler (icône `block`, texte et icône `#FF6B6B`) → ouvre le choix existant `_blockPeer` / `_reportPeer`
4. Les animations d'état (œil, points) tournent aussi dans le menu. Le téléphone tremble 3 fois **à l'ouverture** puis s'arrête.
5. Si la personne est en appel, « Appeler » reste actif (à trancher avec moi : le griser est possible).

## 4. Textes (`AppStrings`, toutes les langues de l'app)

- `presence_section` : « Éveillés maintenant »
- `activity_call` : « Discute avec quelqu'un »
- `activity_typing` : « Écrit un message »
- `activity_discover` : « Fait défiler des profils sur Discover »
- `bubble_send` : « Envoyer un message » ; `bubble_call` : « Appeler » ; `bubble_profile` : « Voir le profil » ; `bubble_block_report` : « Bloquer ou signaler » (`calls_mute` / `calls_unmute` existent déjà).

## 5. Polices et couleurs (déjà dans l'app)

Unbounded 800 (titres), IBM Plex Mono (heures, compteurs), Plus Jakarta Sans (texte). Jaune `#F4FF1F`, dégradé bleu `#1F5EFF` → `#18DDEA`, orange `#FF9F43`, rouge `#FF6B6B`, fond sombre `#0E0E0E`. Utiliser les jetons `SC.*` existants quand ils correspondent.

## 6. Points que je n'ai pas pu vérifier

- Intervalle exact de `AppPoll.every` dans `chat_screen.dart` (ligne ~219).
- Où l'appel démarre et finit dans `call_screen.dart` pour publier l'état « call ».
- La version claire de ces écrans n'existe pas encore en maquette.

## 7. Critères de réussite

1. Une personne qui se connecte apparaît **en première** place, les autres glissent.
2. Appel : le téléphone tremble 3 fois puis reste immobile ; il ne vibre jamais en boucle.
3. L'œil s'ouvre et se ferme en boucle ; les points rebondissent en boucle.
4. L'appui long ouvre le menu avec la bulle agrandie, l'état écrit en toutes lettres et l'heure en orange.
5. Le long-press d'une ligne de conversation fonctionne comme avant.
6. Statut masqué = aucune activité visible, dans les deux sens.
