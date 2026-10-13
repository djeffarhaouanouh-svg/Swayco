// Bulk-create AI (is_ai = true) Discover profiles from local photo folders.
//
//   node admin/scripts/seed_ai_profiles.mjs               # DRY RUN: shows the plan, writes nothing
//   node admin/scripts/seed_ai_profiles.mjs --go           # create for real
//   node admin/scripts/seed_ai_profiles.mjs --go --limit 50
//   node admin/scripts/seed_ai_profiles.mjs --delete       # remove every ai_* account + photos
//
// Photos:  <Downloads>/homme/*.jpg -> 'm'   <Downloads>/femme/*.jpg -> 'f'
//          (override the root with --dir "D:\photos"; gender comes from the folder only)
//
// The country is drawn AT RANDOM from COUNTRIES below. Nothing here looks at the
// photos: no face / skin-colour analysis, the folder only gives the gender.
// Edit COUNTRIES to narrow or weight the draw (a country listed twice is twice as likely).
//
// Needs migration 0064 (profiles.is_ai) applied first. Personas (ai_personas) are
// a separate step. Resumable: finished photos are recorded in
// admin/scripts/.seed_ai_progress.json, so a crash / re-run skips them.
// Uses SUPABASE_SERVICE_ROLE_KEY from admin/.env.local.

import { createClient } from '@supabase/supabase-js';
import { readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { resolve, extname, join } from 'node:path';
import { randomUUID } from 'node:crypto';

// ── env ─────────────────────────────────────────────────────────────────────
const env = Object.fromEntries(
  readFileSync(resolve(import.meta.dirname, '..', '.env.local'), 'utf8')
    .split('\n').map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#') && l.includes('='))
    .map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }),
);
const URL = env.NEXT_PUBLIC_SUPABASE_URL;
const KEY = env.SUPABASE_SERVICE_ROLE_KEY;
if (!URL || !KEY) throw new Error('Missing Supabase URL / service-role key in admin/.env.local');
const db = createClient(URL, KEY, { auth: { persistSession: false } });
const BUCKET = 'avatars';

const arg = (n) => { const i = process.argv.indexOf(n); return i > -1 ? process.argv[i + 1] : undefined; };
const GO = process.argv.includes('--go');
// --photos <dir>      one folder (searched recursively) instead of homme/ + femme/
// --gender m|f        gender of EVERY photo in --photos (never guessed from the image)
// --countries A,B,C   restrict the random draw to these labels (kCountries names)
const PHOTOS_DIR = arg('--photos');
const ONLY_GENDER = arg('--gender');
const COUNTRY_FILTER = arg('--countries');
// Hard floor: this app does not allow minors. There is deliberately no option to lower it.
const MIN_AGE = 18;
const LIMIT = Number(arg('--limit')) || Infinity;
const CONCURRENCY = 6;
const PROGRESS = resolve(import.meta.dirname, '.seed_ai_progress.json');

// ── orphan cleanup ─────────────────────────────────────────────────────────
// An interrupted run can leave an auth user `ai+…@swayco.test` (and its photo)
// with no profile row. This removes exactly those — never an account that has a profile.
if (process.argv.includes('--clean-orphans')) {
  let removed = 0;
  for (let page = 1; ; page++) {
    const { data, error } = await db.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw error;
    const users = (data?.users ?? []).filter((u) => /^ai\+[0-9a-f-]+@swayco\.test$/.test(u.email ?? ''));
    for (const u of users) {
      const { data: prof } = await db.from('profiles').select('id').eq('id', u.id).maybeSingle();
      if (prof) continue;
      const { data: files } = await db.storage.from(BUCKET).list(`ai/${u.id}`);
      if (files?.length) await db.storage.from(BUCKET).remove(files.map((f) => `ai/${u.id}/${f.name}`));
      await db.auth.admin.deleteUser(u.id).catch(() => {});
      removed++;
    }
    if ((data?.users ?? []).length < 200) break;
  }
  console.log(`removed ${removed} orphan auth user(s).`);
  process.exit(0);
}

// ── delete mode ────────────────────────────────────────────────────────────
if (process.argv.includes('--delete')) {
  let total = 0;
  for (;;) {
    const { data: rows, error } = await db.from('profiles').select('id').eq('is_ai', true).limit(200);
    if (error) throw error;
    if (!rows.length) break;
    for (const { id } of rows) {
      await db.from('profiles').delete().eq('id', id);
      await db.auth.admin.deleteUser(id).catch(() => {});
      const { data: files } = await db.storage.from(BUCKET).list(`ai/${id}`);
      if (files?.length) await db.storage.from(BUCKET).remove(files.map((f) => `ai/${id}/${f.name}`));
      total++;
    }
    console.log(`deleted ${total}…`);
  }
  console.log('done.');
  process.exit(0);
}

// ── countries: one source of truth with the app (lib/services/locations.dart) ─
const dart = readFileSync(resolve(import.meta.dirname, '..', '..', 'lib', 'services', 'locations.dart'), 'utf8');
const APP = {};
for (const m of dart.matchAll(/Country\(name: (['"])(.+?)\1, flag: '[^']*', cities: \[([\s\S]*?)\]\)/g)) {
  APP[m[2]] = [...m[3].matchAll(/'([^']+)'/g)].map((c) => c[1]);
}

// country (exact `kCountries` label) -> profile.language (one of the app's 12).
// Add / remove / repeat lines to change the draw.
const COUNTRIES = {
  'France': 'fr', 'Belgique': 'fr', 'Suisse': 'de', 'Canada': 'en',
  'États-Unis': 'en', 'Royaume-Uni': 'en', 'Irlande': 'en', 'Australie': 'en',
  'Espagne': 'es', 'Mexique': 'es', 'Argentine': 'es', 'Colombie': 'es',
  'Portugal': 'pt', 'Brésil': 'pt', 'Italie': 'it', 'Allemagne': 'de',
  'Pays-Bas': 'nl', 'Russie': 'ru', 'Chine': 'zh', 'Japon': 'ja', 'Corée du Sud': 'ko',
  'Maroc': 'ar', 'Algérie': 'ar', 'Tunisie': 'ar', 'Égypte': 'ar',
  'Arabie Saoudite': 'ar', 'Émirats arabes unis': 'ar',
  'Sénégal': 'fr', "Côte d'Ivoire": 'fr',
  'Philippines': 'en', 'Suède': 'en', 'Inde': 'en', // Filipino is not one of the app's 12 languages: English profile
};

// Names that follow the COUNTRY rather than the language (English is spoken in
// several countries with different naming habits).
const NAMES_BY_COUNTRY = {
  Suède: { m: ['Lucas','Liam','Oscar','William','Hugo','Elias','Noah','Axel','Oliver','Viktor','Erik','Filip','Leo','Isak','Anton','Alvin','Melvin','Casper','Gustav','Albin'], f: ['Emma','Alice','Maja','Ella','Wilma','Elsa','Saga','Astrid','Freja','Ebba','Selma','Alma','Klara','Linnea','Stella','Agnes','Signe','Tilda','Vera','Moa','Julia','Lovisa','Elin','Sofia','Hanna','Emelie','Matilda','Ida','Amanda','Filippa','Ingrid','Nora','Josefin','Frida','Cecilia','Johanna'] },
  Inde: { m: ['Aarav','Vihaan','Arjun','Rohan','Kabir','Ishaan','Aditya','Rahul','Karan','Neil','Dev','Nikhil','Sahil','Yash','Veer'], f: ['Priya','Ananya','Aisha','Diya','Isha','Kavya','Meera','Neha','Pooja','Riya','Sanya','Tanvi','Aditi','Anjali','Divya','Kritika','Nisha','Pari','Shreya','Simran','Sneha','Tara','Vani','Zoya','Aarohi','Ishita','Mahi','Naina','Radhika','Sakshi','Trisha','Yashika','Avni','Bhavya','Charvi','Dhriti','Esha','Gauri','Jhanvi','Mansi'] },
  Philippines: {
    m: ['John Paul', 'Mark', 'Paolo', 'Miguel', 'Carlo', 'Joshua', 'Angelo', 'Jerome', 'Kenneth', 'Rafael', 'Gabriel', 'Nathan', 'Dominic', 'Francis', 'Jericho'],
    f: ['Angelica', 'Jasmine', 'Kristine', 'Rhea', 'Marianne', 'Princess', 'Mikaela', 'Bea', 'Kathleen', 'Trisha', 'Camille', 'Nicole', 'Joanna', 'Patricia', 'Andrea',
        'Janine', 'Sheena', 'Charmaine', 'Lovely', 'Shaira', 'Aira', 'Czarina', 'Denise', 'Erika', 'Gwen', 'Kyla', 'Maureen', 'Nadine', 'Pia', 'Queenie',
        'Rica', 'Samantha', 'Tricia', 'Yna', 'Zara', 'Alyssa', 'Bianca', 'Hazel', 'Jocelyn', 'Mariel'] },
};
for (const c of Object.keys(COUNTRIES)) {
  if (!APP[c]?.length) throw new Error(`COUNTRIES has "${c}" which is not in kCountries (or has no city)`);
}
const POOL = COUNTRY_FILTER
  ? COUNTRY_FILTER.split(',').map((c) => c.trim()).filter(Boolean)
  : Object.keys(COUNTRIES);
for (const c of POOL) {
  if (!COUNTRIES[c]) throw new Error(`--countries: "${c}" is not in COUNTRIES`);
}

// ── names per language (m / f) ─────────────────────────────────────────────
const NAMES = {
  fr: { m: ['Lucas', 'Hugo', 'Nathan', 'Léo', 'Enzo', 'Théo', 'Noah', 'Gabriel', 'Raphaël', 'Ethan', 'Maxime', 'Karim', 'Yanis', 'Amadou', 'Ibrahim'],
        f: ['Camille', 'Léa', 'Manon', 'Chloé', 'Inès', 'Jade', 'Louane', 'Sarah', 'Emma', 'Lina', 'Maëlle', 'Aïcha', 'Fatou', 'Mariam', 'Nina'] },
  en: { m: ['Liam', 'Noah', 'Ethan', 'Mason', 'Jack', 'Owen', 'Caleb', 'Ryan', 'Dylan', 'Jordan', 'Marcus', 'Tyler', 'Connor', 'Aaron', 'Isaac'],
        f: ['Emma', 'Olivia', 'Ava', 'Mia', 'Chloe', 'Grace', 'Ella', 'Zoe', 'Hannah', 'Maya', 'Aaliyah', 'Naomi', 'Lily', 'Nora', 'Ruby'] },
  de: { m: ['Ben', 'Paul', 'Jonas', 'Luca', 'Finn', 'Elias', 'Jan', 'Felix', 'Maximilian', 'Tim', 'Noah', 'Leon', 'David', 'Emil', 'Jonathan'],
        f: ['Mia', 'Hannah', 'Emilia', 'Lina', 'Lena', 'Marie', 'Sophie', 'Clara', 'Leonie', 'Nele', 'Amelie', 'Lara', 'Johanna', 'Ida', 'Greta'] },
  es: { m: ['Mateo', 'Diego', 'Daniel', 'Pablo', 'Álvaro', 'Hugo', 'Adrián', 'Sergio', 'Javier', 'Iván', 'Marcos', 'Andrés', 'Nicolás', 'Santiago', 'Rubén', 'Sebastián', 'Matías', 'Emiliano', 'Joaquín', 'Thiago', 'Leonardo', 'Maximiliano', 'Alejandro', 'Gael', 'Bruno', 'Facundo', 'Tomás', 'Esteban', 'Camilo', 'Cristian', 'Julián', 'Leandro', 'Ángel', 'Fabián', 'Ricardo', 'Damián', 'Ezequiel'],
        f: ['Lucía', 'Sofía', 'Valeria', 'Paula', 'Carla', 'Elena', 'Marta', 'Irene', 'Andrea', 'Daniela', 'Camila', 'Julia', 'Nuria', 'Alba', 'Sara',
            'Valentina', 'Isabella', 'Mariana', 'Luciana', 'Renata', 'Ximena', 'Fernanda', 'Gabriela', 'Natalia', 'Carolina', 'Juliana', 'Mía', 'Emilia', 'Agustina',
            'Catalina', 'Antonella', 'Martina', 'Florencia', 'Regina', 'Montserrat', 'Jimena', 'Paola', 'Julieta', 'Abril', 'Milagros', 'Alejandra', 'Victoria', 'Romina'] },
  pt: { m: ['João', 'Pedro', 'Rafael', 'Gabriel', 'Tiago', 'Lucas', 'Bruno', 'Diogo', 'Mateus', 'Gustavo', 'Felipe', 'André', 'Rodrigo', 'Vinícius', 'Caio', 'Davi', 'Arthur', 'Heitor', 'Bernardo', 'Enzo', 'Murilo', 'Henrique', 'Leonardo', 'Thiago', 'Guilherme', 'Eduardo', 'Samuel', 'Otávio', 'Matheus', 'Igor', 'Ryan', 'Luan', 'Wesley'],
        f: ['Maria', 'Beatriz', 'Ana', 'Inês', 'Mariana', 'Carolina', 'Juliana', 'Larissa', 'Bianca', 'Letícia', 'Sofia', 'Camila', 'Rita', 'Luana', 'Isabela',
            'Amanda', 'Fernanda', 'Gabriela', 'Thaís', 'Rafaela', 'Natália', 'Bruna', 'Vitória', 'Aline', 'Sabrina', 'Lorena', 'Yasmin', 'Nicole', 'Eduarda',
            'Marina', 'Giovana', 'Raquel', 'Lívia', 'Helena', 'Alice', 'Manuela', 'Clara', 'Laís', 'Patrícia', 'Tainá'] },
  it: { m: ['Marco', 'Luca', 'Matteo', 'Francesco', 'Alessandro', 'Davide', 'Lorenzo', 'Andrea', 'Simone', 'Federico', 'Giacomo', 'Riccardo', 'Tommaso', 'Nicolò', 'Gabriele'],
        f: ['Giulia', 'Sofia', 'Chiara', 'Martina', 'Sara', 'Elisa', 'Alice', 'Francesca', 'Aurora', 'Giorgia', 'Beatrice', 'Valentina', 'Elena', 'Ginevra', 'Noemi'] },
  nl: { m: ['Daan', 'Sem', 'Lars', 'Tim', 'Jesse', 'Thijs', 'Bram', 'Ruben', 'Milan', 'Luuk', 'Jens', 'Stijn', 'Niels', 'Sven', 'Koen'],
        f: ['Emma', 'Sanne', 'Lotte', 'Fleur', 'Eva', 'Julia', 'Anouk', 'Noor', 'Isa', 'Lieke', 'Femke', 'Maud', 'Esmee', 'Roos', 'Tess'] },
  ru: { m: ['Артём', 'Иван', 'Дмитрий', 'Максим', 'Никита', 'Егор', 'Кирилл', 'Андрей', 'Илья', 'Матвей', 'Сергей', 'Данила', 'Роман', 'Тимур', 'Павел'],
        f: ['Анастасия', 'Мария', 'Анна', 'Виктория', 'Полина', 'Софья', 'Дарья', 'Алиса', 'Ксения', 'Елена', 'Ева', 'Милана', 'Варвара', 'Ульяна', 'Алина'] },
  zh: { m: ['浩然', '子轩', '宇航', '俊杰', '博文', '明轩', '志远', '天宇', '家豪', '梓睿', '思远', '嘉诚', '泽宇', '文博', '逸凡'],
        f: ['欣怡', '子涵', '梓萱', '雨桐', '诗涵', '佳琪', '思颖', '雅婷', '梦琪', '可馨', '语嫣', '静怡', '婉清', '晓彤', '若曦'] },
  ja: { m: ['蓮', '大翔', '陽翔', '湊', '悠真', '颯太', '樹', '翔', '拓海', '健太', '亮', '隼人', '直樹', '駿', '大地'],
        f: ['葵', '凛', '陽葵', '結衣', '美咲', '花', '莉子', '紬', '愛', '彩', '美月', 'さくら', '遥', '真央', '詩織'] },
  ko: { m: ['민준', '서준', '도윤', '시우', '지호', '준서', '현우', '지훈', '건우', '우진', '태민', '승현', '재윤', '동현', '성민'],
        f: ['서연', '지우', '하은', '수아', '다은', '예은', '지민', '서윤', '채원', '유진', '소율', '민서', '하윤', '지안', '은서'] },
  ar: { m: ['يوسف', 'أمين', 'كريم', 'مهدي', 'إلياس', 'ياسين', 'أنس', 'زكريا', 'عمر', 'بلال', 'سامي', 'رياض', 'هشام', 'طارق', 'نبيل'],
        f: ['ياسمين', 'سلمى', 'ليلى', 'نور', 'مريم', 'هدى', 'إيمان', 'سارة', 'دينا', 'لينا', 'ريم', 'أميرة', 'فاطمة', 'جنى', 'رانيا'] },
};

// ── content pools (generic: no national clichés) ───────────────────────────
const rnd = (a) => a[Math.floor(Math.random() * a.length)];
const sample = (a, n) => { const c = [...a], o = []; while (o.length < n && c.length) o.push(c.splice(Math.floor(Math.random() * c.length), 1)[0]); return o; };
const JOBS = ['Étudiant', 'Tech', 'Sport & Divertissement', 'Art & Création', 'Commerce', 'Restauration', 'Médical', 'Ingénierie', 'Droit & Finance', 'Éducation', 'Service public'];
const LOOKING = ['Amitié', 'Pratiquer une langue', 'Faire des activités ensemble', 'Trouver des gamers', 'Du fun', 'Networking', 'Voyager / rencontrer des locaux', 'Une relation'];
const ZODIAC = ['Bélier', 'Taureau', 'Gémeaux', 'Cancer', 'Lion', 'Vierge', 'Balance', 'Scorpion', 'Sagittaire', 'Capricorne', 'Verseau', 'Poissons'];
const PERSONAS = ['Sportif', 'Gamer', 'Mélomane', 'Voyageur', 'Cinéphile', 'Gourmet', 'Fitness', 'Créatif', 'Fashion', 'Curieux', 'Tech', 'Nature', 'Fêtard'];
const INTERESTS = ['Football', 'Basketball', 'Tennis', 'Musculation', 'Rap', 'K-pop', 'Rock', 'Anime', 'Cinéma', 'Séries', 'Cuisine', 'Café', 'Voyage', 'Randonnée', 'Gaming', 'PlayStation', 'Nintendo', 'Mode', 'Photographie', 'Musique'];
const age = () => MIN_AGE + Math.floor(Math.random() * 8); // 18..25 — never a minor
const heightCm = (g) => (g === 'f' ? 153 + Math.floor(Math.random() * 22) : 165 + Math.floor(Math.random() * 25));

// Bios (<= 80 chars: profileBioMaxLength). Concrete and light — no national clichés.
const BIOS = {
  fr: [
    'Je ris à mes blagues avant de les finir.',
    'Un café d’abord, la conversation ensuite.',
    'Mon chat me juge tous les jours. Viens m’aider.',
    'J’apprends des langues pour comprendre les memes des autres pays.',
    'Je cuisine deux plats et je les répète sans honte.',
    'Dimanche idéal : plaid, série, zéro programme.',
    'Toujours en retard, mais avec une bonne playlist.',
    'Je cherche des gens pour parler de tout et de rien.',
    'Je photographie les couchers de soleil et la bouffe, dans cet ordre.',
    'Plus à l’aise par message que par téléphone, je préviens.',
    'Étudiante le jour, curieuse la nuit.',
    'Je collectionne des carnets que je ne finis jamais.',
    'J’ai des avis tranchés sur le chocolat chaud.',
    'Je me perds même avec le GPS. C’est un talent.',
    'Je pratique ta langue si tu pratiques la mienne.',
    'Salle le lundi et le mercredi, canapé le reste du temps.',
    'Dis-moi ta chanson du moment, je te dis qui tu es.',
    'Peu de drames, beaucoup de curiosité pour les nouvelles personnes.',
    'Voyager, c’est mon excuse pour goûter des trucs bizarres.',
    'Je me fais des amis partout, sauf à la salle.',
  ],
  de: [
    'Ich lache über meine Witze, bevor ich sie zu Ende erzählt habe.',
    'Erst Kaffee, dann Gespräch.',
    'Meine Katze beurteilt mich täglich. Komm, hilf mir.',
    'Ich lerne Sprachen, um die Memes anderer Länder zu verstehen.',
    'Ich kann zwei Gerichte kochen und wiederhole sie ohne Scham.',
    'Perfekter Sonntag: Decke, Serie, null Pläne.',
    'Immer zu spät, aber mit guter Playlist.',
    'Suche Leute zum Reden über alles und nichts.',
    'Ich fotografiere Sonnenuntergänge und Essen, in dieser Reihenfolge.',
    'Per Nachricht besser als am Telefon, nur zur Warnung.',
    'Tagsüber Studentin, nachts neugierig.',
    'Ich sammle Notizbücher, die ich nie vollschreibe.',
    'Ich habe starke Meinungen zu heißer Schokolade.',
    'Ich verlaufe mich sogar mit Navi. Ein Talent.',
    'Ich übe deine Sprache, wenn du meine übst.',
    'Montag und Mittwoch Fitnessstudio, sonst Sofa.',
    'Sag mir dein Lied des Moments, ich sag dir, wer du bist.',
    'Wenig Drama, viel Neugier auf neue Leute.',
    'Reisen ist meine Ausrede, seltsames Essen zu probieren.',
    'Ich finde überall Freunde, außer im Fitnessstudio.',
  ],
  it: [
    'Rido alle mie battute prima di finirle.',
    'Prima il caffè, poi la conversazione.',
    'Il mio gatto mi giudica ogni giorno. Vieni ad aiutarmi.',
    'Imparo le lingue per capire i meme degli altri paesi.',
    'So cucinare due piatti e li ripeto senza vergogna.',
    'Domenica ideale: coperta, serie tv, zero programmi.',
    'Sempre in ritardo, ma con una bella playlist.',
    'Cerco persone con cui parlare di tutto e di niente.',
    'Fotografo tramonti e cibo, in quest’ordine.',
    'Meglio per messaggio che al telefono, ti avviso.',
    'Studentessa di giorno, curiosa di notte.',
    'Colleziono quaderni che non finisco mai.',
    'Ho opinioni forti sulla cioccolata calda.',
    'Mi perdo anche con il navigatore. Un talento.',
    'Pratico la tua lingua se tu pratichi la mia.',
    'Palestra lunedì e mercoledì, il resto divano.',
    'Dimmi la tua canzone del momento e ti dico chi sei.',
    'Poco dramma, tanta curiosità per le persone nuove.',
    'Viaggiare è la mia scusa per assaggiare cose strane.',
    'Faccio amicizia ovunque, tranne in palestra.',
  ],
  ja: [
    '自分の冗談で先に笑っちゃうタイプです。',
    'まずコーヒー、話はそれから。',
    '猫に毎日ダメ出しされています。',
    '他の国のミームを理解したくて語学を勉強中。',
    '得意料理は2品。堂々とリピートします。',
    '理想の日曜日：毛布、ドラマ、予定なし。',
    'いつも遅刻するけど、プレイリストだけは自信あり。',
    '何でもない話を一緒にしてくれる人を探しています。',
    '夕焼けとごはんの写真ばかり撮っています。',
    '電話より、メッセージのほうが得意です。',
    '昼は学生、夜は好奇心のかたまり。',
    '使い切れないノートを集めています。',
    'ココアにはちょっとうるさいです。',
    'ナビを見ても迷子になる才能があります。',
    'あなたの言葉を教えてくれたら、私の言葉も教えます。',
    'ジムは月曜と水曜、あとはソファ。',
    '今の気分の曲を教えて。どんな人か当ててみる。',
    'ドラマは少なめ、好奇心は多め。',
    '旅行は、変わったものを食べる口実です。',
    'どこでも友達ができるのに、ジムだけは別。',
  ],
  ko: [
    '제 농담에 제가 먼저 웃는 편이에요.',
    '커피 먼저, 대화는 그다음.',
    '고양이가 매일 저를 평가해요. 같이 변호해 주세요.',
    '다른 나라 밈을 이해하려고 언어를 배워요.',
    '잘하는 요리는 두 가지, 당당하게 반복해요.',
    '완벽한 일요일: 담요, 드라마, 계획 없음.',
    '늘 지각하지만 플레이리스트는 좋아요.',
    '별것 아닌 이야기도 같이 나눌 사람을 찾아요.',
    '노을과 음식 사진을 제일 많이 찍어요.',
    '전화보다 메시지가 훨씬 편해요.',
    '낮에는 학생, 밤에는 호기심 대장.',
    '다 못 채운 노트를 모으는 취미가 있어요.',
    '핫초코에 대해선 의견이 확고해요.',
    '내비를 켜도 길을 잃는 재능이 있어요.',
    '당신 언어를 알려주면 제 언어도 알려드릴게요.',
    '헬스는 월·수, 나머지는 소파.',
    '요즘 꽂힌 노래를 말해 주면 어떤 사람인지 맞혀볼게요.',
    '드라마는 적게, 호기심은 많이.',
    '여행은 이상한 음식을 먹기 위한 핑계예요.',
    '어디서든 친구를 사귀는데 헬스장만 예외.',
  ],
  en: [
    'I laugh at my own jokes before I finish them.',
    'Coffee first, conversation second.',
    'My cat judges me daily. Come defend me.',
    "I learn languages to understand other countries' memes.",
    'I can cook two dishes and I repeat them shamelessly.',
    'Ideal Sunday: blanket, series, zero plans.',
    'Always late, but with a good playlist.',
    'Looking for people to talk about everything and nothing.',
    'I photograph sunsets and food, in that order.',
    'Better by text than by call, fair warning.',
    'Student by day, curious by night.',
    'I collect notebooks I never finish.',
    'Strong opinions about hot chocolate.',
    "I get lost with GPS on. It's a talent.",
    "I'll practice your language if you practice mine.",
    'Gym Monday and Wednesday; the rest is couch.',
    "Tell me your song of the moment and I'll tell you who you are.",
    'Low drama, big curiosity about new people.',
    'Travel is my excuse to eat strange things.',
    'I make friends everywhere except the gym.',
  ],
  es: [
    'Me río de mis propios chistes antes de terminarlos.',
    'Si me invitas a un café, ya tienes media amistad.',
    'Mi gato me juzga todos los días. Ven a defenderme.',
    'Aprendo idiomas para entender los memes de otros países.',
    'Cocino bien dos platos y los repito sin vergüenza.',
    'Domingo ideal: manta, serie y cero planes.',
    'Siempre llego tarde, pero con buena playlist.',
    'Busco gente con quien hablar de todo y de nada.',
    'Fotógrafa de atardeceres y de comida, en ese orden.',
    'Mejor por escrito que por llamada, avisado.',
    'Estudio de día, curiosa de noche.',
    'Colecciono libretas que nunca termino de llenar.',
    'Tengo opiniones fuertes sobre el chocolate caliente.',
    'Me pierdo con el GPS puesto. Es un talento.',
    'Practico inglés contigo si me enseñas tu idioma.',
    'Gym lunes y miércoles; el resto del tiempo, sofá.',
    'Dime tu canción del momento y te digo quién eres.',
    'Hago amigos en todos lados, menos en el gimnasio.',
    'Poco drama, muchas ganas de conocer gente nueva.',
    'Viajar es mi excusa para comer cosas raras.',
  ],
  pt: [
    'Rio das minhas próprias piadas antes de terminar.',
    'Me convida pra um café e já ganhou meia amizade.',
    'Meu gato me julga todo dia. Vem me defender.',
    'Aprendo idiomas pra entender os memes de outros países.',
    'Cozinho bem dois pratos e repito sem vergonha.',
    'Domingo ideal: coberta, série e zero planos.',
    'Sempre atrasada, mas com playlist boa.',
    'Procuro gente pra conversar sobre tudo e nada.',
    'Fotografo pôr do sol e comida, nessa ordem.',
    'Sou melhor por mensagem do que por ligação, aviso.',
    'Estudo de dia, curiosa à noite.',
    'Coleciono cadernos que nunca termino de preencher.',
    'Tenho opiniões fortes sobre chocolate quente.',
    'Me perco com o GPS ligado. É um talento.',
    'Pratico inglês contigo se me ensinar seu idioma.',
    'Academia segunda e quarta; o resto do tempo, sofá.',
    'Me diz a música do momento e eu digo quem você é.',
    'Faço amizade em todo lugar, menos na academia.',
    'Pouco drama, muita vontade de conhecer gente nova.',
    'Viajar é minha desculpa pra comer coisa estranha.',
  ],
};

// Persona = what the chat model knows about the account (table ai_personas).
// Concrete little facts, never a postcard of the country.
const FAMILY = ['an older brother who is a nurse', 'a younger sister still in high school', 'a mom who runs a small shop', 'two close cousins', 'a dad who fixes bikes as a hobby', 'a grandmother who is called every Sunday'];
const QUIRKS = ['runs early two mornings a week and complains about it', 'is learning to play the ukulele badly', 'keeps a plant that almost died twice', 'reads webtoons on the bus', 'has a rescue cat who hates visitors', 'is obsessed with true-crime podcasts', 'collects tiny notebooks', 'is trying to learn Korean from dramas', 'bakes when stressed', 'sketches people on public transport', 'plays pickup volleyball on Saturdays', 'edits short videos for fun'];
const TEXT_STYLE = ['short messages, lowercase, one emoji at most', 'warm and teasing, asks a lot of questions', 'dry humour, understated', 'enthusiastic but never over the top', 'calm and curious, replies with a small story'];
const personaFor = ({ name, a, city, country, job, lookingFor, interests }) =>
  `${name}, ${a}, lives in ${city}, ${country}. Works/studies in: ${job}. Interests: ${interests.join(', ')}. ` +
  `Has ${rnd(FAMILY)}. ${name} ${rnd(QUIRKS)}. Texting style: ${rnd(TEXT_STYLE)}. Here for: ${lookingFor}. ` +
  `Talks about ${name}'s own life with small concrete details, and mostly asks about the other person.`;

// ── photos ─────────────────────────────────────────────────────────────────
const ROOT = arg('--dir') ? resolve(arg('--dir')) : resolve(import.meta.dirname, '..', '..', '..'); // .../Downloads
const pick = (dir, gender) => {
  const d = join(ROOT, dir);
  if (!existsSync(d)) return [];
  return readdirSync(d).filter((f) => /\.(jpe?g|png|webp)$/i.test(f)).sort()
    .map((f) => ({ file: join(d, f), gender }));
};
let all;
if (PHOTOS_DIR) {
  if (ONLY_GENDER !== 'm' && ONLY_GENDER !== 'f') throw new Error('--photos needs --gender m|f (the gender is never read from the images)');
  const d = resolve(PHOTOS_DIR);
  if (!existsSync(d)) throw new Error(`Folder not found: ${d}`);
  all = readdirSync(d, { recursive: true })
    .filter((f) => /\.(jpe?g|png|webp)$/i.test(String(f)))
    .sort()
    .map((f) => ({ file: join(d, String(f)), gender: ONLY_GENDER }));
  if (!all.length) throw new Error(`No photos in ${d}`);
} else {
  all = [...pick('homme', 'm'), ...pick('femme', 'f')];
  if (!all.length) throw new Error(`No photos in ${join(ROOT, 'homme')} / ${join(ROOT, 'femme')}`);
}

const done = new Set(existsSync(PROGRESS) ? JSON.parse(readFileSync(PROGRESS, 'utf8')) : []);
const todo = all.filter((p) => !done.has(p.file)).slice(0, LIMIT);

// Plan: draw every country up front so the dry run shows the real split.
const plan = todo.map((p) => ({ ...p, country: rnd(POOL) }));
const tally = {};
for (const p of plan) tally[p.country] = (tally[p.country] ?? 0) + 1;
console.log(`${all.length} photos found, ${done.size} already done, ${plan.length} to create.`);
console.log(Object.entries(tally).sort((a, b) => b[1] - a[1]).map(([c, n]) => `${c} ${n}`).join(' · '));
if (!GO) {
  console.log('\nDRY RUN — nothing written. Re-run with --go to create these accounts.');
  process.exit(0);
}

// ── optional resize (sharp is only used if installed) ──────────────────────
let sharp = null;
try { sharp = (await import('sharp')).default; } catch { console.warn('sharp not installed — uploading photos as-is.'); }
const prepare = async (file) => {
  const buf = readFileSync(file);
  if (!sharp) {
    const ext = extname(file).toLowerCase() || '.jpg';
    const type = ext === '.png' ? 'image/png' : ext === '.webp' ? 'image/webp' : 'image/jpeg';
    return { buf, type, ext };
  }
  const out = await sharp(buf).rotate().resize({ width: 1080, height: 1440, fit: 'inside', withoutEnlargement: true }).jpeg({ quality: 82 }).toBuffer();
  return { buf: out, type: 'image/jpeg', ext: '.jpg' };
};

// ── create ─────────────────────────────────────────────────────────────────
let ok = 0, fail = 0, idx = 0;
const save = () => writeFileSync(PROGRESS, JSON.stringify([...done]));

async function one(p) {
  const lang = COUNTRIES[p.country];
  const cu = await db.auth.admin.createUser({
    email: `ai+${randomUUID().slice(0, 12)}@swayco.test`,
    password: randomUUID(),
    email_confirm: true,
    user_metadata: { ai: true },
  });
  if (cu.error) throw new Error(`auth: ${cu.error.message}`);
  const id = cu.data.user.id;
  let key;
  try {
    const { buf, type, ext } = await prepare(p.file);
    key = `ai/${id}/pdp${ext}`;
    const up = await db.storage.from(BUCKET).upload(key, buf, { contentType: type, upsert: true });
    if (up.error) throw new Error(`upload: ${up.error.message}`);
    const url = db.storage.from(BUCKET).getPublicUrl(key).data.publicUrl;
    const names = NAMES_BY_COUNTRY[p.country] ?? NAMES[lang] ?? NAMES.en;
    const name = rnd(names[p.gender]);
    const a = age();
    if (a < MIN_AGE) throw new Error('refusing to create a profile under 18');
    const city = rnd(APP[p.country]);
    const job = rnd(JOBS);
    const lookingFor = rnd(LOOKING);
    const interests = sample(INTERESTS, 3 + Math.floor(Math.random() * 3));
    const bioPool = BIOS[lang];
    const bioOk = bioPool && p.gender === 'm' ? bioPool.filter((b) => !/(Fotógrafa|curiosa|atrasada|Étudiante|curieuse|Studentin|Studentessa)/.test(b)) : bioPool;
    const ins = await db.from('profiles').insert({
      id,
      // Même règle que les vrais comptes (jamais de « ai_ » visible) : prénom a-z0-9 + 6 derniers caractères de l'id.
      handle: `${String(name).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '').slice(0, 24) || 'user'}-${id.replace(/-/g, '').slice(-6)}`,
      display_name: name,
      language: lang,
      country: p.country,
      city,
      gender: p.gender,
      age: a,
      height_cm: heightCm(p.gender),
      job,
      zodiac: rnd(ZODIAC),
      looking_for: lookingFor,
      persona_category: rnd(PERSONAS),
      interests,
      ...(bioOk && bioOk.length ? { bio: rnd(bioOk) } : {}),
      avatar_url: url,
      discover_photo_url: url,
      photos: [url],
      is_ai: true,
      updated_at: new Date().toISOString(),
    });
    if (ins.error) throw new Error(`insert: ${ins.error.message}`);
    // The chat persona (table ai_personas, migration 0064). Not fatal if it fails:
    // the responder falls back to a persona built from the profile fields.
    const per = await db.from('ai_personas').insert({
      user_id: id,
      persona: personaFor({ name, a, city, country: p.country, job, lookingFor, interests }),
    });
    if (per.error) console.warn(`persona ${name}: ${per.error.message}`);
  } catch (e) {
    if (key) await db.storage.from(BUCKET).remove([key]).catch(() => {});
    await db.auth.admin.deleteUser(id).catch(() => {});
    throw e;
  }
}
const APP_ISO = (c) => c.normalize('NFD').replace(/[^a-zA-Z]/g, '').slice(0, 3).toLowerCase();

let halt = false; // fatal config error: let in-flight accounts clean up, start no new ones
async function worker() {
  while (!halt && idx < plan.length) {
    const p = plan[idx++];
    try {
      await one(p);
      done.add(p.file); ok++;
      if (ok % 25 === 0) { save(); console.log(`✓ ${ok}/${plan.length}`); }
    } catch (e) {
      fail++;
      console.error(`✗ ${p.file.split(/[\\/]/).pop()} (${p.country}): ${e.message}`);
      if (/is_ai|ai_personas|height_cm/.test(e.message) && /column|schema cache|relation/.test(e.message)) {
        halt = true;
        console.error('Schema missing (migration 0064 not applied?) — stopping after in-flight accounts clean up.');
      }
    }
  }
}
await Promise.all(Array.from({ length: CONCURRENCY }, worker));
save();
if (halt) process.exit(1);
console.log(`\n${ok} created, ${fail} failed.`);
