import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../services/gemma_service.dart';
import '../services/session_service.dart';
import '../services/translation_service.dart';
import 'questionnaire_screen.dart';
import 'conversation_screen.dart';

class ResultScreen extends StatefulWidget {
  final TriageResult result;

  /// 新しいトリアージ結果のとき true（自動保存する）
  /// 保存済み結果を見るだけのとき false（タイムスタンプを上書きしない）
  final bool saveOnLoad;

  const ResultScreen({
    super.key,
    required this.result,
    this.saveOnLoad = true,
  });

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  final FlutterTts _tts = FlutterTts();
  bool _isSpeaking = false;
  final _t = TranslationService.instance;

  @override
  void initState() {
    super.initState();
    _t.addListener(_onTranslationChanged);
    // エラー結果は保存しない（valid な結果のみ保存）
    if (widget.saveOnLoad && !widget.result.isError) {
      SessionService.saveResult(widget.result);
    }
  }

  void _onTranslationChanged() {
    if (mounted) setState(() {});
  }

  // 色覚バリアフリー配色：青・オレンジ・赤＋形＋数字で補完
  Color get _levelColor {
    switch (widget.result.level) {
      case 1:
        return const Color(0xFF1565C0); // 青
      case 3:
        return const Color(0xFFB71C1C); // 濃い赤
      default:
        return const Color(0xFFE65100); // オレンジ
    }
  }

  IconData get _levelIcon {
    switch (widget.result.level) {
      case 1:
        return Icons.check_circle;
      case 3:
        return Icons.cancel;
      default:
        return Icons.warning;
    }
  }

  String get _levelLabel {
    switch (widget.result.level) {
      case 1:
        return 'Manage at home';
      case 3:
        return 'Go to hospital NOW';
      default:
        return 'See a doctor soon';
    }
  }

  String get _speakText {
    final summary = widget.result.summary.isNotEmpty
        ? '${widget.result.summary} '
        : '';
    final conditions = widget.result.possibleConditions.isNotEmpty
        ? ' ${widget.result.possibleConditions}.'
        : '';
    return '${summary}Level ${widget.result.level}. ${widget.result.action}.$conditions ${widget.result.details}';
  }

  Future<void> _toggleSpeak() async {
    if (_isSpeaking) {
      await _tts.stop();
      setState(() => _isSpeaking = false);
    } else {
      setState(() => _isSpeaking = true);
      await _tts.setLanguage(widget.result.languageCode);
      await _tts.setSpeechRate(0.45);
      await _tts.speak(_speakText);
      setState(() => _isSpeaking = false);
    }
  }

  // ─── やり直す（直前の入力からやり直し） ────────────────────
  // 結果画面 → 入力画面（pushReplacement）→ 戻るとホーム
  void _redoTriage() {
    _tts.stop();
    // 入力モードを聞く（問診票 vs 対話相談）
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A2E45),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Choose input mode',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const QuestionnaireScreen()),
                  );
                },
                icon: const Icon(Icons.assignment_outlined),
                label: const Text('Questionnaire'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const ConversationScreen()),
                  );
                },
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Conversation'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF388E3C),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.white54)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── 新しい相談（ホームへ戻る = 結果保持） ─────────────
  void _startNew() {
    _tts.stop();
    Navigator.pop(context); // ホームへ戻る（pushReplacement で来ているのでホームに戻る）
  }

  // ─── 全エラー情報をクリップボードにコピー ──────────────
  // Claude.ai 等に貼り付けて診断してもらえる形式で出力
  Future<void> _copyAllErrorInfo(ErrorExplanation exp) async {
    final timestamp = DateTime.now().toIso8601String();
    final report = '''
═══ MediGemma Field - Error Report ═══
Time: $timestamp
Category: ${exp.tag}
Language: ${widget.result.languageCode}

━━ Likely cause ━━
${exp.suspectedCause}

━━ What you can do ━━
${exp.userAction}

━━ Technical details ━━
${exp.technicalDetails}

═══ End of report ═══
''';

    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF1565C0),
        content: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white, size: 18),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Copied to clipboard',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _t.removeListener(_onTranslationChanged);
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // エラー時は専用画面（Level バッジ・SUMMARY等を出さず赤い大きなエラーUI）
    if (widget.result.isError) {
      return _buildErrorScreen();
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1B2A),
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(_t.t('result_title'),
            style: const TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ━━ 1. 緊急度レベル（色＋形＋数字＋テキスト・色覚バリアフリー） ━━
              _levelHeader(),
              const SizedBox(height: 16),

              // ━━ 2. ★ ACTION（最上部に移動・パニック時に最初に見える） ━━
              _actionCard(),
              const SizedBox(height: 16),

              // ━━ 3. 音声読み上げボタン ━━
              _readAloudButton(),
              const SizedBox(height: 24),

              // ━━ 4. AIが理解した状況サマリー（SBAR S+B・検証用） ━━
              if (widget.result.summary.isNotEmpty) ...[
                _summaryCard(),
                const SizedBox(height: 24),
              ],

              // ━━ 5. 鑑別診断（POSSIBLE_CONDITIONS） ━━
              if (widget.result.possibleConditions.isNotEmpty) ...[
                _conditionsCard(),
                const SizedBox(height: 24),
              ],

              // ━━ 6. 詳細（DETAILS） ━━
              _detailsSection(),
              const SizedBox(height: 24),

              // ━━ 7. 免責事項 ━━
              Text(
                _t.t('result_disclaimer'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
              const SizedBox(height: 24),

              // ━━ 8. アクションボタン群 ━━
              OutlinedButton.icon(
                onPressed: _redoTriage,
                icon: const Icon(Icons.refresh, size: 22),
                label: Text(
                  _t.t('btn_redo_triage'),
                  style: const TextStyle(fontSize: 16),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFFE65100), width: 1.5),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),

              // 新しい相談（NGO ボランティア向け）
              ElevatedButton.icon(
                onPressed: _startNew,
                icon: const Icon(Icons.person_add_alt, size: 22),
                label: Text(
                  _t.t('btn_start_new_triage'),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),

              // 戻る（ホームへ）
              TextButton(
                onPressed: () {
                  _tts.stop();
                  Navigator.pop(context);
                },
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white60,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(_t.t('btn_go_back_home'),
                    style: const TextStyle(fontSize: 15)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── エラー画面（AIエラー時の専用表示・2層構造） ──────────
  // 上段：IT非対応者向け「おそらくの原因」「できること」（平易な日本語）
  // 下段：開発者向け「技術的詳細」（折りたたみ・コピー可能）
  Widget _buildErrorScreen() {
    final exp = widget.result.errorExplanation;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1B2A),
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Error',
            style: TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ━━ 1. 大見出し（赤い大きなエラーバナー） ━━
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFFB71C1C).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: const Color(0xFFB71C1C), width: 2),
                ),
                child: Row(
                  children: const [
                    Icon(Icons.error_outline,
                        color: Color(0xFFB71C1C), size: 32),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Unable to provide a result',
                            style: TextStyle(
                                color: Color(0xFFB71C1C),
                                fontSize: 18,
                                fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'AI could not respond — this is NOT a result',
                            style: TextStyle(
                                color: Color(0xFFB71C1C), fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // ━━ 2. おそらくの原因（IT非対応者向け） ━━
              if (exp != null) _causeCard(exp),
              const SizedBox(height: 12),

              // ━━ 3. できること ━━
              if (exp != null) _actionCardError(exp),
              const SizedBox(height: 16),

              // ━━ 4. 技術的詳細（折りたたみ） ━━
              if (exp != null) _technicalDetailsCard(exp),
              const SizedBox(height: 16),

              // ━━ 5. 全エラー情報を一括コピー（開発者・サポート用） ━━
              if (exp != null)
                OutlinedButton.icon(
                  onPressed: () => _copyAllErrorInfo(exp),
                  icon: const Icon(Icons.copy, size: 20),
                  label: const Text(
                    'Copy full error report',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white54, width: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              if (exp != null) const SizedBox(height: 6),
              if (exp != null)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'Paste this into Claude.ai chat for help diagnosing the issue',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ),
              const SizedBox(height: 16),

              // ━━ 6. ボタン群 ━━
              ElevatedButton.icon(
                onPressed: _redoTriage,
                icon: const Icon(Icons.refresh, size: 22),
                label: const Text(
                  'Try again',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFB71C1C),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  _tts.stop();
                  Navigator.pop(context);
                },
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white60,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text('Go back to home',
                    style: TextStyle(fontSize: 15)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 「おそらくの原因」カード
  Widget _causeCard(ErrorExplanation exp) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFE65100).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: const Color(0xFFE65100).withValues(alpha: 0.5),
            width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.psychology_outlined,
                  color: Color(0xFFE65100), size: 20),
              SizedBox(width: 8),
              Text(
                'Likely cause',
                style: TextStyle(
                    color: Color(0xFFE65100),
                    fontSize: 13,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(
            exp.suspectedCause,
            style: const TextStyle(
                color: Colors.white, fontSize: 15, height: 1.5),
          ),
        ],
      ),
    );
  }

  // 「できること」カード
  Widget _actionCardError(ErrorExplanation exp) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF42A5F5).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: const Color(0xFF42A5F5).withValues(alpha: 0.5),
            width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.lightbulb_outline,
                  color: Color(0xFF42A5F5), size: 20),
              SizedBox(width: 8),
              Text(
                'What you can do',
                style: TextStyle(
                    color: Color(0xFF42A5F5),
                    fontSize: 13,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(
            exp.userAction,
            style: const TextStyle(
                color: Colors.white, fontSize: 14, height: 1.6),
          ),
        ],
      ),
    );
  }

  // 「技術的詳細」カード（折りたたみ可能）
  Widget _technicalDetailsCard(ErrorExplanation exp) {
    return Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
      ),
      child: ExpansionTile(
        tilePadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        childrenPadding:
            const EdgeInsets.fromLTRB(14, 0, 14, 14),
        backgroundColor: Colors.white.withValues(alpha: 0.05),
        collapsedBackgroundColor: Colors.white.withValues(alpha: 0.05),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Colors.white24, width: 1)),
        collapsedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Colors.white24, width: 1)),
        iconColor: Colors.white54,
        collapsedIconColor: Colors.white54,
        title: Row(
          children: [
            const Icon(Icons.bug_report_outlined,
                color: Colors.white54, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Technical details  (${exp.tag})',
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              exp.technicalDetails,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  height: 1.4,
                  fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Long-press to select and copy (share with the developer)',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }

  // ─── ① レベルヘッダー ───────────────────────────────────
  Widget _levelHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _levelColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white30, width: 2),
      ),
      child: Row(
        children: [
          Icon(_levelIcon, color: Colors.white, size: 56),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Level ${widget.result.level}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _levelLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── ② ACTION カード（最上部に表示・最も大きく） ─────────
  Widget _actionCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _levelColor, width: 3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.priority_high, color: _levelColor, size: 20),
              const SizedBox(width: 6),
              Text(
                _t.t('result_what_to_do'),
                style: TextStyle(
                    color: _levelColor,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 長押しで選択 → コピー可能
          SelectableText(
            widget.result.action,
            style: const TextStyle(
              color: Color(0xFF0D1B2A),
              fontSize: 20,
              fontWeight: FontWeight.bold,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  // ─── ③ 読み上げボタン ───────────────────────────────────
  Widget _readAloudButton() {
    return ElevatedButton.icon(
      onPressed: _toggleSpeak,
      icon: Icon(_isSpeaking ? Icons.stop : Icons.volume_up, size: 22),
      label: Text(
        _isSpeaking ? _t.t('btn_stop') : _t.t('btn_read_aloud'),
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white24,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  // ─── ④ サマリーカード（AIが理解した状況・SBAR S+B） ─────
  Widget _summaryCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.fact_check_outlined,
                  color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              Text(
                _t.t('result_summary_header'),
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(
            widget.result.summary,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _t.t('result_summary_redo_hint'),
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ─── ⑤ 鑑別診断カード ───────────────────────────────────
  Widget _conditionsCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _t.t('result_conditions_header'),
          style: const TextStyle(color: Colors.white70, fontSize: 15),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1A2E45),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: const Color(0xFF42A5F5).withValues(alpha: 0.3),
                width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.science_outlined,
                      color: Color(0xFF42A5F5), size: 18),
                  const SizedBox(width: 8),
                  Text(
                    _t.t('result_conditions_dx_label'),
                    style: const TextStyle(
                        color: Color(0xFF42A5F5),
                        fontSize: 14,
                        fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 病名コピー用 — Web検索などに使える
              SelectableText(
                widget.result.possibleConditions,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _t.t('result_conditions_disclaimer'),
                style: const TextStyle(
                    color: Colors.white54, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.touch_app,
                      color: Colors.white38, size: 13),
                  const SizedBox(width: 4),
                  Text(
                    _t.t('result_long_press_hint'),
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── ⑥ 詳細セクション ───────────────────────────────────
  Widget _detailsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _t.t('result_details_header'),
          style: const TextStyle(color: Colors.white70, fontSize: 15),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            widget.result.details,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              height: 1.6,
            ),
          ),
        ),
      ],
    );
  }
}
