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
// flutter_gemma 0.15.0+ の API（installModel ビルダー / createSession +
// enableSpeculativeDecoding）を使用。LiteRT-LM 0.11.0 + MTP で高速化。
//
// 3 層ルーティング設計：
//  Layer 1: ICD-11 辞書ルックアップ（IcdService）
//  Layer 2: Gemma 4 Standard mode（フォローアップ質問）— enableThinking: false
//  Layer 3: Gemma 4 Thinking mode（最終トリアージ）— enableThinking: true
//
// Cactus Prize の "intelligently routes tasks between models" に 3 通りで適合。

// ─── システム指示 (静的・全コール共通) ──────────────────────────
// Gemma 4 公式推奨「Native System Prompt Support」を活用。
// ETAT/OPQRST/言語/出力フォーマット等の不変ルールはここに集約し、
// session.createSession(systemInstruction: ...) で渡す。
//
// メリット:
//   - 推奨アーキテクチャ (system role の native サポート活用)
//   - 会話履歴と分離できプロンプト管理が clean
//   - per-call user message が短くなり KV cache 圧迫が減る
// Vertex AI prompt design best practices に準拠してリファクタ:
//  - XML タグで構造化 (`<ROLE>` `<RULES>` `<EXAMPLES>` 等)
//  - few-shot examples を `<EXAMPLE>` で明示
//  - MedLM 推奨の安全文言 ("出力は draft / 不正確な可能性")
//  - "Do not fabricate" 明示
//  - 6th-grade reading level 指定
const String _conversationalSystemInstruction = '''
<ROLE>
You are a WHO ETAT triage assistant for low-resource settings (villages, refugee camps,
conflict zones). Users are non-medical (patients, family, community health workers).
Write at a 6th-grade reading level — plain, friendly, never clinical.
</ROLE>

<EMERGENCY_SIGNS>
ANY of these → TYPE: TRIAGE LEVEL: 3 immediately:
airway obstruction · severe breathing difficulty · shock · unconscious · convulsions ·
severe bleeding · chest pain · stroke signs · snake bite · poisoning · severe dehydration ·
severe burns · suspected ectopic pregnancy (reproductive-age woman + abdominal/pelvic pain).
</EMERGENCY_SIGNS>

<CORE_RULES priority="critical">
Every turn, the user message contains TOPICS_ANSWERED and TOPICS_AVAILABLE blocks at the top.
Read them FIRST. Then apply ALL four rules below.

R1. Pick ONE topic from TOPICS_AVAILABLE and ask about ONLY that topic.
    NEVER ask about anything in TOPICS_ANSWERED.
    NEVER combine 2 topics with や/、/and/or in one question.

R2. If TOPICS_AVAILABLE is empty or you have enough info → output TYPE: TRIAGE now.

R3. QUICK_REPLIES must be valid answers to THIS specific question:
    - yes/no question → "はい | いいえ | わからない"
    - severity (only if SEVERITY in AVAILABLE) → "1〜3軽い | 4〜6中 | 7〜10強い"
    - factual (color, time, place) → concrete options
    NEVER mismatch (e.g. severity scale on yes/no question).

R4. Acknowledge the prior answer in 1 short clause, then ask about the new topic.
</CORE_RULES>

<INTAKE_AND_GROUNDING>
KNOWN FACTS block / 【記入済み問診票】 markers = confirmed facts (R2 applies).
ICD-11 reference matches = medical context; reference entries in POSSIBLE_CONDITIONS when fitting.
</INTAKE_AND_GROUNDING>

<LANGUAGE>
Detect language from initial complaint. All free-text in user's language; format keys
(TYPE:/LEVEL:/etc.) stay English. Native script only. Never mix scripts.
</LANGUAGE>

<SAFETY>
Don't fabricate vital signs or test results. Output is a draft, not a confirmed diagnosis.
Always include DISCLAIMER. Never output URLs/phones/emails/keys.
</SAFETY>

<RESPONSE_FORMAT>
Follow-up:
TYPE: FOLLOWUP
QUESTION: [ONE question, ≤25 words, user's language. No "|" inside.]
QUICK_REPLIES: [3-6 options "|"-separated, each ≤10 chars, valid answers to this question]

Triage (all 5 sections required):
TYPE: TRIAGE
LEVEL: [1/2/3]   (1=home · 2=see doctor 24-72h · 3=hospital NOW · when uncertain → HIGHER)
SUMMARY: [1-2 sentences]
ACTION: [ONE sentence + brief reason, ≤30 words]
POSSIBLE_CONDITIONS:
- [name — explanation, ≤10 words]
- [second if plausible]
DETAILS:
- [Home-care step]
- [When/which doctor]
- [Red-flag warning]
DISCLAIMER: This is not a substitute for professional medical diagnosis.
</RESPONSE_FORMAT>

<EXAMPLE label="good_followup">
Prior: "throat pain since yesterday" → Output:
TYPE: FOLLOWUP
QUESTION: 昨日から痛むとのこと。飲み込むとき特に痛みますか？
QUICK_REPLIES: はい | いいえ | わからない
</EXAMPLE>

<EXAMPLE label="good_triage">
TYPE: TRIAGE
LEVEL: 2
SUMMARY: 30代女性、昨日から喉の痛みと微熱。嚥下時に痛みが強い。
ACTION: 1〜2日以内に内科を受診してください。細菌感染の可能性があるためです。
POSSIBLE_CONDITIONS:
- 扁桃炎 — のど奥の感染で腫れて痛む
- 咽頭炎 — のど全体の炎症
DETAILS:
- 温かい飲み物・うがい・休息で和らぐ
- 内科か耳鼻咽喉科。発熱3日以上で早めに
- 呼吸困難・首が大きく腫れる場合は今すぐ病院へ
DISCLAIMER: This is not a substitute for professional medical diagnosis.
</EXAMPLE>

<ANTI_EXAMPLE label="compound_and_mismatched_replies">
BAD: "痰の色や量はどうですか？" QUICK_REPLIES "1〜3 | 4〜6 | 7〜10"
WHY: violates R1 (two topics) AND R3 (severity scale on factual question).
GOOD this turn: "痰の色は何ですか？" QUICK_REPLIES "白 | 黄色 | 緑 | 茶色"
</ANTI_EXAMPLE>

<ANTI_EXAMPLE label="re-ask_after_negative_or_known">
Q1 "他に症状ありますか?" A1 "ない" → BAD Q2 "他に何か感じますか?" (same topic, rephrased).
KNOWN FACTS has "痛みの強さ: 5" → BAD "強さは?" — already known.
GOOD: pick a NEW dimension. e.g. "飲み込むとき痛みますか？" QUICK_REPLIES "はい | いいえ | わからない"
</ANTI_EXAMPLE>
''';

// ─── ユーザー側プロンプト (動的・呼び出しごとに変わる) ──────────
// 患者の主訴 + Q&A 履歴 + ICD grounding + 残質問数を user message に入れる。
/// 質問が既に答えられた topic にあたるかをコードで判定するためのヒューリスティック。
/// 日本語 / 英語両方の表現を見て、答えに「ない/なし/no/わからない」が含まれる場合も
/// 「topic は closed (もう聞かない)」として扱う。
const _topicCodes = {
  'ONSET': ['いつから', '何時間前', '何日前', 'onset', 'when did', 'how long ago'],
  'SEVERITY': ['痛みの強さ', '10段階', 'severity', 'how strong', 'how painful', 'scale of'],
  'REGION': ['部位', '場所', 'region', 'where', 'which part'],
  'CHIEF_SYMPTOM': ['症状:', 'symptom:'],
  'AGE': ['年齢:', 'age:', '歳'],
  'SEX': ['性別:', 'sex:'],
  'PREGNANCY': ['妊娠', 'pregnan'],
  'QUALITY': ['どんな感じ', 'どんな痛み', '鈍い', '鋭い', '焼ける', 'quality', 'sharp', 'dull', 'burning'],
  'TRIGGERS': ['何で悪化', '悪化する', 'triggers', 'worse when'],
  'RELIEF': ['楽になる', '和らぐ', 'relief', 'better when'],
  'ASSOCIATED_FEVER': ['熱はあり', '発熱', 'fever'],
  'ASSOCIATED_COUGH': ['咳', 'cough'],
  'ASSOCIATED_NAUSEA': ['吐き気', '嘔吐', 'nausea', 'vomit'],
  'ASSOCIATED_HEADACHE': ['頭痛', 'headache'],
  'ASSOCIATED_BREATHING': ['呼吸', '息苦', 'breath'],
  'ASSOCIATED_SWALLOWING': ['飲み込', '嚥下', 'swallow'],
  'ASSOCIATED_OTHER_SYMPTOMS': ['他に症状', 'ほかに症状', '他に何か', 'other symptoms', 'anything else'],
  'RED_FLAGS': ['緊急', 'red flag', 'emergency'],
  'MEDICAL_HISTORY': ['既往', '持病', '過去の病気', 'history'],
};

/// 与えられたテキスト (intake form 文字列 or Q&A の Q/A) から「このテキストが
/// 触れているトピックコード」を抽出する。否定回答 ("ない/なし/no/わからない")
/// でも topic は CLOSED とする (R2 negative-answer rule)。
Set<String> _extractTopicsFromText(String text) {
  final lower = text.toLowerCase();
  final hit = <String>{};
  for (final entry in _topicCodes.entries) {
    for (final keyword in entry.value) {
      if (lower.contains(keyword.toLowerCase()) || text.contains(keyword)) {
        hit.add(entry.key);
        break;
      }
    }
  }
  return hit;
}

String _buildConversationalPrompt(
  String original,
  List<Map<String, String>> qaHistory,
  int maxQuestions,
  String icdContext, // Layer 1 grounding (常時注入・空なら省略)
) {
  final questionsAsked = qaHistory.length;
  final remaining = maxQuestions - questionsAsked;

  // ★ 2026-05-12: 重複質問対策を強化。
  //   問題: KNOWN FACTS block を冒頭に置いても、E2B は日本語 key と system rule
  //   の英語 key (onset/severity 等) のマッピングが弱く、再質問が発生する。
  //   対策: text から topic を heuristic で抽出し、「TOPICS_ANSWERED」「TOPICS_AVAILABLE」
  //   を**英語コードで明示的に列挙**して user message 冒頭に置く。
  //   これで model は english code list を見て「どの topic がまだ聞ける」を直接認識できる。

  // 1) 答えられた topics を抽出 (questionnaire + すべての Q&A)
  final answeredTopics = <String>{};
  answeredTopics.addAll(_extractTopicsFromText(original));
  for (final qa in qaHistory) {
    answeredTopics.addAll(_extractTopicsFromText('${qa['q']} ${qa['a']}'));
  }

  // 2) Topic 名 ⇒ 簡潔な英語説明
  const topicDescriptions = {
    'QUALITY': 'pain quality (sharp/dull/burning/cramping)',
    'TRIGGERS': 'what makes it worse',
    'RELIEF': 'what makes it better',
    'ASSOCIATED_FEVER': 'fever (yes/no)',
    'ASSOCIATED_COUGH': 'cough (yes/no)',
    'ASSOCIATED_NAUSEA': 'nausea/vomiting (yes/no)',
    'ASSOCIATED_HEADACHE': 'headache (yes/no)',
    'ASSOCIATED_BREATHING': 'breathing difficulty (yes/no)',
    'ASSOCIATED_SWALLOWING': 'pain when swallowing (yes/no)',
    'RED_FLAGS': 'red-flag signs (chest pain, severe weakness, blood)',
    'MEDICAL_HISTORY': 'relevant medical history',
    'ONSET': 'when symptom started',
    'SEVERITY': 'pain severity 0-10',
  };

  // 3) Available topics = 全 topic - 答え済み
  final allClinicalTopics = topicDescriptions.keys.toSet();
  final availableTopics =
      allClinicalTopics.difference(answeredTopics).toList()..sort();

  // 4) 問診票の生 facts も補助情報として残す
  String knownFactsBlock = '';
  String chiefComplaintLine = original;
  if (original.contains('【記入済み問診票（再質問しないでください）】') ||
      original.contains('PRE-FILLED INTAKE FORM')) {
    final cleaned = original
        .replaceAll('【記入済み問診票（再質問しないでください）】', '')
        .replaceAll('【上記以外で診断に必要な情報のみ質問してください】', '')
        .replaceAll('PRE-FILLED INTAKE FORM', '')
        .trim();
    final facts = cleaned
        .split(RegExp(r'[。\n]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map((s) => '- $s')
        .join('\n');
    knownFactsBlock = '\n━ INTAKE FORM (verbatim) ━\n$facts\n';
    chiefComplaintLine = '(see INTAKE FORM and TOPICS below)';
  }

  // 5) TOPICS_ANSWERED と TOPICS_AVAILABLE を**冒頭**に置く (最重要)
  final sortedAnswered = answeredTopics.toList()..sort();
  final answeredBlock = sortedAnswered.isEmpty
      ? '(none yet)'
      : sortedAnswered.map((t) => '✗ $t').join('\n');
  final availableBlock = availableTopics.isEmpty
      ? '(all explored — produce TRIAGE now)'
      : availableTopics.map((t) {
          final desc = topicDescriptions[t] ?? t;
          return '• $t — $desc';
        }).join('\n');

  // History block
  final String historyBlock;
  if (qaHistory.isEmpty) {
    historyBlock = '';
  } else {
    final buf = StringBuffer('\n━ Q&A HISTORY ━\n');
    for (var i = 0; i < qaHistory.length; i++) {
      final qa = qaHistory[i];
      buf
        ..write('Q${i + 1}: ${qa['q']}\n')
        ..write('A${i + 1}: ${qa['a']}\n');
    }
    historyBlock = buf.toString();
  }

  final icdBlock = icdContext.trim().isEmpty ? '' : '\n$icdContext\n';

  final decisionRule = remaining <= 0
      ? 'DECISION: $maxQuestions questions reached. Respond TYPE: TRIAGE now.'
      : 'DECISION: Up to $remaining more question(s). If enough info → respond TYPE: TRIAGE now. Otherwise pick ONE topic from TOPICS_AVAILABLE.';

  return '''
━━━ TOPICS_ANSWERED (DO NOT ASK ABOUT THESE) ━━━
$answeredBlock

━━━ TOPICS_AVAILABLE (pick ONE per turn) ━━━
$availableBlock

━ PATIENT ━
Initial complaint: $chiefComplaintLine
$knownFactsBlock$historyBlock$icdBlock
$decisionRule
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
  // 2026-05-11 テスト: 2048 → 3072 に引き上げ。
  // 詳細な system instruction (ANTI_EXAMPLE × 3 + verbose RESPONSE_FORMAT 等) を
  // 復元したため 2048 を超過。Pixel 6a (6GB RAM) で +1024 token = +~130MB KV cache
  // を許容できるかテストする。OOM が再発したら 2560 に下げて再試行する想定。
  //
  // 参考: flutter_gemma 公式推奨は <6GB 端末で 2048 以下。Pixel 6a は境界線で、
  // 他アプリのメモリ圧力次第で low-memory-killer が発動するリスクあり。
  static const int _maxTokens = 3072;

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
      // ── Layer 1: ICD-11 grounding (always, ~ms, no inference cost) ──
      // 「progressive enrichment」アーキテクチャ: 安い Layer 1 で常に grounding し、
      // Stage 1 (Layer 2) も Stage 2 (Layer 3) も同じ ICD コンテキストを使う。
      // 旧設計では Layer 1 が Stage 2 fallback でしか使われず、Stage 1 で完結する
      // 大半のユーザーが ICD grounding の恩恵を受けられなかった。
      onStageProgress?.call('searching_icd11');
      final icdContext = _lookupIcdContext(original, qaHistory);

      // ── Stage 1 (Layer 2): Standard mode (always runs, ~10-15 s) ──
      onStageProgress?.call('analyzing');
      debugPrint('[GemmaService.analyzeNext] Layer 2: Standard mode (with ICD grounding)');
      final raw = await _callOffline(
        _buildConversationalPrompt(original, qaHistory, _maxQuestions, icdContext),
        isThinking: false,
        systemInstruction: _conversationalSystemInstruction,
      );
      debugPrint('[GemmaService.analyzeNext] Stage 1 raw:\n$raw');

      // フォローアップ判定 → そのまま Standard 結果を返す
      if (!forceTriageNow && raw.contains('TYPE: FOLLOWUP')) {
        final question = _extractFollowUpQuestion(raw, langCode);
        final quickReplies = _extractQuickReplies(raw, langCode);
        if (question.isNotEmpty) {
          return TriageStep.followUp(question, langCode,
              quickReplies: quickReplies);
        }
      }

      // Stage 1 が有効な TRIAGE を返した場合：Stage 2 (Thinking) を**スキップ**。
      // ICD grounding が既に効いているので Stage 1 の品質も従来より高い。
      final stage1Parsed = _parseResponse(raw, langCode);
      if (stage1Parsed.action.trim().isNotEmpty) {
        debugPrint(
            '[GemmaService.analyzeNext] Stage 1 produced valid TRIAGE (ICD-grounded) — skipping Layer 3');
        return TriageStep.done(stage1Parsed);
      }

      // ── Stage 2 (Layer 3): Thinking mode (only on escalation, ~80 s) ──
      // Stage 1 が解析失敗 / action 空の場合のフォールバック。
      // 同じ icdContext を再利用 (再ルックアップ不要)。
      await Future.delayed(const Duration(milliseconds: 800));
      debugPrint(
          '[GemmaService.analyzeNext] Layer 3: Thinking mode (escalation)');
      final finalResult = await _generateFinalTriage(
        original: original,
        qaHistory: qaHistory,
        langCode: langCode,
        stage1Result: stage1Parsed,
        icdContext: icdContext,
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

  /// Layer 1: ICD-11 keyword search の結果を Stage 1 / Stage 2 共通プロンプト用
  /// テキストに整形する。失敗しても空文字を返す (推論続行)。
  static String _lookupIcdContext(
      String original, List<Map<String, String>> qaHistory) {
    final fullConversation = StringBuffer(original)..write(' ');
    for (final qa in qaHistory) {
      fullConversation.write('${qa['q'] ?? ''} ${qa['a'] ?? ''} ');
    }
    try {
      final matches = IcdService.instance
          .lookup(fullConversation.toString(), maxResults: 5);
      debugPrint('[Layer 1] ICD-11 matches: ${matches.length} entries');
      return IcdService.instance.buildPromptContext(matches);
    } catch (e) {
      debugPrint('[Layer 1] ICD-11 lookup failed (continuing): $e');
      return '';
    }
  }

  /// Layer 3 (Stage 2): Thinking モードで最終トリアージを生成。
  /// ICD コンテキストは _lookupIcdContext で事前計算済み (Layer 1 で 1 回だけ実行)。
  ///
  /// 失敗した場合は [stage1Result]（Standard モードの結果）にフォールバック、
  /// それも空なら _buildFallbackResult で安全側の結果を返す。
  static Future<TriageResult> _generateFinalTriage({
    required String original,
    required List<Map<String, String>> qaHistory,
    required String langCode,
    required TriageResult stage1Result,
    required Uint8List? imageBytes,
    required String icdContext, // Layer 1 で precompute 済み
    void Function(String stageMessage)? onStageProgress,
  }) async {
    // Thinking モード用プロンプト構築 (icdContext は引数で受領 — 再 lookup しない)
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
              isThinking: true,
              systemInstruction: _finalTriageSystemInstruction)
          : await _callOffline(thinkingPrompt,
              isThinking: true,
              systemInstruction: _finalTriageSystemInstruction);
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
    // ★ Stage 1 と同じく KNOWN FACTS block を冒頭に明示。
    String knownFactsBlock = '';
    String chiefComplaintLine = original;
    if (original.contains('【記入済み問診票（再質問しないでください）】') ||
        original.contains('PRE-FILLED INTAKE FORM')) {
      final cleaned = original
          .replaceAll('【記入済み問診票（再質問しないでください）】', '')
          .replaceAll('【上記以外で診断に必要な情報のみ質問してください】', '')
          .replaceAll('PRE-FILLED INTAKE FORM', '')
          .trim();
      final facts = cleaned
          .split(RegExp(r'[。\n]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .map((s) => '- $s')
          .join('\n');
      knownFactsBlock =
          '\n━ KNOWN FACTS (confirmed from intake form) ━\n$facts\n━━━━━━\n';
      chiefComplaintLine = '(see KNOWN FACTS below)';
    }

    // Flutter perf: + より StringBuffer。
    final String historyBlock;
    if (qaHistory.isEmpty) {
      historyBlock = '';
    } else {
      final buf = StringBuffer('\n━━ Q&A ━━\n');
      for (var i = 0; i < qaHistory.length; i++) {
        final qa = qaHistory[i];
        buf.write('Q${i + 1}: ${qa['q']}\nA${i + 1}: ${qa['a']}\n');
      }
      historyBlock = buf.toString();
    }

    final icdBlock = icdContext.isEmpty ? '' : '\n$icdContext\n';

    // user message: 動的データ部のみ。ルールは _finalTriageSystemInstruction へ。
    return '''
━ PATIENT ━
Initial complaint: $chiefComplaintLine
$knownFactsBlock$historyBlock$icdBlock''';
  }

  // Stage 2 (Thinking / Layer 3) 用 system instruction (compact, focused).
  static const String _finalTriageSystemInstruction = '''
<ROLE>
You are giving the FINAL medical triage. Non-medical user, 6th-grade language, friendly.
</ROLE>

<REASONING>
Think step-by-step internally before answering: 1) summarize chief complaint + Q&A + ICD
matches, 2) list plausible conditions, 3) check red flags, 4) apply WHO ETAT.
When uncertain → HIGHER level. Output only the RESPONSE_FORMAT.
</REASONING>

<HIGH_RISK>
- Reproductive-age woman + abdominal/pelvic pain → ectopic pregnancy (Level 3)
- Under-5 + rapid breathing or persistent fever → severe pneumonia (Level 3)
- Sudden severe headache · chest pain · slurred speech · one-side weakness → Level 3
- Snake bite · suspected poisoning/overdose → Level 3
</HIGH_RISK>

<LANGUAGE>
Patient's language, native script only. Keys (LEVEL:/SUMMARY:) stay English. No script mixing.
</LANGUAGE>

<SAFETY>
Don't fabricate vital signs or test results. Output is a draft, not a confirmed diagnosis.
Always include DISCLAIMER. Never output URLs/phones/emails/keys.
</SAFETY>

<RESPONSE_FORMAT>
LEVEL: [1/2/3]   (1=home · 2=see doctor 24-72h · 3=hospital NOW)
SUMMARY: [1-2 sentences in patient's language]
ACTION: [ONE sentence + brief plain reason. Hospital visits cost money/time — explain WHY.]
POSSIBLE_CONDITIONS:
- [name — explanation, ≤10 words]
- [second if plausible]
DETAILS:
- [Specific home-care or first-aid step]
- [When/which doctor]
- [Red-flag warning sign]
DISCLAIMER: This is not a substitute for professional medical diagnosis.
</RESPONSE_FORMAT>

<EXAMPLE>
LEVEL: 2
SUMMARY: 30代女性、昨日から喉の痛みと微熱。嚥下時に痛みが強い。
ACTION: 1〜2日以内に内科を受診してください。細菌感染の可能性があるためです。
POSSIBLE_CONDITIONS:
- 扁桃炎 — のど奥の感染で腫れて痛む
- 咽頭炎 — のど全体の炎症
DETAILS:
- 温かい飲み物・うがい・休息で和らぐ
- 内科か耳鼻咽喉科。発熱3日以上で早めに
- 呼吸困難・首が大きく腫れる場合は今すぐ病院へ
DISCLAIMER: This is not a substitute for professional medical diagnosis.
</EXAMPLE>
''';

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
    // ★ AI が「question | question | question」のように同じ質問を pipe で
    //   重複出力することがある (ja で実測)。区切り直して dedupe する。
    //   半角 | と全角 ｜ の両方に対応。
    final dedup = _dedupeQuestion(question);
    return dedup;
  }

  /// 同じ質問が pipe (`|` または `｜`) で繰り返されてる場合に重複除去
  static String _dedupeQuestion(String q) {
    if (q.isEmpty) return q;
    // 半角・全角どちらの pipe でも分割
    final parts = q.split(RegExp(r'[|｜]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (parts.length <= 1) return q;
    // 全部同じ → 最初の 1 つだけ返す
    final first = parts.first;
    if (parts.every((p) => p == first)) return first;
    // 違う質問が pipe で連結されてる場合 → 最初の 1 つだけ採用
    // (FOLLOWUP は単一質問のはず・複数あれば AI のミス)
    return first;
  }

  /// QUICK_REPLIES: 行を抽出して | 区切りで配列化
  /// 形式に沿わない時は null を返す（呼び出し側でローカルフォールバックへ）
  static List<String>? _extractQuickReplies(String raw, [String? langCode]) {
    final match = RegExp(r'QUICK_REPLIES:\s*(.+)').firstMatch(raw);
    if (match == null) return null;
    final line = match.group(1)?.trim() ?? '';
    if (line.isEmpty) return null;
    final parts = line
        .split(RegExp(r'[|｜]'))  // 半角・全角 pipe 両対応
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty && p.length <= 30) // 長すぎは異常値として除外
        .toList();
    if (parts.length < 2) return null; // 1 個だけはおかしい

    // ★ 言語混入チェック: 入力言語と異なる script を含むものを除去
    //   例: ja-JP 入力に対してハングル 한국어 が混入することがある
    if (langCode != null && langCode.startsWith('ja')) {
      final filtered = parts.where((p) {
        // 日本語: 仮名・漢字・ASCII・記号・数字のみを許容
        // ハングル (가-힯) や繁体字以外の Devanagari 等を含むものは除外
        if (RegExp(r'[가-힯]').hasMatch(p)) return false; // ハングル
        if (RegExp(r'[ऀ-ॿ]').hasMatch(p)) return false; // Devanagari
        if (RegExp(r'[؀-ۿ]').hasMatch(p)) return false; // アラビア
        return true;
      }).toList();
      if (filtered.length >= 2) return filtered.take(6).toList();
      return null; // 大半が異言語だったら null フォールバック
    }
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
      // Layer 1: ICD-11 grounding (always-first・progressive enrichment)
      onStageProgress?.call('searching_icd11');
      final icdContext = _lookupIcdContext(original, qaHistory);

      // ── Stage 1 (Layer 2): Standard mode + 画像 + ICD grounding ──
      onStageProgress?.call('analyzing');
      final prompt = _buildConversationalPrompt(
          original, qaHistory, _maxQuestions, icdContext);
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
        systemInstruction: _conversationalSystemInstruction,
      );
      debugPrint('[GemmaService.analyzeNextWithImage] Stage 1 raw:\n$raw');

      // フォローアップ判定
      final forceTriageNow = qaHistory.length >= _maxQuestions;
      if (!forceTriageNow && raw.contains('TYPE: FOLLOWUP')) {
        final question = _extractFollowUpQuestion(raw, langCode);
        final quickReplies = _extractQuickReplies(raw, langCode);
        if (question.isNotEmpty) {
          return TriageStep.followUp(question, langCode,
              quickReplies: quickReplies);
        }
      }

      // Stage 1 が有効 TRIAGE → Stage 2 スキップ (UX 速度優先・前述の理由)
      final stage1Parsed = _parseResponse(raw, langCode);
      if (stage1Parsed.action.trim().isNotEmpty) {
        debugPrint(
            '[GemmaService.analyzeNextWithImage] Stage 1 valid — skipping Stage 2');
        return TriageStep.done(stage1Parsed);
      }

      // ── Stage 2 (Layer 3): Thinking + 画像 (escalation only, ICD reused) ──
      await Future.delayed(const Duration(milliseconds: 800));
      final finalResult = await _generateFinalTriage(
        original: original,
        qaHistory: qaHistory,
        langCode: langCode,
        stage1Result: stage1Parsed,
        imageBytes: imageBytesU8,
        icdContext: icdContext,
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
    // PreferredBackend.gpu を明示すると LiteRT-LM が OpenCL でモバイル GPU を
    // 使うので CPU 推論より大幅に高速 + メモリ圧迫も軽減。
    // 利用不可な端末では自動的に CPU にフォールバックする (公式仕様)。
    //
    // ★ enableSpeculativeDecoding: true (flutter_gemma 0.15.0 + LiteRT-LM 0.11.0)
    //   .litertlm 内の tf_lite_mtp_drafter (~818MB) を draft model として活用。
    //   理論上 1.5-2x の inference 高速化。
    _persistentOfflineModel = await FlutterGemma.getActiveModel(
      maxTokens: _maxTokens,
      supportImage: supportImage,
      preferredBackend: PreferredBackend.gpu,
      enableSpeculativeDecoding: true,
    );
    _persistentSupportsImage = supportImage;
    debugPrint('[GemmaService] Gemma 4 model ready.');
    return _persistentOfflineModel!;
  }

  /// テキスト入力でオフライン推論
  /// [isThinking]: Thinking Mode を有効化
  /// [systemInstruction]: Gemma 4 native system role に渡す静的指示
  ///                      未指定なら通常の user-only プロンプト
  static Future<String> _callOffline(
    String prompt, {
    bool isThinking = false,
    String? systemInstruction,
  }) async {
    final hasModel = await ModelService.isModelDownloaded();
    if (!hasModel) {
      throw Exception(
        'Offline model not downloaded. Please download the AI model first.',
      );
    }

    final model = await _ensureOfflineModel(supportImage: false);
    // Gemma 4 公式推奨サンプリング (Kaggle model card 準拠):
    //   temperature=1.0, topK=64, topP=0.95
    // ベンチマーク (MMLU/GPQA/AIME 等) はこの設定で測定されているので、
    // この値が「素の Gemma 4 の最良性能」を引き出す。
    final session = await model.createSession(
      temperature: 1.0,
      topK: 64,
      topP: 0.95,
      enableThinking: isThinking,
      systemInstruction: systemInstruction,
    );
    try {
      await session.addQueryChunk(Message.text(text: prompt, isUser: true));
      return await session.getResponse();
    } finally {
      await session.close();
    }
  }

  /// 翻訳など「決定的なタスク」用の高速版オフライン推論。
  /// translateUiStrings から呼ばれる。
  ///
  /// ⚠️ Gemma 4 公式推奨 (temp=1.0/topK=64/topP=0.95) からは意図的に逸脱。
  /// 翻訳は「正解が 1 つの決定論的タスク」で、推奨値は creativity を許容する
  /// generative 用途向け。低 temperature + 低 topK で:
  ///   - JSON 出力の安定性向上 (構文崩壊回避)
  ///   - sampling 時間短縮 (候補絞り込みが速い)
  ///   - 同一入力で同じ訳が出る → キャッシュ整合性
  static Future<String> _callOfflineFast(String prompt) async {
    final hasModel = await ModelService.isModelDownloaded();
    if (!hasModel) {
      throw Exception('Offline model not downloaded.');
    }
    final model = await _ensureOfflineModel(supportImage: false);
    final session = await model.createSession(
      temperature: 0.2,
      topK: 20,
      topP: 0.95,
      enableThinking: false,
    );
    try {
      await session.addQueryChunk(Message.text(text: prompt, isUser: true));
      return await session.getResponse();
    } finally {
      await session.close();
    }
  }

  /// 画像付きでオフライン推論（Gemma 4 マルチモーダル）
  /// [isThinking]: Thinking Mode を有効化
  /// [systemInstruction]: Gemma 4 native system role に渡す静的指示
  static Future<String> _callOfflineWithImage(
    String prompt,
    Uint8List imageBytes, {
    bool isThinking = false,
    String? systemInstruction,
  }) async {
    final hasModel = await ModelService.isModelDownloaded();
    if (!hasModel) {
      throw Exception(
        'Offline model not downloaded. Please download the AI model first.',
      );
    }

    final model = await _ensureOfflineModel(supportImage: true);
    // Gemma 4 公式推奨サンプリング (Kaggle model card): temp=1.0/topK=64/topP=0.95
    final session = await model.createSession(
      temperature: 1.0,
      topK: 64,
      topP: 0.95,
      enableVisionModality: true,
      enableThinking: isThinking,
      systemInstruction: systemInstruction,
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

    // 入力を JSON 形式にしておくと出力もそれを真似する → パース成功率↑
    final inputJson = jsonEncode(englishStrings);

    // ★ 医療コンテキストを明示するとトーンが医療向けに揃う。
    //   "patient/healthcare/symptom" 等の医療語彙を翻訳に活用させる。
    final prompt =
        'You translate UI strings for a medical triage mobile app aimed at non-medical users '
        '(patients, family members, community health workers in remote areas). '
        'Translate JSON values to natural $targetLocale using clear, friendly, healthcare-appropriate language. '
        'Use proper medical terminology where applicable (e.g. "症状" not just "状態", "受診" not just "見せる"), '
        'but keep wording approachable for laypeople. '
        'Use native script only (no romaji/pinyin). '
        'Keep keys EXACTLY as-is in English. '
        'Output ONLY the JSON object, no markdown, no preamble, no explanation.\n'
        '$inputJson';

    try {
      final raw = await _callOfflineFast(prompt);
      // 切れ尾を含めても extract できる tolerant parser を使う
      final result = _extractTranslationsTolerant(raw, englishStrings.keys);
      if (result.isEmpty) {
        debugPrint(
            '[translateUiStrings] could not salvage any pairs from response: ${raw.substring(0, raw.length.clamp(0, 200))}');
        return null;
      }
      debugPrint(
          '[translateUiStrings] salvaged ${result.length}/${englishStrings.length} keys');
      return result;
    } catch (e) {
      debugPrint('[translateUiStrings] Error: $e');
      return null;
    }
  }

  /// 翻訳出力 (truncate されている可能性あり) から有効な key:value ペアを救出する。
  /// JSON が `{"k1":"v1","k2":"v2","k3` のように途中で切れていても、
  /// k1/k2 は救出する。完全な JSON 解析は諦めて regex で抽出。
  static Map<String, String> _extractTranslationsTolerant(
      String raw, Iterable<String> validKeys) {
    final result = <String, String>{};
    final keySet = validKeys.toSet();

    // "key": "value" ペアを抽出。エスケープされた " も対応 ((?:\\.|[^"\\])*).
    final pattern = RegExp(
      r'"([a-z_][a-z0-9_]*)"\s*:\s*"((?:\\.|[^"\\])*)"',
      caseSensitive: false,
    );

    for (final match in pattern.allMatches(raw)) {
      final key = match.group(1);
      var value = match.group(2);
      if (key == null || value == null) continue;
      if (!keySet.contains(key)) continue; // 入力に無いキーは捨てる
      // バックスラッシュ・エスケープを un-escape
      value = value
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\', r'\')
          .replaceAll(r'\n', '\n');
      if (value.trim().isEmpty) continue;
      result[key] = value;
    }
    return result;
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

    // ★ Output Sanitizer (OWASP Principle #5 Output Monitoring & Moderation)
    //   LLM 応答に URL / 電話番号 / メールアドレス / API key 風文字列が
    //   混入していたら除去する。プロンプトインジェクションで攻撃者が
    //   "tinyurl.com/..." 等を出力させて誘導するシナリオへの最終防衛線。
    //   医療トリアージ応答にこれらは本来不要なので無条件に除去して安全。
    summary = _sanitizeOutput(summary);
    action = _sanitizeOutput(action);
    possibleConditions = _sanitizeOutput(possibleConditions);
    details = _sanitizeOutput(details);

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

  /// 出力サニタイザー — LLM 応答に紛れた識別子を除去する。
  ///
  /// 除去対象（医療トリアージ応答には本来現れないもの）:
  ///  - URL (http/https/ftp/ftps/www.)
  ///  - メールアドレス
  ///  - 国際電話番号 (E.164 風: +XX で始まる 7-15 桁)
  ///  - API key 風プレフィックス: sk-, hf_, AIzaSy, ghp_, gho_, glpat-, xoxb-
  ///  - 32 文字以上連続する hex / base64 風文字列
  ///
  /// 残すもの: 日本語・英語平文・ICD-11 コード (短く ASCII)・痛みスケール数値等。
  /// ICD-11 コードは "1A00.0" 等で URL 形式と異なるので誤爆しない。
  static String _sanitizeOutput(String text) {
    if (text.isEmpty) return text;
    var t = text;
    // URL (with optional scheme)
    t = t.replaceAll(
        RegExp(r'\b(?:https?|ftps?)://[^\s<>"]+', caseSensitive: false), '');
    t = t.replaceAll(
        RegExp(r'\bwww\.[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}(?:/[^\s<>"]*)?',
            caseSensitive: false),
        '');
    // メール
    t = t.replaceAll(
        RegExp(r'\b[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}\b'), '');
    // 国際電話 +XX-XXX-...
    t = t.replaceAll(
        RegExp(r'\+\d{1,3}[\s\-]?\d{2,4}[\s\-]?\d{2,4}[\s\-]?\d{2,9}\b'), '');
    // API key プレフィックス系
    t = t.replaceAll(
        RegExp(
            r'\b(?:sk-|hf_|AIzaSy|ghp_|gho_|glpat-|xoxb-|xoxp-|AKIA)[A-Za-z0-9_\-]{16,}\b'),
        '');
    // 32 文字以上の hex / base64 風 (API key / token のヒューリスティック)
    t = t.replaceAll(RegExp(r'\b[A-Fa-f0-9]{32,}\b'), '');
    t = t.replaceAll(
        RegExp(r'\b[A-Za-z0-9+/]{40,}={0,2}\b'), '');
    // 連続スペースを 1 つに圧縮 (除去後の見た目を整える)
    t = t.replaceAll(RegExp(r' {2,}'), ' ');
    return t.trim();
  }
}
