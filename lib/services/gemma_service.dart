import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'icd_service.dart';
import 'model_service.dart';

// ─── Gemma 4 完全オフライン医療トリアージサービス ─────────────────
//
// 2026-05-09 完全オフライン化決定：
// オンライン API は廃止。すべての推論は端末内で完結。
//
// 採用モデル：Gemma 4 E2B int4 `.litertlm`（≈ 2.4 GB・Apache 2.0）
// flutter_gemma 0.14.5+ の新 API（installModel ビルダー / createSession）を使用。
//
// 3 層ルーティング設計：
//  Layer 1: ICD-11 辞書ルックアップ（IcdService）
//  Layer 2: Gemma 4 Standard mode（フォローアップ質問）— enableThinking: false
//  Layer 3: Gemma 4 Thinking mode（最終トリアージ）— enableThinking: true
//
// Cactus Prize の "intelligently routes tasks between models" に 3 通りで適合。

// ─── 会話履歴つき多段階問診プロンプト（Standard mode 用）────────
// WHO ETAT + OPQRST + 人口統計的考慮をすべて統合
String _buildConversationalPrompt(
  String original,
  List<Map<String, String>> qaHistory,
  int maxQuestions,
) {
  final questionsAsked = qaHistory.length;
  final remaining = maxQuestions - questionsAsked;

  final historyBlock = qaHistory.isEmpty
      ? ''
      : '\n━━ CONVERSATION SO FAR ━━\n' +
          qaHistory
              .asMap()
              .entries
              .map((e) =>
                  'Question ${e.key + 1}: ${e.value['q']}\n'
                  'Answer ${e.key + 1}: ${e.value['a']}')
              .join('\n\n') +
          '\n';

  final decisionRule = remaining <= 0
      ? 'DECISION RULE: You have reached the maximum of $maxQuestions questions. '
          'You MUST now respond TYPE: TRIAGE. Do NOT ask another question.'
      : 'DECISION RULE: You may ask up to $remaining more question(s). '
          'Ask only if a clinically critical piece of information is still missing. '
          'If you already have enough information to triage accurately, respond TYPE: TRIAGE now.';

  return '''
You are a medical triage assistant following WHO Emergency Triage Assessment and Treatment (ETAT) guidelines, designed for remote areas and resource-limited settings.

━━ PATIENT ━━
Initial complaint: "$original"
$historyBlock
━━ PRIORITY CHECK: WHO ETAT Emergency Signs ━━
If ANY of these signs are present, respond TYPE: TRIAGE with LEVEL: 3 immediately:
• Airway obstruction or severe difficulty breathing
• Signs of shock: cold extremities, weak/rapid pulse, altered consciousness
• Unconsciousness or active convulsions
• Severe uncontrolled bleeding or major trauma
• Chest pain or pressure (possible cardiac event)
• Signs of stroke: facial droop, arm weakness, speech difficulty
• Snake or animal bite / suspected poisoning or overdose
• Severe dehydration: sunken eyes, dry mouth, no urine output
• Severe burns covering large body area

━━ INFORMATION COMPLETENESS: OPQRST + Demographics ━━
Assess what is still unknown. A clinically sound triage should ideally cover:
• Onset — when did it start? sudden or gradual?
• Quality — what does it feel like? (sharp / dull / burning / cramping / pressure)
• Region — where exactly? does it radiate or spread?
• Severity — how bad on a scale of 1–10?
• Time — how long? constant or intermittent?
• Associated symptoms — fever, vomiting, bleeding, etc.
• Age — required if triage level differs between child / adult / elderly
• Sex and pregnancy status — required for abdominal, pelvic, back pain, leg swelling,
  breast symptoms, or urinary symptoms in anyone who may be female of reproductive age
• Location / access to care — affects recommended triage level in remote settings

$decisionRule

━━ FOLLOW-UP QUESTION GUIDELINES — CRITICAL ━━
• ACCEPT REASONABLE ANSWERS. If the patient gave a reasonable answer (even if vague),
  accept it and move on to a different aspect. NEVER re-ask the same thing rephrased.
  Example WRONG: "Where is the pain?" → "middle" → "Can you be more specific?" ❌
  Example RIGHT: "Where is the pain?" → "middle" → next question about another aspect ✓
• Patients in remote/refugee settings often cannot give precise answers. That is OK.
  Move on to a different OPQRST element or demographic factor.
• ★★ Do not ask about the same topic twice. Check the conversation history above.
   If the patient already gave the body part (e.g. "throat / 喉"), do NOT ask
   "where exactly?" — the part is fixed. Drill into pain quality / duration / severity instead.
• ★★ Do not ask about information the patient ALREADY provided in the initial complaint.
   If the initial complaint says "throat pain", do NOT ask "where does it hurt?".
• ★★ Once the patient answers a question, treat that answer as final. Do not ask the same
   question with synonyms or examples. If they said "sharp / 鋭い", do NOT ask
   "is it sharp, dull, or burning?" again.
• Use plain, friendly language — assume the user has no medical training.

━━ CONVERSATION CONTINUITY RULE (HARD CONSTRAINT) ━━
The next question MUST be a logical continuation of the conversation.
ABSOLUTELY FORBIDDEN behaviors:
✗ Starting with vague phrases like "Can you...?" / "できますか？" / "教えてください" without
  immediate context referring to a specific symptom.
✗ Ignoring the patient's most recent answer.
✗ Introducing topics unrelated to the patient's stated symptoms.
✗ Asking generic questions that could apply to any patient.

REQUIRED:
✓ Reference a specific symptom or detail the patient already mentioned.
✓ Drill DEEPER into the existing symptom set (e.g. if abdominal pain → ask about pain
  location, associated nausea, fever, etc., not random topics).
✓ Each question should feel like it is BUILDING on what was said before.

━━ PAIN ASSESSMENT — PLAIN-LANGUAGE GUIDANCE ━━
When asking about pain severity (the "S" in OPQRST), use friendly language with examples:
• Good: "1〜10で表すと、1は『軽い違和感』、10は『今までで一番ひどい痛み』、今はどのくらい？"
• Good (English): "On a scale of 1–10, where 1 is mild and 10 is the worst pain you can imagine, how bad is it?"
• BAD: "Severity 1-10?" (too clinical, confusing for laypeople)

When asking about pain quality (the "Q" in OPQRST), give CHOICES instead of open question:
• Good: "鋭い痛みですか？鈍い痛みですか？焼けるような痛みですか？"
• Good (English): "Is it sharp, dull, burning, or cramping?"
• BAD: "Describe the quality of the pain." (too vague)

━━ SIZE / AMOUNT QUESTIONS — USE EVERYDAY OBJECTS ━━
When asking about size (rashes, lumps, bumps, wounds, blood loss volume, etc.), use
everyday-object analogies that anyone can answer without measuring:
• Good: "大きさはどのくらい？米粒くらい？小豆くらい？大豆くらい？それより大きい？"
• Good (English): "How big is it? Like a grain of rice? A small bean? A pea? Larger?"
• BAD: "What is the diameter in millimeters?" (impossible for laypeople)
For blood: "ティースプーン1杯くらい / コップ半分くらい / それ以上"

━━ TIME / DURATION QUESTIONS — USE EVERYDAY TIMEFRAMES ━━
When asking about timing, give common timeframes as choices:
• Good: "いつ始まりましたか？数分前 / 数時間前 / 今日 / 昨日 / 数日前 / 1週間以上前"
• Good (English): "When did it start? Minutes ago / hours ago / today / yesterday / a few days ago / over a week ago"

━━ DEMOGRAPHIC REASONING ━━
AGE:
• Children under 5 (WHO IMCI): lower threshold for Level 3 for fever, breathing, feeding
• Elderly 65+: atypical presentations; assign HIGHER level when uncertain
• If age is not stated and it would change the triage level — ask

SEX AND PREGNANCY:
• Female of reproductive age with abdominal/pelvic/back pain, leg swelling, or vaginal bleeding:
  always consider ectopic pregnancy, miscarriage, ovarian torsion, or DVT/PE
• If sex and pregnancy status are unknown and clinically relevant — ask

━━ CRITICAL LANGUAGE RULE ━━
Detect the language of the initial complaint. All QUESTION / ACTION / DETAILS content
must be written in that language. Format keys stay in English.

SCRIPT RULE — native writing system ONLY, no romanization of any kind:
• Japanese → kanji/hiragana/katakana only. Zero romaji.
• Arabic, Persian, Urdu → Arabic script only. No Latin letters.
• Hindi, Nepali, Marathi → Devanagari only.
• Thai, Lao → native scripts only.
• Korean → Hangul only.
• Chinese → characters only. No pinyin.
• Russian, Ukrainian → Cyrillic only.
• Greek → Greek script only.

━━ RESPONSE FORMAT ━━

If asking a follow-up question → respond EXACTLY:
TYPE: FOLLOWUP
QUESTION: [One question in USER'S LANGUAGE. Ask only the SINGLE most important missing item. Max 25 words. Do not combine multiple questions.]
QUICK_REPLIES: [3 to 6 short answer options for THIS specific question, in USER'S LANGUAGE, separated by " | ". Each option max 10 characters. Examples:
  - For "鋭い痛みですか、鈍い痛みですか？" → "鋭い | 鈍い | 焼ける | 締めつけ | 波がある"
  - For "いつから痛いですか？" → "数分前 | 数時間前 | 今日 | 昨日 | 数日前 | 1週間以上"
  - For "10段階でどのくらい痛い？" → "軽い (2) | 中くらい (5) | かなり (7) | 我慢できない (9)"
  - For "発熱はありますか？" → "はい | いいえ | わからない"
  - For yes/no questions, use "はい | いいえ | わからない"
  - For age questions, use age groups like "0〜4歳 | 5〜12歳 | 13〜17歳 | 18〜64歳 | 65歳以上"
  - DO NOT generate "yes/no/unknown" for non-yes-no questions. Match the question type.]

If triaging → respond EXACTLY:
TYPE: TRIAGE
LEVEL: [1, 2, or 3]
SUMMARY: [SBAR Situation+Background — 1–3 sentences in USER'S LANGUAGE summarizing what you understood from the patient. Include: key symptoms, location, severity, duration, and any demographic factors (age/sex/pregnancy) that influenced your assessment.]
ACTION: [One concrete sentence in USER'S LANGUAGE — what to do RIGHT NOW]
POSSIBLE_CONDITIONS:
- [Most likely condition in USER'S LANGUAGE — short phrase + brief clinical reason. Max 15 words.]
- [Second possibility, if applicable. Same format.]
- [Third possibility max. Only include if genuinely plausible.]
DETAILS:
- [Specific immediate home care or first-aid steps]
- [When and which type of doctor/department to see, if applicable]
- [Specific red-flag warning signs indicating deterioration]
DISCLAIMER: This is not a substitute for professional medical diagnosis.

━━ TRIAGE LEVELS (WHO ETAT) ━━
Level 1 — Non-urgent: Manageable at home with specific home care instructions.
Level 2 — Priority: See a doctor within 24–72 hours. Specify specialty.
Level 3 — Emergency: Go to hospital immediately. State what to tell the doctor.
When uncertain, always assign the HIGHER level.
''';
}

// ─── 画像診断用プロンプト ──────────────────────────────────────
String _buildImageTriagePrompt({
  String description = '',
  String bodyRegion = '',
}) {
  final contextBlock = (description.isEmpty && bodyRegion.isEmpty)
      ? 'No additional context provided. Analyze the image alone.'
      : [
          if (bodyRegion.isNotEmpty) 'Body region shown: $bodyRegion',
          if (description.isNotEmpty)
            'Patient\'s description: "$description"',
          'Use this context to focus your analysis on the relevant area of the image.',
        ].join('\n');

  return '''
You are a medical triage assistant following WHO Emergency Triage Assessment and Treatment (ETAT) guidelines.

━━ PATIENT CONTEXT ━━
$contextBlock

━━ IMAGE ANALYSIS TASK ━━
Analyze the attached image for visible medical symptoms (wounds, rashes, swelling, burns, discoloration, etc.).
If a description is provided, focus on the area/condition the patient mentioned.
If you cannot identify the medical issue with confidence, say so in DETAILS and recommend in-person evaluation.

━━ CRITICAL LANGUAGE RULE ━━
Detect the language of the patient's description above (if any).
If no description is given, default to English.
ALL content in ACTION, POSSIBLE_CONDITIONS, and DETAILS MUST be in that language.
Format keys (LEVEL:, ACTION:, etc.) stay in English.

SCRIPT RULE — native writing system ONLY, no romanization of any kind:
• Japanese → kanji/hiragana/katakana only. Zero romaji.
• Arabic, Persian, Urdu → Arabic script only. No Latin letters.
• Hindi, Nepali, Marathi → Devanagari only.
• Thai, Lao → native scripts only.
• Korean → Hangul only.
• Chinese → characters only. No pinyin.
• Russian, Ukrainian → Cyrillic only.
• Greek → Greek script only.

━━ CONTENT RULES ━━
- ACTION: one concrete sentence — what to do RIGHT NOW
- POSSIBLE_CONDITIONS: 1–3 most likely conditions visible in the image
- DETAILS must include:
  * Immediate wound/skin care steps
  * Signs of infection or worsening to watch for
  * When to seek emergency care

━━ RESPONSE FORMAT (EXACTLY) ━━
LEVEL: [1, 2, or 3]
SUMMARY: [1–3 sentences in USER'S LANGUAGE summarizing what you observed in the image and the patient's context.]
ACTION: [One concrete sentence in USER'S LANGUAGE]
POSSIBLE_CONDITIONS:
- [Most likely visible condition — short phrase + brief reason. Max 15 words.]
- [Second possibility if applicable]
- [Third possibility max]
DETAILS:
- [Point 1]
- [Point 2]
- [Point 3 max]
DISCLAIMER: This is not a substitute for professional medical diagnosis.

━━ TRIAGE LEVELS (WHO ETAT) ━━
- Level 1 — Non-urgent: Manageable at home
- Level 2 — Priority: See a doctor within 24–72 hours
- Level 3 — Emergency: Go to hospital immediately

When uncertain, assign the HIGHER level.
''';
}

// ─── データモデル ──────────────────────────────────────────────
class TriageResult {
  final int level;
  final String summary; // SBAR S+B — AIが理解した状況の要約
  final String action;
  final String possibleConditions; // 鑑別診断（箇条書き）
  final String details;
  final String rawResponse;
  final String languageCode;
  final bool isError; // true = AIエラー（valid Level 2と区別）
  final ErrorExplanation? errorExplanation;

  TriageResult({
    required this.level,
    this.summary = '',
    required this.action,
    this.possibleConditions = '',
    required this.details,
    required this.rawResponse,
    this.languageCode = 'en-US',
    this.isError = false,
    this.errorExplanation,
  });

  /// AIエラー時の専用ファクトリ（heuristic で原因と対処法を自動生成）
  factory TriageResult.error(Object error,
      {StackTrace? stack, String? langCode}) {
    return TriageResult(
      level: 0,
      action: '',
      details: '',
      rawResponse: '',
      languageCode: langCode ?? 'en-US',
      isError: true,
      errorExplanation: ErrorExplanation.fromError(error, stack),
    );
  }
}

/// エラー説明：IT非対応者向けの「おそらくの原因」と「できること」+ 技術詳細
/// Gemma 自身がエラー時には呼べないため、エラーパターンから heuristic で生成
///
/// 完全オフライン化により、ネットワーク/認証/レート制限系のエラーは
/// 通常 DL 段階のみで発生（推論段階では発生しない）。
class ErrorExplanation {
  final String suspectedCause;
  final String userAction;
  final String technicalDetails;
  final String tag;

  const ErrorExplanation({
    required this.suspectedCause,
    required this.userAction,
    required this.technicalDetails,
    required this.tag,
  });

  factory ErrorExplanation.fromError(Object error, [StackTrace? stack]) {
    final s = error.toString().toLowerCase();
    final tech = stack != null ? '$error\n\n$stack' : error.toString();

    // モデル未DL（推論前にチェックされるが万一の保険）
    if (s.contains('no active') ||
        s.contains('not installed') ||
        s.contains('model not downloaded') ||
        s.contains('no offline model')) {
      return ErrorExplanation(
        suspectedCause:
            'AI モデルがまだダウンロードされていません。\n'
            '初回は約 2.4 GB のダウンロードが必要です。',
        userAction:
            '・ホーム画面から「AI をダウンロード」を実行\n'
            '・Wi-Fi 環境を推奨（モバイルデータでも可）\n'
            '・一度ダウンロードすれば、以降はネット不要',
        technicalDetails: tech,
        tag: 'model_not_installed',
      );
    }

    // メモリ不足（OOM）
    if (s.contains('out of memory') ||
        s.contains('oom') ||
        s.contains('failed to allocate')) {
      return ErrorExplanation(
        suspectedCause:
            '端末のメモリが不足しています。\n'
            '他のアプリが多くのメモリを使っている可能性があります。',
        userAction:
            '・他のアプリを終了\n'
            '・端末を再起動\n'
            '・もう一度試す',
        technicalDetails: tech,
        tag: 'oom',
      );
    }

    // タイムアウト
    if (s.contains('timeout') || s.contains('timed out') || s.contains('deadline')) {
      return ErrorExplanation(
        suspectedCause:
            'AI の応答に時間がかかりすぎました。\n'
            '端末の処理性能や負荷の問題の可能性があります。',
        userAction:
            '・「もう一度試す」を押す\n'
            '・他のアプリを終了して再試行\n'
            '・端末を再起動',
        technicalDetails: tech,
        tag: 'timeout',
      );
    }

    // パース失敗・形式エラー
    if (s.contains('format') ||
        s.contains('parse') ||
        s.contains('unexpected') ||
        s.contains("type 'null'") ||
        s.contains('null check') ||
        s.contains('range error')) {
      return ErrorExplanation(
        suspectedCause:
            'AI の応答が想定外の形式でした。\n'
            'AI が指示通りに答えなかったか、応答が途中で切れた可能性があります。',
        userAction:
            '・「もう一度試す」を押す（毎回同じとは限らないので）\n'
            '・症状の説明をもう少し詳しく書いてみる\n'
            '・続くようなら開発者に下の「技術的詳細」を見せてください',
        technicalDetails: tech,
        tag: 'parse',
      );
    }

    // ダウンロード関連（DL 中の問題）
    if (s.contains('download') ||
        s.contains('socket') ||
        s.contains('failed host lookup') ||
        s.contains('network is unreachable') ||
        s.contains('connection')) {
      return ErrorExplanation(
        suspectedCause:
            'モデルのダウンロード中にネットワークの問題が発生しました。\n'
            '電波が弱い、Wi-Fi が切れている、または一時的にネットが落ちている可能性があります。',
        userAction:
            '・Wi-Fi または モバイル通信が ON か確認\n'
            '・電波の良い場所へ移動\n'
            '・「もう一度試す」を押す（中断地点から再開可能）',
        technicalDetails: tech,
        tag: 'network',
      );
    }

    // 不明
    return ErrorExplanation(
      suspectedCause:
          '原因がはっきり分かりませんでしたが、何らかの問題で AI が応答できませんでした。',
      userAction:
          '・「もう一度試す」を押す\n'
          '・続くようなら開発者に下の「技術的詳細」を見せてください',
      technicalDetails: tech,
      tag: 'unknown',
    );
  }
}

class TriageStep {
  final bool needsFollowUp;
  final String? followUpQuestion;
  final List<String>? quickReplies; // AI 生成のクイック返信候補（質問に応じて動的に変わる）
  final TriageResult? result;
  final String languageCode; // フォローアップ時のTTS用

  const TriageStep._({
    required this.needsFollowUp,
    required this.languageCode,
    this.followUpQuestion,
    this.quickReplies,
    this.result,
  });

  factory TriageStep.followUp(
    String question,
    String langCode, {
    List<String>? quickReplies,
  }) =>
      TriageStep._(
        needsFollowUp: true,
        followUpQuestion: question,
        quickReplies: quickReplies,
        languageCode: langCode,
      );

  factory TriageStep.done(TriageResult result) => TriageStep._(
        needsFollowUp: false,
        languageCode: result.languageCode,
        result: result,
      );
}

// ─── GemmaService（完全オフライン Gemma 4） ───────────────────
class GemmaService {
  static const int _maxQuestions = 5;

  // Gemma 4 モデル設定
  // 推論コンテキスト：SUMMARY + ACTION + POSSIBLE_CONDITIONS + DETAILS の
  // 5 セクション応答 + 会話履歴を考慮して 2048 トークン確保
  static const int _maxTokens = 2048;

  // 永続化されたオフラインモデル（init は1回のみ・close するまで保持）
  // → 推論ごとの数十秒の初期化コストを回避
  static InferenceModel? _persistentOfflineModel;
  static bool _persistentSupportsImage = false;

  /// 会話ループ型問診：1呼び出しごとに追加質問 or 最終トリアージを返す
  ///
  /// [original]   : 患者が最初に伝えた症状（変わらない）
  /// [qaHistory]  : これまでの Q&A ペア [{q: "質問", a: "回答"}, ...]
  ///
  /// ・質問数が上限（5問）に達した場合は強制的にトリアージ結果を返す
  /// ・緊急サインが1つでも検出されたらその場でLevel3を返す
  ///
  /// ⚠️ Day 3 で 2-stage 化予定（Standard で判定 + Thinking で本番）
  /// 2-stage 解析：
  ///   Stage 1: Standard mode で「フォローアップ要 vs 最終トリアージ」を判定
  ///   Stage 2: 最終トリアージなら ICD-11 ルックアップ + Thinking mode で再生成
  static Future<TriageStep> analyzeNext(
    String original,
    List<Map<String, String>> qaHistory, {
    void Function(String stageMessage)? onStageProgress,
  }) async {
    final langCode = _detectLanguageCode(original);
    final forceTriageNow = qaHistory.length >= _maxQuestions;

    try {
      // ── Stage 1: Standard mode（高速・10 秒前後） ──
      onStageProgress?.call('analyzing');
      debugPrint('[GemmaService.analyzeNext] Stage 1: standard mode');
      final raw = await _callOffline(
        _buildConversationalPrompt(original, qaHistory, _maxQuestions),
        isThinking: false,
      );
      debugPrint('[GemmaService.analyzeNext] Stage 1 raw:\n$raw');

      // フォローアップ判定 → そのまま Standard 結果を返す
      if (!forceTriageNow && raw.contains('TYPE: FOLLOWUP')) {
        final question = _extractFollowUpQuestion(raw, langCode);
        final quickReplies = _extractQuickReplies(raw);
        if (question.isNotEmpty) {
          return TriageStep.followUp(question, langCode,
              quickReplies: quickReplies);
        }
      }

      // ── Stage 2: ICD-11 + Thinking mode（高精度・~30 秒） ──
      // 最終トリアージとなる場合のみ実行
      debugPrint(
          '[GemmaService.analyzeNext] Stage 2: ICD-11 lookup + thinking mode');
      final stage1Parsed = _parseResponse(raw, langCode);
      final finalResult = await _generateFinalTriage(
        original: original,
        qaHistory: qaHistory,
        langCode: langCode,
        stage1Result: stage1Parsed,
        onStageProgress: onStageProgress,
        imageBytes: null,
      );
      return TriageStep.done(finalResult);
    } catch (e, stack) {
      debugPrint('[GemmaService.analyzeNext] ERROR: $e');
      debugPrint('[GemmaService.analyzeNext] stack: $stack');
      return TriageStep.done(
          TriageResult.error(e, stack: stack, langCode: langCode));
    }
  }

  /// Stage 2: ICD-11 ルックアップ + Thinking モードで最終トリアージを生成
  ///
  /// 失敗した場合は [stage1Result]（Standard モードの結果）にフォールバック、
  /// それも空なら _buildFallbackResult で安全側の結果を返す。
  static Future<TriageResult> _generateFinalTriage({
    required String original,
    required List<Map<String, String>> qaHistory,
    required String langCode,
    required TriageResult stage1Result,
    required Uint8List? imageBytes,
    void Function(String stageMessage)? onStageProgress,
  }) async {
    // 全会話を 1 つのテキストに連結（ICD-11 検索キー用）
    final fullConversation = original +
        ' ' +
        qaHistory
            .map((qa) => '${qa['q'] ?? ''} ${qa['a'] ?? ''}')
            .join(' ');

    // ICD-11 ルックアップ（失敗してもクリティカルでない・空配列で続行）
    onStageProgress?.call('searching_icd11');
    List<IcdMatch> icdMatches = const [];
    try {
      icdMatches =
          IcdService.instance.lookup(fullConversation, maxResults: 5);
      debugPrint(
          '[GemmaService] ICD-11 matches: ${icdMatches.length} entries');
    } catch (e) {
      debugPrint('[GemmaService] ICD-11 lookup failed (continuing): $e');
    }
    final icdContext = IcdService.instance.buildPromptContext(icdMatches);

    // Thinking モード用プロンプト構築
    final thinkingPrompt = _buildFinalTriagePrompt(
      original: original,
      qaHistory: qaHistory,
      icdContext: icdContext,
    );

    onStageProgress?.call('thinking');
    debugPrint(
        '[GemmaService] Stage 2 thinking prompt size: ${thinkingPrompt.length} chars');
    try {
      final thinkingRaw = imageBytes != null
          ? await _callOfflineWithImage(thinkingPrompt, imageBytes,
              isThinking: true)
          : await _callOffline(thinkingPrompt, isThinking: true);
      debugPrint(
          '[GemmaService] Stage 2 thinking raw:\n$thinkingRaw');

      final thinkingParsed = _parseResponse(thinkingRaw, langCode);
      if (thinkingParsed.action.trim().isNotEmpty) {
        return thinkingParsed;
      }
      debugPrint(
          '[GemmaService] Stage 2 result empty — falling back to Stage 1');
    } catch (e, st) {
      debugPrint('[GemmaService] Stage 2 ERROR (falling back): $e\n$st');
    }

    // フォールバック：Stage 1 結果が有効ならそれを使う
    if (stage1Result.action.trim().isNotEmpty) {
      return stage1Result;
    }
    // 最終フォールバック：「診断できませんでした」を出さない安全側 Level 2
    return _buildFallbackResult(
        original, qaHistory, stage1Result.rawResponse, langCode);
  }

  /// Stage 2 用プロンプト：会話全体 + ICD-11 結果 + Thinking モード指示
  /// 短くコンパクトに保つ（プロンプト + 推論で 2048 トークンに収まるように）
  static String _buildFinalTriagePrompt({
    required String original,
    required List<Map<String, String>> qaHistory,
    required String icdContext,
  }) {
    final historyBlock = qaHistory.isEmpty
        ? ''
        : '\n━━ Q&A ━━\n' +
            qaHistory
                .asMap()
                .entries
                .map((e) =>
                    'Q${e.key + 1}: ${e.value['q']}\nA${e.key + 1}: ${e.value['a']}')
                .join('\n') +
            '\n';

    final icdBlock = icdContext.isEmpty ? '' : '\n$icdContext\n';

    return '''
You are providing the FINAL medical triage assessment based on the full conversation below. Use careful step-by-step reasoning before answering.

━━ PATIENT ━━
Initial complaint: "$original"
$historyBlock$icdBlock
━━ TRIAGE INSTRUCTIONS ━━
- Reason carefully about the most likely conditions, considering ICD-11 references above if relevant.
- Apply WHO ETAT triage levels (1=home care, 2=see doctor in 24-72h, 3=emergency now).
- When uncertain, assign HIGHER level. Especially:
  • Reproductive-age woman + abdominal/pelvic pain → consider ectopic pregnancy (Level 3)
  • Children under 5 with rapid breathing / fever → consider severe pneumonia (Level 3)
  • Sudden severe headache, chest pain, slurred speech → emergency
- Respond in patient's language. Native script only (no romaji for Japanese, etc.)

━━ RESPONSE FORMAT (EXACTLY) ━━
LEVEL: [1, 2, or 3]
SUMMARY: [1-3 sentences in patient's language summarizing what you understood: key symptoms, location, severity, duration, demographic factors.]
ACTION: [One concrete sentence in patient's language — what to do RIGHT NOW.]
POSSIBLE_CONDITIONS:
- [Most likely condition (use ICD-11 reference name if applicable). Max 15 words.]
- [Second possibility if applicable]
- [Third possibility max]
DETAILS:
- [Specific home care or first-aid steps]
- [When and which type of doctor to see if applicable]
- [Red-flag warning signs to watch for]
DISCLAIMER: This is not a substitute for professional medical diagnosis.
''';
  }

  /// 強制トリアージで AI が指定形式で返さなかった時の最終フォールバック。
  /// 「診断できませんでした」と表示するより、控えめだが有用な結果を出す。
  static TriageResult _buildFallbackResult(
    String original,
    List<Map<String, String>> qaHistory,
    String raw,
    String langCode,
  ) {
    final isJa = langCode == 'ja-JP';
    return TriageResult(
      level: 2, // 不明確な場合は安全側に Level 2
      summary: isJa
          ? '症状：${original.length > 100 ? "${original.substring(0, 100)}..." : original}'
          : 'Symptoms: ${original.length > 100 ? "${original.substring(0, 100)}..." : original}',
      action: isJa
          ? '判断が難しい症状のため、念のため数日以内に医療機関を受診してください。'
          : 'When uncertain, please see a healthcare provider within a few days as a precaution.',
      possibleConditions: isJa
          ? '- AI が確定的な判断をできなかった症状\n- 専門家による評価が必要'
          : '- Symptoms the AI could not assess definitively\n- Requires professional evaluation',
      details: isJa
          ? '・AI からの応答が形式に沿わなかったため、安全側で Level 2 を提示しています\n'
              '・症状が悪化したり緊急サインが出たら、すぐに救急受診してください\n'
              '・もう一度詳しく症状を入力すると、より良い回答が得られる可能性があります'
          : '• AI response was not in expected format. Showing Level 2 as a safe default.\n'
              '• If symptoms worsen or emergency signs appear, seek emergency care immediately.\n'
              '• Re-entering symptoms with more detail may give a better answer.',
      rawResponse: raw,
      languageCode: langCode,
    );
  }

  /// FOLLOWUP 形式から QUESTION: 行を抽出
  static String _extractFollowUpQuestion(String raw, String langCode) {
    // QUESTION: 〜 (QUICK_REPLIES: または改行2回 まで)
    final match = RegExp(
      r'QUESTION:\s*(.+?)(?=\nQUICK_REPLIES:|\n\n|$)',
      dotAll: true,
    ).firstMatch(raw);
    var question = match?.group(1)?.trim() ?? '';
    if (langCode == 'ja-JP') question = _stripRomaji(question);
    return question;
  }

  /// QUICK_REPLIES: 行を抽出して | 区切りで配列化
  /// 形式に沿わない時は null を返す（呼び出し側でローカルフォールバックへ）
  static List<String>? _extractQuickReplies(String raw) {
    final match = RegExp(r'QUICK_REPLIES:\s*(.+)').firstMatch(raw);
    if (match == null) return null;
    final line = match.group(1)?.trim() ?? '';
    if (line.isEmpty) return null;
    final parts = line
        .split('|')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty && p.length <= 30) // 長すぎは異常値として除外
        .toList();
    if (parts.length < 2) return null; // 1 個だけはおかしい
    return parts.take(6).toList(); // 最大 6 個
  }

  /// 後方互換性のためのラッパー（analyzeNext の空履歴版）
  static Future<TriageStep> analyzeFirst(String userInput) =>
      analyzeNext(userInput, []);

  /// 問診票＋画像の統合トリアージ
  /// [original]: 問診票から組み立てたテキスト
  /// [qaHistory]: フォローアップQ&A履歴（最初は空）
  /// [imageBytes]: 添付された画像（null なら画像なし）
  /// [mimeType]: 画像のMIMEタイプ（Gemma 4 マルチモーダルは形式自動判定のため未使用）
  static Future<TriageStep> analyzeNextWithImage(
    String original,
    List<Map<String, String>> qaHistory, {
    List<int>? imageBytes,
    String mimeType = 'image/jpeg',
    void Function(String stageMessage)? onStageProgress,
  }) async {
    // 画像がない場合は通常の analyzeNext へ
    if (imageBytes == null) {
      return analyzeNext(original, qaHistory,
          onStageProgress: onStageProgress);
    }

    final langCode = _detectLanguageCode(original);

    try {
      // ── Stage 1: Standard mode + 画像 ──
      onStageProgress?.call('analyzing');
      final prompt =
          _buildConversationalPrompt(original, qaHistory, _maxQuestions);
      const imagePromptSuffix = '''

━━ IMAGE ATTACHED ━━
The patient has also attached an image. Analyze the image alongside the text information.
Apply the same response format. Include visual findings in SUMMARY.
''';

      final imageBytesU8 = Uint8List.fromList(imageBytes);
      debugPrint(
          '[GemmaService.analyzeNextWithImage] Stage 1: standard + image');
      final raw = await _callOfflineWithImage(
        prompt + imagePromptSuffix,
        imageBytesU8,
        isThinking: false,
      );
      debugPrint('[GemmaService.analyzeNextWithImage] Stage 1 raw:\n$raw');

      // フォローアップ判定
      final forceTriageNow = qaHistory.length >= _maxQuestions;
      if (!forceTriageNow && raw.contains('TYPE: FOLLOWUP')) {
        final question = _extractFollowUpQuestion(raw, langCode);
        final quickReplies = _extractQuickReplies(raw);
        if (question.isNotEmpty) {
          return TriageStep.followUp(question, langCode,
              quickReplies: quickReplies);
        }
      }

      // ── Stage 2: ICD-11 + Thinking + 画像 ──
      final stage1Parsed = _parseResponse(raw, langCode);
      final finalResult = await _generateFinalTriage(
        original: original,
        qaHistory: qaHistory,
        langCode: langCode,
        stage1Result: stage1Parsed,
        imageBytes: imageBytesU8,
        onStageProgress: onStageProgress,
      );
      return TriageStep.done(finalResult);
    } catch (e, stack) {
      debugPrint('[GemmaService.analyzeNextWithImage] ERROR: $e');
      debugPrint('[GemmaService.analyzeNextWithImage] stack: $stack');
      return TriageStep.done(
          TriageResult.error(e, stack: stack, langCode: langCode));
    }
  }

  /// 画像診断（写真入力画面から呼ぶ）
  /// Gemma 4 のマルチモーダル機能でオフライン画像解析
  /// [description]: ユーザーが書いた症状説明（言語検出のソース）
  /// [bodyRegion]: 部位選択ラベル（AIに撮影部位を伝える）
  static Future<TriageResult> triageWithImage(
    List<int> imageBytes,
    String mimeType, {
    String description = '',
    String bodyRegion = '',
  }) async {
    final langCode = description.isEmpty
        ? 'en-US'
        : _detectLanguageCode(description);

    try {
      final raw = await _callOfflineWithImage(
        _buildImageTriagePrompt(
          description: description,
          bodyRegion: bodyRegion,
        ),
        Uint8List.fromList(imageBytes),
      );
      return _parseResponse(raw, langCode);
    } catch (e, stack) {
      debugPrint('[GemmaService.triageWithImage] ERROR: $e');
      debugPrint('[GemmaService.triageWithImage] stack: $stack');
      return TriageResult.error(e, stack: stack, langCode: langCode);
    }
  }

  // ─── 内部ヘルパー ────────────────────────────────────────────

  /// オフラインモデルを取得・初回のみ作成
  /// [supportImage]: 画像対応セッションが必要かどうか
  /// 画像対応の有無で別インスタンスが必要なため、要求された機能と
  /// 既存インスタンスの能力が合わない場合は再作成する
  static Future<InferenceModel> _ensureOfflineModel({
    bool supportImage = false,
  }) async {
    // 既存モデルが要求機能を満たすなら使い回し
    if (_persistentOfflineModel != null &&
        (!supportImage || _persistentSupportsImage)) {
      return _persistentOfflineModel!;
    }

    // 機能が足りない・未生成 → 既存を破棄して再生成
    if (_persistentOfflineModel != null) {
      await _persistentOfflineModel!.close();
      _persistentOfflineModel = null;
    }

    debugPrint(
        '[GemmaService] Creating Gemma 4 model (supportImage=$supportImage)...');
    _persistentOfflineModel = await FlutterGemma.getActiveModel(
      maxTokens: _maxTokens,
      supportImage: supportImage,
    );
    _persistentSupportsImage = supportImage;
    debugPrint('[GemmaService] Gemma 4 model ready.');
    return _persistentOfflineModel!;
  }

  /// テキスト入力でオフライン推論
  /// [isThinking]: Thinking Mode を有効化（Day 3 で activated）
  static Future<String> _callOffline(
    String prompt, {
    bool isThinking = false,
  }) async {
    final hasModel = await ModelService.isModelDownloaded();
    if (!hasModel) {
      throw Exception(
        'Offline model not downloaded. Please download the AI model first.',
      );
    }

    final model = await _ensureOfflineModel(supportImage: false);
    final session = await model.createSession(
      temperature: 0.7,
      topK: 40,
      enableThinking: isThinking,
    );
    try {
      await session.addQueryChunk(Message.text(text: prompt, isUser: true));
      return await session.getResponse();
    } finally {
      await session.close();
    }
  }

  /// 画像付きでオフライン推論（Gemma 4 マルチモーダル）
  /// [isThinking]: Thinking Mode を有効化（Day 3 で activated）
  static Future<String> _callOfflineWithImage(
    String prompt,
    Uint8List imageBytes, {
    bool isThinking = false,
  }) async {
    final hasModel = await ModelService.isModelDownloaded();
    if (!hasModel) {
      throw Exception(
        'Offline model not downloaded. Please download the AI model first.',
      );
    }

    final model = await _ensureOfflineModel(supportImage: true);
    final session = await model.createSession(
      temperature: 0.7,
      topK: 40,
      enableVisionModality: true,
      enableThinking: isThinking,
    );
    try {
      await session.addQueryChunk(
        Message.withImage(
          text: prompt,
          imageBytes: imageBytes,
          isUser: true,
        ),
      );
      return await session.getResponse();
    } finally {
      await session.close();
    }
  }

  /// 必要に応じてオフラインモデルのリソースを解放（メモリ逼迫時用）
  static Future<void> disposeOfflineModel() async {
    await _persistentOfflineModel?.close();
    _persistentOfflineModel = null;
    _persistentSupportsImage = false;
  }

  /// 初回モデルロードを明示的にトリガー（DL 直後のセットアップ画面用）
  ///
  /// flutter_gemma の `getActiveModel` は内部で `litert_lm_engine_create` を
  /// 呼び出し、これは GPU 初期化 + KV cache prefill 等で 60〜120 秒かかる。
  /// ホーム画面の最初のインタラクションで走らせると ANR を引き起こすため、
  /// DL 直後の Setup 画面で明示的に走らせて事前にウォームアップしておく。
  ///
  /// 戻り値：成功なら true、失敗（モデル未 DL 等）なら false
  static Future<bool> warmUp() async {
    try {
      debugPrint('[GemmaService.warmUp] start');
      final hasModel = await ModelService.isModelDownloaded();
      if (!hasModel) {
        debugPrint('[GemmaService.warmUp] no model — skipping');
        return false;
      }
      // モデル取得（getActiveModel が内部で重い init を実行）
      final model = await _ensureOfflineModel(supportImage: false);
      // 軽い session を作って即閉じ、native 側のウォームアップを完了させる
      final session = await model.createSession(
        temperature: 0.7,
        topK: 40,
      );
      await session.close();
      debugPrint('[GemmaService.warmUp] complete');
      return true;
    } catch (e, st) {
      debugPrint('[GemmaService.warmUp] ERROR: $e\n$st');
      return false;
    }
  }

  /// UI 文字列を一括翻訳（オフライン Gemma 使用）
  /// CLAUDE.md の「翻訳ファイル0行で140言語UI」を実現する核心メソッド。
  /// 戻り値：翻訳された Map<キー, 翻訳済み文字列> または失敗時 null
  static Future<Map<String, String>?> translateUiStrings(
    Map<String, String> englishStrings,
    String targetLocale,
  ) async {
    final hasModel = await ModelService.isModelDownloaded();
    if (!hasModel) return null;

    final stringList = englishStrings.entries
        .map((e) => '${e.key}=${e.value}')
        .join('\n');

    final prompt = '''
You are translating UI strings for a medical triage mobile app into the language with code "$targetLocale".

Rules:
- Output ONLY a JSON object. No markdown, no explanation, no preamble.
- Keys (left of =) MUST stay exactly as-is, in English.
- Values (right of =) MUST be translated naturally for a mobile app UI.
- Keep translations short (mobile screens are narrow).
- For "$targetLocale", use its native script and natural phrasing.
- Do not include keys not in the input.

Input strings:
$stringList

JSON output:
''';

    try {
      final raw = await _callOffline(prompt);

      // JSON 抽出（モデルが余計な前置き出すことがあるため正規表現で）
      final jsonMatch = RegExp(r'\{[\s\S]+\}').firstMatch(raw);
      if (jsonMatch == null) {
        debugPrint(
            '[translateUiStrings] No JSON found in response: ${raw.substring(0, raw.length.clamp(0, 200))}');
        return null;
      }

      final decoded = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
      // 値を文字列に正規化
      final result = decoded.map((k, v) => MapEntry(k, v.toString()));
      return result;
    } catch (e) {
      debugPrint('[translateUiStrings] Error: $e');
      return null;
    }
  }

  /// 入力テキストから言語を検出して TTS / 翻訳に使う言語コードを返す。
  ///
  /// 検出方針：
  ///  1. 文字スクリプト（中国漢字・日本仮名・アラビア・キリル・ハングル等）でまず判定
  ///  2. ラテン文字の場合は語彙の特徴（特殊文字・典型単語）で推定
  ///  3. どれにも該当しなければ英語（en-US）にフォールバック
  ///
  /// 静的規約画面の 10 言語（en/ja/ar/es/fr/pt/sw/hi/zh/ru）すべてに対応。
  static String _detectLanguageCode(String text) {
    // ── 文字スクリプトでの判定（最優先）──
    if (RegExp(r'[぀-ヿ]').hasMatch(text)) return 'ja-JP'; // 平仮名・片仮名 → 日本語
    if (RegExp(r'[一-鿿]').hasMatch(text)) {
      // 漢字のみ → 日本語 vs 中国語の判別が必要
      // 仮名なし & 漢字あり → 中国語と判定（日本語なら高確率で仮名が混ざる）
      return 'zh-CN';
    }
    if (RegExp(r'[가-힯]').hasMatch(text)) return 'ko-KR';
    if (RegExp(r'[؀-ۿ]').hasMatch(text)) return 'ar';
    if (RegExp(r'[Ѐ-ӿ]').hasMatch(text)) return 'ru-RU';
    if (RegExp(r'[ऀ-ॿ]').hasMatch(text)) return 'hi-IN';
    if (RegExp(r'[฀-๿]').hasMatch(text)) return 'th-TH';

    // ── ラテン文字系（語彙特徴で判別）──
    final lower = text.toLowerCase();
    // フランス語：accented chars + 典型単語
    if (RegExp(r'[àâçéèêëîïôûùüÿœæ]').hasMatch(lower) ||
        RegExp(r"\b(je|nous|vous|c'est|qu'|n'|d')\b")
            .hasMatch(lower)) {
      return 'fr-FR';
    }
    // ポルトガル語：チルダ + 特殊文字 + 典型単語
    if (RegExp(r'[ãõ]').hasMatch(lower) ||
        RegExp(r'\b(não|você|está|também|obrigad)\b').hasMatch(lower)) {
      return 'pt-BR';
    }
    // スペイン語：スペイン特有の文字 + 典型単語
    if (RegExp(r'[ñ¿¡]').hasMatch(lower) ||
        RegExp(r'\b(que|usted|está|por favor|gracias|hola)\b')
            .hasMatch(lower)) {
      return 'es-ES';
    }
    // スワヒリ語：典型単語（特殊文字なしなので語彙のみで判定）
    if (RegExp(
            r'\b(habari|asante|tafadhali|maumivu|mgonjwa|ndio|hapana|nina)\b')
        .hasMatch(lower)) {
      return 'sw';
    }
    // 上記以外のラテン文字 → 英語
    return 'en-US';
  }

  // ─── ローマ字除去（日本語出力のみ適用） ─────────────────────
  // モデルが「日本語（romaji）」形式で出力することがあるため後処理で除去する
  static String _stripRomaji(String text) {
    final cjkPattern = RegExp(r'[぀-ヿ一-鿿々ー]');

    // パターン1: ASCII括弧内のローマ字 (kore wa itami desu)
    text = text.replaceAll(
        RegExp(r'\s*\([a-zA-Z][a-zA-Z0-9 ,.\-]{0,150}\)'), '');
    // パターン2: 全角括弧内のローマ字 （romaji）
    text = text.replaceAll(
        RegExp(' ?\\s*（[a-zA-Z][a-zA-Z0-9 ,.\\-]{0,150}）'), '');

    // パターン3: 行単位処理
    final lines = text.split('\n');
    final keep = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        keep.add(line);
        continue;
      }
      if (cjkPattern.hasMatch(trimmed)) {
        // CJKを含む行 → 行内のローマ字部分を削除
        var cleaned = line;
        // 3a. CJK文字直後にスペースなしで続くローマ字: "日本語romaji"
        cleaned = cleaned.replaceAll(
          RegExp(r'([぀-ヿ一-鿿々ー])[a-zA-Z]{3,}(?:[\s,.\-][a-zA-Z]+){0,15}'),
          r'$1',
        );
        // 3b. スペース挟んだローマ字（CJK行内の任意位置）: "日本語 romaji words"
        cleaned = cleaned.replaceAll(
          RegExp(r'\s+[a-zA-Z]{3,}(?:[\s,.\-][a-zA-Z]+){0,15}'),
          '',
        );
        // 3c. 行頭のローマ字: "romaji 日本語"
        cleaned = cleaned.replaceAll(
          RegExp(r'^[a-zA-Z]{3,}(?:[\s,.\-][a-zA-Z]+){0,15}\s+'),
          '',
        );
        // 3d. ダッシュ・コロン・スラッシュ後のローマ字
        cleaned = cleaned.replaceAll(
          RegExp(r'\s*[/／\-—–:：]\s*[a-zA-Z][a-zA-Z0-9 ,.\-]{2,150}\s*$'),
          '',
        );
        keep.add(cleaned);
      } else {
        // CJKを含まない行：4文字以上のラテン単語があれば削除（ローマ字行）
        if (RegExp(r'[a-zA-Z]{4,}').hasMatch(trimmed)) {
          continue;
        }
        keep.add(line);
      }
    }
    text = keep.join('\n');

    // 末尾のクリーンアップ：空のbullet項目を除去
    text = text
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => !RegExp(r'^\s*[-•・*]\s*$').hasMatch(l))
        .join('\n');

    return text.trim();
  }

  static TriageResult _parseResponse(String text,
      [String langCode = 'en-US']) {
    // TYPE: TRIAGE ヘッダーを除去してパース
    final clean = text.replaceAll(RegExp(r'TYPE:\s*TRIAGE\s*\n?'), '');

    int level = 2;
    String summary = '';
    String action = '';
    String possibleConditions = '';
    String details = '';

    final levelMatch = RegExp(r'LEVEL:\s*(\d)').firstMatch(clean);
    if (levelMatch != null) {
      level = int.tryParse(levelMatch.group(1) ?? '2') ?? 2;
    }

    // SUMMARY: SBAR Situation+Background（AIが理解した状況）
    final summaryMatch = RegExp(
            r'SUMMARY:\s*([\s\S]+?)(?:ACTION:|POSSIBLE_CONDITIONS:|DETAILS:|DISCLAIMER:|$)',
            dotAll: true)
        .firstMatch(clean);
    if (summaryMatch != null) {
      summary = summaryMatch.group(1)?.trim() ?? '';
    }

    final actionMatch = RegExp(r'ACTION:\s*(.+)').firstMatch(clean);
    if (actionMatch != null) action = actionMatch.group(1)?.trim() ?? '';

    final conditionsMatch = RegExp(
            r'POSSIBLE_CONDITIONS:\s*([\s\S]+?)(?:DETAILS:|DISCLAIMER:|$)',
            dotAll: true)
        .firstMatch(clean);
    if (conditionsMatch != null) {
      possibleConditions = conditionsMatch.group(1)?.trim() ?? '';
    }

    final detailsMatch =
        RegExp(r'DETAILS:\s*([\s\S]+?)(?:DISCLAIMER:|$)', dotAll: true)
            .firstMatch(clean);
    if (detailsMatch != null) details = detailsMatch.group(1)?.trim() ?? '';

    // 日本語の場合はローマ字を後処理で除去
    if (langCode == 'ja-JP') {
      summary = _stripRomaji(summary);
      action = _stripRomaji(action);
      possibleConditions = _stripRomaji(possibleConditions);
      details = _stripRomaji(details);
    }

    return TriageResult(
      level: level,
      summary: summary,
      action: action,
      possibleConditions: possibleConditions,
      details: details,
      rawResponse: text,
      languageCode: langCode,
    );
  }
}
