// integration_test/app_test.dart
//
// MediGemma Field — 統合テスト (Pixel 6a 実機向け)
//
// 実行:
//   flutter test integration_test/app_test.dart -d <pixel-6a-device-id>
//
// 1 回のテスト実行で:
//   1. fresh install (flutter test が自動で行う)
//   2. アプリ起動 → 規約画面
//   3. 同意チェック → DL ボタンタップ
//   4. DL 進捗を最大 20 分待機 (foreground 状態で DL 進行)
//   5. DL 完了 → Post-DL Setup (engine warmup + UI 翻訳, ~4 分)
//   6. ホーム画面到達を確認
//   7. (オプション) S2 問診票フローで重複質問バグの回帰チェック
//
// 制約 (manual testing が必要):
//   - "背面で DL が継続するか" は integration_test では検証不能
//     (テスト中は app が常に foreground)
//   - "完了通知の heads-up 表示" もテスト不能
//     (OS レベルの通知挙動は integration_test の管轄外)
//   - これらは手動テスト (test_scenarios.md S1 / S6) + 動画撮影で検証
//
// 推奨環境:
//   - **USB ケーブル接続**: wireless adb は 15-20 分の長丁場でタイムアウトする

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:medigemma_field/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ─────────────────────────────────────────────────────────
  // 共通ヘルパー
  // ─────────────────────────────────────────────────────────

  /// 画面上の全 Text widget を結合 (debug + assertion 用)
  String collectAllText(WidgetTester tester) {
    final buf = StringBuffer();
    tester.allWidgets.whereType<Text>().forEach((w) {
      if (w.data != null) buf.write('${w.data}\n');
    });
    return buf.toString();
  }

  /// keyword のいずれかが見えるまで polling 待機。
  /// pumpAndSettle は CircularProgressIndicator で永久にブロックされるので使えない。
  Future<bool> waitForAnyText(
    WidgetTester tester,
    List<String> keywords, {
    required Duration timeout,
    Duration step = const Duration(seconds: 1),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final visible = collectAllText(tester);
      for (final kw in keywords) {
        if (visible.contains(kw)) {
          // UI 安定化のため少し追加 pump
          await tester.pump(const Duration(milliseconds: 500));
          return true;
        }
      }
      await tester.pump(step);
    }
    return false;
  }

  /// 起動後 → 規約画面 (TermsScreen) or DL 画面 が出るまで待つ
  Future<void> waitForFirstScreen(WidgetTester tester) async {
    app.main();
    final found = await waitForAnyText(
      tester,
      [
        '同意して', 'Agree', 'agree', 'Terms', '規約',
        'Gemma 4', 'AI をセットアップ', 'Setup AI', 'ダウンロード', 'Download',
        '問診票', 'intake form', '対話', 'consult',
      ],
      timeout: const Duration(seconds: 90),
    );
    expect(found, isTrue,
        reason:
            'After bootstrap, expected to land on Terms/Download/Home screen.');
  }

  /// 「同意」チェックボックスを探してタップ
  /// 優先: ValueKey('agree_checkbox_row') の InkWell をタップ (InkWell の onTap が toggle)
  /// fallback: Checkbox widget 直接 tap → 同意テキスト周辺の tap
  Future<bool> tickAgreeCheckbox(WidgetTester tester) async {
    // Primary: keyed InkWell
    final keyedRow = find.byKey(const ValueKey('agree_checkbox_row'));
    if (tester.any(keyedRow)) {
      try {
        await tester.ensureVisible(keyedRow.first);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(keyedRow.first);
        await tester.pump(const Duration(seconds: 1));
        debugPrint('[TEST] Tapped agree_checkbox_row (keyed)');
        return true;
      } catch (e) {
        debugPrint('[TEST] Keyed agree tap failed: $e');
      }
    }
    // Fallback: Checkbox widget
    final checkbox = find.byType(Checkbox);
    if (tester.any(checkbox)) {
      try {
        await tester.tap(checkbox.first, warnIfMissed: false);
        await tester.pump(const Duration(seconds: 1));
        debugPrint('[TEST] Tapped Checkbox (fallback)');
        return true;
      } catch (e) {
        debugPrint('[TEST] Checkbox tap failed: $e');
      }
    }
    debugPrint('[TEST] WARN: no agree checkbox found');
    return false;
  }

  /// 「同意して DL」ボタンを探してタップ
  /// 優先: ValueKey('download_button') の ElevatedButton
  /// fallback: テキスト検索
  Future<bool> tapDownloadButton(WidgetTester tester) async {
    final keyedBtn = find.byKey(const ValueKey('download_button'));
    if (tester.any(keyedBtn)) {
      try {
        await tester.ensureVisible(keyedBtn.first);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(keyedBtn.first);
        await tester.pump(const Duration(seconds: 2));
        debugPrint('[TEST] Tapped download_button (keyed)');
        return true;
      } catch (e) {
        debugPrint('[TEST] Keyed download tap failed: $e');
      }
    }
    // Fallback: text-based
    final candidates = [
      RegExp(r'同意してダウンロード'),
      RegExp(r'Agree.*download', caseSensitive: false),
    ];
    for (final pat in candidates) {
      final btn = find.textContaining(pat);
      if (tester.any(btn)) {
        try {
          await tester.tap(btn.first, warnIfMissed: false);
          await tester.pump(const Duration(seconds: 2));
          debugPrint('[TEST] Tapped download button (text fallback)');
          return true;
        } catch (_) {}
      }
    }
    fail('Could not find/tap download button.\n${collectAllText(tester)}');
  }

  // ─────────────────────────────────────────────────────────
  // S1: Fresh install → DL → Setup → Home (end-to-end automated)
  // ─────────────────────────────────────────────────────────
  testWidgets(
      'S1: end-to-end fresh install → download → setup → home',
      (tester) async {
    // ─ Phase 1: 起動 → 規約 / DL 画面 ─
    await waitForFirstScreen(tester);
    debugPrint('[TEST] Phase 1: First screen reached');
    debugPrint(
        '[TEST] Visible (first 300):\n${collectAllText(tester).substring(0, collectAllText(tester).length.clamp(0, 300))}');

    // 既にホーム画面なら DL flow を skip (前回のテストでモデル残ってる場合)
    if (collectAllText(tester).contains('問診票') ||
        collectAllText(tester).contains('対話') ||
        collectAllText(tester).contains('intake')) {
      debugPrint('[TEST] Already on home screen, skipping DL flow');
    } else {
      // ─ Phase 2: 規約同意 → DL ボタンタップ ─
      final agreed = await tickAgreeCheckbox(tester);
      if (!agreed) {
        fail('Could not toggle agree checkbox. Visible:\n'
            '${collectAllText(tester)}');
      }
      // チェック後 1 秒待って state 反映
      await tester.pump(const Duration(seconds: 1));
      debugPrint('[TEST] Phase 2: Checkbox toggled');

      final clicked = await tapDownloadButton(tester);
      if (!clicked) fail('Could not tap download button');
      debugPrint('[TEST] Phase 2: Download button tapped');

      // ─ Phase 3: DL 進捗が始まるのを確認 (最大 30 秒) ─
      final dlStarted = await waitForAnyText(
        tester,
        ['%', 'GB', 'ダウンロード中', 'Downloading'],
        timeout: const Duration(seconds: 30),
      );
      expect(dlStarted, isTrue,
          reason: 'Download did not start within 30s');
      debugPrint('[TEST] Phase 3: Download started');

      // ─ Phase 4: DL 完了を待つ (最大 30 分) ─
      // 完了 signal: PostDownloadSetupScreen 遷移後の text。
      // ModelDownloadScreen の "100.0%" は使わない (substring match の罠あり)。
      // 画面遷移後の text のみを完了 signal にする。
      //
      // 注: pump 間隔を 30 秒に伸ばして CPU を解放 (DL を妨げないため)。
      debugPrint('[TEST] Phase 4: Waiting for download completion (up to 30 min)...');
      final phase4Start = DateTime.now();
      bool dlDone = false;
      const phase4Timeout = Duration(minutes: 30);
      while (DateTime.now().difference(phase4Start) < phase4Timeout) {
        // 軽い pump (1 秒) で画面 frame 確認 → 直後に長め (29 秒) 寝る
        await tester.pump(const Duration(seconds: 1));
        final visible = collectAllText(tester);
        // PostDownloadSetupScreen のいずれかの文字列を検出
        if (visible.contains('Loading Gemma') ||
            visible.contains('Gemma 4 を読み込み') ||
            visible.contains('Translating') ||
            visible.contains('UI を翻訳') ||
            visible.contains('Setting up AI for first use') ||
            visible.contains('AI を初回起動中')) {
          dlDone = true;
          break;
        }
        // 進捗 % を log に出す (debug 補助)
        final pctMatch = RegExp(r'(\d+(?:\.\d+)?)\s*%').firstMatch(visible);
        final elapsed = DateTime.now().difference(phase4Start).inSeconds;
        debugPrint('[TEST] Phase 4 elapsed ${elapsed}s, current %: '
            '${pctMatch?.group(1) ?? "?"}');
        await tester.pump(const Duration(seconds: 29));
      }
      expect(dlDone, isTrue,
          reason: 'Download did not complete within ${phase4Timeout.inMinutes} minutes');
      debugPrint('[TEST] Phase 4: Download complete '
          '(${DateTime.now().difference(phase4Start).inSeconds}s)');
    }

    // ─ Phase 5: Post-DL Setup (warmup + translation) を待つ ─
    debugPrint('[TEST] Phase 5: Waiting for setup (up to 6 min)...');
    final setupDone = await waitForAnyText(
      tester,
      // ホーム画面の signal を待つ
      ['問診票', '対話', 'intake form', 'conversation', 'consult'],
      timeout: const Duration(minutes: 6),
      step: const Duration(seconds: 3),
    );
    expect(setupDone, isTrue,
        reason: 'Setup did not complete (no home screen) within 6 min');
    debugPrint('[TEST] Phase 5: Home screen reached');

    // ─ Phase 6: ホーム画面の主要素を検証 ─
    final homeText = collectAllText(tester);
    final hasIntake = homeText.contains('問診票') ||
        homeText.contains('intake form') ||
        homeText.contains('Medical intake');
    final hasConvo = homeText.contains('対話') ||
        homeText.contains('conversation') ||
        homeText.contains('consult');
    expect(hasIntake, isTrue,
        reason: 'Home screen should show intake entry');
    expect(hasConvo, isTrue,
        reason: 'Home screen should show conversation entry');
    debugPrint('[TEST] Phase 6: Home screen verified (intake + convo present)');
  }, timeout: const Timeout(Duration(minutes: 30)));

  // ─────────────────────────────────────────────────────────
  // S2: Questionnaire flow → triage (KNOWN FACTS 再質問バグの回帰テスト)
  // ─────────────────────────────────────────────────────────
  // 注: S1 完了後 (= モデル DL 済 + ホーム到達) を前提とするため、
  //     fresh install から走らせる場合は S1 と続けて実行されること。
  //     test framework は 1 ファイル内のテストを順番に実行する。
  testWidgets('S2: questionnaire flow does not re-ask known facts',
      (tester) async {
    // 既にアプリが起動済 (S1 の続き) ならホーム画面
    // 単独実行ならここから新規起動
    if (!tester.any(find.byType(MaterialApp))) {
      await waitForFirstScreen(tester);
      // モデル未 DL なら skip
      if (!collectAllText(tester).contains('問診票') &&
          !collectAllText(tester).contains('intake')) {
        markTestSkipped(
            'Model not ready. Run S1 first or download manually.');
        return;
      }
    }

    // 問診票ボタン
    final intakeBtn = find.textContaining(
        RegExp(r'問診票|intake form', caseSensitive: false));
    expect(intakeBtn, findsWidgets);
    await tester.tap(intakeBtn.first);
    await tester.pump(const Duration(seconds: 2));

    // のど / 痛み / 昨日
    for (final kw in ['のど', '痛み', '昨日']) {
      final chip = find.textContaining(kw);
      if (tester.any(chip)) {
        await tester.tap(chip.first);
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    // 送信
    final submit = find.textContaining(
        RegExp(r'送信|Submit|症状を確認', caseSensitive: false));
    if (!tester.any(submit)) {
      fail('Submit button not found. Visible:\n${collectAllText(tester)}');
    }
    await tester.tap(submit.first);
    await tester.pump(const Duration(seconds: 2));

    // AI 応答を待つ (最大 2 分)
    final initialLen = collectAllText(tester).length;
    final responded = await waitForAnyText(
      tester,
      ['?', '？', 'LEVEL', 'レベル'],
      timeout: const Duration(minutes: 2),
    );
    expect(responded, isTrue, reason: 'AI did not respond within 2 min');

    // 重要: KNOWN FACTS を再質問していないこと
    final afterResp = collectAllText(tester);
    debugPrint('[TEST] Length: $initialLen → ${afterResp.length}');

    final reAskedOnset = RegExp(r'いつから.*[?？]').hasMatch(afterResp);
    expect(reAskedOnset, isFalse,
        reason: 'Should NOT re-ask onset (was in intake form)');

    final reAskedSeverity =
        RegExp(r'(強さ|どのくらい強).*[?？]').hasMatch(afterResp);
    expect(reAskedSeverity, isFalse,
        reason: 'Should NOT re-ask severity (was in intake form)');

    debugPrint('[TEST] S2 passed: no re-ask of known facts');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
