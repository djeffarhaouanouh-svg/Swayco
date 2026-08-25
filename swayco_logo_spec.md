# Wordmark Swayco — 6d

Réponse aux questions ouvertes :

- Le "o" **n'est pas** le glyphe ø de la police. C'est un cercle redessiné (anneau + barre),
  volontairement, parce que c'est la forme du logo existant.
- Ne pas agrandir le wordmark. Taille de référence : **23 px** dans l'en-tête Discover.
- Ne pas amincir le trait ni raccourcir la barre au-delà des valeurs ci-dessous.

## Composition

`swayc` en texte + un "o" dessiné, posés sur une même ligne de base, alignés en bas.

Mot :
- Police : Plus Jakarta Sans, poids 800, italique
- letterSpacing : `-0.04 × fontSize`
- height / line-height : 1
- inclinaison supplémentaire : skewX **-9°** (`Matrix4.skewX(-0.157)`), pivot en bas
- couleur : blanc `#FFFFFF`

Le "o" (toutes les cotes sont des multiples de fontSize) :
- diamètre extérieur : `0.522 × fontSize`  (= hauteur d'x)
- épaisseur de l'anneau : `0.152 × fontSize`
- barre : longueur `0.609 × fontSize`, épaisseur `0.109 × fontSize`, rotation **-45°**, centrée sur le cercle
- la barre dépasse légèrement du cercle des deux côtés, symétriquement
- espace entre le `c` et le "o" : `0.065 × fontSize`
- décalage vertical : `0.03 × fontSize` vers le bas
- couleur : cyan `#22C8DE` (anneau et barre, même couleur)
- le "o" **reste droit** : aucune inclinaison, aucun skew

À 23 px cela donne : cercle 12 px, anneau 3,5 px, barre 14 × 2,5 px, espace 1,5 px.

## Implémentation

`swayco_logo.dart` contient exactement ça. Usage :

```dart
const SwaycoLogo()              // 23 px, en-tête Discover
const SwaycoLogo(fontSize: 40)  // tout se met à l'échelle
```

pubspec.yaml :

```yaml
fonts:
  - family: PlusJakartaSans
    fonts:
      - asset: assets/fonts/PlusJakartaSans-ExtraBoldItalic.ttf
        weight: 800
        style: italic
```
