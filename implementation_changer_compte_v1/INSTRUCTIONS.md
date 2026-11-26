# Changer de compte (Réglages) — implémentation

Dossier à donner tel quel à l'IA qui code. Référence visuelle : `reference/Swayco Changer de Compte 8c.dc.html` (3 écrans : la ligne dans Réglages, le panneau à 3 comptes, le panneau à 5 comptes). Ouvrir dans un navigateur.

**Version choisie : « simple ».** Bascule en un tap. Seul le compte actif reçoit notifications et appels. Pas de réception multi-comptes (Instagram-like), qui demanderait un chantier serveur.

## Ce que j'ai vérifié dans le repo

- **Une seule session aujourd'hui.** `AuthService` (lib/services/auth_service.dart) enveloppe `Supabase.instance.client.auth` : un seul `currentUser`. Aucun stockage de plusieurs comptes n'existe.
- **L'identité du compte = l'id Supabase.** `DeviceId.getOrCreate()` renvoie `AuthService.currentUserId` quand on est connecté (l'UUID d'installation n'est qu'un repli pour les builds sans Supabase). Tous les appels `ProfileApi`, chats, amis passent par là. Changer de session suffit donc à changer d'identité, à condition de **rafraîchir tout ce qui a été chargé avec l'ancien id**.
- **Le flux de déconnexion existe** (`_signOut` dans settings_screen.dart) et montre ce qu'il faut défaire : `NotificationClient.unregister(uid)`, `IosCallKit.unregisterToken(uid)`, `AuthService.signOut()`, puis `popUntil(isFirst)`. Le commentaire du code le dit : les cibles push sont **par appareil**, sinon le téléphone sonne encore pour l'ancien compte.
- `main.dart` écoute `AuthService.onAuthStateChange` (ligne ~364) et bascule `_authed`. **Un changement de compte ne doit pas passer par l'écran de login** : éviter `signOut()` pendant la bascule, ou le routeur renverra l'utilisateur sur Login.
- `RevenueCat` fait déjà `Purchases.logIn(userId)` (ligne ~128) et `Purchases.logOut()` (~163) : à réutiliser pour que le Pro d'un compte ne se retrouve pas sur l'autre.

## 1. La ligne dans Réglages

Fichier : `lib/screens/settings_screen.dart`, section « Compte » (`settings_section_account`).

- Ajouter **en première ligne** du `_SettingsCard` de la section Compte, avant l'e-mail :
  ```dart
  _SettingsRow(
    icon: Icons.swap_horiz_rounded,
    label: AppStrings.t('switch_account'),
    trailing: _SubtleText(_profile?.displayName.trim().isNotEmpty ?? false ? _profile!.displayName.trim() : '—'),
    onTap: _openAccountSwitcher,
  ),
  ```
- Même style que les autres lignes (icône 22, texte 14 / 500, valeur grise 13, chevron). Rien d'autre ne change dans la page.

## 2. Le panneau

Ouvert par `_openAccountSwitcher` avec `showModalBottomSheet` (`isScrollControlled: true`, `backgroundColor: Colors.transparent`, voile par défaut noir 54 %).

| Élément | Valeur |
|---|---|
| Fond | dégradé vertical `#1A2040` → `#16161E`, même teinte que la pop-up « On ne te comprend pas » |
| Forme | angles hauts rayon 28, bordure haute 1 px `white 14 %` |
| Padding | 12 haut, 18 côtés, 30 bas (+ `MediaQuery.viewPadding.bottom`) |
| Poignée | 36 × 4, `white 24 %`, centrée, 18 sous elle |
| Titre | « Changer de compte », Unbounded 800, 19 px, espacement −0,03 em |
| Compteur | à droite du titre, IBM Plex Mono 12 px : « 3 sur 5 » en gris 60 % ; « 5 sur 5 » en jaune `#F4FF1F` |
| Liste | 16 px sous le titre, écart 8 px entre lignes |
| Ligne de compte | padding 10 / 12, rayon 18, avatar rond 48 (`ProfileAvatar`), prénom 15 / 700, e-mail 12,5 gris 60 % (une ligne, ellipsis), icône à droite 26 px |
| Compte actif | fond `#F4FF1F` à 7 %, bordure 1 px `#F4FF1F` à 50 %, icône `check_circle` pleine jaune |
| Autres comptes | fond transparent, bordure 1 px `white 10 %`, icône `radio_button_unchecked` `white 40 %` |
| Bouton « Ajouter un compte » | hauteur 50, pilule, 14 px sous la liste, bordure 1,5 px `white 28 %`, texte blanc 15 / 800, icône `add` 22 |
| Bouton à 5 comptes | texte « 5 comptes maximum », icône `block`, bordure `white 12 %`, texte `white 40 %`, **non cliquable** |
| Légende | 14 px sous le bouton, 12,5 px, centrée, gris 60 % : « Les notifications et les appels arrivent sur le compte actif. » |

Le panneau défile si la liste dépasse l'écran (5 comptes tiennent sans défiler sur un téléphone standard).

## 3. Comportements

- **Tap sur un autre compte** : bascule (voir §4), ferme le panneau, `HapticFeedback.selectionClick()`. Tap sur le compte actif : ferme le panneau, rien d'autre.
- **Pendant la bascule** (1 à 2 s) : remplacer l'icône de la ligne tapée par un `CircularProgressIndicator` de 22 px jaune, désactiver les autres lignes. Si la bascule échoue : snackbar via `friendlyError(e)`, le compte précédent reste actif.
- **« Ajouter un compte »** : ouvre l'écran de connexion existant (`LoginScreen`) **par-dessus** l'app, sans déconnecter. Quand la connexion réussit, le nouveau compte est ajouté à la liste et devient actif. Si l'utilisateur annule, rien ne change.
- **Retirer un compte** : appui long sur une ligne (autre que l'actif) → `showSwaycoConfirm` « Retirer ce compte de cet appareil ? », bouton destructif. Cela n'efface pas le compte, seulement la connexion gardée sur ce téléphone. Retirer le compte actif est impossible (utiliser Déconnexion).
- **Déconnexion** (`_signOut`) : ne déconnecte que le compte actif. S'il reste d'autres comptes enregistrés, basculer sur le suivant au lieu d'afficher Login ; sinon, comportement actuel.
- **Suppression du compte** (`_deleteAccount`) : retirer aussi ce compte de la liste enregistrée.
- Maximum **5 comptes** par appareil.

## 4. Mécanique de bascule (à créer)

Nouveau service, par exemple `lib/services/account_switcher.dart`.

**Stockage** : `flutter_secure_storage` (Keychain / Keystore), **pas** SharedPreferences. Pour chaque compte : id Supabase, e-mail, prénom, URL d'avatar, `refreshToken`. Aucune recherche de `flutter_secure_storage` dans le repo n'a abouti : la dépendance est probablement à ajouter dans `pubspec.yaml`.

**À chaque connexion réussie** (`onAuthStateChange`) : enregistrer ou mettre à jour le compte courant dans la liste, avec son `refreshToken` le plus récent. Les jetons tournent : toujours réécrire à chaque `tokenRefreshed`.

**Bascule vers le compte B** :
1. Sauvegarder le jeton rafraîchi du compte A.
2. Défaire les liaisons de l'appareil pour A, comme `_signOut` : `NotificationClient.unregister(idA)`, `IosCallKit.unregisterToken(idA)`, `RevenueCat` `Purchases.logOut()`. **Sans** `AuthService.signOut()`.
3. Ouvrir la session de B : `Supabase.instance.client.auth.setSession(refreshTokenB)`. Si le jeton est expiré ou révoqué : retirer B de la liste et ouvrir `LoginScreen` avec son e-mail prérempli.
4. Lier l'appareil à B : `NotificationClient.register(idB)`, `IosCallKit` (enregistrer le jeton), `Purchases.logIn(idB)`.
5. Recharger tout l'état dépendant du compte (voir §5) puis ramener l'utilisateur sur l'onglet Profil ou Discover, comme après un login.

Garde-fou : une seule bascule à la fois (verrou), et refuser de basculer **pendant un appel**.

## 5. Données à passer en revue (risque de mélange)

Tout ce qui a été mis en cache avec l'ancien id doit être vidé ou relu pour B. Liste à auditer (pas exhaustive) :
- **Préférences locales** (SharedPreferences) : `AppSettings` (`kPush`, `kHideOnline`, `kHideFromCountry`), `UserPrefs` (prénom, langue source, langue d'appel, `keyCallSpokenLang`). Soit les **préfixer par id de compte**, soit les relire depuis le profil du compte B à la bascule. Les réglages propres à l'appareil (son de l'app, apparence) restent communs.
- **Notifiers en mémoire** : `AppSettings.hideOnlineLocal`, `RevenueCat.proActive`, présence (`PresenceService`), listes d'amis et de conversations de `ChatScreen`, profil de Discover.
- **Mémoires des animations de match / « déjà vu »** : elles sont communes à tout le téléphone aujourd'hui. À rattacher à l'id du compte.
- **Abonnement Pro** : vérifier que `RevenueCat.proActive` reflète bien le compte B après `Purchases.logIn`, et que le Pro de A ne reste pas actif.
- **Analytics** : appeler l'identification avec l'id de B.
- **Realtime / abonnements Supabase** (chat, présence, signaux de frappe) : fermer ceux de A, ouvrir ceux de B.

## 6. Textes (`AppStrings`, toutes les langues de l'interface)

- `switch_account` : « Changer de compte »
- `switch_account_count` : « {n} sur 5 »
- `switch_account_add` : « Ajouter un compte »
- `switch_account_max` : « 5 comptes maximum »
- `switch_account_note` : « Les notifications et les appels arrivent sur le compte actif. »
- `switch_account_remove_title` : « Retirer ce compte de cet appareil ? » ; `switch_account_remove_body` : « Tu pourras te reconnecter plus tard. Le compte n'est pas supprimé. » ; `switch_account_remove_confirm` : « Retirer »
- `switch_account_failed` : « Impossible de changer de compte. Réessaie. »
- `switch_account_in_call` : « Termine ton appel avant de changer de compte. »

## 7. Ce qui n'est PAS dessiné

L'appui long sur l'icône Profil de la barre de navigation (raccourci à la Instagram), l'état de chargement dessiné, la confirmation de retrait, l'écran de connexion lancé depuis « Ajouter un compte ». Les valeurs du §3 suffisent pour les trois derniers ; le premier est une option à décider.

## 8. Critères de réussite

1. Réglages > Compte : la ligne « Changer de compte » est en première position et affiche le prénom actif.
2. Le panneau liste les comptes enregistrés ; l'actif est coché en jaune.
3. Un tap sur un autre compte ouvre sa session **sans retaper le mot de passe** et sans passer par Login.
4. Après la bascule : chats, amis, profil, Discover et Pro correspondent au nouveau compte, aucune donnée de l'ancien ne reste affichée.
5. Les notifications et les appels n'arrivent que sur le compte actif.
6. À 5 comptes, « Ajouter un compte » est grisé.
7. Impossible de changer de compte pendant un appel.
8. Un jeton expiré renvoie vers Login avec l'e-mail prérempli, sans casser la liste.
