import '../services/languages.dart';
import '../services/user_prefs.dart';

/// Quelle langue on va parler pendant l'appel — répondu SANS rien demander.
///
/// Il y avait ici un dialogue obligatoire avant chaque appel. Il n'a plus lieu
/// d'être : la langue se change désormais en pleine conversation, sur la
/// pastille scindée du dock (moitié gauche = ce que je parle), donc la faire
/// demander avant de décrocher ne faisait que retarder l'appel — et pendant ce
/// temps-là, l'autre attend.
///
/// L'ordre reste celui du dialogue : la dernière langue réellement utilisée en
/// appel d'abord, la langue du compte ensuite. Le dernier choix gagne parce
/// qu'il est la déclaration d'intention la plus récente — qui a passé son
/// dernier appel en japonais a plus de chances de recommencer que de revenir à
/// la langue de son profil.
///
/// Ce que ça pilote est inchangé : le tag est minté dans le token LiveKit (donc
/// l'app d'en face sait depuis quelle langue traduire) et il choisit le
/// recogniser embarqué.
Future<String> resolveSpokenLanguage({required String preselect}) async {
  final saved = await UserPrefs.loadCallSpokenLang();
  // `pt` nu → `pt-BR` ou `pt-PT` (la ligne de la roue) selon l'interface.
  final wanted = callLanguageCode(saved.lang.isNotEmpty ? saved.lang : preselect);
  // Toujours une langue du catalogue : le reste de la chaîne (recogniser, voix)
  // n'en connaît pas d'autres.
  return callLanguages.any((l) => l.code == wanted)
      ? wanted
      : callLanguages.first.code;
}
