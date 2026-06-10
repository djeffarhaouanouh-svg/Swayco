import 'app_strings.dart';

/// Display translations for interest category names and tags.
///
/// The profile stores the FRENCH label as the stable key (so existing data and
/// interest matching keep working regardless of the viewer's language); this
/// map only localises what is shown on screen. Keys are the exact French labels
/// from `interests.dart`. Missing entries fall back to the French key, and the
/// `fr` locale always returns the key verbatim (no entry needed).
const Map<String, Map<String, String>> _kInterestI18n = {
  // ─── Japan — categories ───────────────────────────────────────────────────
  'Manga & Anime': {
    'en': 'Manga & Anime', 'es': 'Manga y anime', 'de': 'Manga & Anime',
    'it': 'Manga e anime', 'pt': 'Mangá e anime', 'nl': 'Manga & anime',
    'ar': 'المانغا والأنمي', 'ru': 'Манга и аниме', 'zh': '漫画与动漫',
    'ja': '漫画・アニメ', 'ko': '만화 & 애니메이션',
  },
  'Cuisine': {
    'en': 'Food', 'es': 'Gastronomía', 'de': 'Küche', 'it': 'Cucina',
    'pt': 'Gastronomia', 'nl': 'Keuken', 'ar': 'المطبخ', 'ru': 'Кухня',
    'zh': '美食', 'ja': '料理', 'ko': '음식',
  },
  'Traditions': {
    'en': 'Traditions', 'es': 'Tradiciones', 'de': 'Traditionen',
    'it': 'Tradizioni', 'pt': 'Tradições', 'nl': 'Tradities',
    'ar': 'التقاليد', 'ru': 'Традиции', 'zh': '传统', 'ja': '伝統',
    'ko': '전통',
  },
  'Pop & Tech': {
    'en': 'Pop & Tech', 'es': 'Pop y tecnología', 'de': 'Pop & Technik',
    'it': 'Pop e tech', 'pt': 'Pop e tecnologia', 'nl': 'Pop & tech',
    'ar': 'البوب والتقنية', 'ru': 'Поп и технологии', 'zh': '流行与科技',
    'ja': 'ポップ＆テック', 'ko': '팝 & 테크',
  },
  'Voyage & Nature': {
    'en': 'Travel & Nature', 'es': 'Viajes y naturaleza',
    'de': 'Reisen & Natur', 'it': 'Viaggi e natura', 'pt': 'Viagem e natureza',
    'nl': 'Reizen & natuur', 'ar': 'السفر والطبيعة',
    'ru': 'Путешествия и природа', 'zh': '旅行与自然', 'ja': '旅行・自然',
    'ko': '여행 & 자연',
  },

  // ─── Japan — tags ─────────────────────────────────────────────────────────
  'Manga': {
    'en': 'Manga', 'es': 'Manga', 'de': 'Manga', 'it': 'Manga', 'pt': 'Mangá',
    'nl': 'Manga', 'ar': 'مانغا', 'ru': 'Манга', 'zh': '漫画', 'ja': '漫画',
    'ko': '만화',
  },
  'Anime': {
    'en': 'Anime', 'es': 'Anime', 'de': 'Anime', 'it': 'Anime', 'pt': 'Anime',
    'nl': 'Anime', 'ar': 'أنمي', 'ru': 'Аниме', 'zh': '动漫', 'ja': 'アニメ',
    'ko': '애니메이션',
  },
  'Studio Ghibli': {
    'en': 'Studio Ghibli', 'es': 'Studio Ghibli', 'de': 'Studio Ghibli',
    'it': 'Studio Ghibli', 'pt': 'Studio Ghibli', 'nl': 'Studio Ghibli',
    'ar': 'استوديو غيبلي', 'ru': 'Студия Гибли', 'zh': '吉卜力工作室',
    'ja': 'スタジオジブリ', 'ko': '스튜디오 지브리',
  },
  'One Piece': {
    'en': 'One Piece', 'es': 'One Piece', 'de': 'One Piece', 'it': 'One Piece',
    'pt': 'One Piece', 'nl': 'One Piece', 'ar': 'ون بيس', 'ru': 'Ван-Пис',
    'zh': '海贼王', 'ja': 'ワンピース', 'ko': '원피스',
  },
  'Naruto': {
    'en': 'Naruto', 'es': 'Naruto', 'de': 'Naruto', 'it': 'Naruto',
    'pt': 'Naruto', 'nl': 'Naruto', 'ar': 'ناروتو', 'ru': 'Наруто',
    'zh': '火影忍者', 'ja': 'ナルト', 'ko': '나루토',
  },
  'Dragon Ball': {
    'en': 'Dragon Ball', 'es': 'Dragon Ball', 'de': 'Dragon Ball',
    'it': 'Dragon Ball', 'pt': 'Dragon Ball', 'nl': 'Dragon Ball',
    'ar': 'دراغون بول', 'ru': 'Драгонболл', 'zh': '龙珠',
    'ja': 'ドラゴンボール', 'ko': '드래곤볼',
  },
  'Demon Slayer': {
    'en': 'Demon Slayer', 'es': 'Demon Slayer', 'de': 'Demon Slayer',
    'it': 'Demon Slayer', 'pt': 'Demon Slayer', 'nl': 'Demon Slayer',
    'ar': 'قاتل الشياطين', 'ru': 'Клинок, рассекающий демонов',
    'zh': '鬼灭之刃', 'ja': '鬼滅の刃', 'ko': '귀멸의 칼날',
  },
  'Cosplay': {
    'en': 'Cosplay', 'es': 'Cosplay', 'de': 'Cosplay', 'it': 'Cosplay',
    'pt': 'Cosplay', 'nl': 'Cosplay', 'ar': 'كوسبلاي', 'ru': 'Косплей',
    'zh': '角色扮演', 'ja': 'コスプレ', 'ko': '코스프레',
  },
  'Sushi': {
    'en': 'Sushi', 'es': 'Sushi', 'de': 'Sushi', 'it': 'Sushi', 'pt': 'Sushi',
    'nl': 'Sushi', 'ar': 'سوشي', 'ru': 'Суши', 'zh': '寿司', 'ja': '寿司',
    'ko': '스시',
  },
  'Ramen': {
    'en': 'Ramen', 'es': 'Ramen', 'de': 'Ramen', 'it': 'Ramen', 'pt': 'Ramen',
    'nl': 'Ramen', 'ar': 'رامن', 'ru': 'Рамен', 'zh': '拉面', 'ja': 'ラーメン',
    'ko': '라멘',
  },
  'Mochi': {
    'en': 'Mochi', 'es': 'Mochi', 'de': 'Mochi', 'it': 'Mochi', 'pt': 'Mochi',
    'nl': 'Mochi', 'ar': 'موتشي', 'ru': 'Моти', 'zh': '麻糬', 'ja': '餅',
    'ko': '모찌',
  },
  'Takoyaki': {
    'en': 'Takoyaki', 'es': 'Takoyaki', 'de': 'Takoyaki', 'it': 'Takoyaki',
    'pt': 'Takoyaki', 'nl': 'Takoyaki', 'ar': 'تاكوياكي', 'ru': 'Такояки',
    'zh': '章鱼烧', 'ja': 'たこ焼き', 'ko': '타코야키',
  },
  'Matcha': {
    'en': 'Matcha', 'es': 'Matcha', 'de': 'Matcha', 'it': 'Matcha',
    'pt': 'Matcha', 'nl': 'Matcha', 'ar': 'ماتشا', 'ru': 'Матча',
    'zh': '抹茶', 'ja': '抹茶', 'ko': '말차',
  },
  'Wagyū': {
    'en': 'Wagyū', 'es': 'Wagyū', 'de': 'Wagyū', 'it': 'Wagyū', 'pt': 'Wagyū',
    'nl': 'Wagyū', 'ar': 'واغيو', 'ru': 'Вагю', 'zh': '和牛', 'ja': '和牛',
    'ko': '와규',
  },
  'Tempura': {
    'en': 'Tempura', 'es': 'Tempura', 'de': 'Tempura', 'it': 'Tempura',
    'pt': 'Tempura', 'nl': 'Tempura', 'ar': 'تمبورا', 'ru': 'Темпура',
    'zh': '天妇罗', 'ja': '天ぷら', 'ko': '덴푸라',
  },
  'Okonomiyaki': {
    'en': 'Okonomiyaki', 'es': 'Okonomiyaki', 'de': 'Okonomiyaki',
    'it': 'Okonomiyaki', 'pt': 'Okonomiyaki', 'nl': 'Okonomiyaki',
    'ar': 'أوكونومياكي', 'ru': 'Окономияки', 'zh': '御好烧',
    'ja': 'お好み焼き', 'ko': '오코노미야키',
  },
  'Samouraïs': {
    'en': 'Samurai', 'es': 'Samuráis', 'de': 'Samurai', 'it': 'Samurai',
    'pt': 'Samurais', 'nl': 'Samoerai', 'ar': 'الساموراي', 'ru': 'Самураи',
    'zh': '武士', 'ja': '侍', 'ko': '사무라이',
  },
  'Ninjas': {
    'en': 'Ninjas', 'es': 'Ninjas', 'de': 'Ninjas', 'it': 'Ninja',
    'pt': 'Ninjas', 'nl': "Ninja's", 'ar': 'النينجا', 'ru': 'Ниндзя',
    'zh': '忍者', 'ja': '忍者', 'ko': '닌자',
  },
  'Geishas': {
    'en': 'Geishas', 'es': 'Geishas', 'de': 'Geishas', 'it': 'Geishe',
    'pt': 'Gueixas', 'nl': "Geisha's", 'ar': 'الغايشا', 'ru': 'Гейши',
    'zh': '艺伎', 'ja': '芸者', 'ko': '게이샤',
  },
  'Sakura': {
    'en': 'Cherry blossoms', 'es': 'Sakura', 'de': 'Kirschblüte',
    'it': 'Sakura', 'pt': 'Sakura', 'nl': 'Sakura', 'ar': 'أزهار الكرز',
    'ru': 'Сакура', 'zh': '樱花', 'ja': '桜', 'ko': '벚꽃',
  },
  'Onsen': {
    'en': 'Onsen', 'es': 'Onsen', 'de': 'Onsen', 'it': 'Onsen', 'pt': 'Onsen',
    'nl': 'Onsen', 'ar': 'أونسن', 'ru': 'Онсэн', 'zh': '温泉', 'ja': '温泉',
    'ko': '온천',
  },
  'Kimono': {
    'en': 'Kimono', 'es': 'Kimono', 'de': 'Kimono', 'it': 'Kimono',
    'pt': 'Quimono', 'nl': 'Kimono', 'ar': 'كيمونو', 'ru': 'Кимоно',
    'zh': '和服', 'ja': '着物', 'ko': '기모노',
  },
  'Sumo': {
    'en': 'Sumo', 'es': 'Sumo', 'de': 'Sumo', 'it': 'Sumo', 'pt': 'Sumô',
    'nl': 'Sumo', 'ar': 'سومو', 'ru': 'Сумо', 'zh': '相扑', 'ja': '相撲',
    'ko': '스모',
  },
  'Temples': {
    'en': 'Temples', 'es': 'Templos', 'de': 'Tempel', 'it': 'Templi',
    'pt': 'Templos', 'nl': 'Tempels', 'ar': 'المعابد', 'ru': 'Храмы',
    'zh': '寺庙', 'ja': '寺院', 'ko': '사원',
  },
  'Nintendo': {
    'en': 'Nintendo', 'es': 'Nintendo', 'de': 'Nintendo', 'it': 'Nintendo',
    'pt': 'Nintendo', 'nl': 'Nintendo', 'ar': 'نينتندو', 'ru': 'Nintendo',
    'zh': '任天堂', 'ja': '任天堂', 'ko': '닌텐도',
  },
  'Pokémon': {
    'en': 'Pokémon', 'es': 'Pokémon', 'de': 'Pokémon', 'it': 'Pokémon',
    'pt': 'Pokémon', 'nl': 'Pokémon', 'ar': 'بوكيمون', 'ru': 'Покемон',
    'zh': '宝可梦', 'ja': 'ポケモン', 'ko': '포켓몬',
  },
  'J-pop': {
    'en': 'J-pop', 'es': 'J-pop', 'de': 'J-pop', 'it': 'J-pop', 'pt': 'J-pop',
    'nl': 'J-pop', 'ar': 'جيه-بوب', 'ru': 'J-pop', 'zh': '日本流行音乐',
    'ja': 'J-POP', 'ko': '제이팝',
  },
  'Karaoké': {
    'en': 'Karaoke', 'es': 'Karaoke', 'de': 'Karaoke', 'it': 'Karaoke',
    'pt': 'Karaokê', 'nl': 'Karaoke', 'ar': 'كاريوكي', 'ru': 'Караоке',
    'zh': '卡拉OK', 'ja': 'カラオケ', 'ko': '노래방',
  },
  'Kawaii': {
    'en': 'Kawaii', 'es': 'Kawaii', 'de': 'Kawaii', 'it': 'Kawaii',
    'pt': 'Kawaii', 'nl': 'Kawaii', 'ar': 'كاواي', 'ru': 'Каваий',
    'zh': '卡哇伊', 'ja': 'かわいい', 'ko': '카와이',
  },
  'Vocaloid': {
    'en': 'Vocaloid', 'es': 'Vocaloid', 'de': 'Vocaloid', 'it': 'Vocaloid',
    'pt': 'Vocaloid', 'nl': 'Vocaloid', 'ar': 'فوكالويد', 'ru': 'Вокалоид',
    'zh': '虚拟歌手', 'ja': 'ボーカロイド', 'ko': '보컬로이드',
  },
  'Arcades': {
    'en': 'Arcades', 'es': 'Recreativas', 'de': 'Spielhallen',
    'it': 'Sale giochi', 'pt': 'Arcades', 'nl': 'Speelhallen',
    'ar': 'صالات الألعاب', 'ru': 'Аркады', 'zh': '电玩城',
    'ja': 'ゲームセンター', 'ko': '오락실',
  },
  'Robots': {
    'en': 'Robots', 'es': 'Robots', 'de': 'Roboter', 'it': 'Robot',
    'pt': 'Robôs', 'nl': 'Robots', 'ar': 'الروبوتات', 'ru': 'Роботы',
    'zh': '机器人', 'ja': 'ロボット', 'ko': '로봇',
  },
  'Mont Fuji': {
    'en': 'Mount Fuji', 'es': 'Monte Fuji', 'de': 'Fudschijama',
    'it': 'Monte Fuji', 'pt': 'Monte Fuji', 'nl': 'Fuji', 'ar': 'جبل فوجي',
    'ru': 'Фудзи', 'zh': '富士山', 'ja': '富士山', 'ko': '후지산',
  },
  'Tokyo': {
    'en': 'Tokyo', 'es': 'Tokio', 'de': 'Tokio', 'it': 'Tokyo', 'pt': 'Tóquio',
    'nl': 'Tokio', 'ar': 'طوكيو', 'ru': 'Токио', 'zh': '东京', 'ja': '東京',
    'ko': '도쿄',
  },
  'Kyoto': {
    'en': 'Kyoto', 'es': 'Kioto', 'de': 'Kyoto', 'it': 'Kyoto', 'pt': 'Quioto',
    'nl': 'Kyoto', 'ar': 'كيوتو', 'ru': 'Киото', 'zh': '京都', 'ja': '京都',
    'ko': '교토',
  },
  'Osaka': {
    'en': 'Osaka', 'es': 'Osaka', 'de': 'Osaka', 'it': 'Osaka', 'pt': 'Osaka',
    'nl': 'Osaka', 'ar': 'أوساكا', 'ru': 'Осака', 'zh': '大阪', 'ja': '大阪',
    'ko': '오사카',
  },
  'Jardins zen': {
    'en': 'Zen gardens', 'es': 'Jardines zen', 'de': 'Zen-Gärten',
    'it': 'Giardini zen', 'pt': 'Jardins zen', 'nl': 'Zentuinen',
    'ar': 'حدائق الزن', 'ru': 'Сады дзен', 'zh': '禅意庭园', 'ja': '禅庭',
    'ko': '젠 가든',
  },
  'Bonsaï': {
    'en': 'Bonsai', 'es': 'Bonsái', 'de': 'Bonsai', 'it': 'Bonsai',
    'pt': 'Bonsai', 'nl': 'Bonsai', 'ar': 'بونساي', 'ru': 'Бонсай',
    'zh': '盆栽', 'ja': '盆栽', 'ko': '분재',
  },
  'Calligraphie': {
    'en': 'Calligraphy', 'es': 'Caligrafía', 'de': 'Kalligrafie',
    'it': 'Calligrafia', 'pt': 'Caligrafia', 'nl': 'Kalligrafie',
    'ar': 'الخط', 'ru': 'Каллиграфия', 'zh': '书法', 'ja': '書道',
    'ko': '서예',
  },
  'Bambou': {
    'en': 'Bamboo', 'es': 'Bambú', 'de': 'Bambus', 'it': 'Bambù',
    'pt': 'Bambu', 'nl': 'Bamboe', 'ar': 'الخيزران', 'ru': 'Бамбук',
    'zh': '竹子', 'ja': '竹', 'ko': '대나무',
  },

  // ─── France — categories ──────────────────────────────────────────────────
  'Paris & Monuments': {
    'en': 'Paris & Landmarks', 'es': 'París y monumentos',
    'de': 'Paris & Sehenswürdigkeiten', 'it': 'Parigi e monumenti',
    'pt': 'Paris e monumentos', 'nl': 'Parijs & monumenten',
    'ar': 'باريس والمعالم', 'ru': 'Париж и достопримечательности',
    'zh': '巴黎与地标', 'ja': 'パリと名所', 'ko': '파리 & 명소',
  },
  'Gastronomie': {
    'en': 'Gastronomy', 'es': 'Gastronomía', 'de': 'Gastronomie',
    'it': 'Gastronomia', 'pt': 'Gastronomia', 'nl': 'Gastronomie',
    'ar': 'فنون الطهي', 'ru': 'Гастрономия', 'zh': '美食', 'ja': '美食',
    'ko': '미식',
  },
  'Vins & Café': {
    'en': 'Wine & Café', 'es': 'Vinos y café', 'de': 'Wein & Café',
    'it': 'Vini e caffè', 'pt': 'Vinhos e café', 'nl': 'Wijn & café',
    'ar': 'النبيذ والمقاهي', 'ru': 'Вино и кофе', 'zh': '葡萄酒与咖啡',
    'ja': 'ワインとカフェ', 'ko': '와인 & 카페',
  },
  'Mode & Luxe': {
    'en': 'Fashion & Luxury', 'es': 'Moda y lujo', 'de': 'Mode & Luxus',
    'it': 'Moda e lusso', 'pt': 'Moda e luxo', 'nl': 'Mode & luxe',
    'ar': 'الموضة والرفاهية', 'ru': 'Мода и роскошь', 'zh': '时尚与奢华',
    'ja': 'ファッション・ラグジュアリー', 'ko': '패션 & 럭셔리',
  },
  'Art & Culture': {
    'en': 'Art & Culture', 'es': 'Arte y cultura', 'de': 'Kunst & Kultur',
    'it': 'Arte e cultura', 'pt': 'Arte e cultura', 'nl': 'Kunst & cultuur',
    'ar': 'الفن والثقافة', 'ru': 'Искусство и культура', 'zh': '艺术与文化',
    'ja': '芸術・文化', 'ko': '예술 & 문화',
  },
  'Art de vivre': {
    'en': 'Art of living', 'es': 'Arte de vivir', 'de': 'Lebenskunst',
    'it': 'Arte di vivere', 'pt': 'Arte de viver', 'nl': 'Levenskunst',
    'ar': 'فن العيش', 'ru': 'Искусство жить', 'zh': '生活艺术',
    'ja': '暮らしの美学', 'ko': '삶의 예술',
  },

  // ─── France — tags ────────────────────────────────────────────────────────
  'Tour Eiffel': {
    'en': 'Eiffel Tower', 'es': 'Torre Eiffel', 'de': 'Eiffelturm',
    'it': 'Torre Eiffel', 'pt': 'Torre Eiffel', 'nl': 'Eiffeltoren',
    'ar': 'برج إيفل', 'ru': 'Эйфелева башня', 'zh': '埃菲尔铁塔',
    'ja': 'エッフェル塔', 'ko': '에펠탑',
  },
  'Paris': {
    'en': 'Paris', 'es': 'París', 'de': 'Paris', 'it': 'Parigi', 'pt': 'Paris',
    'nl': 'Parijs', 'ar': 'باريس', 'ru': 'Париж', 'zh': '巴黎', 'ja': 'パリ',
    'ko': '파리',
  },
  'Versailles': {
    'en': 'Versailles', 'es': 'Versalles', 'de': 'Versailles',
    'it': 'Versailles', 'pt': 'Versalhes', 'nl': 'Versailles', 'ar': 'فرساي',
    'ru': 'Версаль', 'zh': '凡尔赛', 'ja': 'ヴェルサイユ', 'ko': '베르사유',
  },
  'Mont-Saint-Michel': {
    'en': 'Mont-Saint-Michel', 'es': 'Mont-Saint-Michel',
    'de': 'Mont-Saint-Michel', 'it': 'Mont-Saint-Michel',
    'pt': 'Mont-Saint-Michel', 'nl': 'Mont-Saint-Michel',
    'ar': 'مون سان ميشيل', 'ru': 'Мон-Сен-Мишель', 'zh': '圣米歇尔山',
    'ja': 'モン・サン＝ミシェル', 'ko': '몽생미셸',
  },
  'Notre-Dame': {
    'en': 'Notre-Dame', 'es': 'Notre-Dame', 'de': 'Notre-Dame',
    'it': 'Notre-Dame', 'pt': 'Notre-Dame', 'nl': 'Notre-Dame',
    'ar': 'نوتردام', 'ru': 'Нотр-Дам', 'zh': '巴黎圣母院',
    'ja': 'ノートルダム', 'ko': '노트르담',
  },
  'Arc de Triomphe': {
    'en': 'Arc de Triomphe', 'es': 'Arco del Triunfo', 'de': 'Triumphbogen',
    'it': 'Arco di Trionfo', 'pt': 'Arco do Triunfo', 'nl': 'Arc de Triomphe',
    'ar': 'قوس النصر', 'ru': 'Триумфальная арка', 'zh': '凯旋门',
    'ja': '凱旋門', 'ko': '개선문',
  },
  'Châteaux': {
    'en': 'Castles', 'es': 'Castillos', 'de': 'Schlösser', 'it': 'Castelli',
    'pt': 'Castelos', 'nl': 'Kastelen', 'ar': 'القصور', 'ru': 'Замки',
    'zh': '城堡', 'ja': '城', 'ko': '성',
  },
  'Croissant': {
    'en': 'Croissant', 'es': 'Cruasán', 'de': 'Croissant', 'it': 'Croissant',
    'pt': 'Croissant', 'nl': 'Croissant', 'ar': 'كرواسون', 'ru': 'Круассан',
    'zh': '可颂', 'ja': 'クロワッサン', 'ko': '크루아상',
  },
  'Baguette': {
    'en': 'Baguette', 'es': 'Baguette', 'de': 'Baguette', 'it': 'Baguette',
    'pt': 'Baguete', 'nl': 'Stokbrood', 'ar': 'باغيت', 'ru': 'Багет',
    'zh': '法棍', 'ja': 'バゲット', 'ko': '바게트',
  },
  'Fromage': {
    'en': 'Cheese', 'es': 'Queso', 'de': 'Käse', 'it': 'Formaggio',
    'pt': 'Queijo', 'nl': 'Kaas', 'ar': 'الجبن', 'ru': 'Сыр', 'zh': '奶酪',
    'ja': 'チーズ', 'ko': '치즈',
  },
  'Macarons': {
    'en': 'Macarons', 'es': 'Macarons', 'de': 'Macarons', 'it': 'Macaron',
    'pt': 'Macarons', 'nl': 'Macarons', 'ar': 'ماكارون', 'ru': 'Макаруны',
    'zh': '马卡龙', 'ja': 'マカロン', 'ko': '마카롱',
  },
  'Crêpes': {
    'en': 'Crêpes', 'es': 'Crepes', 'de': 'Crêpes', 'it': 'Crêpe',
    'pt': 'Crepes', 'nl': 'Crêpes', 'ar': 'كريب', 'ru': 'Блинчики',
    'zh': '可丽饼', 'ja': 'クレープ', 'ko': '크레프',
  },
  'Pâtisserie': {
    'en': 'Pastries', 'es': 'Repostería', 'de': 'Patisserie',
    'it': 'Pasticceria', 'pt': 'Pastelaria', 'nl': 'Patisserie',
    'ar': 'الحلويات', 'ru': 'Выпечка', 'zh': '法式糕点', 'ja': 'パティスリー',
    'ko': '파티스리',
  },
  'Escargots': {
    'en': 'Escargots', 'es': 'Caracoles', 'de': 'Schnecken', 'it': 'Lumache',
    'pt': 'Escargots', 'nl': 'Slakken', 'ar': 'الحلزون', 'ru': 'Улитки',
    'zh': '法式蜗牛', 'ja': 'エスカルゴ', 'ko': '에스카르고',
  },
  'Foie gras': {
    'en': 'Foie gras', 'es': 'Foie gras', 'de': 'Foie gras', 'it': 'Foie gras',
    'pt': 'Foie gras', 'nl': 'Foie gras', 'ar': 'فوا غرا', 'ru': 'Фуа-гра',
    'zh': '鹅肝', 'ja': 'フォアグラ', 'ko': '푸아그라',
  },
  'Vin': {
    'en': 'Wine', 'es': 'Vino', 'de': 'Wein', 'it': 'Vino', 'pt': 'Vinho',
    'nl': 'Wijn', 'ar': 'النبيذ', 'ru': 'Вино', 'zh': '葡萄酒', 'ja': 'ワイン',
    'ko': '와인',
  },
  'Champagne': {
    'en': 'Champagne', 'es': 'Champán', 'de': 'Champagner', 'it': 'Champagne',
    'pt': 'Champanhe', 'nl': 'Champagne', 'ar': 'الشمبانيا',
    'ru': 'Шампанское', 'zh': '香槟', 'ja': 'シャンパン', 'ko': '샴페인',
  },
  'Bordeaux': {
    'en': 'Bordeaux', 'es': 'Burdeos', 'de': 'Bordeaux', 'it': 'Bordeaux',
    'pt': 'Bordéus', 'nl': 'Bordeaux', 'ar': 'بوردو', 'ru': 'Бордо',
    'zh': '波尔多', 'ja': 'ボルドー', 'ko': '보르도',
  },
  'Café': {
    'en': 'Coffee', 'es': 'Café', 'de': 'Kaffee', 'it': 'Caffè', 'pt': 'Café',
    'nl': 'Koffie', 'ar': 'القهوة', 'ru': 'Кофе', 'zh': '咖啡', 'ja': 'カフェ',
    'ko': '카페',
  },
  'Bistrot': {
    'en': 'Bistro', 'es': 'Bistró', 'de': 'Bistro', 'it': 'Bistrot',
    'pt': 'Bistrô', 'nl': 'Bistro', 'ar': 'بيسترو', 'ru': 'Бистро',
    'zh': '小酒馆', 'ja': 'ビストロ', 'ko': '비스트로',
  },
  'Apéro': {
    'en': 'Apéritif', 'es': 'Aperitivo', 'de': 'Aperitif', 'it': 'Aperitivo',
    'pt': 'Aperitivo', 'nl': 'Aperitief', 'ar': 'مقبلات', 'ru': 'Аперитив',
    'zh': '餐前酒', 'ja': 'アペリティフ', 'ko': '아페리티프',
  },
  'Mode': {
    'en': 'Fashion', 'es': 'Moda', 'de': 'Mode', 'it': 'Moda', 'pt': 'Moda',
    'nl': 'Mode', 'ar': 'الموضة', 'ru': 'Мода', 'zh': '时尚',
    'ja': 'ファッション', 'ko': '패션',
  },
  'Haute couture': {
    'en': 'Haute couture', 'es': 'Alta costura', 'de': 'Haute Couture',
    'it': 'Alta moda', 'pt': 'Alta-costura', 'nl': 'Haute couture',
    'ar': 'الأزياء الراقية', 'ru': 'Высокая мода', 'zh': '高级定制',
    'ja': 'オートクチュール', 'ko': '오트 쿠튀르',
  },
  'Parfum': {
    'en': 'Perfume', 'es': 'Perfume', 'de': 'Parfum', 'it': 'Profumo',
    'pt': 'Perfume', 'nl': 'Parfum', 'ar': 'العطور', 'ru': 'Парфюм',
    'zh': '香水', 'ja': '香水', 'ko': '향수',
  },
  'Luxe': {
    'en': 'Luxury', 'es': 'Lujo', 'de': 'Luxus', 'it': 'Lusso', 'pt': 'Luxo',
    'nl': 'Luxe', 'ar': 'الرفاهية', 'ru': 'Роскошь', 'zh': '奢华',
    'ja': 'ラグジュアリー', 'ko': '럭셔리',
  },
  'Élégance': {
    'en': 'Elegance', 'es': 'Elegancia', 'de': 'Eleganz', 'it': 'Eleganza',
    'pt': 'Elegância', 'nl': 'Elegantie', 'ar': 'الأناقة',
    'ru': 'Элегантность', 'zh': '优雅', 'ja': 'エレガンス', 'ko': '우아함',
  },
  'Bijoux': {
    'en': 'Jewellery', 'es': 'Joyas', 'de': 'Schmuck', 'it': 'Gioielli',
    'pt': 'Joias', 'nl': 'Sieraden', 'ar': 'المجوهرات', 'ru': 'Украшения',
    'zh': '珠宝', 'ja': 'ジュエリー', 'ko': '주얼리',
  },
  'Louvre': {
    'en': 'Louvre', 'es': 'Louvre', 'de': 'Louvre', 'it': 'Louvre',
    'pt': 'Louvre', 'nl': 'Louvre', 'ar': 'اللوفر', 'ru': 'Лувр',
    'zh': '卢浮宫', 'ja': 'ルーヴル', 'ko': '루브르',
  },
  'Impressionnisme': {
    'en': 'Impressionism', 'es': 'Impresionismo', 'de': 'Impressionismus',
    'it': 'Impressionismo', 'pt': 'Impressionismo', 'nl': 'Impressionisme',
    'ar': 'الانطباعية', 'ru': 'Импрессионизм', 'zh': '印象派',
    'ja': '印象派', 'ko': '인상주의',
  },
  'Monet': {
    'en': 'Monet', 'es': 'Monet', 'de': 'Monet', 'it': 'Monet', 'pt': 'Monet',
    'nl': 'Monet', 'ar': 'مونيه', 'ru': 'Моне', 'zh': '莫奈', 'ja': 'モネ',
    'ko': '모네',
  },
  'Cinéma': {
    'en': 'Cinema', 'es': 'Cine', 'de': 'Kino', 'it': 'Cinema', 'pt': 'Cinema',
    'nl': 'Cinema', 'ar': 'السينما', 'ru': 'Кино', 'zh': '电影', 'ja': '映画',
    'ko': '영화',
  },
  'Littérature': {
    'en': 'Literature', 'es': 'Literatura', 'de': 'Literatur',
    'it': 'Letteratura', 'pt': 'Literatura', 'nl': 'Literatuur',
    'ar': 'الأدب', 'ru': 'Литература', 'zh': '文学', 'ja': '文学',
    'ko': '문학',
  },
  'Musées': {
    'en': 'Museums', 'es': 'Museos', 'de': 'Museen', 'it': 'Musei',
    'pt': 'Museus', 'nl': 'Musea', 'ar': 'المتاحف', 'ru': 'Музеи',
    'zh': '博物馆', 'ja': '美術館', 'ko': '박물관',
  },
  'Théâtre': {
    'en': 'Theatre', 'es': 'Teatro', 'de': 'Theater', 'it': 'Teatro',
    'pt': 'Teatro', 'nl': 'Theater', 'ar': 'المسرح', 'ru': 'Театр',
    'zh': '戏剧', 'ja': '演劇', 'ko': '연극',
  },
  'Architecture': {
    'en': 'Architecture', 'es': 'Arquitectura', 'de': 'Architektur',
    'it': 'Architettura', 'pt': 'Arquitetura', 'nl': 'Architectuur',
    'ar': 'العمارة', 'ru': 'Архитектура', 'zh': '建筑', 'ja': '建築',
    'ko': '건축',
  },
  'Romance': {
    'en': 'Romance', 'es': 'Romance', 'de': 'Romantik', 'it': 'Romanticismo',
    'pt': 'Romance', 'nl': 'Romantiek', 'ar': 'الرومانسية', 'ru': 'Романтика',
    'zh': '浪漫', 'ja': 'ロマンス', 'ko': '로맨스',
  },
  'Terrasses': {
    'en': 'Terraces', 'es': 'Terrazas', 'de': 'Terrassen', 'it': 'Terrazze',
    'pt': 'Esplanadas', 'nl': 'Terrassen', 'ar': 'الشرفات', 'ru': 'Террасы',
    'zh': '露天座', 'ja': 'テラス', 'ko': '테라스',
  },
  'Marchés': {
    'en': 'Markets', 'es': 'Mercados', 'de': 'Märkte', 'it': 'Mercati',
    'pt': 'Mercados', 'nl': 'Markten', 'ar': 'الأسواق', 'ru': 'Рынки',
    'zh': '集市', 'ja': '市場', 'ko': '시장',
  },
  'Flâner': {
    'en': 'Strolling', 'es': 'Pasear', 'de': 'Flanieren', 'it': 'Passeggiare',
    'pt': 'Passear', 'nl': 'Slenteren', 'ar': 'التنزه', 'ru': 'Прогулки',
    'zh': '漫步', 'ja': '散策', 'ko': '산책',
  },
  'Provence': {
    'en': 'Provence', 'es': 'Provenza', 'de': 'Provence', 'it': 'Provenza',
    'pt': 'Provença', 'nl': 'Provence', 'ar': 'بروفانس', 'ru': 'Прованс',
    'zh': '普罗旺斯', 'ja': 'プロヴァンス', 'ko': '프로방스',
  },
  "Côte d'Azur": {
    'en': 'French Riviera', 'es': 'Costa Azul', 'de': 'Côte d’Azur',
    'it': 'Costa Azzurra', 'pt': 'Riviera Francesa', 'nl': 'Côte d’Azur',
    'ar': 'الريفييرا الفرنسية', 'ru': 'Лазурный берег', 'zh': '蔚蓝海岸',
    'ja': 'コート・ダジュール', 'ko': '코트다쥐르',
  },
};

/// Localised display text for an interest [key] (a French category/tag label
/// from `interests.dart`). Returns the key itself for French and for any term
/// without a translation, so display always degrades to the stored French
/// label rather than throwing.
String interestLabel(String key) {
  final lang = AppStrings.currentBcp47.value;
  if (lang == 'fr') return key;
  return _kInterestI18n[key]?[lang] ?? key;
}
