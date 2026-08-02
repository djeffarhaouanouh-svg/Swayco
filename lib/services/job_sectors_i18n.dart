import 'app_strings.dart';

/// Display translations for job-sector keys (French labels from `job_sectors.dart`).
const Map<String, Map<String, String>> _kJobSectorI18n = {
  'Étudiant': {
    'en': 'Student', 'es': 'Estudiante', 'de': 'Student', 'it': 'Studente',
    'pt': 'Estudante', 'nl': 'Student', 'ar': 'طالب', 'ru': 'Студент',
    'zh': '学生', 'ja': '学生', 'ko': '학생',
  },
  'Médical': {
    'en': 'Healthcare', 'es': 'Salud', 'de': 'Medizin', 'it': 'Sanità',
    'pt': 'Saúde', 'nl': 'Gezondheidszorg', 'ar': 'طب', 'ru': 'Медицина',
    'zh': '医疗', 'ja': '医療', 'ko': '의료',
  },
  'Éducation': {
    'en': 'Education', 'es': 'Educación', 'de': 'Bildung', 'it': 'Istruzione',
    'pt': 'Educação', 'nl': 'Onderwijs', 'ar': 'تعليمليم', 'ru': 'Образование',
    'zh': '教育', 'ja': '教育', 'ko': '교육',
  },
  'Tech': {
    'en': 'Tech', 'es': 'Tecnología', 'de': 'Tech', 'it': 'Tech',
    'pt': 'Tech', 'nl': 'Tech', 'ar': 'تقنية', 'ru': 'IT',
    'zh': '科技', 'ja': 'テック', 'ko': '테크',
  },
  'Commerce': {
    'en': 'Sales & Retail', 'es': 'Comercio', 'de': 'Handel', 'it': 'Commercio',
    'pt': 'Comércio', 'nl': 'Handel', 'ar': 'تجارة', 'ru': 'Торговля',
    'zh': '商业', 'ja': '販売・商業', 'ko': '상업',
  },
  'Restauration': {
    'en': 'Hospitality', 'es': 'Hostelería', 'de': 'Gastronomie',
    'it': 'Ristorazione', 'pt': 'Restauração', 'nl': 'Horeca',
    'ar': 'ضيافة', 'ru': 'Общепит', 'zh': '餐饮', 'ja': '飲食', 'ko': '외식',
  },
  'Art & Création': {
    'en': 'Arts & Creative', 'es': 'Arte y creación', 'de': 'Kunst & Kreatives',
    'it': 'Arte e creatività', 'pt': 'Arte e criação', 'nl': 'Kunst & creatie',
    'ar': 'فن وإبداع', 'ru': 'Искусство', 'zh': '艺术与创作',
    'ja': 'アート・クリエイティブ', 'ko': '예술·창작',
  },
  'Droit & Finance': {
    'en': 'Law & Finance', 'es': 'Derecho y finanzas', 'de': 'Recht & Finanzen',
    'it': 'Diritto e finanza', 'pt': 'Direito e finanças',
    'nl': 'Recht & financiën', 'ar': 'قانون ومالية', 'ru': 'Право и финансы',
    'zh': '法律与金融', 'ja': '法律・金融', 'ko': '법률·금융',
  },
  'Ingénierie': {
    'en': 'Engineering', 'es': 'Ingeniería', 'de': 'Ingenieurwesen',
    'it': 'Ingegneria', 'pt': 'Engenharia', 'nl': 'Engineering',
    'ar': 'هندسة', 'ru': 'Инженерия', 'zh': '工程', 'ja': 'エンジニアリング',
    'ko': '엔지니어링',
  },
  'Sport & Divertissement': {
    'en': 'Sport & Entertainment', 'es': 'Deporte y ocio',
    'de': 'Sport & Unterhaltung', 'it': 'Sport e intrattenimento',
    'pt': 'Desporto e entretenimento', 'nl': 'Sport & entertainment',
    'ar': 'رياضة وترفيه', 'ru': 'Спорт и развлечения', 'zh': '体育与娱乐',
    'ja': 'スポーツ・エンタメ', 'ko': '스포츠·엔터',
  },
  'Service public': {
    'en': 'Public service', 'es': 'Servicio público', 'de': 'Öffentlicher Dienst',
    'it': 'Pubblica amministrazione', 'pt': 'Serviço público',
    'nl': 'Overheid', 'ar': 'خدمة عامة', 'ru': 'Госслужба',
    'zh': '公共服务', 'ja': '公務員', 'ko': '공공 서비스',
  },
  'Autre': {
    'en': 'Other', 'es': 'Otro', 'de': 'Sonstiges', 'it': 'Altro',
    'pt': 'Outro', 'nl': 'Overig', 'ar': 'أخرى', 'ru': 'Другое',
    'zh': '其他', 'ja': 'その他', 'ko': '기타',
  },
};

String jobSectorLabel(String key) {
  final lang = AppStrings.currentBcp47.value;
  if (lang == 'fr') return key;
  return _kJobSectorI18n[key]?[lang] ?? key;
}
