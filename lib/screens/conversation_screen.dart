import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../services/gemma_service.dart';
import '../services/translation_service.dart';
import 'result_screen.dart';

// ─── 状態 ────────────────────────────────────────────────────
// 開始選択 → 入力（音声 or テキスト）→ 解析 → フォローアップ → ...
enum _Stage {
  initialChoice, // 「話す」「入力する」の選択画面
  textInput,     // テキストで入力中
  voiceListening,// 音声録音中
  analyzing,     // AI 解析中
  ttsReading,    // AI 質問を読み上げ中
  followUpInput, // フォローアップ回答入力中（音声 or テキスト切替可）
  followUpVoice, // フォローアップ音声録音中
}

// ─── 入力モード（フォローアップ時のトグル用） ──────────────
enum _InputMode { text, voice }

class _Message {
  final String text;
  final bool isUser;
  // AI 応答を「ChatGPT 風」に1文字ずつ表示するか
  final bool typewriter;
  const _Message({
    required this.text,
    required this.isUser,
    this.typewriter = false,
  });
}

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({super.key});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen>
    with SingleTickerProviderStateMixin {
  // 翻訳
  final _t = TranslationService.instance;

  // 音声サービス
  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _speechAvailable = false;

  // 状態
  // 初期画面は廃止：開いた瞬間からテキスト入力可（🎤 ボタンで音声に切替）。
  // 「対話を始めるには…」のメニューは認知負荷を増やすだけで、入力手段は
  // ターン単位で切り替わるので最初に選ばせる必要がない。
  _Stage _stage = _Stage.textInput;
  _InputMode _followUpMode = _InputMode.text;

  // TTS 自動読み上げの有効/無効
  // 初期選択で「Speak to start」→ true（識字弱者・ハンズフリー想定）
  // 初期選択で「Type to start」→ false（静かな場所・聴覚障害・公共空間想定）
  // ユーザーは AppBar のアイコンで手動切替可能
  bool _ttsEnabled = false;

  // 入力データ
  final TextEditingController _initialTextCtrl = TextEditingController();
  final TextEditingController _answerCtrl = TextEditingController();
  String _voiceTranscribed = '';

  // 会話履歴
  final List<_Message> _messages = [];
  final List<Map<String, String>> _qaHistory = [];
  String _originalInput = '';
  String _pendingQuestion = '';
  String _detectedLangCode = 'en-US';

  // クイックリプライ候補（質問タイプを検出して提示）
  List<String>? _quickReplies;

  // スクロール
  final ScrollController _scrollCtrl = ScrollController();

  // パルスアニメーション
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _t.addListener(_onTranslationChanged);
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.18).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _initServices();
  }

  void _onTranslationChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initServices() async {
    _speechAvailable = await _speech.initialize(
      onError: (_) {
        if (mounted) setState(() {});
      },
    );
    await _tts.setVolume(1.0);
    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
  }

  @override
  void dispose() {
    _t.removeListener(_onTranslationChanged);
    _speech.stop();
    _tts.stop();
    _pulseCtrl.dispose();
    _initialTextCtrl.dispose();
    _answerCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ─── 開始選択：テキスト ─────────────────────────────────
  // テキストモード = 静かな環境想定 → TTS は無効化
  void _startWithText() {
    setState(() {
      _stage = _Stage.textInput;
      _ttsEnabled = false;
      _followUpMode = _InputMode.text;
    });
  }

  // ─── 開始選択：音声 ──────────────────────────────────────
  // 音声モード = ハンズフリー・識字弱者想定 → TTS は有効化
  Future<void> _startWithVoice() async {
    if (!_speechAvailable) {
      _showSnack('Speech recognition not available / 音声認識が利用できません');
      return;
    }
    setState(() {
      _stage = _Stage.voiceListening;
      _voiceTranscribed = '';
      _ttsEnabled = true;
      _followUpMode = _InputMode.voice;
    });
    await _speech.listen(
      onResult: (r) {
        if (!mounted) return;
        setState(() => _voiceTranscribed = r.recognizedWords);
        if (r.finalResult) _handleInitialVoiceRecorded();
      },
      // 初期症状入力は長めに話す可能性があるため dictation
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: true,
      ),
      pauseFor: const Duration(milliseconds: 1500),
      listenFor: const Duration(seconds: 30),
    );
  }

  void _handleInitialVoiceRecorded() {
    if (_stage != _Stage.voiceListening) return;
    if (_voiceTranscribed.isEmpty) {
      // 何も録音できなかったらテキスト入力に戻す（initialChoice 画面は廃止）
      setState(() => _stage = _Stage.textInput);
      return;
    }
    _submitInitial(_voiceTranscribed);
  }

  // ─── 初期送信（テキスト送信ボタンから） ───────────────────
  void _submitInitialText() {
    final text = _initialTextCtrl.text.trim();
    if (text.isEmpty) return;
    _submitInitial(text);
  }

  // ─── 初期送信（共通） ────────────────────────────────────
  Future<void> _submitInitial(String text) async {
    _originalInput = text; // AI 送信用 (markers 含む完全な version)
    final displayText = _stripInternalMarkers(text); // user に見せる用
    setState(() {
      _messages.add(_Message(text: displayText, isUser: true));
      _stage = _Stage.analyzing;
      _initialTextCtrl.clear();
    });
    _scrollToBottom();
    await _runNextStep();
  }

  /// 問診票が AI に渡す内部マーカーをユーザー表示から除去する。
  /// 「【記入済み問診票（再質問しないでください）】」のような prompt-engineering
  /// 文字列が user の最初のメッセージとしてチャットに表示される問題への対策。
  /// AI に送る `_originalInput` には markers を残し、表示だけ綺麗にする。
  String _stripInternalMarkers(String text) {
    return text
        .replaceAll('【記入済み問診票（再質問しないでください）】', '')
        .replaceAll('【上記以外で診断に必要な情報のみ質問してください】', '')
        .replaceAll('PRE-FILLED INTAKE FORM', '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  // 3 段階ローディング：Stage 1 (analyzing) → Stage 2a (searching ICD-11) → Stage 2b (thinking)
  String _analyzingStage = 'analyzing';

  // ─── 共通：次の問診ステップ ────────────────────────────
  Future<void> _runNextStep() async {
    // タイピングバブル表示直後にスクロール（呼び出し側でanalyzingに設定済み想定）
    _scrollToBottom();
    setState(() => _analyzingStage = 'analyzing');

    final step = await GemmaService.analyzeNext(
      _originalInput,
      _qaHistory,
      onStageProgress: (stage) {
        if (mounted) setState(() => _analyzingStage = stage);
      },
    );
    if (!mounted) return;

    if (step.needsFollowUp) {
      _pendingQuestion = step.followUpQuestion!;
      _detectedLangCode = step.languageCode;
      // AI 生成のクイック返信を優先・無ければローカル検出にフォールバック
      _quickReplies = step.quickReplies ?? _detectQuickReplies(_pendingQuestion);
      setState(() {
        _messages.add(_Message(
          text: _pendingQuestion,
          isUser: false,
          typewriter: true,
        ));
        _stage = _ttsEnabled ? _Stage.ttsReading : _Stage.followUpInput;
      });
      _scrollToBottom();
      if (_ttsEnabled) {
        await _speakQuestion(_pendingQuestion, _detectedLangCode);
      }
      _scrollToBottom(); // TTS完了後・入力エリア出現後の保険
    } else {
      Navigator.pushReplacement(
        context,
        _fadeRoute(ResultScreen(result: step.result!)),
      );
    }
  }

  Future<void> _speakQuestion(String text, String langCode) async {
    final ttsLang = langCode == 'ar' ? 'ar-SA' : langCode;

    // ★ Android の TTS エンジンは Japanese を要求しても Chinese 音声が
    //   流れることがある (CJK 漢字を Chinese voice で読み上げてしまう)。
    //   isLanguageAvailable で確認し、利用可能なら明示設定。
    //   さらに setVoice で voice 自体を pin して言語崩れを防ぐ。
    try {
      final available = await _tts.isLanguageAvailable(ttsLang);
      debugPrint('[TTS] $ttsLang available: $available');
      if (available == true || available == 1) {
        await _tts.setLanguage(ttsLang);
        // 利用可能な voice の中から目的言語に一致するものを探して固定
        final voices = await _tts.getVoices;
        if (voices is List) {
          final langPrefix = ttsLang.split('-').first;
          final matched = voices.firstWhere(
            (v) {
              if (v is! Map) return false;
              final locale = (v['locale'] ?? '').toString().toLowerCase();
              return locale == ttsLang.toLowerCase() ||
                  locale.startsWith('$langPrefix-') ||
                  locale.startsWith(langPrefix);
            },
            orElse: () => null,
          );
          if (matched != null && matched is Map) {
            await _tts.setVoice({
              'name': matched['name']?.toString() ?? '',
              'locale': matched['locale']?.toString() ?? ttsLang,
            });
            debugPrint('[TTS] pinned voice: ${matched['name']} (${matched['locale']})');
          }
        }
      } else {
        debugPrint('[TTS] WARN: $ttsLang not available — TTS may fall back '
            'to a different language. Skip speak() to avoid wrong-language audio.');
        // 言語が無い → 読み上げスキップ (中国語混入を防ぐ)
        if (mounted && _stage == _Stage.ttsReading) {
          setState(() => _stage = _Stage.followUpInput);
        }
        return;
      }
    } catch (e) {
      debugPrint('[TTS] language setup failed: $e');
    }

    _tts.setCompletionHandler(() {
      if (mounted && _stage == _Stage.ttsReading) {
        setState(() => _stage = _Stage.followUpInput);
      }
    });
    await _tts.speak(text);
  }

  // ─── TTS スキップ（タップで割り込み） ──────────────────
  Future<void> _skipTtsAndAnswer() async {
    await _tts.stop();
    if (mounted) setState(() => _stage = _Stage.followUpInput);
  }

  // ─── フォローアップ：テキスト送信 ──────────────────────
  Future<void> _submitAnswerText() async {
    final answer = _answerCtrl.text.trim();
    if (answer.isEmpty) return;
    _submitAnswerCommon(answer);
    _answerCtrl.clear();
  }

  // ─── フォローアップ：音声開始 ──────────────────────────
  Future<void> _startFollowUpVoice() async {
    if (!_speechAvailable) {
      _showSnack('Speech recognition not available / 音声認識が利用できません');
      return;
    }
    await _tts.stop();
    setState(() {
      _stage = _Stage.followUpVoice;
      _voiceTranscribed = '';
    });
    // ★ Android の confirmation モードは短答 ("5", "はい" 等) で finalResult を
    //   発火しないことがある (実機検証で確認)。dictation モードに切替し、
    //   pauseFor を短く (1.5s silence で auto-stop)、listenFor も短くする。
    //   さらに手動停止時に最後の partial result を採用するよう defensively 改修。
    await _speech.listen(
      onResult: (r) {
        if (!mounted) return;
        // 空でない結果のみ保存 (空の partial で上書きしない)
        if (r.recognizedWords.trim().isNotEmpty) {
          setState(() => _voiceTranscribed = r.recognizedWords);
        }
        if (r.finalResult) _handleFollowUpVoiceRecorded();
      },
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: true,
      ),
      pauseFor: const Duration(milliseconds: 1500),
      listenFor: const Duration(seconds: 8),
    );
  }

  void _handleFollowUpVoiceRecorded() {
    if (_stage != _Stage.followUpVoice) return;
    if (_voiceTranscribed.isEmpty) {
      setState(() => _stage = _Stage.followUpInput);
      return;
    }
    _submitAnswerCommon(_voiceTranscribed);
  }

  void _submitAnswerCommon(String answer) {
    HapticFeedback.lightImpact(); // 回答送信の触覚フィードバック
    _qaHistory.add({'q': _pendingQuestion, 'a': answer});
    setState(() {
      _messages.add(_Message(text: answer, isUser: true));
      _stage = _Stage.analyzing;
      _quickReplies = null;
    });
    _scrollToBottom();
    _runNextStep();
  }

  // ─── マイクボタン手動停止 ─────────────────────────────
  Future<void> _stopVoiceManually() async {
    await _speech.stop();
    // ★ 手動停止後に少し待つ: speech_to_text engine は stop() 後に
    //   最後の onResult (finalResult=true) を遅延発火することがある。
    //   500ms 待ってから処理することで取りこぼしを減らす。
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    if (_stage == _Stage.voiceListening) {
      _handleInitialVoiceRecorded();
    } else if (_stage == _Stage.followUpVoice) {
      _handleFollowUpVoiceRecorded();
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ─── クイックリプライ：質問タイプを検出して選択肢を返す ────
  // 翻訳キャッシュがあれば翻訳済み文字列を返す（フォールバックは英語）
  List<String>? _detectQuickReplies(String question) {
    // サイズ/大きさ
    if (RegExp(r'大きさ|サイズ|どのくらい大き|どのくらいの大き|何センチ|how big|size|how large')
        .hasMatch(question)) {
      return [
        _t.t('reply_size_rice'),
        _t.t('reply_size_small_bean'),
        _t.t('reply_size_large_bean'),
        _t.t('reply_size_1cm'),
        _t.t('reply_size_3cm'),
        _t.t('reply_size_larger'),
      ];
    }

    // 量（出血量・分泌物など）
    if (RegExp(r'量|どのくらい出|how much|どのくらい血|amount of').hasMatch(question)) {
      return [
        _t.t('reply_amount_little'),
        _t.t('reply_amount_teaspoon'),
        _t.t('reply_amount_tablespoon'),
        _t.t('reply_amount_cup'),
      ];
    }

    // 期間/時間
    if (RegExp(r'いつから|いつ始|when did|when start|how long|どれくらい前|始まりま')
        .hasMatch(question)) {
      return [
        _t.t('duration_now'),
        _t.t('duration_hours'),
        _t.t('duration_today'),
        _t.t('duration_yesterday'),
        _t.t('duration_days'),
        _t.t('duration_week'),
      ];
    }

    // 重症度
    if (RegExp(r'強さ|severity|10段階|どのくらい痛|how bad|how painful|how severe')
        .hasMatch(question)) {
      return [
        '${_t.t('severity_mild')} (2/10)',
        '${_t.t('severity_moderate')} (5/10)',
        '${_t.t('severity_severe')} (7/10)',
        '${_t.t('severity_worst')} (9/10)',
      ];
    }

    // 頻度
    if (RegExp(r'何回|頻度|frequency|how often|how many times').hasMatch(question)) {
      return [
        _t.t('reply_once'),
        _t.t('reply_a_few_times'),
        _t.t('reply_many_times'),
        _t.t('reply_constant'),
      ];
    }

    // Yes/No
    if (RegExp(r'ですか[？\?]|ありますか[？\?]|していますか[？\?]|do you|are you|is there|can you|have you')
        .hasMatch(question)) {
      return [
        _t.t('reply_yes'),
        _t.t('reply_no'),
        _t.t('reply_dont_know'),
      ];
    }

    // 年齢（直接的な質問のみ）
    if (RegExp(r'何歳|年齢|how old|何才').hasMatch(question)) {
      return [
        _t.t('age_infant'),
        _t.t('age_child'),
        _t.t('age_teen'),
        _t.t('age_adult'),
        _t.t('age_elderly'),
      ];
    }

    // 性別
    if (RegExp(r'性別|男性ですか|女性ですか|male.*female|sex\b').hasMatch(question)) {
      return [
        _t.t('sex_female'),
        _t.t('sex_male'),
        _t.t('sex_other'),
      ];
    }

    return null;
  }

  // ─── クイックリプライ送信（テキスト or 音声中でも使える） ──
  void _submitQuickReply(String text) {
    if (_stage == _Stage.followUpInput || _stage == _Stage.followUpVoice) {
      _submitAnswerCommon(text);
    }
  }

  // 信頼性のためレイアウト確定後と少し遅延させてトリプルスクロール。
  // 最後の長めのディレイは、クイック返信 / キーボード / 入力エリアが
  // 表示されてレイアウトが安定した後にスクロールし直すためのもの。
  // これがないと最新の質問が入力エリアの裏に隠れてしまう。
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

  // ════════════════════════════════════════════════════════════
  // Build
  // ════════════════════════════════════════════════════════════
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
              child: const Icon(Icons.chat_bubble_outline,
                  color: Color(0xFF42A5F5), size: 20),
            ),
            const SizedBox(width: 10),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Conversation',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                Text('対話相談 — 音声 or テキスト',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
              ],
            ),
          ],
        ),
        actions: [
          // TTS 有効/無効トグル（初期選択画面では非表示）
          if (_stage != _Stage.initialChoice)
            IconButton(
              tooltip: _ttsEnabled
                  ? 'Disable read-aloud / 読み上げをオフ'
                  : 'Enable read-aloud / 読み上げをオン',
              icon: Icon(
                _ttsEnabled ? Icons.volume_up : Icons.volume_off,
                color: _ttsEnabled
                    ? const Color(0xFF42A5F5)
                    : Colors.white54,
              ),
              onPressed: () {
                setState(() => _ttsEnabled = !_ttsEnabled);
                if (!_ttsEnabled) _tts.stop();
              },
            ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_stage == _Stage.initialChoice) return _initialChoiceView();

    return Column(
      children: [
        // 会話エリア（タップで TTS スキップ）
        Expanded(child: _buildConversationArea()),
        // 入力エリア
        _buildInputArea(),
      ],
    );
  }

  // ─── 開始選択画面 ────────────────────────────────────────
  Widget _initialChoiceView() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(flex: 1),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF1A2E45),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: const Color(0xFF42A5F5).withValues(alpha: 0.3),
                  width: 1),
            ),
            child: Column(
              children: [
                const Icon(Icons.medical_services,
                    color: Color(0xFF42A5F5), size: 42),
                const SizedBox(height: 14),
                Text(
                  _t.t('conv_how_to_start'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 14),
                const Text(
                  'You can switch between speaking and typing anytime.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white60, fontSize: 13, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // テキスト開始ボタン（デフォルト推奨）
          _startButton(
            icon: Icons.keyboard,
            primaryLabel: '⌨️  ${_t.t('conv_type')}',
            secondaryLabel: '',
            description:
                'Quiet places, hearing-impaired, public spaces',
            color: const Color(0xFF388E3C),
            onTap: _startWithText,
          ),
          const SizedBox(height: 14),

          // 音声開始ボタン
          _startButton(
            icon: Icons.mic,
            primaryLabel: '🎤  ${_t.t('conv_speak')}',
            secondaryLabel: '',
            description:
                'Cannot read, hands occupied, quick input',
            color: const Color(0xFF1976D2),
            onTap: _startWithVoice,
          ),
          const Spacer(flex: 2),
        ],
      ),
    );
  }

  Widget _startButton({
    required IconData icon,
    required String primaryLabel,
    required String secondaryLabel,
    required String description,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(icon, color: Colors.white, size: 36),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(primaryLabel,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.bold)),
                    Text(secondaryLabel,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16)),
                    const SizedBox(height: 6),
                    Text(description,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            height: 1.4)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── 会話エリア ───────────────────────────────────────────
  Widget _buildConversationArea() {
    // ★ キーボード表示時に最新メッセージ・クイック返信が隠れる問題への対策。
    //   ListView の下部 padding にキーボード分 + クイック返信 chips 分の余白を追加。
    //   Scaffold の resizeToAvoidBottomInset と組み合わせて、入力欄と
    //   クイック返信は viewInsets により上に押し上げられる。ListView 側は
    //   その押し上げ分を「余白」として吸収して最新メッセージを見せる。
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final hasQuickReplies = _quickReplies != null &&
        _quickReplies!.isNotEmpty &&
        (_stage == _Stage.followUpInput || _stage == _Stage.followUpVoice);
    final extraBottomPadding =
        (bottomInset > 0 ? 8.0 : 0.0) + (hasQuickReplies ? 80.0 : 0.0);

    final content = ListView.builder(
      controller: _scrollCtrl,
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + extraBottomPadding),
      itemCount: _messages.length + (_stage == _Stage.analyzing ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == _messages.length) return const _TypingBubble();
        // ★ ValueKey を付与して既存 State を再利用させる。
        //   これがないと新メッセージ追加時に全 bubble の typewriter が
        //   再起動されてしまう (text + isUser の組合せでメッセージを識別)。
        final m = _messages[i];
        return _MessageBubble(
          key: ValueKey('msg_${i}_${m.isUser}_${m.text.hashCode}'),
          message: m,
        );
      },
    );

    // TTS 読み上げ中はタップでスキップ
    if (_stage == _Stage.ttsReading) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _skipTtsAndAnswer,
        child: Stack(
          children: [
            Positioned.fill(child: content),
            Positioned(
              left: 16,
              right: 16,
              bottom: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF00897B).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color:
                          const Color(0xFF00897B).withValues(alpha: 0.5),
                      width: 1),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.touch_app,
                        color: Color(0xFF00897B), size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Tap anywhere to answer now / タップして回答へ',
                      style: TextStyle(
                          color: Color(0xFF00897B),
                          fontSize: 14,
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return content;
  }

  // ─── 入力エリア（状態によって切替） ───────────────────
  Widget _buildInputArea() {
    switch (_stage) {
      case _Stage.textInput:
        return _initialTextInputArea();
      case _Stage.voiceListening:
        return _voiceRecordingArea(isInitial: true);
      case _Stage.followUpInput:
        return _followUpInputArea();
      case _Stage.followUpVoice:
        return _voiceRecordingArea(isInitial: false);
      case _Stage.analyzing:
      case _Stage.ttsReading:
        return _disabledHint();
      default:
        return const SizedBox.shrink();
    }
  }

  // ─── 初期テキスト入力 ────────────────────────────────────
  Widget _initialTextInputArea() {
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
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 4),
            child: Text(
              _t.t('conv_describe_symptoms'),
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                onPressed: _startWithVoice,
                icon: const Icon(Icons.mic, size: 26),
                tooltip: 'Switch to voice / 音声に切替',
                color: const Color(0xFF1976D2),
              ),
              Expanded(
                child: TextField(
                  controller: _initialTextCtrl,
                  maxLines: 4,
                  minLines: 1,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 17),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submitInitialText(),
                  decoration: InputDecoration(
                    hintText:
                        'e.g. stomach ache since morning / 朝からお腹が痛い',
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
              const SizedBox(width: 6),
              GestureDetector(
                onTap: _submitInitialText,
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF388E3C),
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

  // ─── フォローアップ入力（音声/テキストトグル付き） ──
  Widget _followUpInputArea() {
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
          // クイックリプライ候補（質問タイプ別）
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

          // モード切替トグル
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Text(
                  'Or type / 自由に入力',
                  style: TextStyle(color: Colors.white60, fontSize: 13),
                ),
              ),
              _modeSegment(),
            ],
          ),
          const SizedBox(height: 8),

          if (_followUpMode == _InputMode.text)
            _textAnswerRow()
          else
            _voiceAnswerRow(),
        ],
      ),
    );
  }

  Widget _modeSegment() {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2E45),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _modeButton(
            icon: Icons.keyboard,
            label: '⌨️',
            selected: _followUpMode == _InputMode.text,
            onTap: () => setState(() => _followUpMode = _InputMode.text),
          ),
          _modeButton(
            icon: Icons.mic,
            label: '🎤',
            selected: _followUpMode == _InputMode.voice,
            onTap: () => setState(() => _followUpMode = _InputMode.voice),
          ),
        ],
      ),
    );
  }

  Widget _modeButton({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1565C0) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(label,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
      ),
    );
  }

  Widget _textAnswerRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: _answerCtrl,
            maxLines: 3,
            minLines: 1,
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontSize: 17),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _submitAnswerText(),
            decoration: InputDecoration(
              hintText: 'Type your answer... / 回答を入力',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
              filled: true,
              fillColor: const Color(0xFF1A2E45),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: _submitAnswerText,
          child: Container(
            width: 52,
            height: 52,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF00897B),
            ),
            child: const Icon(Icons.send, color: Colors.white, size: 22),
          ),
        ),
      ],
    );
  }

  Widget _voiceAnswerRow() {
    return Center(
      child: Column(
        children: [
          GestureDetector(
            onTap: _startFollowUpVoice,
            child: Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF1976D2),
              ),
              child: const Icon(Icons.mic, color: Colors.white, size: 38),
            ),
          ),
          const SizedBox(height: 10),
          const Text('Tap to speak / タップして話す',
              style: TextStyle(color: Colors.white70, fontSize: 14)),
        ],
      ),
    );
  }

  // ─── 録音中エリア ────────────────────────────────────────
  Widget _voiceRecordingArea({required bool isInitial}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      decoration: const BoxDecoration(
        color: Color(0xFF0D1B2A),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // リアルタイム文字起こし
          if (_voiceTranscribed.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1A2E45),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _voiceTranscribed,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),

          Text(
            _t.t('hint_listening'),
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 14),
          AnimatedBuilder(
            animation: _pulseAnim,
            builder: (_, child) =>
                Transform.scale(scale: _pulseAnim.value, child: child),
            child: GestureDetector(
              onTap: _stopVoiceManually,
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFB71C1C),
                  boxShadow: [
                    BoxShadow(
                      color:
                          const Color(0xFFB71C1C).withValues(alpha: 0.35),
                      blurRadius: 24,
                      spreadRadius: 6,
                    ),
                  ],
                ),
                child: const Icon(Icons.stop_rounded,
                    color: Colors.white, size: 38),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '話し終わったら ■ をタップ\nTap ■ when finished speaking',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
  }

  // ─── 解析中・読み上げ中の placeholder ──────────────────
  // 3 段階のローディング状態を表示：
  //  - analyzing      : 「解析中...」（標準応答待ち）
  //  - searching_icd11: 「📚 ICD-11 を検索中...」（最終トリアージ前）
  //  - thinking       : 「🧠 詳細な鑑別診断中...」（Thinking モード推論）
  Widget _disabledHint() {
    final isReading = _stage == _Stage.ttsReading;
    if (isReading) {
      return _hintRow(
        icon: const Icon(Icons.volume_up,
            color: Color(0xFF42A5F5), size: 18),
        text: _t.t('hint_tap_to_stop'),
      );
    }
    // ステージごとにメッセージを切り替え
    switch (_analyzingStage) {
      case 'searching_icd11':
        return _hintRow(
          icon: const Icon(Icons.menu_book,
              color: Color(0xFF66BB6A), size: 20),
          text: _t.t('hint_searching_icd11'),
        );
      case 'thinking':
        return _hintRow(
          icon: const Icon(Icons.psychology,
              color: Color(0xFFE65100), size: 20),
          text: _t.t('hint_thinking'),
        );
      case 'analyzing':
      default:
        return _hintRow(
          icon: const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Color(0xFF42A5F5)),
          ),
          text: _t.t('hint_analyzing'),
        );
    }
  }

  Widget _hintRow({required Widget icon, required String text}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF0D1B2A),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          icon,
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── メッセージバブル ──────────────────────────────────────
class _MessageBubble extends StatefulWidget {
  final _Message message;
  const _MessageBubble({super.key, required this.message});

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble>
    with TickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;
  late Animation<Offset> _slide;

  // タイプライター用
  AnimationController? _typeCtrl;
  Animation<int>? _typeAnim;

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

    if (widget.message.typewriter) {
      // 1文字 ≈ 28ms で reveal（短文 0.5秒〜長文 3秒くらい）
      final charCount = widget.message.text.characters.length;
      _typeCtrl = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: (charCount * 28).clamp(400, 4000)),
      );
      _typeAnim = IntTween(begin: 0, end: charCount).animate(
        CurvedAnimation(parent: _typeCtrl!, curve: Curves.easeOut),
      );
      _typeCtrl!.forward();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _typeCtrl?.dispose();
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
                  child: _typeAnim == null
                      ? Text(
                          widget.message.text,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              height: 1.5),
                        )
                      : AnimatedBuilder(
                          animation: _typeAnim!,
                          builder: (_, __) {
                            final n = _typeAnim!.value;
                            final shown = widget.message.text.characters
                                .take(n)
                                .toString();
                            final isComplete =
                                n >= widget.message.text.characters.length;
                            return Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(text: shown),
                                  if (!isComplete)
                                    const TextSpan(
                                      text: '▍',
                                      style: TextStyle(
                                          color: Color(0xFF42A5F5)),
                                    ),
                                ],
                              ),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  height: 1.5),
                            );
                          },
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
                  child: const Icon(Icons.person,
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
            // Flutter perf:
            // - Opacity widget は (子が複雑だと) saveLayer を発火するアンチパターン
            //   → 色に alpha を直接乗せる (withValues) 方式に変更
            // - AnimatedBuilder の builder 内で List.generate するとアニメーション
            //   tick ごとに 3 個の widget が作り直される → 静的部を child に外出し
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
