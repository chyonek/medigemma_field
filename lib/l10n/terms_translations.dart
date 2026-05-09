/// セットアップ画面（モデルDL前）の静的翻訳
///
/// 重要：この画面は AI モデルが起動していないタイミングで表示される。
/// したがって Gemma による動的翻訳は使えない。
/// CLAUDE.md のターゲット地域をカバーする 10 言語を静的に持つ。
///
/// 対応言語：
///   en (English) - default
///   ja (Japanese) - 開発言語
///   ar (Arabic) - MENA・難民キャンプ
///   es (Spanish) - 中南米
///   fr (French) - フランス語圏アフリカ
///   pt (Portuguese) - 伯・葡語圏アフリカ
///   sw (Swahili) - 東アフリカ
///   hi (Hindi) - 南アジア
///   zh (Chinese) - 中国語圏
///   ru (Russian) - 旧ソ連圏

class TermsL10n {
  final String title;
  final String subtitle;
  final String benefitOffline;
  final String benefitPrivacy;
  final String benefitNoCost;
  final String termsTitle;
  final String termsBody;
  final String urlTermsLabel;
  final String urlPolicyLabel;
  final String agreeCheckbox;
  final String downloadButton;
  final String retryButton;
  final String checkboxRequired;
  final String downloading;
  final String keepOpen;
  final String complete;
  final String urlCopied;

  const TermsL10n({
    required this.title,
    required this.subtitle,
    required this.benefitOffline,
    required this.benefitPrivacy,
    required this.benefitNoCost,
    required this.termsTitle,
    required this.termsBody,
    required this.urlTermsLabel,
    required this.urlPolicyLabel,
    required this.agreeCheckbox,
    required this.downloadButton,
    required this.retryButton,
    required this.checkboxRequired,
    required this.downloading,
    required this.keepOpen,
    required this.complete,
    required this.urlCopied,
  });

  /// システム言語コードから対応する TermsL10n を取得（無ければ英語にフォールバック）
  static TermsL10n forLocale(String? langCode) {
    if (langCode == null) return _en;
    final code = langCode.toLowerCase().split('_').first.split('-').first;
    return _translations[code] ?? _en;
  }

  /// 利用可能な全言語コード（言語ピッカー用）
  static List<String> availableLocales() => _translations.keys.toList();

  /// 各言語コードのネイティブ名（言語ピッカーに表示）
  static const Map<String, String> nativeNames = {
    'en': 'English',
    'ja': '日本語',
    'ar': 'العربية',
    'es': 'Español',
    'fr': 'Français',
    'pt': 'Português',
    'sw': 'Kiswahili',
    'hi': 'हिन्दी',
    'zh': '中文',
    'ru': 'Русский',
  };

  /// 各言語コードの英語表記（補助表示）
  static const Map<String, String> englishNames = {
    'en': 'English',
    'ja': 'Japanese',
    'ar': 'Arabic',
    'es': 'Spanish',
    'fr': 'French',
    'pt': 'Portuguese',
    'sw': 'Swahili',
    'hi': 'Hindi',
    'zh': 'Chinese',
    'ru': 'Russian',
  };

  // ─── English (default) ───────────────────────────────
  static const _en = TermsL10n(
    title: 'Set up AI',
    subtitle: 'One-time download (~2.4 GB)\nWorks offline after that',
    benefitOffline: 'Works without internet',
    benefitPrivacy: 'Your data never leaves this device',
    benefitNoCost: 'No data fees, no subscriptions',
    termsTitle: 'Gemma Terms of Use',
    termsBody:
        'This app uses Google\'s Gemma model. Please review and agree to '
        'Google\'s Terms of Use and Prohibited Use Policy before downloading:\n\n'
        '• Use this app only as a reference for medical questions\n'
        '• Illegal or harmful uses are prohibited\n'
        '• AI output is NOT a replacement for a doctor\n'
        '• The model is owned by Google; redistribution follows the terms',
    urlTermsLabel: 'Gemma Terms of Use',
    urlPolicyLabel: 'Prohibited Use Policy',
    agreeCheckbox: 'I have read and agree to the terms above',
    downloadButton: 'Accept and download',
    retryButton: 'Retry',
    checkboxRequired: '↑ Accept terms above to enable download',
    downloading: 'Downloading...',
    keepOpen: 'Screen will stay on automatically.\nYou can lock or switch apps — we will notify you when ready.',
    complete: 'Complete!',
    urlCopied: 'URL copied — open it in your browser',
  );

  // ─── 日本語 ────────────────────────────────────────
  static const _ja = TermsL10n(
    title: 'AIをセットアップする',
    subtitle: '一度だけダウンロード（約2.4 GB）\n'
        'その後は電波なしでも使えます',
    benefitOffline: '電波なしで使える',
    benefitPrivacy: 'データはこの端末の外に出ません',
    benefitNoCost: '通信費・利用料金なし',
    termsTitle: 'Gemma 利用規約',
    termsBody: 'このAIは Google の Gemma モデルを使用します。\n'
        'ダウンロード前に Google の利用規約と禁止事項ポリシーに'
        '同意してください：\n\n'
        '・本アプリでは医療相談の参考情報を提供する目的でのみ使用\n'
        '・違法・有害な目的での使用は禁止\n'
        '・出力は「医師の診断の代替」ではない\n'
        '・モデルの著作権は Google にあり、改変配布は規約に従う',
    urlTermsLabel: 'Gemma 利用規約',
    urlPolicyLabel: '禁止事項ポリシー',
    agreeCheckbox: '上記の規約とポリシーを読み、同意します',
    downloadButton: '同意してダウンロード',
    retryButton: '再試行',
    checkboxRequired: '↑ 規約に同意するとダウンロードできます',
    downloading: 'ダウンロード中...',
    keepOpen: '画面は自動で点灯したままになります。\nロックや他のアプリに切り替えてもOK — 完了時に通知でお知らせします。',
    complete: '完了！',
    urlCopied: 'URLをコピーしました — ブラウザで開いてください',
  );

  // ─── العربية ────────────────────────────────────────
  static const _ar = TermsL10n(
    title: 'إعداد الذكاء الاصطناعي',
    subtitle: 'تنزيل لمرة واحدة (~2.4 GB)\n'
        'يعمل دون إنترنت بعد ذلك',
    benefitOffline: 'يعمل دون إنترنت',
    benefitPrivacy: 'بياناتك لا تغادر هذا الجهاز أبداً',
    benefitNoCost: 'بدون رسوم بيانات أو اشتراكات',
    termsTitle: 'شروط استخدام Gemma',
    termsBody: 'يستخدم هذا التطبيق نموذج Gemma من Google. '
        'يرجى مراجعة شروط الاستخدام وسياسة الاستخدام المحظور '
        'والموافقة عليها قبل التنزيل:\n\n'
        '• استخدم هذا التطبيق كمرجع للأسئلة الطبية فقط\n'
        '• يُحظر الاستخدام غير القانوني أو الضار\n'
        '• إخراج الذكاء الاصطناعي ليس بديلاً عن الطبيب\n'
        '• النموذج مملوك لشركة Google',
    urlTermsLabel: 'شروط استخدام Gemma',
    urlPolicyLabel: 'سياسة الاستخدام المحظور',
    agreeCheckbox: 'لقد قرأت ووافقت على الشروط أعلاه',
    downloadButton: 'موافق وتنزيل',
    retryButton: 'إعادة المحاولة',
    checkboxRequired: '↑ وافق على الشروط أعلاه لتفعيل التنزيل',
    downloading: 'جاري التنزيل...',
    keepOpen: 'ستبقى الشاشة مضاءة تلقائياً.\nيمكنك القفل أو التبديل — سنخطرك عند الانتهاء.',
    complete: 'اكتمل!',
    urlCopied: 'تم نسخ الرابط — افتحه في المتصفح',
  );

  // ─── Español ──────────────────────────────────────────
  static const _es = TermsL10n(
    title: 'Configurar IA',
    subtitle: 'Descarga única (~2.4 GB)\nFunciona sin internet después',
    benefitOffline: 'Funciona sin internet',
    benefitPrivacy: 'Sus datos nunca salen de este dispositivo',
    benefitNoCost: 'Sin tarifas de datos ni suscripciones',
    termsTitle: 'Términos de uso de Gemma',
    termsBody: 'Esta aplicación usa el modelo Gemma de Google. '
        'Revise y acepte los Términos de uso y la Política de uso '
        'prohibido antes de descargar:\n\n'
        '• Use esta aplicación solo como referencia para preguntas médicas\n'
        '• Se prohíbe el uso ilegal o dañino\n'
        '• La salida de IA NO reemplaza a un médico\n'
        '• El modelo es propiedad de Google',
    urlTermsLabel: 'Términos de uso de Gemma',
    urlPolicyLabel: 'Política de uso prohibido',
    agreeCheckbox: 'He leído y acepto los términos anteriores',
    downloadButton: 'Aceptar y descargar',
    retryButton: 'Reintentar',
    checkboxRequired: '↑ Acepte los términos para habilitar la descarga',
    downloading: 'Descargando...',
    keepOpen: 'La pantalla se mantendrá encendida automáticamente.\nPuede bloquear o cambiar de app — le notificaremos al terminar.',
    complete: '¡Completado!',
    urlCopied: 'URL copiada — ábrala en su navegador',
  );

  // ─── Français ─────────────────────────────────────────
  static const _fr = TermsL10n(
    title: 'Configurer l\'IA',
    subtitle:
        'Téléchargement unique (~2.4 GB)\nFonctionne hors ligne ensuite',
    benefitOffline: 'Fonctionne sans internet',
    benefitPrivacy: 'Vos données ne quittent jamais cet appareil',
    benefitNoCost: 'Aucun frais de données ni abonnement',
    termsTitle: 'Conditions d\'utilisation Gemma',
    termsBody: 'Cette application utilise le modèle Gemma de Google. '
        'Veuillez examiner et accepter les Conditions d\'utilisation et '
        'la Politique d\'utilisation interdite avant de télécharger:\n\n'
        '• Utilisez cette application uniquement comme référence pour '
        'les questions médicales\n'
        '• Les utilisations illégales ou nuisibles sont interdites\n'
        '• La sortie de l\'IA NE remplace PAS un médecin\n'
        '• Le modèle appartient à Google',
    urlTermsLabel: 'Conditions d\'utilisation Gemma',
    urlPolicyLabel: 'Politique d\'utilisation interdite',
    agreeCheckbox: 'J\'ai lu et j\'accepte les conditions ci-dessus',
    downloadButton: 'Accepter et télécharger',
    retryButton: 'Réessayer',
    checkboxRequired:
        '↑ Acceptez les conditions pour activer le téléchargement',
    downloading: 'Téléchargement...',
    keepOpen:
        "L'écran restera allumé automatiquement.\nVous pouvez verrouiller ou changer d'app — nous vous notifierons.",
    complete: 'Terminé !',
    urlCopied: 'URL copiée — ouvrez-la dans votre navigateur',
  );

  // ─── Português ────────────────────────────────────────
  static const _pt = TermsL10n(
    title: 'Configurar IA',
    subtitle: 'Download único (~2.4 GB)\nFunciona offline depois',
    benefitOffline: 'Funciona sem internet',
    benefitPrivacy: 'Dados não saem do seu dispositivo',
    benefitNoCost: 'Sem taxas de dados nem assinaturas',
    termsTitle: 'Termos de uso do Gemma',
    termsBody: 'Este aplicativo usa o modelo Gemma do Google. '
        'Revise e aceite os Termos de uso e a Política de uso proibido '
        'antes de baixar:\n\n'
        '• Use este aplicativo apenas como referência para perguntas médicas\n'
        '• Uso ilegal ou prejudicial é proibido\n'
        '• A saída da IA NÃO substitui um médico\n'
        '• O modelo pertence ao Google',
    urlTermsLabel: 'Termos de uso do Gemma',
    urlPolicyLabel: 'Política de uso proibido',
    agreeCheckbox: 'Li e concordo com os termos acima',
    downloadButton: 'Aceitar e baixar',
    retryButton: 'Tentar novamente',
    checkboxRequired: '↑ Aceite os termos para habilitar o download',
    downloading: 'Baixando...',
    keepOpen: 'A tela ficará ligada automaticamente.\nVocê pode bloquear ou trocar de app — notificaremos quando terminar.',
    complete: 'Concluído!',
    urlCopied: 'URL copiada — abra no seu navegador',
  );

  // ─── Kiswahili ────────────────────────────────────────
  static const _sw = TermsL10n(
    title: 'Sanidi AI',
    subtitle:
        'Pakua mara moja (~2.4 GB)\nInafanya kazi bila intaneti baadaye',
    benefitOffline: 'Inafanya kazi bila intaneti',
    benefitPrivacy: 'Data haiondoki kwenye kifaa chako',
    benefitNoCost: 'Hakuna ada ya data wala usajili',
    termsTitle: 'Masharti ya Matumizi ya Gemma',
    termsBody: 'Programu hii inatumia muundo wa Gemma wa Google. '
        'Tafadhali kagua na ukubali Masharti ya Matumizi na Sera ya '
        'Matumizi Yaliyokatazwa kabla ya kupakua:\n\n'
        '• Tumia programu hii tu kama rejeleo la maswali ya matibabu\n'
        '• Matumizi haramu au madhara yamekatazwa\n'
        '• Pato la AI HALIBADILISHI daktari\n'
        '• Muundo unamilikiwa na Google',
    urlTermsLabel: 'Masharti ya Matumizi ya Gemma',
    urlPolicyLabel: 'Sera ya Matumizi Yaliyokatazwa',
    agreeCheckbox: 'Nimesoma na ninakubali masharti hapo juu',
    downloadButton: 'Kubali na upakue',
    retryButton: 'Jaribu tena',
    checkboxRequired: '↑ Kubali masharti ili uweze kupakua',
    downloading: 'Inapakua...',
    keepOpen: 'Skrini itabaki ikiwa imewashwa kiotomatiki.\nUnaweza kufunga au kubadilisha — tutakuarifu ikamilika.',
    complete: 'Imekamilika!',
    urlCopied: 'URL imenakiliwa — ifungue katika kivinjari chako',
  );

  // ─── हिन्दी ───────────────────────────────────────────
  static const _hi = TermsL10n(
    title: 'AI सेट अप करें',
    subtitle: 'एक बार डाउनलोड (~2.4 GB)\nइसके बाद ऑफ़लाइन काम करता है',
    benefitOffline: 'इंटरनेट के बिना काम करता है',
    benefitPrivacy: 'डेटा आपके डिवाइस से बाहर नहीं जाता',
    benefitNoCost: 'कोई डेटा शुल्क या सब्सक्रिप्शन नहीं',
    termsTitle: 'Gemma उपयोग की शर्तें',
    termsBody: 'यह ऐप Google के Gemma मॉडल का उपयोग करता है। '
        'डाउनलोड करने से पहले Google की उपयोग की शर्तें और '
        'निषिद्ध उपयोग नीति की समीक्षा करें और सहमत हों:\n\n'
        '• इस ऐप का उपयोग केवल चिकित्सा प्रश्नों के संदर्भ के रूप में करें\n'
        '• अवैध या हानिकारक उपयोग निषिद्ध है\n'
        '• AI आउटपुट डॉक्टर का विकल्प नहीं है\n'
        '• मॉडल Google के स्वामित्व में है',
    urlTermsLabel: 'Gemma उपयोग की शर्तें',
    urlPolicyLabel: 'निषिद्ध उपयोग नीति',
    agreeCheckbox: 'मैंने उपरोक्त शर्तें पढ़ ली हैं और सहमत हूं',
    downloadButton: 'स्वीकार करें और डाउनलोड करें',
    retryButton: 'पुनः प्रयास करें',
    checkboxRequired: '↑ डाउनलोड सक्षम करने के लिए शर्तें स्वीकार करें',
    downloading: 'डाउनलोड हो रहा है...',
    keepOpen: 'स्क्रीन स्वचालित रूप से चालू रहेगी।\nलॉक या ऐप स्विच कर सकते हैं — पूरा होने पर सूचित करेंगे।',
    complete: 'पूर्ण!',
    urlCopied: 'URL कॉपी किया गया — अपने ब्राउज़र में खोलें',
  );

  // ─── 中文 ──────────────────────────────────────────────
  static const _zh = TermsL10n(
    title: '设置 AI',
    subtitle: '一次性下载（约2.4 GB）\n之后可离线使用',
    benefitOffline: '无需互联网即可使用',
    benefitPrivacy: '数据不离开您的设备',
    benefitNoCost: '无数据费用、无订阅',
    termsTitle: 'Gemma 使用条款',
    termsBody: '本应用使用 Google 的 Gemma 模型。'
        '下载前请查看并同意 Google 的使用条款和禁止使用政策：\n\n'
        '• 仅将本应用作为医疗问题的参考\n'
        '• 禁止非法或有害的使用\n'
        '• AI 输出不能替代医生\n'
        '• 模型归 Google 所有',
    urlTermsLabel: 'Gemma 使用条款',
    urlPolicyLabel: '禁止使用政策',
    agreeCheckbox: '我已阅读并同意上述条款',
    downloadButton: '接受并下载',
    retryButton: '重试',
    checkboxRequired: '↑ 接受条款以启用下载',
    downloading: '下载中...',
    keepOpen: '屏幕将自动保持开启。\n您可以锁屏或切换应用 — 完成后会通知您。',
    complete: '完成！',
    urlCopied: 'URL 已复制 — 在浏览器中打开',
  );

  // ─── Русский ──────────────────────────────────────────
  static const _ru = TermsL10n(
    title: 'Настройка ИИ',
    subtitle: 'Однократная загрузка (~2.4 GB)\nЗатем работает офлайн',
    benefitOffline: 'Работает без интернета',
    benefitPrivacy: 'Данные не покидают ваше устройство',
    benefitNoCost: 'Без платы за данные и подписок',
    termsTitle: 'Условия использования Gemma',
    termsBody: 'Это приложение использует модель Gemma от Google. '
        'Перед загрузкой ознакомьтесь и согласитесь с Условиями '
        'использования и Политикой запрещенного использования:\n\n'
        '• Используйте это приложение только как справочник по '
        'медицинским вопросам\n'
        '• Незаконное или вредное использование запрещено\n'
        '• Вывод ИИ НЕ заменяет врача\n'
        '• Модель принадлежит Google',
    urlTermsLabel: 'Условия использования Gemma',
    urlPolicyLabel: 'Политика запрещенного использования',
    agreeCheckbox: 'Я прочитал(а) и согласен(на) с условиями выше',
    downloadButton: 'Принять и загрузить',
    retryButton: 'Повторить',
    checkboxRequired: '↑ Примите условия для активации загрузки',
    downloading: 'Загрузка...',
    keepOpen: 'Экран автоматически останется включённым.\nМожно заблокировать или переключить приложение — уведомим по готовности.',
    complete: 'Готово!',
    urlCopied: 'URL скопирован — откройте в браузере',
  );

  // ─── 言語コード → 翻訳のマップ ─────────────────────────
  static const Map<String, TermsL10n> _translations = {
    'en': _en,
    'ja': _ja,
    'ar': _ar,
    'es': _es,
    'fr': _fr,
    'pt': _pt,
    'sw': _sw,
    'hi': _hi,
    'zh': _zh,
    'ru': _ru,
  };
}
