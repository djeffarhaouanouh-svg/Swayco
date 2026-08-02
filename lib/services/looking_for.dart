import 'looking_for_i18n.dart';

export 'looking_for_i18n.dart';

/// Closed set of "what I'm looking for" answers. Stored as French keys.
const List<String> kLookingForOptions = [
  'Amitié',
  'Une relation',
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
  // English (incl. the "sing" typo seen in the wild)
  'friendship': 'Amitié',
  'friends': 'Amitié',
  'friend': 'Amitié',
  'relationship': 'Une relation',
  'dating': 'Une relation',
  'love': 'Une relation',
  'something serious': 'Une relation',
  'casual': 'Du fun',
  'not sure': 'Je ne sais pas encore',
  "don't know": 'Je ne sais pas encore',
  'idk': 'Je ne sais pas encore',
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
