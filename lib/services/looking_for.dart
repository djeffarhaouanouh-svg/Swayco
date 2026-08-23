import 'looking_for_i18n.dart';

export 'looking_for_i18n.dart';

/// Closed set of "what I'm looking for" answers. Stored as French keys.
/// `Amitié` / `Une relation` / `Du fun` / `Je ne sais pas encore` are the
/// original four (real profiles already carry these values); the rest widen
/// the set to the fuller "why are you here" intents — friendship and dating
/// aren't the only reasons two people with no common language would want to
/// talk to each other.
const List<String> kLookingForOptions = [
  'Amitié',
  'Une relation',
  "Rencontrer d'autres cultures",
  'Pratiquer une langue',
  'Faire des activités ensemble',
  'Trouver des gamers',
  'Networking',
  'Voyager / rencontrer des locaux',
  'Du fun',
  'Je ne sais pas encore',
];

/// Map a free-text legacy value onto a canonical key when possible.
String normalizeLookingFor(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '';
  if (kLookingForOptions.contains(t)) return t;
  final lower = t.toLowerCase();
  return _kLookingForAliases[lower] ?? t;
}

const Map<String, String> _kLookingForAliases = {
  // French
  'amitie': 'Amitié',
  'amitié': 'Amitié',
  'amis': 'Amitié',
  'des amis': 'Amitié',
  'relation': 'Une relation',
  'une relation': 'Une relation',
  'couple': 'Une relation',
  'sérieux': 'Une relation',
  'fun': 'Du fun',
  'du fun': 'Du fun',
  'discuter': 'Du fun',
  'je ne sais pas': 'Je ne sais pas encore',
  'je sais pas': 'Je ne sais pas encore',
  'nsp': 'Je ne sais pas encore',
  'rencontrer des gens d\'autres pays': "Rencontrer d'autres cultures",
  "d'autres cultures": "Rencontrer d'autres cultures",
  'pratiquer une langue': 'Pratiquer une langue',
  'apprendre une langue': 'Pratiquer une langue',
  'faire des activités': 'Faire des activités ensemble',
  'activités': 'Faire des activités ensemble',
  'gamers': 'Trouver des gamers',
  'jouer': 'Trouver des gamers',
  'networking': 'Networking',
  'réseauter': 'Networking',
  'voyager': 'Voyager / rencontrer des locaux',
  'rencontrer des locaux': 'Voyager / rencontrer des locaux',
  // English (incl. the "sing" typo seen in the wild)
  'friendship': 'Amitié',
  'friends': 'Amitié',
  'friend': 'Amitié',
  'make friends': 'Amitié',
  'relationship': 'Une relation',
  'dating': 'Une relation',
  'love': 'Une relation',
  'something serious': 'Une relation',
  'casual': 'Du fun',
  'not sure': 'Je ne sais pas encore',
  "don't know": 'Je ne sais pas encore',
  'idk': 'Je ne sais pas encore',
  'meet people from other countries': "Rencontrer d'autres cultures",
  'meet people from other cultures': "Rencontrer d'autres cultures",
  'other cultures': "Rencontrer d'autres cultures",
  'practice languages': 'Pratiquer une langue',
  'practice a language': 'Pratiquer une langue',
  'language exchange': 'Pratiquer une langue',
  'find people to do activities with': 'Faire des activités ensemble',
  'activity partners': 'Faire des activités ensemble',
  'gaming buddies': 'Trouver des gamers',
  'find gaming buddies': 'Trouver des gamers',
  'gaming': 'Trouver des gamers',
  'travel': 'Voyager / rencontrer des locaux',
  'meet locals': 'Voyager / rencontrer des locaux',
  'travel / meet locals': 'Voyager / rencontrer des locaux',
  // Mis-entered relationship status → closest looking-for intent
  'sing': 'Je ne sais pas encore',
  'single': 'Je ne sais pas encore',
  'célibataire': 'Je ne sais pas encore',
  'celibataire': 'Je ne sais pas encore',
};

int lookingForIndex(String key) {
  final i = kLookingForOptions.indexOf(normalizeLookingFor(key));
  return i < 0 ? 0 : i;
}

String displayLookingFor(String raw) {
  final key = normalizeLookingFor(raw);
  if (key.isEmpty) return '';
  if (kLookingForOptions.contains(key)) return lookingForLabel(key);
  return key;
}
