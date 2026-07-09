# flag_border_kit — contour drapeau (design « 2a »)

Un contour Flutter **uniquement** : un fin liseré dégradé aux couleurs du drapeau,
avec une légère lueur, façon carte de rencontre internationale.
**L'intérieur de la carte (photo, nom, âge, ville…) reste 100 % de ton côté.**

## Installation

Copie le dossier `lib/` dans ton projet (ou tout le dossier `flutter_flag_border/`
comme package local). Deux façons :

**A. En vrac dans ton app**
Copie `lib/flag_border.dart` et `lib/flag_gradients.dart` dans `lib/widgets/` (par ex.)
et importe-les directement.

**B. En package local**
Ajoute dans le `pubspec.yaml` de ton app :

```yaml
dependencies:
  flag_border_kit:
    path: ../flutter_flag_border
```

puis `flutter pub get`.

## Utilisation

```dart
import 'package:flag_border_kit/flag_border_kit.dart';

FlagBorder(
  country: FlagCountry.portugal,
  child: MaCarte(), // 👈 TON contenu : photo + overlay nom/âge/ville
)
```

Le widget ajoute uniquement le liseré + la lueur autour de `child`, et rogne
`child` aux coins arrondis. Rien d'autre.

## Paramètres

| Paramètre     | Défaut (2a) | Rôle                                        |
|---------------|-------------|---------------------------------------------|
| `country`     | —           | Pays → couleurs du dégradé                  |
| `child`       | —           | Ton contenu de carte                        |
| `borderWidth` | `2.0`       | Épaisseur du liseré                         |
| `radius`      | `28.0`      | Rayon des coins extérieurs                  |
| `glowBlur`    | `30.0`      | Flou de la lueur                            |
| `dropShadow`  | `true`      | Ombre portée sous la carte                  |

## Pays inclus

🇵🇹 Portugal · 🇫🇷 France · 🇯🇵 Japon · 🇮🇹 Italie · 🇧🇷 Brésil · 🇪🇸 Espagne ·
🇰🇷 Corée du Sud · 🇺🇸 États-Unis · 🇬🇧 Royaume-Uni · 🇧🇪 Belgique

## Ajouter un pays

Ajoute une valeur à l'enum `FlagCountry` puis une entrée dans `kFlagGradients`
(`lib/flag_gradients.dart`) :

```dart
FlagCountry.pays: FlagGradient(
  colors: [Color(0xFF...), Color(0xFF...), Color(0xFF...), Color(0xFF...)],
  stops:  [0.0, 0.30, 0.55, 1.0],
  glow:   Color(0x38......), // couleur dominante à ~22% (alpha 0x38)
),
```

## Démo

`example/flag_border_demo.dart` affiche le contour sur tous les pays.
