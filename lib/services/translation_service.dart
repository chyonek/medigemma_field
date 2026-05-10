import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'gemma_service.dart';
import 'model_service.dart';

/// 動的 UI 翻訳サービス
///
/// 思想：
///  - **モデル DL 後**に Gemma 4 がオンデバイスで UI 翻訳を生成
///  - **翻訳ファイル ゼロ**で 140 言語対応
///  - 結果は SharedPreferences にキャッシュ → 2回目以降はインスタント
///  - キャッシュ無し・モデル無しのときは英語にフォールバック（壊れない）
///
/// 使い方：
///   1. アプリ起動時に [initialize] を呼ぶ（キャッシュからロード）
///   2. ホーム画面で [ensureTranslated] を呼ぶ（必要なら Gemma で翻訳）
///   3. ウィジェットは [t] で翻訳取得
///   4. 完了通知は [addListener] / [removeListener] で受け取れる
class TranslationService extends ChangeNotifier {
  // シングルトン
  static final TranslationService _i = TranslationService._();
  factory TranslationService() => _i;
  TranslationService._();

  static TranslationService get instance => _i;

  // 現在の言語コード（ja, ar, tl 等）
  String _currentLocale = 'en';
  String get currentLocale => _currentLocale;

  // 翻訳マップ（キャッシュ・実行時翻訳の保存先）
  Map<String, String> _translations = {};

  // 翻訳実行中フラグ
  bool _isTranslating = false;
  bool get isTranslating => _isTranslating;

  // ★ このセッションで一度諦めたら、再起動まで再試行しない。
  //   理由: 翻訳が裏で延々続くと推論エンジン取り合いで SIGSEGV クラッシュする。
  //   部分翻訳でユーザーには既に十分な体験が提供されている (英語フォールバック)。
  bool _gaveUpThisSession = false;

  // 翻訳が完了したか（キャッシュ or Gemma 実行）
  // ⚠️ 「1個でも翻訳が入っていれば true」だと部分翻訳キャッシュで Phase 2 を
  // スキップしてしまい UI が英語のまま残る。全キー翻訳済みのみ ready 扱い。
  bool get isReady =>
      _currentLocale == 'en' ||
      _translations.length >= englishStrings.length;

  // 翻訳済みのキー数（PostDownloadSetupScreen の進捗表示用）
  int get translatedCount => _translations.length;

  // v5: result_details_header を 'Suggested care steps' に変更
  //     → 「受診時の注意点」誤訳回避のため
  static const _cacheKeyPrefix = 'ui_translations_v5_';
  static const _localeOverrideKey = 'ui_locale_override';

  // ─── マスター UI 文字列（英語・このアプリで唯一の "ハードコード"） ──
  // すべての UI ラベルはここに集約。新しい文字列を追加したいときは
  // ここに追加すれば翻訳パイプラインが自動で対応する。
  static const Map<String, String> englishStrings = {
    // ─ ホーム画面 (6) ─
    'app_subtitle': 'Frontier healthcare for those beyond the frontier',
    'home_questionnaire': 'Fill out medical intake form',
    'home_questionnaire_desc':
        'Tap to select symptoms · attach photo',
    'home_conversation': 'Conversational consultation',
    'home_conversation_desc': 'Speak or type · switch anytime',
    'home_end_session': 'End session & clear history',

    // ─ ステータスバッジ (5) ─
    'badge_works_anywhere': 'Works anywhere',
    'badge_works_anywhere_sub': 'On-device · works without internet',
    'badge_setup_required': 'Setup required',
    'badge_setup_tap_online': 'Tap to download AI (one-time)',
    'badge_setup_tap_offline': 'Download when internet returns',

    // ─ 体の部位 (12) ─
    'body_head': 'Head/Face',
    'body_neck': 'Neck',
    'body_chest': 'Chest',
    'body_abdomen': 'Abdomen',
    'body_arms': 'Arms/Hands',
    'body_legs': 'Legs/Feet',
    'body_arm_left': 'Left arm/hand',
    'body_arm_right': 'Right arm/hand',
    'body_leg_left': 'Left leg/foot',
    'body_leg_right': 'Right leg/foot',
    'body_eye': 'Eye',
    'body_ear': 'Ear',
    'body_mouth': 'Mouth/Teeth',
    'body_throat': 'Throat',
    'body_back': 'Back/Lower back',
    'body_skin': 'Skin',
    'body_general': 'Whole body',

    // ─ 症状 (10) ─
    'symptom_pain': 'Pain',
    'symptom_fever': 'Fever',
    'symptom_nausea': 'Nausea/Vomiting',
    'symptom_diarrhea': 'Diarrhea',
    'symptom_bleeding': 'Bleeding',
    'symptom_breathing': 'Breathing difficulty',
    'symptom_dizziness': 'Dizziness',
    'symptom_rash': 'Rash/Swelling',
    'symptom_cough': 'Cough',
    'symptom_headache': 'Headache',

    // ─ 期間 (6) ─ 全て「過去」を明示。「now」「currently」を避ける。
    'duration_now': 'Started moments ago',  // ついさっき
    'duration_hours': 'Started a few hours ago',
    'duration_today': 'Started earlier today',
    'duration_yesterday': 'Started since yesterday',
    'duration_days': 'Started a few days ago',
    'duration_week': 'Started one week ago or earlier',

    // ─ 重症度ラベル (5) ─
    'severity_not_set': 'Not specified',
    'severity_mild': 'Mild',
    'severity_moderate': 'Moderate',
    'severity_severe': 'Severe',
    'severity_worst': 'Worst ever',

    // ─ 年齢グループ (5) ─
    'age_infant': 'Under 5',
    'age_child': '5–12',
    'age_teen': '13–17',
    'age_adult': '18–64',
    'age_elderly': '65+',

    // ─ 性別 (3) ─
    'sex_female': 'Female',
    'sex_male': 'Male',
    'sex_other': 'Other / Prefer not to say',

    // ─ 妊娠 (4) ─
    'pregnancy_no': 'No',
    'pregnancy_possible': 'Possible',
    'pregnancy_yes': 'Yes / Currently pregnant',
    'pregnancy_unknown': 'Unknown',

    // ─ クイックリプライ (~16) ─
    'reply_size_rice': 'Like a grain of rice',
    'reply_size_small_bean': 'Like a small bean',
    'reply_size_large_bean': 'Like a large bean',
    'reply_size_1cm': '1–2 cm',
    'reply_size_3cm': '3–5 cm',
    'reply_size_larger': 'Larger',
    'reply_amount_little': 'A little',
    'reply_amount_teaspoon': 'About a teaspoon',
    'reply_amount_tablespoon': 'About a tablespoon',
    'reply_amount_cup': 'A cup or more',
    'reply_yes': 'Yes',
    'reply_no': 'No',
    'reply_dont_know': 'Don\'t know',
    'reply_once': 'Once',
    'reply_a_few_times': '2–3 times',
    'reply_many_times': 'Many times',
    'reply_constant': 'Constant',

    // ─ 結果画面 (10) ─ "Diagnosis" は医師の正式診断と誤解されるので回避
    'result_title': 'Symptom check result',
    'result_what_to_do': 'WHAT TO DO NOW',
    'result_summary_header': 'What the AI understood',
    'result_summary_redo_hint':
        'If this is wrong, tap "Check again" below.',
    'result_conditions_header': 'Possible conditions',
    'result_conditions_dx_label': 'Differential diagnosis',
    'result_conditions_disclaimer':
        'These are possibilities, not a confirmed diagnosis.',
    'result_details_header': 'Suggested care steps',
    'result_disclaimer':
        'This is not a substitute for professional medical diagnosis.',
    'result_long_press_hint': 'Long-press to select & copy',

    // ─ ボタン (8) ─ "triage" は医療専門用語のため一般語に置換
    'btn_redo_triage': 'Check symptoms again',
    'btn_start_new_triage': 'Start a new symptom check',
    'btn_go_back_home': 'Go back to home',
    'btn_read_aloud': 'Read aloud',
    'btn_stop': 'Stop',
    'btn_try_again': 'Try again',
    'btn_copy_error': 'Copy full error report',
    'btn_get_triage': 'Check my symptoms',

    // ─ 問診票セクション (10) ─
    'q_section_who': 'Whose symptoms?',
    'q_section_about': 'About the patient',
    'q_section_where': 'Where?',
    'q_section_what': 'What?',
    'q_section_how_bad': 'How bad?',
    'q_section_when': 'When?',
    'q_section_anything_else': 'Anything else?',
    'q_section_photo': 'Photo?',
    // セクションヒント
    'q_section_who_hint': 'Affects pediatric / pregnancy assessment',
    'q_section_about_hint': 'Optional · Age, sex, pregnancy',
    'q_section_where_hint':
        'Tap the body or chips below — both pick the same part. Tap again to deselect.',
    'q_section_what_hint': 'Tap all that apply',
    'q_section_how_bad_hint': 'Optional · 0 means not specified',
    'q_section_when_hint': 'Optional',
    'q_section_anything_else_hint': 'Optional free text',
    'q_section_photo_hint':
        'Visual symptoms — wound, rash, swelling, etc.',
    'q_self': 'My symptoms',
    'q_other': 'Someone else',
    'q_submit': 'Check my symptoms',
    'q_intro':
        'Fill in what you can. AI will ask follow-up questions if needed.',
    'q_other_parts_label': 'Other parts',
    'q_selected_label': 'Selected',  // body-region selection summary card label
    'q_mirror_view': 'Mirror view: your left = diagram\'s left',
    'q_age_label': 'Age',
    'q_sex_label': 'Sex',
    'q_pregnancy_label': 'Pregnancy',

    // ─ 対話相談 (5) ─
    'conv_how_to_start': 'How would you like to start?',
    'conv_type': 'Type to start',
    'conv_speak': 'Speak to start',
    'conv_describe_symptoms': 'Describe your symptoms',
    'conv_quick_reply_label': 'Quick reply',

    // ─ 共通ヒント (5) ─
    'hint_tap_to_stop': 'Tap to stop',
    'hint_listening': 'Listening — auto-stops after silence',
    'hint_analyzing': 'Analyzing...',
    'hint_searching_icd11': 'Cross-checking with WHO ICD-11 medical reference...',
    'hint_thinking':
        'Generating detailed diagnosis (this takes a bit longer)...',
  };

  /// アプリ起動時：システム言語検出 + キャッシュ読み込み
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();

    // 1. ユーザーが手動で選んだ言語があればそれ
    final manualOverride = prefs.getString(_localeOverrideKey);
    if (manualOverride != null) {
      _currentLocale = manualOverride;
    } else {
      // 2. システム言語
      _currentLocale = ui.PlatformDispatcher.instance.locale.languageCode
          .toLowerCase()
          .split('_')
          .first
          .split('-')
          .first;
    }

    if (_currentLocale == 'en') {
      // 英語はマスターなので翻訳不要
      return;
    }

    // キャッシュ読み込み
    final cached = prefs.getString('$_cacheKeyPrefix$_currentLocale');
    if (cached != null) {
      try {
        _translations = Map<String, String>.from(jsonDecode(cached));
      } catch (_) {
        _translations = {};
      }
    }
    notifyListeners();
  }

  /// 翻訳取得（無ければ英語にフォールバック・壊れない）
  String t(String key) {
    if (_currentLocale == 'en') {
      return englishStrings[key] ?? key;
    }
    final translated = _translations[key];
    if (translated != null && translated.isNotEmpty) return translated;
    return englishStrings[key] ?? key;
  }

  /// オフライン Gemma で UI 翻訳を生成（必要なら）
  /// ホーム画面の最初のロード時に呼ぶ想定
  Future<void> ensureTranslated() async {
    if (_currentLocale == 'en') return;
    if (_translations.length >= englishStrings.length) return; // 既に十分

    // ★ このセッションで諦めた場合は再試行しない (推論エンジンの SIGSEGV 回避)
    if (_gaveUpThisSession) {
      debugPrint(
          '[TranslationService] Already gave up this session — not retrying');
      return;
    }

    // ★ 既に別の呼び出しで翻訳中なら、それの完了を待つ。
    //   setup 画面と home 画面の両方から呼ばれるため。
    //   早期 return すると await した側が「終わった」と誤解して画面遷移してしまう。
    if (_isTranslating) {
      while (_isTranslating) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
      return;
    }

    final hasModel = await ModelService.isModelDownloaded();
    if (!hasModel) {
      debugPrint('[TranslationService] Skipped: model not downloaded');
      return;
    }

    _isTranslating = true;
    notifyListeners();

    try {
      // ⚠️ チャンクサイズの設計トレードオフ:
      //   小さい (10-20) → セッション数増 → SIGSEGV リスク + 累積時間長
      //   大きい (130 全部) → 出力が maxTokens を超えて truncate (実機ログで確認)
      //   中間 (50) → 入出力 ~1500 token で maxTokens=2048 に収まる + セッション 3 回
      // tolerant parser が部分救出するので 1 chunk が truncate しても次に進める
      const chunkSize = 50;
      final allKeys = englishStrings.keys.toList();

      // ★ 全キー揃うまで自動リトライ。setup 画面はこれを await しているので
      //   ユーザーがログを見て判断する必要なく、完了するまで block される。
      //   ただし「同じ truncate 出力を 5 回繰り返す」無駄を避けるため、
      //   進捗ゼロなら早期 break する。tolerant parser が部分救出してくれる。
      const maxOuterAttempts = 3;
      var lastTranslatedCount = -1;
      for (var outerAttempt = 1; outerAttempt <= maxOuterAttempts; outerAttempt++) {
        // 未翻訳のキーを抽出
        final pending = allKeys.where((k) {
          final v = _translations[k];
          return v == null || v.isEmpty;
        }).toList();

        if (pending.isEmpty) break; // 全キー完了

        // 進捗ゼロ判定: 前回試行から 1 件も増えてないなら模型は同じ truncated 出力を返している
        // → これ以上 retry しても無駄なので break (英語フォールバック)
        if (outerAttempt > 1 && _translations.length == lastTranslatedCount) {
          debugPrint(
              '[TranslationService] No progress between attempts — giving up early');
          break;
        }
        lastTranslatedCount = _translations.length;

        debugPrint(
            '[TranslationService] Outer attempt $outerAttempt/$maxOuterAttempts: '
            'translating ${pending.length}/${allKeys.length} keys to "$_currentLocale"...');

        for (var i = 0; i < pending.length; i += chunkSize) {
          final end =
              (i + chunkSize < pending.length) ? i + chunkSize : pending.length;
          final chunkKeys = pending.sublist(i, end);

          Map<String, String> chunkResult = {};
          var innerAttempt = 0;
          while (innerAttempt < 2) {
            innerAttempt++;
            final remaining = <String, String>{
              for (final k in chunkKeys)
                if (!chunkResult.containsKey(k)) k: englishStrings[k]!,
            };
            if (remaining.isEmpty) break;

            try {
              final partial = await GemmaService.translateUiStrings(
                remaining,
                _currentLocale,
              );
              if (partial != null && partial.isNotEmpty) {
                for (final entry in partial.entries) {
                  if (chunkKeys.contains(entry.key) &&
                      entry.value.trim().isNotEmpty) {
                    chunkResult[entry.key] = entry.value;
                  }
                }
              }
            } catch (e) {
              debugPrint(
                  '[TranslationService] Inner attempt $innerAttempt failed: $e');
            }

            if (chunkResult.length >= chunkKeys.length) break;

            // セッション再作成前に native cleanup を待つ
            await Future.delayed(const Duration(milliseconds: 800));
          }

          if (chunkResult.isNotEmpty) {
            _translations.addAll(chunkResult);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(
              '$_cacheKeyPrefix$_currentLocale',
              jsonEncode(_translations),
            );
            debugPrint(
                '[TranslationService] Got ${chunkResult.length}/${chunkKeys.length} keys '
                '(total ${_translations.length}/${allKeys.length})');
            notifyListeners();
          }
        }

        // 外側リトライ前にも cleanup 待ち
        if (_translations.length < allKeys.length) {
          await Future.delayed(const Duration(milliseconds: 800));
        }
      }

      final missing = allKeys.length - _translations.length;
      if (missing == 0) {
        debugPrint(
            '[TranslationService] ✅ Done. All ${allKeys.length} keys translated.');
      } else {
        // ★ 諦めたフラグを立てて、このセッションでは再試行しない。
        //   推論エンジンの SIGSEGV クラッシュ回避のため。
        _gaveUpThisSession = true;
        debugPrint(
            '[TranslationService] ⚠️ Gave up after $maxOuterAttempts outer attempts. '
            '$missing keys still untranslated — UI will show English fallback. '
            'No retries this session.');
      }
    } catch (e) {
      debugPrint('[TranslationService] Failed: $e');
    } finally {
      _isTranslating = false;
      notifyListeners();
    }
  }

  /// ユーザーが言語を手動切替（規約画面の language picker から）
  Future<void> setLocale(String code) async {
    if (code == _currentLocale) return;
    _currentLocale = code;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localeOverrideKey, code);

    // キャッシュ確認
    final cached = prefs.getString('$_cacheKeyPrefix$code');
    if (cached != null) {
      try {
        _translations = Map<String, String>.from(jsonDecode(cached));
      } catch (_) {
        _translations = {};
      }
    } else {
      _translations = {};
    }
    notifyListeners();

    // バックグラウンドで Gemma 翻訳を実行（モデル DL 済みなら）
    ensureTranslated();
  }
}
