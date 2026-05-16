import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

// ─── ICD-11 ルックアップサービス（Layer 1） ───────────────────
//
// 設計：
// 1. アプリ起動後（モデル DL 完了後でも問題ない）に一度だけ JSON ロード
// 2. キーワード → エントリのインデックスをメモリ上に構築
// 3. lookup(text) で部分一致検索 → 関連エントリリスト返却
// 4. 結果を Layer 3（Gemma 4 Thinking mode）のプロンプトに統合
//
// ライセンス：CC BY-ND 3.0 IGO（assets 同梱・改変なし）
// CLAUDE.md ⑦.8 ICD-11 連携セクションに準拠

/// ICD-11 エントリ（JSON のスキーマと対応）
class IcdEntry {
  final String code;
  final String title;
  final String category;
  final List<String> keywords;
  final int urgencyHint; // 1-3 (WHO ETAT level)
  final String primaryCareNote;

  const IcdEntry({
    required this.code,
    required this.title,
    required this.category,
    required this.keywords,
    required this.urgencyHint,
    required this.primaryCareNote,
  });

  factory IcdEntry.fromJson(Map<String, dynamic> json) {
    return IcdEntry(
      code: json['code'] as String? ?? '',
      title: json['title'] as String? ?? '',
      category: json['category'] as String? ?? '',
      keywords: (json['keywords'] as List?)
              ?.map((k) => (k as String).toLowerCase())
              .toList() ??
          const [],
      urgencyHint: (json['urgency_hint'] as int?) ?? 2,
      primaryCareNote: json['primary_care_note'] as String? ?? '',
    );
  }

  /// WHO ICD-11 canonical linearization URI (MMS release).
  ///
  /// 規格: `http://id.who.int/icd/release/11/mms/{code}` — WHO Foundation
  /// が発行する deterministic URI で、stem code から一意に決まる。
  ///
  /// ライセンス上の意義 (ICD-11 Reference Guide §0.1 software license):
  /// > "reproduce ICD-11 in part or whole without the ICD-11 URIs
  /// >  (not applicable for print publications)"
  /// → ソフトウェアでの利用時は URI を保持して再配布する必要がある。
  ///   本アプリは grounding context として URI をプロンプトに含めることで
  ///   この要件を満たす。
  String get canonicalUri =>
      code.isEmpty ? '' : 'https://id.who.int/icd/release/11/mms/$code';

  /// Gemma 4 プロンプトに統合する際の整形
  ///
  /// 出力例:
  ///   - 1F40 "Malaria" (L3, Infectious) <https://id.who.int/icd/release/11/mms/1F40>
  ///     Fever with chills/rigors in endemic area...
  ///
  /// URI を含めることで:
  ///  (a) ICD-11 ライセンス §0.1 の URI 保持要件を満たす
  ///  (b) AI が source を引用可能になる (paraphrase ではなく)
  String toPromptLine() {
    final uriPart = canonicalUri.isEmpty ? '' : ' <$canonicalUri>';
    return '- $code "$title" (L$urgencyHint, $category)$uriPart: $primaryCareNote';
  }
}

/// ICD-11 検索結果（マッチしたキーワード情報を含む）
class IcdMatch {
  final IcdEntry entry;
  final List<String> matchedKeywords;
  final double score; // 0.0-1.0、複数キーワード一致でスコア上昇

  const IcdMatch({
    required this.entry,
    required this.matchedKeywords,
    required this.score,
  });
}

class IcdService {
  static const _assetPath = 'assets/icd11/primary_care_subset.json';

  // シングルトン
  static final IcdService instance = IcdService._();
  IcdService._();

  List<IcdEntry> _entries = [];
  // キーワード → そのキーワードを含むエントリのインデックス
  final Map<String, List<int>> _keywordIndex = {};
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;
  int get entryCount => _entries.length;

  /// アプリ起動時に呼ぶ。冪等（重複呼び出しは無視）。
  Future<void> initialize() async {
    if (_isLoaded) return;

    try {
      final jsonStr = await rootBundle.loadString(_assetPath);
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final entriesJson = data['entries'] as List? ?? [];

      _entries = entriesJson
          .map((e) => IcdEntry.fromJson(e as Map<String, dynamic>))
          .toList();

      // インデックス構築
      _keywordIndex.clear();
      for (var i = 0; i < _entries.length; i++) {
        for (final kw in _entries[i].keywords) {
          _keywordIndex.putIfAbsent(kw, () => []).add(i);
          // 単語単位でも索引（"watery diarrhea" → ["watery", "diarrhea"] も追加）
          for (final word in kw.split(RegExp(r'\s+'))) {
            if (word.length >= 4) {
              _keywordIndex.putIfAbsent(word, () => []).add(i);
            }
          }
        }
      }

      _isLoaded = true;
      debugPrint(
          '[IcdService] Loaded ${_entries.length} entries, ${_keywordIndex.length} keyword index entries');
    } catch (e, stack) {
      debugPrint('[IcdService] Failed to load ICD-11 data: $e');
      debugPrint('$stack');
      _isLoaded = false;
    }
  }

  /// テキストから ICD-11 エントリを検索
  ///
  /// アルゴリズム：
  /// 1. 入力テキストを小文字化・トークン化
  /// 2. 各エントリの keywords と部分一致チェック
  /// 3. マッチ数でスコアリング（多く一致したエントリほど高スコア）
  /// 4. 上位 [maxResults] エントリを返却
  ///
  /// [text]: 検索対象（症状記述・会話履歴の連結など）
  /// [maxResults]: 最大返却数（デフォルト 5）
  /// [minScore]: 最小スコア閾値（0.0〜1.0、デフォルト 0.0 = 全候補返却）
  List<IcdMatch> lookup(
    String text, {
    int maxResults = 5,
    double minScore = 0.0,
  }) {
    if (!_isLoaded || _entries.isEmpty) return [];
    if (text.trim().isEmpty) return [];

    final normalized = text.toLowerCase();
    final scores = <int, _ScoreData>{};

    // フェーズ 1: フルキーワード（複合語）の一致を最優先
    for (final entry in _keywordIndex.entries) {
      final keyword = entry.key;
      if (normalized.contains(keyword)) {
        // 複合語ほど高得点（"rice water stool" > "fever"）
        final wordCount = keyword.split(' ').length;
        final boost = 1.0 + (wordCount - 1) * 0.5;
        for (final idx in entry.value) {
          scores.putIfAbsent(idx, () => _ScoreData());
          if (!scores[idx]!.matched.contains(keyword)) {
            scores[idx]!.matched.add(keyword);
            scores[idx]!.rawScore += boost;
          }
        }
      }
    }

    if (scores.isEmpty) return [];

    // 最大スコアで正規化
    final maxScore = scores.values
        .map((s) => s.rawScore)
        .fold<double>(0, (a, b) => a > b ? a : b);

    final matches = scores.entries
        .map((e) {
          final entry = _entries[e.key];
          final normalizedScore =
              maxScore > 0 ? e.value.rawScore / maxScore : 0.0;
          return IcdMatch(
            entry: entry,
            matchedKeywords: List.unmodifiable(e.value.matched),
            score: normalizedScore,
          );
        })
        .where((m) => m.score >= minScore)
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    return matches.take(maxResults).toList();
  }

  /// Layer 3 プロンプト統合用：マッチ結果を整形済み文字列で返す
  ///
  /// 出力例：
  /// ```
  /// ━━ ICD-11 REFERENCE (informational, do not cite codes verbatim) ━━
  /// Top relevant entries from WHO ICD-11 Primary Care subset:
  /// - 1F40 "Malaria" (urgency hint: L3, Infectious): Fever with chills/rigors...
  /// - DA92.0 "Acute appendicitis" (urgency hint: L3, Gastrointestinal): Classic migration...
  /// ```
  String buildPromptContext(List<IcdMatch> matches) {
    if (matches.isEmpty) {
      return ''; // 空なら何も入れない（無関係なら追加しない）
    }
    final lines = <String>[
      '━━ ICD-11 REFERENCE (WHO Primary Care subset, informational) ━━',
      'Source: WHO ICD-11 https://icd.who.int/browse11 (CC BY-ND 3.0 IGO).',
      'Each entry below shows: code "title" (urgency hint, category) <canonical URI>: note.',
      'Use these as background only — do not assume any are correct without clinical reasoning. '
          'You may cite condition names in your response when appropriate; the LEVEL/ACTION decision is yours.',
      '',
      ...matches.map((m) => m.entry.toPromptLine()),
    ];
    return lines.join('\n');
  }
}

class _ScoreData {
  final List<String> matched = [];
  double rawScore = 0;
}
