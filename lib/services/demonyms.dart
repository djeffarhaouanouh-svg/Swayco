/// Singular, gendered nationality for the "Une Brésilienne t'a ajouté 👀"
/// push. Keys are the verbatim `profiles.country` labels (French names from
/// [kCountries] in locations.dart). Plural twin for the online broadcast:
/// backend/nationalities.js.
///
/// fr / fr f — French demonym, masculine / feminine singular.
/// en        — English adjective ("A Brazilian woman added you").
/// ja        — Japanese nationality noun; 女性 / 男性 carries the gender.
const Map<String, ({String frM, String frF, String en, String ja})> kDemonyms = {
  'France': (frM: 'Français', frF: 'Française', en: 'French', ja: 'フランス人'),
  'Belgique': (frM: 'Belge', frF: 'Belge', en: 'Belgian', ja: 'ベルギー人'),
  'Suisse': (frM: 'Suisse', frF: 'Suisse', en: 'Swiss', ja: 'スイス人'),
  'Canada': (frM: 'Canadien', frF: 'Canadienne', en: 'Canadian', ja: 'カナダ人'),
  'États-Unis': (frM: 'Américain', frF: 'Américaine', en: 'American', ja: 'アメリカ人'),
  'Royaume-Uni': (frM: 'Britannique', frF: 'Britannique', en: 'British', ja: 'イギリス人'),
  'Espagne': (frM: 'Espagnol', frF: 'Espagnole', en: 'Spanish', ja: 'スペイン人'),
  'Portugal': (frM: 'Portugais', frF: 'Portugaise', en: 'Portuguese', ja: 'ポルトガル人'),
  'Italie': (frM: 'Italien', frF: 'Italienne', en: 'Italian', ja: 'イタリア人'),
  'Allemagne': (frM: 'Allemand', frF: 'Allemande', en: 'German', ja: 'ドイツ人'),
  'Pays-Bas': (frM: 'Néerlandais', frF: 'Néerlandaise', en: 'Dutch', ja: 'オランダ人'),
  'Mexique': (frM: 'Mexicain', frF: 'Mexicaine', en: 'Mexican', ja: 'メキシコ人'),
  'Argentine': (frM: 'Argentin', frF: 'Argentine', en: 'Argentine', ja: 'アルゼンチン人'),
  'Colombie': (frM: 'Colombien', frF: 'Colombienne', en: 'Colombian', ja: 'コロンビア人'),
  'Brésil': (frM: 'Brésilien', frF: 'Brésilienne', en: 'Brazilian', ja: 'ブラジル人'),
  'Maroc': (frM: 'Marocain', frF: 'Marocaine', en: 'Moroccan', ja: 'モロッコ人'),
  'Algérie': (frM: 'Algérien', frF: 'Algérienne', en: 'Algerian', ja: 'アルジェリア人'),
  'Tunisie': (frM: 'Tunisien', frF: 'Tunisienne', en: 'Tunisian', ja: 'チュニジア人'),
  'Sénégal': (frM: 'Sénégalais', frF: 'Sénégalaise', en: 'Senegalese', ja: 'セネガル人'),
  "Côte d'Ivoire": (frM: 'Ivoirien', frF: 'Ivoirienne', en: 'Ivorian', ja: 'コートジボワール人'),
  'Égypte': (frM: 'Égyptien', frF: 'Égyptienne', en: 'Egyptian', ja: 'エジプト人'),
  'Arabie Saoudite': (frM: 'Saoudien', frF: 'Saoudienne', en: 'Saudi', ja: 'サウジアラビア人'),
  'Émirats arabes unis': (frM: 'Émirati', frF: 'Émiratie', en: 'Emirati', ja: 'アラブ首長国連邦の'),
  'Turquie': (frM: 'Turc', frF: 'Turque', en: 'Turkish', ja: 'トルコ人'),
  'Russie': (frM: 'Russe', frF: 'Russe', en: 'Russian', ja: 'ロシア人'),
  'Chine': (frM: 'Chinois', frF: 'Chinoise', en: 'Chinese', ja: '中国人'),
  'Japon': (frM: 'Japonais', frF: 'Japonaise', en: 'Japanese', ja: '日本人'),
  'Corée du Sud': (frM: 'Coréen', frF: 'Coréenne', en: 'Korean', ja: '韓国人'),
  'Inde': (frM: 'Indien', frF: 'Indienne', en: 'Indian', ja: 'インド人'),
  'Australie': (frM: 'Australien', frF: 'Australienne', en: 'Australian', ja: 'オーストラリア人'),
  'Luxembourg': (frM: 'Luxembourgeois', frF: 'Luxembourgeoise', en: 'Luxembourgish', ja: 'ルクセンブルク人'),
  'Islande': (frM: 'Islandais', frF: 'Islandaise', en: 'Icelandic', ja: 'アイスランド人'),
  'Norvège': (frM: 'Norvégien', frF: 'Norvégienne', en: 'Norwegian', ja: 'ノルウェー人'),
  'Suède': (frM: 'Suédois', frF: 'Suédoise', en: 'Swedish', ja: 'スウェーデン人'),
  'Danemark': (frM: 'Danois', frF: 'Danoise', en: 'Danish', ja: 'デンマーク人'),
  'Finlande': (frM: 'Finlandais', frF: 'Finlandaise', en: 'Finnish', ja: 'フィンランド人'),
  'Irlande': (frM: 'Irlandais', frF: 'Irlandaise', en: 'Irish', ja: 'アイルランド人'),
  'Pologne': (frM: 'Polonais', frF: 'Polonaise', en: 'Polish', ja: 'ポーランド人'),
  'Ukraine': (frM: 'Ukrainien', frF: 'Ukrainienne', en: 'Ukrainian', ja: 'ウクライナ人'),
  'Grèce': (frM: 'Grec', frF: 'Grecque', en: 'Greek', ja: 'ギリシャ人'),
  'Philippines': (frM: 'Philippin', frF: 'Philippine', en: 'Filipino', ja: 'フィリピン人'),
};

/// "Une Brésilienne t'a ajouté 👀" in [lang] (fr / en / ja), for a sender
/// from [country] of [senderGender] ('f' = woman). Null when the country is
/// unknown or [lang] has no nationality wording — caller then falls back to
/// the plain "Someone added you 👀".
String? addedByNationality({
  required String lang,
  required String country,
  required String senderGender,
}) {
  final d = kDemonyms[country.trim()];
  if (d == null) return null;
  final woman = senderGender.trim().toLowerCase() == 'f';
  switch (lang.trim().toLowerCase().split(RegExp('[-_]')).first) {
    case 'fr':
      return woman
          ? "Une ${d.frF} t'a ajouté 👀"
          : "Un ${d.frM} t'a ajouté 👀";
    case 'en':
      return 'A ${d.en} ${woman ? 'woman' : 'man'} added you 👀';
    case 'ja':
      return '${d.ja}${woman ? '女性' : '男性'}があなたを追加しました 👀';
  }
  return null;
}
