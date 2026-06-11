// nationalities.js — builds the localized, gender-aware text for the
// "5 Japonaises en ligne" pull notification (see runOnlineBroadcast in
// server.js).
//
// Wording rule, per the product spec:
//   • recipient is a man   → show the FEMININE form ("5 Japonaises en ligne")
//   • recipient is a woman → show the MASCULINE form ("5 Japonais en ligne")
//   • recipient gender unknown/'x'/NULL → treated as a man (default H), so they
//     get the feminine form. (Decided product-side.)
//
// LOCALISATION SCOPE: French AND Japanese render fully (the two launch markets).
// French uses proper gendered demonyms; Japanese has no grammatical gender, so
// it carries gender with 女性 (women) / 男性 (men) on the nationality noun. The
// other 10 app languages fall back to the English string. The COUNTRY table is
// the single source of truth; adding a language is just adding a field + a
// template branch in onlineTitle, no engine change.
//
// Country keys MUST match the verbatim labels stored on profiles.country,
// i.e. the French names in lib/services/locations.dart (kCountries).

// Per country:
//   frM / frF — French demonym (masc / fem plural), used as "{n} {frX} en ligne".
//               Some are gender-invariant (Belge, Britannique, Russe) — both
//               forms identical, gender just isn't surfaced; correct French.
//   enAdj     — English adjective, used as "{n} {enAdj} women/men online".
//   ja        — Japanese nationality noun the gender suffix attaches to, used as
//               "{ja}女性/男性が{n}人オンライン" (e.g. 日本人 → 日本人女性).
const COUNTRY = {
  'France':              { frM: 'Français',       frF: 'Françaises',     enAdj: 'French',        ja: 'フランス人' },
  'Belgique':            { frM: 'Belges',         frF: 'Belges',         enAdj: 'Belgian',       ja: 'ベルギー人' },
  'Suisse':              { frM: 'Suisses',        frF: 'Suissesses',     enAdj: 'Swiss',         ja: 'スイス人' },
  'Canada':              { frM: 'Canadiens',      frF: 'Canadiennes',    enAdj: 'Canadian',      ja: 'カナダ人' },
  'États-Unis':          { frM: 'Américains',     frF: 'Américaines',    enAdj: 'American',      ja: 'アメリカ人' },
  'Royaume-Uni':         { frM: 'Britanniques',   frF: 'Britanniques',   enAdj: 'British',       ja: 'イギリス人' },
  'Espagne':             { frM: 'Espagnols',      frF: 'Espagnoles',     enAdj: 'Spanish',       ja: 'スペイン人' },
  'Portugal':            { frM: 'Portugais',      frF: 'Portugaises',    enAdj: 'Portuguese',    ja: 'ポルトガル人' },
  'Italie':              { frM: 'Italiens',       frF: 'Italiennes',     enAdj: 'Italian',       ja: 'イタリア人' },
  'Allemagne':           { frM: 'Allemands',      frF: 'Allemandes',     enAdj: 'German',        ja: 'ドイツ人' },
  'Pays-Bas':            { frM: 'Néerlandais',    frF: 'Néerlandaises',  enAdj: 'Dutch',         ja: 'オランダ人' },
  'Mexique':             { frM: 'Mexicains',      frF: 'Mexicaines',     enAdj: 'Mexican',       ja: 'メキシコ人' },
  'Argentine':           { frM: 'Argentins',      frF: 'Argentines',     enAdj: 'Argentine',     ja: 'アルゼンチン人' },
  'Colombie':            { frM: 'Colombiens',     frF: 'Colombiennes',   enAdj: 'Colombian',     ja: 'コロンビア人' },
  'Brésil':              { frM: 'Brésiliens',     frF: 'Brésiliennes',   enAdj: 'Brazilian',     ja: 'ブラジル人' },
  'Maroc':               { frM: 'Marocains',      frF: 'Marocaines',     enAdj: 'Moroccan',      ja: 'モロッコ人' },
  'Algérie':             { frM: 'Algériens',      frF: 'Algériennes',    enAdj: 'Algerian',      ja: 'アルジェリア人' },
  'Tunisie':             { frM: 'Tunisiens',      frF: 'Tunisiennes',    enAdj: 'Tunisian',      ja: 'チュニジア人' },
  'Sénégal':             { frM: 'Sénégalais',     frF: 'Sénégalaises',   enAdj: 'Senegalese',    ja: 'セネガル人' },
  "Côte d'Ivoire":       { frM: 'Ivoiriens',      frF: 'Ivoiriennes',    enAdj: 'Ivorian',       ja: 'コートジボワール人' },
  'Égypte':              { frM: 'Égyptiens',      frF: 'Égyptiennes',    enAdj: 'Egyptian',      ja: 'エジプト人' },
  'Arabie Saoudite':     { frM: 'Saoudiens',      frF: 'Saoudiennes',    enAdj: 'Saudi',         ja: 'サウジアラビア人' },
  'Émirats arabes unis': { frM: 'Émiratis',       frF: 'Émiraties',      enAdj: 'Emirati',       ja: 'アラブ首長国連邦の' },
  'Turquie':             { frM: 'Turcs',          frF: 'Turques',        enAdj: 'Turkish',       ja: 'トルコ人' },
  'Russie':              { frM: 'Russes',         frF: 'Russes',         enAdj: 'Russian',       ja: 'ロシア人' },
  'Chine':               { frM: 'Chinois',        frF: 'Chinoises',      enAdj: 'Chinese',       ja: '中国人' },
  'Japon':               { frM: 'Japonais',       frF: 'Japonaises',     enAdj: 'Japanese',      ja: '日本人' },
  'Corée du Sud':        { frM: 'Coréens',        frF: 'Coréennes',      enAdj: 'Korean',        ja: '韓国人' },
  'Inde':                { frM: 'Indiens',        frF: 'Indiennes',      enAdj: 'Indian',        ja: 'インド人' },
  'Australie':           { frM: 'Australiens',    frF: 'Australiennes',  enAdj: 'Australian',    ja: 'オーストラリア人' },
  'Luxembourg':          { frM: 'Luxembourgeois', frF: 'Luxembourgeoises', enAdj: 'Luxembourgish', ja: 'ルクセンブルク人' },
};

// Country flag emoji, appended to the end of every notification. Mirrors the
// flags in lib/services/locations.dart (kCountries) — keep in sync.
const FLAG = {
  'France': '🇫🇷', 'Belgique': '🇧🇪', 'Suisse': '🇨🇭', 'Canada': '🇨🇦',
  'États-Unis': '🇺🇸', 'Royaume-Uni': '🇬🇧', 'Espagne': '🇪🇸', 'Portugal': '🇵🇹',
  'Italie': '🇮🇹', 'Allemagne': '🇩🇪', 'Pays-Bas': '🇳🇱', 'Mexique': '🇲🇽',
  'Argentine': '🇦🇷', 'Colombie': '🇨🇴', 'Brésil': '🇧🇷', 'Maroc': '🇲🇦',
  'Algérie': '🇩🇿', 'Tunisie': '🇹🇳', 'Sénégal': '🇸🇳', "Côte d'Ivoire": '🇨🇮',
  'Égypte': '🇪🇬', 'Arabie Saoudite': '🇸🇦', 'Émirats arabes unis': '🇦🇪',
  'Turquie': '🇹🇷', 'Russie': '🇷🇺', 'Chine': '🇨🇳', 'Japon': '🇯🇵',
  'Corée du Sud': '🇰🇷', 'Inde': '🇮🇳', 'Australie': '🇦🇺', 'Luxembourg': '🇱🇺',
};

// Short call-to-action used as the notification body, per app language.
// Falls back to English for any language not listed.
const CTA = {
  fr: 'Lance un appel et discute en direct 👀',
  en: 'Start a call and chat live 👀',
  es: 'Inicia una llamada y habla en directo 👀',
  de: 'Starte einen Anruf und chatte live 👀',
  it: 'Avvia una chiamata e parla dal vivo 👀',
  pt: 'Inicia uma chamada e fala ao vivo 👀',
  nl: 'Start een gesprek en chat live 👀',
  ar: 'ابدأ مكالمة وتحدث مباشرة 👀',
  ru: 'Начни звонок и общайся вживую 👀',
  zh: '发起通话，实时聊天 👀',
  ja: '通話を始めてライブで話そう 👀',
  ko: '통화를 시작하고 실시간으로 대화하세요 👀',
};

// gender: 'm' or 'f' — the gender of the people being COUNTED (the opposite sex
// of the recipient). Returns the headline title string, or null when the
// country isn't in the table (engine then skips that send).
function onlineTitle(lang, countryFr, gender, n) {
  const c = COUNTRY[countryFr];
  if (!c) return null;
  const g = gender === 'f' ? 'f' : 'm';
  const flag = FLAG[countryFr] || '';
  let text;
  if (lang === 'fr') {
    text = `${n} ${g === 'f' ? c.frF : c.frM} en ligne`;
  } else if (lang === 'ja') {
    // No grammatical gender in Japanese — 女性 (women) / 男性 (men) carries it.
    text = `${c.ja}${g === 'f' ? '女性' : '男性'}が${n}人オンライン`;
  } else {
    // Every other language falls back to English: "5 Japanese women online".
    text = `${n} ${c.enAdj} ${g === 'f' ? 'women' : 'men'} online`;
  }
  // Green dot = "online", then the country flag at the very end.
  return `${text} 🟢 ${flag}`.trimEnd();
}

// Full notification payload for one recipient. `country` is the verbatim
// profiles.country value; `gender` is the OPPOSITE sex to advertise.
function onlineNotif(lang, countryFr, gender, n) {
  const title = onlineTitle(lang, countryFr, gender, n);
  if (!title) return null;
  return {
    title,
    body: CTA[lang] || CTA.en,
    type: 'online_broadcast',
    data: { country: countryFr, gender, count: String(n) },
  };
}

module.exports = { COUNTRY, onlineTitle, onlineNotif };
