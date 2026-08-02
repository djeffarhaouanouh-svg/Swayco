import 'job_sectors_i18n.dart';

export 'job_sectors_i18n.dart';

/// Closed set of job / life sectors. Stored as French keys — free-text titles
/// are gone; the picker only ever writes one of these.
const List<String> kJobSectors = [
  'Étudiant',
  'Médical',
  'Éducation',
  'Tech',
  'Commerce',
  'Restauration',
  'Art & Création',
  'Droit & Finance',
  'Ingénierie',
  'Sport & Divertissement',
  'Service public',
  'Autre',
];

/// Map a free-text legacy job onto a sector when the wording is obvious.
String normalizeJob(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '';
  if (kJobSectors.contains(t)) return t;
  final lower = t.toLowerCase();
  if (_kJobAliases.containsKey(lower)) return _kJobAliases[lower]!;
  // Loose contains-match for common free-text leftovers ("Footbaler",
  // "Étudiante en droit", "Architecte" …). Longer needles first so
  // "architecte" hits Ingénierie before the bare "art" → Art & Création.
  final needles = _kJobContains.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final needle in needles) {
    if (lower.contains(needle)) return _kJobContains[needle]!;
  }
  return t;
}

const Map<String, String> _kJobAliases = {
  'etudiant': 'Étudiant',
  'étudiant': 'Étudiant',
  'etudiante': 'Étudiant',
  'étudiante': 'Étudiant',
  'student': 'Étudiant',
  'medical': 'Médical',
  'médical': 'Médical',
  'medecin': 'Médical',
  'médecin': 'Médical',
  'doctor': 'Médical',
  'nurse': 'Médical',
  'infirmier': 'Médical',
  'infirmière': 'Médical',
  'education': 'Éducation',
  'éducation': 'Éducation',
  'enseignant': 'Éducation',
  'teacher': 'Éducation',
  'prof': 'Éducation',
  'tech': 'Tech',
  'it': 'Tech',
  'informatique': 'Tech',
  'developer': 'Tech',
  'développeur': 'Tech',
  'commerce': 'Commerce',
  'vente': 'Commerce',
  'sales': 'Commerce',
  'restauration': 'Restauration',
  'cuisine': 'Restauration',
  'chef': 'Restauration',
  'autre': 'Autre',
  'other': 'Autre',
};

const Map<String, String> _kJobContains = {
  'étudiant': 'Étudiant',
  'etudiant': 'Étudiant',
  'student': 'Étudiant',
  'médic': 'Médical',
  'medic': 'Médical',
  'infirm': 'Médical',
  'doctor': 'Médical',
  'nurse': 'Médical',
  'enseign': 'Éducation',
  'teacher': 'Éducation',
  'professeur': 'Éducation',
  'dévelop': 'Tech',
  'develop': 'Tech',
  'program': 'Tech',
  'ingénieur logiciel': 'Tech',
  'software': 'Tech',
  'data': 'Tech',
  'vente': 'Commerce',
  'commer': 'Commerce',
  'sales': 'Commerce',
  'restaur': 'Restauration',
  'cuisin': 'Restauration',
  'waiter': 'Restauration',
  'serve': 'Restauration',
  'art': 'Art & Création',
  'design': 'Art & Création',
  'créat': 'Art & Création',
  'creat': 'Art & Création',
  'music': 'Art & Création',
  'avocat': 'Droit & Finance',
  'lawyer': 'Droit & Finance',
  'droit': 'Droit & Finance',
  'financ': 'Droit & Finance',
  'compta': 'Droit & Finance',
  'banque': 'Droit & Finance',
  'ingénieur': 'Ingénierie',
  'engineer': 'Ingénierie',
  'architect': 'Ingénierie',
  'foot': 'Sport & Divertissement',
  'sport': 'Sport & Divertissement',
  'acteur': 'Sport & Divertissement',
  'actor': 'Sport & Divertissement',
  'fonctionnaire': 'Service public',
  'public': 'Service public',
};

int jobSectorIndex(String key) {
  final i = kJobSectors.indexOf(normalizeJob(key));
  return i < 0 ? 0 : i;
}

String displayJob(String raw) {
  final key = normalizeJob(raw);
  if (key.isEmpty) return '';
  if (kJobSectors.contains(key)) return jobSectorLabel(key);
  return key;
}
