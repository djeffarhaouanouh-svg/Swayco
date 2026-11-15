/// Pourquoi la liste des demandes (Likes) est vide : trois situations à ne PAS
/// confondre, chacune son écran (maquettes 1a / 1b / 1c).
enum LikesEmptyKind {
  /// Jamais la moindre demande reçue : la personne vient d'arriver.
  never,

  /// Tout est traité, et il s'est passé quelque chose aujourd'hui : une demande
  /// reçue aujourd'hui, ou une réponse donnée aujourd'hui.
  caughtUp,

  /// Des demandes par le passé, mais ni reçue ni traitée aujourd'hui.
  quietToday,
}

/// Choisit l'écran vide.
///
/// - [lastReceived] : la date de la dernière demande reçue, tous statuts
///   confondus (`null` = jamais aucune).
/// - [lastAnswered] : la date de ma dernière réponse (accepter / refuser), ou
///   `null`.
/// - « Aujourd'hui » = depuis minuit, heure locale de [now].
///
/// Ordre : jamais d'abord ; puis « à jour » s'il s'est passé quelque chose
/// aujourd'hui (reçu OU répondu) ; sinon « calme ». Répondre aujourd'hui à une
/// demande d'HIER compte : sans ça l'écran « Tu es à jour ! » repassait en
/// « rien aujourd'hui » au premier rafraîchissement.
///
/// [lastIncoming] : la dernière demande que j'ai REÇUE (envoyée par quelqu'un
/// d'autre). Absente, elle vaut [lastReceived]. Sans elle, quelqu'un qui n'a fait
/// qu'envoyer des likes voyait « Tu as répondu à toutes tes demandes » alors qu'il
/// n'en a jamais reçu : s'il n'a rien reçu ni traité, il a l'écran « calme ».
LikesEmptyKind classifyLikesEmpty({
  required DateTime? lastReceived,
  required DateTime? lastAnswered,
  required DateTime now,
  DateTime? lastIncoming,
  bool trackIncoming = false,
}) {
  if (lastReceived == null) return LikesEmptyKind.never;
  if (trackIncoming && lastIncoming == null && lastAnswered == null) {
    return LikesEmptyKind.quietToday;
  }
  final midnight = DateTime(now.year, now.month, now.day);
  final received = trackIncoming ? lastIncoming : lastReceived;
  final receivedToday = received != null && !received.isBefore(midnight);
  final answeredToday = lastAnswered != null && !lastAnswered.isBefore(midnight);
  return (receivedToday || answeredToday)
      ? LikesEmptyKind.caughtUp
      : LikesEmptyKind.quietToday;
}
