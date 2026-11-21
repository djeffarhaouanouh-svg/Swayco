# Discover et profils populaires : pastille, « En ligne », contour jaune (Flutter)

Ouvrir `reference/Swayco Discover Verifie 8c.dc.html` dans un navigateur (il charge `support.js`). Les écrans à reprendre sont **B** et **B2**. A et C sont des pistes abandonnées, ne pas les faire.

Deux maquettes de référence dans `reference/` : `Swayco Discover Verifie 8c.dc.html` (parties 1 à 3 ci-dessous) et `Swayco Profil Pro Visible 8c.dc.html` (parties 4 et 5).

Fichier concerné : `lib/screens/discover_screen.dart`, dans la carte (`_TinderCard`), le bloc « En haut à gauche, UNE seule pastille » (environ ligne 3434) et le bloc nom + ville (environ ligne 3650).

## Ce qui change
Aujourd'hui le coin haut gauche n'a qu'une pastille : « POPULAIRE » si le profil est Pro ou Plus, sinon `SwaycoSealCapsule` (la pastille « vérifié »). Le changement :
1. La pastille « vérifié » **quitte le coin haut gauche** et passe à côté du prénom.
2. Le coin haut gauche affiche « **En ligne** ».
3. « POPULAIRE » garde sa priorité, « En ligne » passe en dessous (B2).

## 1. Pastille à côté du prénom (B)
- Condition inchangée : `p.isVerified && !widget.preview`.
- Position : dans la ligne du nom, **après l'âge**. Ordre : prénom, âge, pastille.
- Forme : rond de 24 px, dégradé `#1F5EFF` → `#2B7FFF` → `#18DDEA` (135°), icône `verified` pleine blanche de 17 px, centrée verticalement sur la ligne.
- Espacement : 10 px entre chaque élément de la ligne (comme entre le prénom et l'âge aujourd'hui).
- Nom : 30 px, interlettrage -1,2, âge 22 px à 85 % d'opacité (valeurs déjà dans le code, ne pas les changer).
- Retirer le bloc `else if (p.isVerified …) SwaycoSealCapsule` du coin haut gauche. Le widget `SwaycoSealCapsule` peut rester s'il sert ailleurs.
- Pas de libellé texte : c'est une pastille seule, sans le mot « Vérifié ».

## 2. « En ligne » en haut à gauche
- Affichage : `isPeerOnline(profile)` dans `lib/services/presence_service.dart`. Cette règle existe déjà (réciproque, fenêtre de 3 minutes, tient compte du réglage « masquer mon statut »). Ne pas réécrire de condition à la main dans l'écran.
- Pas d'aperçu : ne pas l'afficher sur l'aperçu de ma carte (`widget.preview`), comme la pastille vérifié.
- Position : `top: 14`, `left: 14` pour rester aligné sur l'ancienne pastille. La maquette est à 16 px dans la carte, utiliser 14 comme dans le code.
- Forme : pilule, padding 13 horizontal et 7 vertical, fond blanc à 18 % avec flou de fond de 20, bordure blanche à 30 % de 1 px, rayon 999.
- Contenu : point vert `#4ADE80` de 8 px avec une lueur verte de 8 px, 7 px d'écart, puis « En ligne » en Plus Jakarta Sans 12,5 px gras, blanc.
- Texte : ajouter une clé de traduction (par exemple `discover_online`) dans `AppStrings`, ne pas écrire « En ligne » en dur.
- La pastille ne capte aucun tap : l'envelopper dans `IgnorePointer`, comme les pastilles actuelles, pour que le carrousel de photos reste cliquable dessous.

## 3. Profil populaire (B2)
- Si `p.isPro || p.isPlus` : « POPULAIRE » reste en haut à gauche, inchangée (jaune `SC.accent`, étincelles `Sparkles`).
- « En ligne » se place **juste en dessous**, à environ 36 px sous le haut de « POPULAIRE » (`top: 50` au lieu de `14`). Même style que ci-dessus.
- Le centre du haut de la carte reste libre pour les points de photos.
- Si la personne n'est pas en ligne : seule « POPULAIRE » s'affiche.
- La pastille bleue à côté du prénom s'affiche aussi sur un profil populaire vérifié.

## Résumé des cas
| Profil | Haut gauche | À côté du prénom |
|---|---|---|
| Normal, hors ligne | rien | rien |
| Normal, en ligne | En ligne | rien |
| Vérifié, en ligne | En ligne | pastille bleue |
| Populaire, en ligne | POPULAIRE puis En ligne dessous | pastille si vérifié |
| Populaire, hors ligne | POPULAIRE | pastille si vérifié |

## Dimensions de la maquette
Elle reprend celles de l'app : marges de la carte 14 px, rayon 32, boutons ✕ et ❤ de 58 px, bouton message de 47 px, bulles de pays de 50 px. Les marges verticales sont estimées, les valeurs du code font foi.

## 4. Liste des messages : contour jaune (Profil Pro Visible, écrans 1a et 1c)
- Condition : le correspondant a `isPro || isPlus` (même règle que « POPULAIRE » sur Discover).
- La photo de profil de la ligne est entourée d'un anneau jaune `#F4FF1F` : 50 px au total, anneau de 2,5 px, puis un liseré intérieur de 2 px de la couleur du fond (`#0E0E0E` en sombre) entre l'anneau et la photo. Lueur jaune autour : `BoxShadow` jaune à 45 %, flou 14.
- Les autres conversations n'ont aucun contour.
- Bulle du pays : rond de 22 px en bas à droite de la photo, décalé de 4 px à droite et 3 px vers le bas, drapeau rogné en cercle, liseré de 2 px de la couleur du fond. Le contour jaune entoure la photo seule, jamais la bulle.
- Proportions pour d'autres tailles (écran 1c) : anneau = 5 % du diamètre, liseré = 4 %, bulle pays = 44 % du diamètre, lueur = 28 %.
- Version claire : liseré de la couleur du fond clair. Le jaune `#F4FF1F` a peu de contraste sur blanc, garder la lueur et ajouter un fin trait `#04123A` à 20 % à l'extérieur de l'anneau.

## 5. Profil d'une personne populaire (écran 1b)
- « POPULAIRE » **ne va pas sur la photo** : pastille jaune `#F4FF1F`, texte `#04123A` 11 px gras, interlettrage 0,5, padding 3 sur 9, lueur jaune légère, placée **à droite du @pseudo** sous le nom, dans la zone sombre du dégradé.
- Une lueur jaune diffuse (radial, jaune à 20 % vers transparent) derrière la zone du nom, sur environ 240 px de haut.
- Le bouton « Message » reste bleu (dégradé bleu), les tuiles photo de « Ses photos » n'ont ni contour ni lueur.
- Profil non populaire : aucun de ces éléments.
