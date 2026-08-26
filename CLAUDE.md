# Swayco — consignes projet

## Écris pour Flutter 3.41.2, pas pour celui qui est installé

**La règle : n'utilise aucune API Flutter/Dart ajoutée après la 3.41.2.**

Le Flutter global de cette machine est en **3.47.1**. Les builds de release,
eux, tournent en **3.41.2** — le worktree `../flutter-3.41.2` en local, et
`FLUTTER_VERSION: 3.41.2` dans `.github/workflows/ios-release.yml`.

Pourquoi on ne peut pas monter : `livekit_client 2.7.0` ne compile pas sur
Dart 3.13 (il lit `publishOptions.videoCodec` après un `await`, et la
promotion non-null ne survit plus au point de suspension). Monter la
librairie touche la couche WebRTC, donc l'audio d'appel — chantier à faire
à froid, sur une branche, avec un vrai appel testé dans les deux sens.

**Le piège :** `flutter analyze` et `flutter run` utilisent le 3.47 global.
Ils acceptent sans broncher une API trop récente. Elle ne casse qu'au build
de release, c'est-à-dire au pire moment. Un exemple réel : `onReorderItem`
sur `ReorderableListView` (Flutter ≥ 3.47) a fait échouer Android **et** iOS
en pleine release ; l'équivalent 3.41.2 est `onReorder`, avec un
`if (newIndex > oldIndex) newIndex -= 1`.

**Comment vérifier avant de pousser :**

```bash
../flutter-3.41.2/bin/flutter analyze lib/le_fichier_touche.dart
```

Si le worktree manque, le recréer :

```bash
git -C <sdk-flutter> worktree add ../flutter-3.41.2 3.41.2
```

## Ne jamais builder sans la configuration client

Google Play a suspendu la 6.1.7 : l'AAB avait été compilé sans les
`--dart-define`, donc sans Supabase. L'app démarrait, et « Sign in » ne
répondait pas.

Les valeurs vivent dans `dart_defines.env` (une seule source de vérité,
identifiants publics, pas des secrets). Builder avec :

```bash
flutter build appbundle --release --dart-define-from-file=dart_defines.env
```

Ou plus simplement `.\build-release.ps1`, qui prend le bon Flutter, passe
les defines et vérifie l'artefact produit.

`scripts/verify-release.sh` relit le binaire compilé (`libapp.so` d'un
`.aab`, `App.framework/App` d'un `.ipa`/`.app`) et refuse un artefact dont
la configuration a disparu. Le workflow iOS l'exécute avant toute signature.

## i18n

Toute chaîne visible par l'utilisateur va dans **les 12 maps** de
`lib/services/app_strings.dart` (fr en es it pt nl ar ru zh ko de ja), pas
seulement fr/en. Une clé manquante retombe silencieusement sur l'anglais.
