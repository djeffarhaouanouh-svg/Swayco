# Handoff: Tags d'intérêts — Style "Relief 3D"

## Overview
Style visuel pour les tags de centres d'intérêt affichés sur le profil utilisateur d'une app de rencontre. Fond noir, tags pleins colorés avec un effet de relief façon bouton (bord inférieur foncé).

## About the Design Files
Le fichier HTML de ce dossier est une **référence de design** créée en HTML/React — il montre le rendu visuel et le comportement au survol, ce n'est pas du code à copier tel quel. Recrée ce design dans l'environnement existant du projet (React Native, SwiftUI, Compose, etc.) en utilisant ses composants et patterns établis.

## Fidelity
**Haute fidélité (hifi)** — couleurs, typographie, espacements et effet de relief définitifs. Reproduire pixel-perfect avec les outils du codebase cible.

## Screens / Views
### Nuage de tags (profil)
- **Purpose**: afficher la liste des centres d'intérêt de l'utilisateur sous forme de tags colorés.
- **Layout**: conteneur flex, `flex-wrap: wrap`, `gap: 12px`, aligné à gauche (`align-content: flex-start`). Fond du panneau : noir quasi-pur avec un léger dégradé radial (`#16161a` → `#0a0a0c` → `#060608`), coins arrondis 12px, padding ~30px 28px 34px.
- **Components**: chaque tag est un bouton/pill individuel (voir Design Tokens).

## Interactions & Behavior
- **Hover** : le tag se déplace de `translateY(2px)` (s'enfonce légèrement, comme un bouton pressé) — transition `160ms cubic-bezier(.2,.8,.3,1)`.
- Pas d'état "sélectionné" distinct dans cette version (tous les tags affichés sont "actifs"/déjà ajoutés au profil). Si un état de sélection est nécessaire (écran d'édition), prévoir une variante avec anneau ou opacité réduite pour les tags non sélectionnés — à valider avec le design.

## State Management
Aucun state complexe : la liste des tags vient des données du profil utilisateur (array de strings). La couleur de chaque tag est assignée de façon cyclique à partir d'une palette fixe (voir tokens), indexée par la position du tag dans la liste.

## Design Tokens

### Couleurs (palette cyclique, une par tag, dans l'ordre)
```
#22C55E  (vert)
#F97316  (orange)
#D946EF  (magenta)
#3B82F6  (bleu)
#EAB308  (jaune)
#EC4899  (rose)
#8B5CF6  (violet)
#0EA5E9  (cyan)
#EF4444  (rouge)
#14B8A6  (teal)
```
Assignation : `couleur = PALETTE[index % PALETTE.length]`.

### Effet de relief (par tag)
- Fond : couleur pleine de la palette.
- Ombre du bas (l'effet "3D") : `box-shadow: 0 5px 0 0 <couleur assombrie de 38%>, 0 10px 20px rgba(0,0,0,0.45)`.
- Assombrissement : multiplier chaque canal RGB par `(1 - 0.38)`.
- Au hover : `transform: translateY(2px)` (le tag "s'enfonce", l'ombre reste visible mais le tag semble pressé).

### Typographie
- Police : **Archivo**, weight 900 (black), fallback `sans-serif`.
- Taille : 16px.
- Letter-spacing : 0.005em.
- Couleur du texte : blanc `#fff`.
- Line-height : 1.

### Forme / espacement
- Padding interne du tag : `10px 18px`.
- Border-radius : `13px`.
- Gap entre tags : `12px`.
- Pas de bordure.

## Assets
Aucun asset externe. Police via Google Fonts : `Archivo` (weight 900).

## Files
- `Tags - Style 3 (Relief 3D).html` — prototype isolé du style retenu.
