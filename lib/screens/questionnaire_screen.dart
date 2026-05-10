import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/gemma_service.dart';
import '../services/translation_service.dart';
import '../widgets/body_diagram.dart';
import 'result_screen.dart';

// ─── 画面ステージ ─────────────────────────────────────────────
enum _Stage { form, conversation }
enum _ConvState { analyzing, followUp }

// ─── メッセージモデル ─────────────────────────────────────────
class _Message {
  final String text;
  final bool isUser;
  const _Message({required this.text, required this.isUser});
}

// ─── 選択肢モデル ─────────────────────────────────────────────
class _Choice {
  final String key;
  final String labelEn;
  final String labelJa;
  final IconData? icon;
  const _Choice(this.key, this.labelEn, this.labelJa, {this.icon});
}

// 体図でタップする主要部位（BodyDiagram が処理・左右別キー）
const _mainBodyRegions = [
  _Choice('head',      'Head/Face',     '頭・顔'),
  _Choice('neck',      'Neck',          '首'),
  _Choice('chest',     'Chest',         '胸'),
  _Choice('abdomen',   'Abdomen',       'お腹'),
  _Choice('arm_left',  'Left arm/hand', '左腕・手'),
  _Choice('arm_right', 'Right arm/hand','右腕・手'),
  _Choice('leg_left',  'Left leg/foot', '左脚・足'),
  _Choice('leg_right', 'Right leg/foot','右脚・足'),
];

// 体図に表現しづらい・補助的な部位（チップで選択）
const _extraBodyRegions = [
  _Choice('eye',     'Eye',         '目',         icon: Icons.visibility),
  _Choice('ear',     'Ear',         '耳',         icon: Icons.hearing),
  _Choice('mouth',   'Mouth/Teeth', '口・歯',     icon: Icons.sentiment_neutral),
  _Choice('throat',  'Throat',      '喉',         icon: Icons.air),
  _Choice('back',    'Back',        '背中・腰',   icon: Icons.airline_seat_recline_normal),
  _Choice('skin',    'Skin',        '皮膚',       icon: Icons.spa_outlined),
  _Choice('general', 'Whole body',  '全身',       icon: Icons.accessibility_new),
];

// 上記をマージしたフルリスト（送信時のラベル解決用）
const _allBodyRegions = [..._mainBodyRegions, ..._extraBodyRegions];

const _symptomChoices = [
  _Choice('pain',      'Pain',                 '痛み'),
  _Choice('fever',     'Fever',                '発熱'),
  _Choice('nausea',    'Nausea/Vomiting',      '吐き気・嘔吐'),
  _Choice('diarrhea',  'Diarrhea',             '下痢'),
  _Choice('bleeding',  'Bleeding',             '出血'),
  _Choice('breathing', 'Breathing difficulty', '息苦しさ'),
  _Choice('dizziness', 'Dizziness',            'めまい'),
  _Choice('rash',      'Rash/Swelling',        '発疹・腫れ'),
  _Choice('cough',     'Cough',                '咳'),
  _Choice('headache',  'Headache',             '頭痛'),
];

const _durations = [
  _Choice('now',       'Just now',        '今・直前',     icon: Icons.flash_on),
  _Choice('hours',     'Hours ago',       '数時間前',     icon: Icons.schedule),
  _Choice('today',     'Today',           '今日',         icon: Icons.wb_sunny_outlined),
  _Choice('yesterday', 'Yesterday',       '昨日から',     icon: Icons.brightness_3),
  _Choice('days',      'Days ago',        '数日前',       icon: Icons.calendar_today),
  _Choice('week',      '1+ week',         '1週間以上',    icon: Icons.date_range),
];

// 年齢グループ（WHO IMCI 等）
const _ageGroups = [
  _Choice('infant',     'Under 5',     '0〜4歳（乳幼児）'),
  _Choice('child',      '5–12',        '5〜12歳（小児）'),
  _Choice('teen',       '13–17',       '13〜17歳（青少年）'),
  _Choice('adult',      '18–64',       '18〜64歳（成人）'),
  _Choice('elderly',    '65+',         '65歳以上（高齢者）'),
];

const _sexChoices = [
  _Choice('female', 'Female', '女性'),
  _Choice('male',   'Male',   '男性'),
  _Choice('other',  'Other / Prefer not to say', 'その他・回答しない'),
];

const _pregnancyChoices = [
  _Choice('no',      'No',           'なし'),
  _Choice('possible','Possible',     '可能性あり'),
  _Choice('yes',     'Yes / Currently pregnant', '妊娠中'),
  _Choice('unknown', 'Unknown',      '不明'),
];

// ─── メイン画面 ────────────────────────────────────────────────
class QuestionnaireScreen extends StatefulWidget {
  const QuestionnaireScreen({super.key});

  @override
  State<QuestionnaireScreen> createState() => _QuestionnaireScreenState();
}

class _QuestionnaireScreenState extends State<QuestionnaireScreen> {
  final _t = TranslationService.instance;

  // 3 段階のローディング状態（'analyzing' / 'searching_icd11' / 'thinking'）
  String _analyzingStage = 'analyzing';

  // ステージ管理
  _Stage _stage = _Stage.form;
  _ConvState _convState = _ConvState.analyzing;

  // 患者ターゲット（自分 / 他の人）
  bool _isSelf = true;

  // 人口統計フィールド（任意）
  String _ageGroup = '';
  String _sex = '';
  String _pregnancy = '';

  // 主要フォーム状態
  final Set<String> _regions = {};
  final Set<String> _symptoms = {};
  double _severity = 0;
  String _duration = '';
  final _additionalCtrl = TextEditingController();

  // 各セクションの1行自由記述（任意）
  final _locationNoteCtrl = TextEditingController();
  final _symptomsNoteCtrl = TextEditingController();
  final _severityNoteCtrl = TextEditingController();
  final _durationNoteCtrl = TextEditingController();

  // 写真添付（任意）
  File? _attachedImage;
  final ImagePicker _picker = ImagePicker();

  // 会話状態
  final List<_Message> _messages = [];
  final List<Map<String, String>> _qaHistory = [];
  String _originalInput = '';
  String _pendingQuestion = '';
  List<int>? _imageBytes;
  String _imageMime = 'image/jpeg';
  final _answerCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  // クイックリプライ候補
  List<String>? _quickReplies;

  @override
  void initState() {
    super.initState();
    _t.addListener(_onTranslationChanged);
  }

  void _onTranslationChanged() {
    if (mounted) setState(() {});
  }

  /// 翻訳ヘルパー：prefix_key で翻訳取得・フォールバックは英語
  String _lbl(String prefix, String key, String fallback) {
    final tk = '${prefix}_$key';
    final v = _t.t(tk);
    // _t.t は キー無し時にキー文字列をそのまま返す → フォールバックに置換
    if (v == tk) return fallback;
    return v;
  }

  @override
  void dispose() {
    _t.removeListener(_onTranslationChanged);
    _additionalCtrl.dispose();
    _locationNoteCtrl.dispose();
    _symptomsNoteCtrl.dispose();
    _severityNoteCtrl.dispose();
    _durationNoteCtrl.dispose();
    _answerCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ─── 写真撮影/選択 ────────────────────────────────────────
  Future<void> _takePhoto() async {
    final XFile? photo = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (photo != null) {
      setState(() => _attachedImage = File(photo.path));
    }
  }

  Future<void> _pickFromGallery() async {
    final XFile? photo = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (photo != null) {
      setState(() => _attachedImage = File(photo.path));
    }
  }

  // ─── フォームから初期入力文字列を構築 ──────────────────────
  String _buildOriginalInput() {
    final parts = <String>[];

    // 患者ターゲット
    parts.add(_isSelf ? '患者は本人です' : '患者は他の人（家族など）です');

    // 人口統計（任意）
    if (_ageGroup.isNotEmpty) {
      final label =
          _ageGroups.firstWhere((x) => x.key == _ageGroup).labelJa;
      parts.add('年齢: $label');
    }
    if (_sex.isNotEmpty) {
      final label = _sexChoices.firstWhere((x) => x.key == _sex).labelJa;
      parts.add('性別: $label');
    }
    if (_pregnancy.isNotEmpty) {
      final label =
          _pregnancyChoices.firstWhere((x) => x.key == _pregnancy).labelJa;
      parts.add('妊娠の可能性: $label');
    }

    if (_regions.isNotEmpty) {
      final ja = _regions
          .map((k) => _allBodyRegions
              .firstWhere((r) => r.key == k, orElse: () => _Choice(k, k, k))
              .labelJa)
          .join('、');
      parts.add('部位: $ja');
    }
    final locationNote = _locationNoteCtrl.text.trim();
    if (locationNote.isNotEmpty) {
      parts.add('部位の補足: $locationNote');
    }

    if (_symptoms.isNotEmpty) {
      final ja = _symptoms
          .map((k) => _symptomChoices
              .firstWhere((x) => x.key == k, orElse: () => _Choice(k, k, k))
              .labelJa)
          .join('、');
      parts.add('症状: $ja');
    }
    final symptomsNote = _symptomsNoteCtrl.text.trim();
    if (symptomsNote.isNotEmpty) {
      parts.add('症状の補足: $symptomsNote');
    }

    if (_severity > 0) {
      parts.add('痛みの強さ: 10段階で${_severity.toInt()}');
    }
    final severityNote = _severityNoteCtrl.text.trim();
    if (severityNote.isNotEmpty) {
      parts.add('痛みの感じ: $severityNote');
    }

    if (_duration.isNotEmpty) {
      final d = _durations.firstWhere((x) => x.key == _duration).labelJa;
      parts.add('いつから: $d');
    }
    final durationNote = _durationNoteCtrl.text.trim();
    if (durationNote.isNotEmpty) {
      parts.add('時期の補足: $durationNote');
    }

    final extra = _additionalCtrl.text.trim();
    if (extra.isNotEmpty) {
      parts.add('その他: $extra');
    }

    if (_attachedImage != null) {
      parts.add('（患部の写真を添付しています）');
    }

    // ★ 構造化問診票の入力をすべて「確定情報」としてラップ。
    //   AI が「部位は?」「重症度は?」と再質問するのを防ぐ。
    //   Plain text の前置きで AI に「これは答え済み」と明示する。
    final body = parts.join('。 ');
    return '【記入済み問診票（再質問しないでください）】\n$body\n'
        '【上記以外で診断に必要な情報のみ質問してください】';
  }

  bool get _canSubmit =>
      _regions.isNotEmpty &&
      (_symptoms.isNotEmpty ||
          _additionalCtrl.text.trim().isNotEmpty ||
          _attachedImage != null);

  // ─── フォーム送信 ─────────────────────────────────────────
  Future<void> _submitForm() async {
    if (!_canSubmit) return;
    final input = _buildOriginalInput();
    _originalInput = input;

    // 画像があればバイトを準備
    if (_attachedImage != null) {
      _imageBytes = await _attachedImage!.readAsBytes();
    }

    setState(() {
      _stage = _Stage.conversation;
      _messages.add(_Message(text: input, isUser: true));
      _convState = _ConvState.analyzing;
    });
    await _runNextStep();
  }

  // ─── 共通：次の問診ステップ ──────────────────────────────
  Future<void> _runNextStep() async {
    _scrollToBottom(); // タイピングバブル表示直後の保険
    setState(() => _analyzingStage = 'analyzing');

    final step = await GemmaService.analyzeNextWithImage(
      _originalInput,
      _qaHistory,
      imageBytes: _imageBytes,
      mimeType: _imageMime,
      onStageProgress: (stage) {
        if (mounted) setState(() => _analyzingStage = stage);
      },
    );
    if (!mounted) return;

    if (step.needsFollowUp) {
      _pendingQuestion = step.followUpQuestion!;
      // AI 生成のクイック返信を優先・無ければローカル検出にフォールバック
      _quickReplies = step.quickReplies ?? _detectQuickReplies(_pendingQuestion);
      setState(() {
        _messages.add(_Message(text: _pendingQuestion, isUser: false));
        _convState = _ConvState.followUp;
      });
      _scrollToBottom();
      _scrollToBottom();
    } else {
      Navigator.pushReplacement(
        context,
        _fadeRoute(ResultScreen(result: step.result!)),
      );
    }
  }

  // ─── 追加回答送信 ─────────────────────────────────────────
  Future<void> _submitAnswer() async {
    final answer = _answerCtrl.text.trim();
    if (answer.isEmpty) return;
    _qaHistory.add({'q': _pendingQuestion, 'a': answer});
    setState(() {
      _messages.add(_Message(text: answer, isUser: true));
      _convState = _ConvState.analyzing;
      _answerCtrl.clear();
      _quickReplies = null;
    });
    _scrollToBottom();
    await _runNextStep();
  }

  void _scrollToBottom() {
    void doScroll(Duration animDur) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: animDur,
        curve: Curves.easeOut,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      doScroll(const Duration(milliseconds: 300));
    });
    Future.delayed(const Duration(milliseconds: 350), () {
      doScroll(const Duration(milliseconds: 200));
    });
    // クイック返信・キーボード・入力エリア出現後の最終スクロール
    Future.delayed(const Duration(milliseconds: 700), () {
      doScroll(const Duration(milliseconds: 250));
    });
  }

  PageRoute _fadeRoute(Widget page) => PageRouteBuilder(
        pageBuilder: (_, __, ___) => page,
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      );

  // ─── クイックリプライ：質問タイプ検出 ──────────────────
  List<String>? _detectQuickReplies(String question) {
    if (RegExp(r'大きさ|サイズ|どのくらい大き|どのくらいの大き|何センチ|how big|size|how large')
        .hasMatch(question)) {
      return ['米粒くらい', '小豆くらい', '大豆くらい', '1〜2cm', '3〜5cm', 'もっと大きい'];
    }
    if (RegExp(r'量|どのくらい出|how much|どのくらい血|amount of').hasMatch(question)) {
      return ['少し', 'ティースプーン1杯', '大さじ1杯', 'コップ1杯以上'];
    }
    if (RegExp(r'いつから|いつ始|when did|when start|how long|どれくらい前|始まりま')
        .hasMatch(question)) {
      return ['数分前', '数時間前', '今日', '昨日から', '数日前', '1週間以上前'];
    }
    if (RegExp(r'強さ|severity|10段階|どのくらい痛|how bad|how painful')
        .hasMatch(question)) {
      return ['軽い（2/10）', '中くらい（5/10）', 'かなり痛い（7/10）', '我慢できない（9/10）'];
    }
    if (RegExp(r'どんな痛|痛みの感じ|sharp.*dull|どのような痛|質').hasMatch(question)) {
      return ['鋭い', '鈍い', '焼けるような', 'うずく', '締めつけられる', '波がある'];
    }
    if (RegExp(r'何回|頻度|frequency|how often').hasMatch(question)) {
      return ['1回だけ', '2〜3回', '何度も', '常に続いている'];
    }
    if (RegExp(r'ですか[？\?]|ありますか[？\?]|していますか[？\?]|do you|are you|is there|can you|have you')
        .hasMatch(question)) {
      return ['はい', 'いいえ', 'わからない'];
    }
    if (RegExp(r'何歳|年齢|how old|何才').hasMatch(question)) {
      return ['0〜4歳', '5〜12歳', '13〜17歳', '18〜64歳', '65歳以上'];
    }
    if (RegExp(r'性別|男性ですか|女性ですか|male.*female|sex\b').hasMatch(question)) {
      return ['女性', '男性', 'その他'];
    }
    return null;
  }

  void _submitQuickReply(String text) {
    if (_convState != _ConvState.followUp) return;
    _qaHistory.add({'q': _pendingQuestion, 'a': text});
    setState(() {
      _messages.add(_Message(text: text, isUser: true));
      _convState = _ConvState.analyzing;
      _quickReplies = null;
    });
    _scrollToBottom();
    _runNextStep();
  }

  // ─── Build ────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1B2A),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF1A2E45),
              ),
              child: const Icon(Icons.assignment_outlined,
                  color: Color(0xFF42A5F5), size: 20),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Symptom checklist',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                Text(
                  _stage == _Stage.form ? '問診票 / 症状を選択' : '問診結果 / 回答中',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: _stage == _Stage.form ? _buildForm() : _buildConversation(),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════
  // フォームステージ
  // ════════════════════════════════════════════════════════════
  Widget _buildForm() {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _intro(),
                const SizedBox(height: 20),

                // ─ 患者ターゲット（自分 / 他人）─
                _section('1', _t.t('q_section_who'),
                    _t.t('q_section_who_hint')),
                const SizedBox(height: 12),
                _patientToggle(),
                const SizedBox(height: 24),

                // ─ 年齢・性別・妊娠（任意） ─
                _section('2', _t.t('q_section_about'),
                    _t.t('q_section_about_hint')),
                const SizedBox(height: 12),
                _demographicsBlock(),
                const SizedBox(height: 24),

                // ─ 部位（体図 + 補助チップ） ─
                _section('3', _t.t('q_section_where'),
                    _t.t('q_section_where_hint')),
                const SizedBox(height: 12),
                _bodyDiagramSection(),
                const SizedBox(height: 24),

                // ─ 症状 ─
                _section('4', _t.t('q_section_what'),
                    _t.t('q_section_what_hint')),
                const SizedBox(height: 12),
                _symptomChips(),
                const SizedBox(height: 10),
                _inlineNote(
                  controller: _symptomsNoteCtrl,
                  hint:
                      'e.g. also feeling weak / 他に倦怠感もある',
                ),
                const SizedBox(height: 24),

                // ─ 重症度 ─
                _section('5', _t.t('q_section_how_bad'),
                    _t.t('q_section_how_bad_hint')),
                const SizedBox(height: 12),
                _severitySlider(),
                const SizedBox(height: 10),
                _inlineNote(
                  controller: _severityNoteCtrl,
                  hint: 'e.g. sharp / dull / burning / 鋭い・鈍い・焼ける',
                ),
                const SizedBox(height: 24),

                // ─ 期間 ─
                _section('6', _t.t('q_section_when'),
                    _t.t('q_section_when_hint')),
                const SizedBox(height: 12),
                _durationCards(),
                const SizedBox(height: 10),
                _inlineNote(
                  controller: _durationNoteCtrl,
                  hint:
                      'e.g. 3 hours ago / 3時間前から、波がある',
                ),
                const SizedBox(height: 24),

                // ─ 自由記述 ─
                _section('7', _t.t('q_section_anything_else'),
                    _t.t('q_section_anything_else_hint')),
                const SizedBox(height: 12),
                _additionalField(),
                const SizedBox(height: 24),

                // ─ 写真添付 ─
                _section('8', _t.t('q_section_photo'),
                    _t.t('q_section_photo_hint')),
                const SizedBox(height: 12),
                _photoSection(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
        _submitBar(),
      ],
    );
  }

  Widget _intro() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2E45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: const Color(0xFF42A5F5).withValues(alpha: 0.3), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline,
              color: Color(0xFF42A5F5), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _t.t('q_intro'),
              style: const TextStyle(
                  color: Colors.white70, fontSize: 14, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String num, String en, String hint) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFF1565C0),
          ),
          child: Center(
            child: Text(num,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(en,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              Text(hint,
                  style: const TextStyle(
                      color: Colors.white60, fontSize: 13, height: 1.4)),
            ],
          ),
        ),
      ],
    );
  }

  // ─── 患者ターゲットトグル ─────────────────────────────────
  Widget _patientToggle() {
    return Row(
      children: [
        Expanded(
          child: _toggleCard(
            icon: Icons.person,
            label: _t.t('q_self'),
            sub: '',
            selected: _isSelf,
            onTap: () => setState(() => _isSelf = true),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _toggleCard(
            icon: Icons.family_restroom,
            label: _t.t('q_other'),
            sub: '',
            selected: !_isSelf,
            onTap: () => setState(() => _isSelf = false),
          ),
        ),
      ],
    );
  }

  Widget _toggleCard({
    required IconData icon,
    required String label,
    required String sub,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1565C0) : const Color(0xFF1A2E45),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? Colors.white : Colors.white12,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(icon,
                color: selected ? Colors.white : Colors.white54, size: 28),
            const SizedBox(height: 8),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            Text(sub,
                style: const TextStyle(color: Colors.white60, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  // ─── 人口統計ブロック ─────────────────────────────────────
  Widget _demographicsBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _miniLabel(_t.t('q_age_label')),
        const SizedBox(height: 6),
        _smallChips(
          choices: _ageGroups,
          selectedKey: _ageGroup,
          onTap: (k) => setState(() => _ageGroup = (_ageGroup == k) ? '' : k),
          activeColor: const Color(0xFF00897B),
          prefix: 'age',
        ),
        const SizedBox(height: 14),
        _miniLabel(_t.t('q_sex_label')),
        const SizedBox(height: 6),
        _smallChips(
          choices: _sexChoices,
          selectedKey: _sex,
          onTap: (k) => setState(() => _sex = (_sex == k) ? '' : k),
          activeColor: const Color(0xFF00897B),
          prefix: 'sex',
        ),
        if (_sex == 'female' || _sex == 'other') ...[
          const SizedBox(height: 14),
          _miniLabel(_t.t('q_pregnancy_label')),
          const SizedBox(height: 6),
          _smallChips(
            choices: _pregnancyChoices,
            selectedKey: _pregnancy,
            onTap: (k) => setState(
                () => _pregnancy = (_pregnancy == k) ? '' : k),
            activeColor: const Color(0xFF00897B),
            prefix: 'pregnancy',
          ),
        ],
      ],
    );
  }

  Widget _miniLabel(String text) {
    return Text(text,
        style: const TextStyle(
            color: Colors.white70,
            fontSize: 14,
            fontWeight: FontWeight.bold));
  }

  Widget _smallChips({
    required List<_Choice> choices,
    required String selectedKey,
    required void Function(String) onTap,
    required Color activeColor,
    required String prefix,
  }) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: choices.map((c) {
        final selected = selectedKey == c.key;
        return GestureDetector(
          onTap: () => onTap(c.key),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: selected ? activeColor : const Color(0xFF1A2E45),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? Colors.white : Colors.white12,
                width: selected ? 2 : 1,
              ),
            ),
            child: Text(_lbl(prefix, c.key, c.labelEn),
                style: const TextStyle(color: Colors.white, fontSize: 16)),
          ),
        );
      }).toList(),
    );
  }

  // ─── 部位選択：体図 + 補助チップ + 1行自由記述 ──────────
  Widget _bodyDiagramSection() {
    void toggleRegion(String key) {
      setState(() {
        if (_regions.contains(key)) {
          _regions.remove(key);
        } else {
          _regions.add(key);
        }
      });
    }

    // 選択中の部位ラベル（翻訳を優先・フォールバックは英語）
    final selectedEntries = _regions
        .map((k) {
          final r = _allBodyRegions
              .firstWhere((r) => r.key == k, orElse: () => _Choice(k, k, k));
          return MapEntry(k, _lbl('body', r.key, r.labelEn));
        })
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 鏡像ノート
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.flip,
                  color: Colors.white.withValues(alpha: 0.6), size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _t.t('q_mirror_view'),
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 13, height: 1.4),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 体図
        Center(
          child: SizedBox(
            width: 200,
            child: BodyDiagram(
              selectedKeys: _regions,
              onTap: toggleRegion,
              accent: const Color(0xFF1565C0),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // 選択中の部位サマリー (削除可能なチップ + カウント)
        // ★ 体図と部位チップで重複選択された場合、ここで「2 選択中」と
        //   一目で分かる。各チップに × があるのでタップで個別削除可能。
        //   テキストヒントを読まないユーザーでも視覚的に気付ける。
        if (selectedEntries.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            decoration: BoxDecoration(
              color: const Color(0xFF1565C0).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: const Color(0xFF1565C0).withValues(alpha: 0.5),
                  width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.check_circle,
                        color: Color(0xFF42A5F5), size: 18),
                    const SizedBox(width: 8),
                    Text(
                      '${_t.t('q_selected_label')} (${selectedEntries.length})',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: selectedEntries.map((entry) {
                    return InkWell(
                      onTap: () => toggleRegion(entry.key),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF42A5F5)
                              .withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: const Color(0xFF42A5F5),
                              width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(entry.value,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500)),
                            const SizedBox(width: 4),
                            const Icon(Icons.close,
                                color: Colors.white, size: 16),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),

        // 補助チップ（体図に表現しづらい部位）
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            _t.t('q_other_parts_label'),
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.bold),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _extraBodyRegions.map((r) {
            final selected = _regions.contains(r.key);
            return GestureDetector(
              onTap: () => toggleRegion(r.key),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFF1565C0)
                      : const Color(0xFF1A2E45),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: selected ? Colors.white : Colors.white12,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(r.icon, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    if (selected) ...[
                      const Icon(Icons.check, color: Colors.white, size: 14),
                      const SizedBox(width: 4),
                    ],
                    Text(_lbl('body', r.key, r.labelEn),
                        style: const TextStyle(
                            color: Colors.white, fontSize: 16)),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),

        // 1行自由記述：場所の補足
        _inlineNote(
          controller: _locationNoteCtrl,
          hint: 'e.g. right temple, between shoulders / 右こめかみ、肩甲骨の間',
        ),
      ],
    );
  }

  // ─── 1行自由記述ヘルパー ──────────────────────────────
  Widget _inlineNote({
    required TextEditingController controller,
    required String hint,
  }) {
    return TextField(
      controller: controller,
      maxLines: 1,
      style: const TextStyle(color: Colors.white, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
        prefixIcon: const Icon(Icons.edit_note,
            color: Colors.white54, size: 22),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 38, minHeight: 38),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.04),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
              color: Colors.white.withValues(alpha: 0.1), width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
              color: Colors.white.withValues(alpha: 0.1), width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(
              color: Color(0xFF42A5F5), width: 1.5),
        ),
      ),
    );
  }

  // ─── 症状チップ（複数選択） ───────────────────────────────
  Widget _symptomChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _symptomChoices.map((s) {
        final selected = _symptoms.contains(s.key);
        return GestureDetector(
          onTap: () => setState(() {
            if (selected) {
              _symptoms.remove(s.key);
            } else {
              _symptoms.add(s.key);
            }
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFF1565C0)
                  : const Color(0xFF1A2E45),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: selected ? Colors.white : Colors.white12,
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(Icons.check, color: Colors.white, size: 16),
                  ),
                Text(
                  _lbl('symptom', s.key, s.labelEn),
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  // ─── 重症度スライダー ───────────────────────────────────────
  Widget _severitySlider() {
    final v = _severity.toInt();
    final label = v == 0
        ? _t.t('severity_not_set')
        : v <= 3
            ? _t.t('severity_mild')
            : v <= 6
                ? _t.t('severity_moderate')
                : v <= 8
                    ? _t.t('severity_severe')
                    : _t.t('severity_worst');
    final color = v == 0
        ? Colors.white24
        : v >= 8
            ? const Color(0xFFB71C1C)
            : v >= 5
                ? const Color(0xFFE65100)
                : const Color(0xFF1565C0);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2E45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                v == 0 ? '—' : '$v / 10',
                style: TextStyle(
                    color: color == Colors.white24 ? Colors.white : color,
                    fontSize: 26,
                    fontWeight: FontWeight.bold),
              ),
              Text(
                label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: color,
              inactiveTrackColor: Colors.white12,
              thumbColor: Colors.white,
              overlayColor: color.withValues(alpha: 0.2),
            ),
            child: Slider(
              value: _severity,
              min: 0,
              max: 10,
              divisions: 10,
              onChanged: (val) => setState(() => _severity = val),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const [
                Text('0',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
                Text('5',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
                Text('10',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── 期間カード（3列グリッド・アイコン付きで一目で分かる） ──
  Widget _durationCards() {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.4,
      children: _durations.map((d) {
        final selected = _duration == d.key;
        return GestureDetector(
          onTap: () => setState(() {
            _duration = selected ? '' : d.key;
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFF00897B)
                  : const Color(0xFF1A2E45),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? Colors.white : Colors.white12,
                width: selected ? 2 : 1,
              ),
            ),
            child: Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(d.icon, color: Colors.white, size: 28),
                      const SizedBox(height: 6),
                      Text(_lbl('duration', d.key, d.labelEn),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                if (selected)
                  const Positioned(
                    top: 6,
                    right: 6,
                    child: Icon(Icons.check_circle,
                        color: Colors.white, size: 18),
                  ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  // ─── 自由記述欄 ────────────────────────────────────────────
  Widget _additionalField() {
    return TextField(
      controller: _additionalCtrl,
      maxLines: 4,
      minLines: 2,
      style: const TextStyle(color: Colors.white, fontSize: 16),
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText:
            'e.g. right lower abdomen, sharp pain, no pregnancy possibility\n'
            '例: 右下腹部に鋭い痛み、妊娠の可能性なし',
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
        filled: true,
        fillColor: const Color(0xFF1A2E45),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }

  // ─── 写真添付セクション ────────────────────────────────────
  Widget _photoSection() {
    if (_attachedImage != null) {
      return Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.file(_attachedImage!, fit: BoxFit.cover),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () => setState(() => _attachedImage = null),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close,
                    color: Colors.white, size: 18),
              ),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _takePhoto,
            icon: const Icon(Icons.camera_alt, size: 18),
            label: const Text('Camera / カメラ'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Colors.white24, width: 1.5),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _pickFromGallery,
            icon: const Icon(Icons.photo_library, size: 18),
            label: const Text('Gallery / アルバム'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Colors.white24, width: 1.5),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
      ],
    );
  }

  // ─── 送信バー ──────────────────────────────────────────────
  Widget _submitBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: const BoxDecoration(
        color: Color(0xFF0D1B2A),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 56,
        child: ElevatedButton.icon(
          onPressed: _canSubmit ? _submitForm : null,
          icon: const Icon(Icons.medical_services_outlined, size: 22),
          label: Text(
            _t.t('q_submit'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1565C0),
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.white12,
            disabledForegroundColor: Colors.white24,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════
  // 会話ステージ
  // ════════════════════════════════════════════════════════════
  Widget _buildConversation() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            itemCount: _messages.length +
                (_convState == _ConvState.analyzing ? 1 : 0),
            itemBuilder: (_, i) {
              if (i == _messages.length) return const _TypingBubble();
              return _MessageBubble(message: _messages[i]);
            },
          ),
        ),
        _convArea(),
      ],
    );
  }

  Widget _convArea() {
    if (_convState == _ConvState.followUp) {
      return _answerArea();
    }
    // 3 段階のローディング表示
    Widget icon;
    String text;
    switch (_analyzingStage) {
      case 'searching_icd11':
        icon = const Icon(Icons.menu_book,
            color: Color(0xFF66BB6A), size: 20);
        text = _t.t('hint_searching_icd11');
        break;
      case 'thinking':
        icon = const Icon(Icons.psychology,
            color: Color(0xFFE65100), size: 20);
        text = _t.t('hint_thinking');
        break;
      case 'analyzing':
      default:
        icon = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Color(0xFF42A5F5)),
        );
        text = _t.t('hint_analyzing');
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          icon,
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _answerArea() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: const BoxDecoration(
        color: Color(0xFF0D1B2A),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // クイックリプライ
          if (_quickReplies != null && _quickReplies!.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(
                _t.t('conv_quick_reply_label'),
                style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                    fontWeight: FontWeight.w500),
              ),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _quickReplies!.map((reply) {
                return InkWell(
                  onTap: () => _submitQuickReply(reply),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00897B).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: const Color(0xFF00897B), width: 1.2),
                    ),
                    child: Text(
                      reply,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 16),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
          ],

          const Padding(
            padding: EdgeInsets.only(bottom: 8, left: 4),
            child: Text(
              'Or type your answer / 自由に回答',
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _answerCtrl,
                  maxLines: 3,
                  minLines: 1,
                  autofocus: true,
                  style:
                      const TextStyle(color: Colors.white, fontSize: 17),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submitAnswer(),
                  decoration: InputDecoration(
                    hintText: 'Type your answer... / 回答を入力',
                    hintStyle: const TextStyle(
                        color: Colors.white38, fontSize: 14),
                    filled: true,
                    fillColor: const Color(0xFF1A2E45),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _submitAnswer,
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF00897B),
                  ),
                  child: const Icon(Icons.send,
                      color: Colors.white, size: 22),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── メッセージバブル ──────────────────────────────────────
class _MessageBubble extends StatefulWidget {
  final _Message message;
  const _MessageBubble({required this.message});

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 350));
    _opacity = Tween<double>(begin: 0, end: 1)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _slide = Tween<Offset>(
      begin: widget.message.isUser
          ? const Offset(0.15, 0)
          : const Offset(-0.15, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isUser = widget.message.isUser;
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _slide,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            mainAxisAlignment:
                isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isUser) ...[
                Container(
                  width: 32,
                  height: 32,
                  decoration: const BoxDecoration(
                      shape: BoxShape.circle, color: Color(0xFF1A2E45)),
                  child: const Icon(Icons.medical_services,
                      color: Color(0xFF42A5F5), size: 17),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: isUser
                        ? const Color(0xFF1565C0)
                        : const Color(0xFF1A2E45),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: Radius.circular(isUser ? 18 : 4),
                      bottomRight: Radius.circular(isUser ? 4 : 18),
                    ),
                    border: isUser
                        ? null
                        : Border.all(
                            color: const Color(0xFF42A5F5)
                                .withValues(alpha: 0.3),
                            width: 1),
                  ),
                  child: Text(
                    widget.message.text,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 17, height: 1.5),
                  ),
                ),
              ),
              if (isUser) ...[
                const SizedBox(width: 8),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        const Color(0xFF1565C0).withValues(alpha: 0.4),
                  ),
                  child: const Icon(Icons.assignment_outlined,
                      color: Colors.white54, size: 17),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── タイピングインジケーター ────────────────────────────────
class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: Color(0xFF1A2E45)),
            child: const Icon(Icons.medical_services,
                color: Color(0xFF42A5F5), size: 17),
          ),
          const SizedBox(width: 8),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF1A2E45),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(18),
              ),
              border: Border.all(
                  color:
                      const Color(0xFF42A5F5).withValues(alpha: 0.3),
                  width: 1),
            ),
            // Flutter perf: Opacity widget → 色 alpha 直接適用に変更 (saveLayer 回避)
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(
                            alpha: sin(((_ctrl.value + i / 3) % 1.0) * pi)
                                .clamp(0.25, 1.0),
                          ),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
