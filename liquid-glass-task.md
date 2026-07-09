# Tâche : Vrai Liquid Glass (iOS 26) sur l'écran Messages

## Contexte
App Flutter. Je veux du vrai effet **Liquid Glass** (iOS 26) sur l'écran Messages.
Aujourd'hui j'ai un faux glass (juste des `Container` sombres translucides) et ça
fait plat. Trois chantiers, dans cet ordre.

## Règle préalable
Avant de coder, va lire les README / pages pub.dev des packages cités et confirme
les noms de classes / APIs exacts (versions courantes). **N'invente aucune API** :
si un nom diffère de ce que je donne, utilise le vrai et signale-le-moi.

---

## Tâche 1 — Verre NATIF (route platform-view)
Pour 2 éléments **statiques** : la barre de navigation du bas + le bouton
« Invite to a call ».

- Package : `cupertino_native_plus` (vérifier nom + dernière version sur pub.dev).
- Bouton → style glass natif (type `CNButtonStyle.glass` / `prominentGlass`).
- Tab bar du bas → tab bar native qui reçoit le style Liquid Glass sur iOS 26+.
- Garde une détection de version (ex. `PlatformVersion.shouldUseNativeGlass`) avec
  un **fallback propre** pour iOS < 26 et Android (mon design actuel fait l'affaire).
- Ces éléments sont statiques → les platform views sont OK ici.

## Tâche 2 — Verre SHADER (cross-platform)
Pour la carte de liste de discussions (Lenny / Alice / Ines).

- Package : `liquid_glass_widgets` (vérifier sur pub.dev).
- Enveloppe le **conteneur** de la liste dans le widget glass, **PAS chaque ligne**.
- Le `ListView` reste à l'intérieur du conteneur en verre.
- La ligne sélectionnée (surlignée) = une simple **teinte** par-dessus, surtout
  **pas** un 2e calque de verre (pas de verre-sur-verre).

## Tâche 3 — Fond avec de la matière derrière le verre
Sinon l'effet est invisible sur fond noir.

- À la racine du `Scaffold`, mets un `Stack` :
  - couche du fond = dégradé sombre + 2-3 « blobs » colorés très floutés
    (`Container` circulaires positionnés, fort blur), couleurs discrètes.
- Laisse les couleurs des avatars transparaître légèrement.
- Objectif : donner au verre quelque chose à réfracter / flouter.

---

## Contraintes (ne pas violer)
- **NE JAMAIS** mettre un widget glass en platform view dans un `ListView.builder` /
  `GridView` → jank garanti.
- Pas de verre natif imbriqué dans du verre natif.
- Respecter l'accessibilité « Réduire la transparence » → fallback sans shader.
- Builder iOS **ET** Android sans crash.

## Critères d'acceptation
- Sur iOS 26 : barre + bouton montrent du vrai Liquid Glass.
- Carte de liste : verre shader visible, fluide au scroll, sur iOS et Android.
- Le fond donne du relief au verre (plus de rendu « plat »).
- Fallback gracieux sur les anciennes versions / Android.

## Démarrage
1. Localise d'abord l'écran Messages, le `Scaffold` racine et le thème.
2. Montre-moi ton plan (fichiers à toucher, packages, versions) **avant** de tout
   modifier. On valide, puis tu fais la Tâche 1, je teste, on enchaîne.

---

## Notes
- Tâche 1 (iOS) : les platform views demandent souvent un `pod install` + rebuild
  complet (pas juste un hot reload). En cas de galère, c'est presque toujours là.
- Tâche 3 trop discrète ? Augmente le blur des blobs et leur opacité — c'est le
  réglage qui fait la différence entre « plat » et « verre ».
