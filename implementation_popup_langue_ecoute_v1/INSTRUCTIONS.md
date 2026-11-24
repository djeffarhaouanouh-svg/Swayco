# Pop-up « On ne te comprend pas » (langue d'écoute) — écran d'appel

Dossier à donner tel quel à l'IA qui code. Référence visuelle : `reference/Swayco Appel Langue Ecoute 8c.dc.html` (5 écrans : FR sombre, FR clair, DE, RU, AR + états). Valeurs exactes : `reference/popup_langue_ecoute_valeurs.html` (à ouvrir dans un navigateur).

## Ce qui existe déjà dans le repo (lib/screens/call_screen.dart)

La mécanique est DÉJÀ codée. Il s'agit de **redessiner** la pop-up, pas de la créer.
- `_trackDeliveryStreak(SpokenLine)` : compte les phrases non livrées (`_undeliveredStreak`), ignore les segments vides, remet à zéro dès qu'une phrase passe.
- `_kLangCheckThreshold = 3` (ligne ~1983). **Le brief demande 2 phrases** : passer la constante à 2 si c'est voulu.
- `_langCheckShown` : une seule fois par appel (ligne ~1986). `_sheetOpen` : pas d'ouverture si un panneau est déjà ouvert.
- `_promptSpokenLanguageCheck()` (ligne ~2021) : affiche aujourd'hui un `showSwaycoNotice(icon: Icons.mic_rounded, message: call_lang_check_q, buttonLabel: call_lang_check_change, secondaryLabel: call_lang_check_keep)`. Si le résultat vaut `true` : `_openLanguagePairSheet()` (le sélecteur à deux roues, ligne ~2963).
- Chaînes existantes : `call_lang_check_q`, `call_lang_check_change`, `call_lang_check_keep`.
- Le nom de langue affiché doit venir de `_mySourceLang` (langue d'écoute actuelle), au même format que dans `_LanguageWheels`.

## Ce qui change

1. **Titre** : nouvelle chaîne `call_lang_check_title` = « On ne te comprend pas ».
2. **Texte** : `call_lang_check_q` devient « Ton micro écoute en {langue}. Si tu parles une autre langue, change-la : ce n'est pas une panne, juste un réglage. » La langue est une **pastille** insérée dans la phrase (voir ci-dessous), pas du texte brut. Prévoir `Text.rich` avec un `WidgetSpan` aligné au milieu de la ligne.
3. **Boutons** : « Changer la langue » (`call_lang_check_change`, existant) et « C'est la bonne » (`call_lang_check_keep`, existant). Empilés, 48 px, pilule.
4. **Habillage** : `showSwaycoNotice` sert à d'autres messages. Soit lui ajouter un paramètre optionnel `titleWidget` / `messageSpan`, soit créer `showSwaycoLanguageCheck(...)` qui reprend la même carte. Ne pas modifier l'apparence des autres notices.
5. **Pastille tappable** : un tap sur la pastille = « Changer la langue ».
6. **Tap en dehors** = « C'est la bonne » (barrière ferme avec `false`).

## Quand elle apparaît (inchangé, à vérifier)

Après N phrases d'affilée non livrées (2 selon le brief), une seule fois par appel, par-dessus l'appel qui continue derrière (audio et vidéo). Jamais si : même langue des deux côtés, micro coupé, traduction désactivée. Vérifier que `_trackDeliveryStreak` n'est pas appelé dans ces cas. « C'est la bonne » ne la fait pas revenir (`_langCheckShown` reste vrai).

## Carte (valeurs exactes)

| Élément | Valeur |
|---|---|
| Voile derrière | sombre `rgba(4,10,30,.70)` ; clair `rgba(4,18,58,.50)` |
| Carte | marges latérales 28, rayon 30, bordure 1 px |
| Fond sombre | dégradé vertical `#1A2040` → `#16161E`, bordure `white 14 %` |
| Fond clair | `#FFFFFF`, bordure `rgba(4,18,58,.12)` (le code dit que l'appel reste sombre en toute apparence : la version claire est facultative) |
| Ombre | `0 24 60`, sombre `black 50 %`, clair `rgba(4,18,58,.35)` |
| Padding | 24 haut, 20 côtés, 20 bas |
| Pastille d'icône | rond 56 px, icône `mic_rounded` pleine 28 px, blanche (le micro : c'est lui qui écoute) |
| Fond de l'icône (sombre ET clair) | dégradé 135° `#1F5EFF` → `#18DDEA`, sans bordure |
| Titre | Unbounded 800, 20 px (18 en russe, 22 en arabe avec Noto Kufi Arabic 800), interligne 1,22, espacement −0,03 em, **2 lignes max**, 16 px sous l'icône |
| Texte | Plus Jakarta Sans 500, 14 px, interligne 1,6, centré, **4 lignes max**, 10 px sous le titre |
| Couleur texte | sombre `rgba(245,247,255,.80)`, clair `rgba(4,18,58,.78)` |
| Boutons | colonne, écart 10, 20 px sous le texte, hauteur 48, pilule, texte 15 px / 800 |
| Principal | fond `#F4FF1F`, texte `#04123A` (sombre ET clair) |
| Secondaire | sans remplissage, bordure 1,5 px : sombre `white 28 %` / texte blanc ; clair `rgba(4,18,58,.22)` / texte `#04123A` |

### Pastille de langue (élément clé)

Hauteur 28, padding horizontal 6, rayon pilule, vertical-align milieu, jamais coupée en deux (`nowrap`). Contenu : drapeau rond 18 px, nom de la langue (13 px / 800), icône `unfold_more_rounded` 18 px. Sombre : fond `rgba(24,221,234,.14)`, bordure 1 px `rgba(24,221,234,.45)`, texte blanc, chevron `#18DDEA`. Clair : fond `rgba(31,94,255,.08)`, bordure `rgba(31,94,255,.35)`, texte `#04123A`, chevron `#1F5EFF`. Le chevron « deux flèches » annonce une roue qui défile, comme dans le sélecteur.

### États appuyés

Échelle 0,97 sur 90 ms. Principal appuyé : fond `#D7E218`. Secondaire appuyé : fond `white 10 %`, bordure `white 50 %`. Pastille appuyée : fond `rgba(24,221,234,.30)`, bordure `#18DDEA`.

## Animation

Entrée : fondu + montée de 8 px, 180 ms, `Curves.easeOut`. Sortie : fondu 120 ms. Aucun son, aucun retour haptique fort (au plus `selectionClick`).

## Après « Changer la langue »

Ferme la pop-up puis ouvre `_openLanguagePairSheet()`. **À ajouter** : entourer de jaune `#F4FF1F` (bordure 2 px) la roue de gauche « langue que je parle » à l'ouverture, pour guider le geste. Paramètre à passer au sélecteur, par exemple `highlightSpoken: true`. Aucune validation : le panneau applique ses choix à la fermeture, comme aujourd'hui.

## Langues

Le brief liste 13 langues (fr, en, es, de, it, pt, pt-BR, nl, ar, ru, zh, ja, ko). **Le sélecteur actuel n'en liste que trois** (français, anglais, japonais, d'après le commentaire de `_LanguageWheels`). Deux sujets distincts :
- **Textes de la pop-up** : à fournir dans toutes les langues de l'interface déjà gérées par `AppStrings`.
- **Langues du sélecteur** : si les 13 doivent y figurer, c'est un autre chantier. Ne pas afficher dans la pastille un nom de langue absent du sélecteur.

Textes des maquettes (à faire relire par un locuteur natif pour DE, RU, AR, écrits par moi) :
- DE : « Wir verstehen dich nicht » / « Dein Mikrofon hört auf [Französisch]. Sprichst du anders, ändere sie: keine Störung, nur eine Einstellung. » / « Sprache ändern » / « Passt so »
- RU : « Мы тебя не понимаем » / « Микрофон слушает на [Русский]. Говоришь на другом языке? Поменяй: это не поломка, а настройка. » / « Сменить язык » / « Всё верно »
- AR : « لا نفهمك » / « ميكروفونك يستمع بـ[العربية]. إذا كنت تتحدث لغة أخرى، غيّرها: هذا ليس عطلًا، مجرد إعداد. » / « تغيير اللغة » / « هذه هي اللغة الصحيحة »

### Arabe (lecture droite à gauche)

`Directionality(textDirection: TextDirection.rtl)` sur la carte seulement : le drapeau passe à droite de la pastille, le chevron à gauche. La barre d'appel et les icônes de l'appel ne s'inversent pas. Police arabe : Noto Kufi Arabic 800 (titre), Noto Sans Arabic (texte et boutons).

## Barre d'appel

Dans la maquette, la barre reste **au-dessus du voile** : on peut toujours raccrocher. Si ce n'est pas possible avec la barrière modale actuelle, laisser le voile couvrir la barre mais garder « Raccrocher » actif est préférable.

## Ton

Ni « tu as mal réglé » ni « erreur ». Pas de rouge, pas d'icône d'alerte. Si une chaîne dérive vers l'un des deux, la reformuler.

## Critères de réussite

1. Après 2 phrases non livrées, la pop-up apparaît une seule fois ; l'appel continue derrière.
2. La pastille affiche la langue réellement réglée (`_mySourceLang`), avec son drapeau.
3. « Changer la langue » et la pastille ouvrent le sélecteur avec la roue « je parle » entourée de jaune.
4. « C'est la bonne » et le tap en dehors ferment sans rien changer, et elle ne revient pas.
5. Titre sur 2 lignes et texte sur 4 lignes maximum en allemand, russe et arabe.
6. Les autres `showSwaycoNotice` sont inchangées.

## Aligner les deux panneaux de réglages sur cette couleur

Les panneaux **Son** et **Langues** (`_CallSettingsSheet`, `_AudioSettingsSheet`, `_LanguagePairSheet`, tous ouverts par `_showCallSheet`, ligne ~465) ont aujourd'hui un fond uni `Color(0xFF16161B)`. La pop-up a un fond différent (dégradé bleuté). Décision : **la couleur de la pop-up fait référence**, les deux panneaux s'alignent dessus.

- Fond, dans `_showCallSheet` : `backgroundColor: Colors.transparent`, puis envelopper le contenu du `builder` dans un `DecoratedBox` :
  `gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF1A2040), Color(0xFF16161E)])`, avec les mêmes angles supérieurs arrondis (28 dans le code, à laisser) et une bordure supérieure `white 14 %` de 1 px.
- Créer une constante unique, par exemple `SC.callSurface` (dégradé) utilisée par la pop-up ET les panneaux, pour qu'ils ne divergent plus.
- Ne pas toucher au voile, au flou de la vidéo ni au galet des panneaux (ils restent comme aujourd'hui).
- Les roues de langue et les curseurs de son gardent leurs couleurs internes, seul le fond du panneau change.
- Vérifier le contraste des textes et des poignées (`_SheetHandle`, `Colors.white24`) sur le nouveau fond.
- Critère de réussite : pop-up ouverte, puis panneau Son, puis panneau Langues : même teinte de fond à chaque fois.
