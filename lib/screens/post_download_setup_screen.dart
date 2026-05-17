import 'dart:async';
import 'package:flutter/material.dart';
import '../services/screen_keep_on.dart';
import '../services/translation_service.dart';
import '../services/gemma_service.dart';
import '../services/notification_service.dart';

/// DL 完了後・ホーム画面遷移前のセットアップ画面
///
/// 役割：
///  1. Gemma 4 モデルの初回ロード（ウォームアップ。60〜120 秒の重い処理）
///  2. UI 翻訳（システム言語が英語以外なら 100+ キーを Gemma で翻訳）
///
/// なぜ必要：
///  - モデル初回ロードはホーム画面初回表示時に走らせると ANR を引き起こす
///  - 翻訳をホーム画面後に走らせると「英語で表示 → 徐々に日本語化」の体験が悪い
///  - ここで先にすべて終わらせれば、ホーム画面はサクサク動く
class PostDownloadSetupScreen extends StatefulWidget {
  final VoidCallback onComplete;

  /// true なら言語切替後の再翻訳モード (warmup スキップ可・コピー差し替え)
  final bool isLanguageSwitch;

  const PostDownloadSetupScreen({
    super.key,
    required this.onComplete,
    this.isLanguageSwitch = false,
  });

  @override
  State<PostDownloadSetupScreen> createState() =>
      _PostDownloadSetupScreenState();
}

class _PostDownloadSetupScreenState extends State<PostDownloadSetupScreen> {
  // 進捗追跡
  // Phase 1: モデルウォームアップ（不確定タイマー・60〜120 秒）
  // Phase 2: 翻訳（チャンクごとに進捗）
  bool _modelReady = false;
  bool _translationDone = false;
  String _currentStep = '';
  double _translationProgress = 0; // 0.0 - 1.0

  bool _hasError = false;
  String? _errorDetail;

  // ★ 2026-05-17: Phase 1 (warmup) はプログレス取得不可なので、
  //   ハートビート (経過秒 + アニメ済みドット) を表示して "止まってない" 感を出す。
  //   ユーザーが「バグで止まってる?」と思って強制終了するのを防ぐ。
  Timer? _heartbeatTimer;
  DateTime? _warmupStartedAt;
  int _warmupElapsedSeconds = 0;
  // Phase 2 (翻訳) も chunk 間で時間がかかる時のために同じ仕組みを再利用。
  DateTime? _translationStartedAt;
  int _translationElapsedSeconds = 0;

  // 想定範囲 (Pixel 6a 実測ベース)
  static const _warmupTypicalMin = 60;
  static const _warmupTypicalMax = 120;
  static const _translationTypicalMin = 120;
  static const _translationTypicalMax = 300;

  @override
  void initState() {
    super.initState();
    _runSetup();
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    ScreenKeepOn.disable().catchError((_) {});
    super.dispose();
  }

  /// 1 秒ごとに経過秒を更新して "動いてる" 感を出す
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_warmupStartedAt != null && !_modelReady) {
          _warmupElapsedSeconds =
              DateTime.now().difference(_warmupStartedAt!).inSeconds;
        }
        if (_translationStartedAt != null && !_translationDone) {
          _translationElapsedSeconds =
              DateTime.now().difference(_translationStartedAt!).inSeconds;
        }
      });
    });
  }

  String _formatElapsed(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// 経過秒に応じた状況メッセージ。
  /// - typical 範囲内: "Typically X–Y seconds. Just wait."
  /// - typical 範囲超過: "Taking longer than usual. Still running, please keep the screen open."
  String _statusFor(int elapsed, int minSec, int maxSec) {
    if (elapsed < minSec) {
      return 'Typically ${minSec}–${maxSec} seconds.';
    } else if (elapsed < maxSec) {
      return 'Almost there (typical max ${maxSec}s).';
    } else if (elapsed < maxSec * 2) {
      return 'Taking longer than usual — still running. Keep the screen open.';
    } else {
      return 'This is unusually long. Please keep waiting or restart the app if completely frozen.';
    }
  }

  Future<void> _runSetup() async {
    final t = TranslationService.instance;
    final needsTranslation =
        t.currentLocale != 'en' && !t.isReady;

    // 画面消灯防止 ON（モデルロード + 翻訳が終わるまで）
    try {
      await ScreenKeepOn.enable();
      debugPrint('[PostDLSetup] wakelock enabled');
    } catch (_) {}

    _startHeartbeat();

    try {
      // ── Phase 1: モデル初回ロード（ダミー推論で warm-up） ──
      // 言語切替モードの場合は既にモデルウォームアップ済なので skip。
      if (widget.isLanguageSwitch) {
        debugPrint('[PostDLSetup] Language switch mode — skipping warmup');
        setState(() => _modelReady = true);
      } else {
        // 「Gemma 4 を起動中…」を表示しながら、軽いプロンプトで初回 init を発火
        setState(() {
          _currentStep = 'warmup';
          _warmupStartedAt = DateTime.now();
        });
        debugPrint('[PostDLSetup] Phase 1: warming up Gemma 4...');
        await GemmaService.warmUp();
        debugPrint('[PostDLSetup] Phase 1: complete');
        setState(() => _modelReady = true);
      }

      // ── Phase 2: UI 翻訳（必要な場合のみ） ──
      if (needsTranslation) {
        setState(() {
          _currentStep = 'translating';
          _translationStartedAt = DateTime.now();
        });
        debugPrint('[PostDLSetup] Phase 2: translating UI...');

        // TranslationService の進捗を購読
        void onProgress() {
          if (!mounted) return;
          // 翻訳済みキー数 / 全キー数 で進捗計算
          final total = TranslationService.englishStrings.length;
          // _translations は private なので公開メソッド/getter を使う
          // 簡易的に「完了したか」だけで進捗を 0 → 1 にしてもよい
          final done = t.translatedCount;
          setState(() {
            _translationProgress = total > 0 ? (done / total).clamp(0.0, 1.0) : 1.0;
          });
        }

        t.addListener(onProgress);
        try {
          await t.ensureTranslated();
        } finally {
          t.removeListener(onProgress);
        }
        debugPrint('[PostDLSetup] Phase 2: complete');
      }
      setState(() => _translationDone = true);

      // ★ Setup 完了通知（画面消灯中でもユーザーに伝わる）
      NotificationService.show(
        id: NotificationService.idSetupComplete,
        title: 'MediGemma Field is ready!',
        body: 'Tap to start using the app',
      );

      // 軽いディレイで完了演出を見せてから遷移
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      widget.onComplete();
    } catch (e, st) {
      debugPrint('[PostDLSetup] ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _errorDetail = e.toString();
      });
    } finally {
      try {
        await ScreenKeepOn.disable();
        debugPrint('[PostDLSetup] wakelock disabled');
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.medical_services,
                    color: Color(0xFF42A5F5), size: 56),
                const SizedBox(height: 24),
                Text(
                  widget.isLanguageSwitch
                      ? 'Switching language'
                      : 'Setting up AI for first use',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      height: 1.4),
                ),
                const SizedBox(height: 12),
                Text(
                  widget.isLanguageSwitch
                      ? 'Translating the UI on-device. Typically 2 minutes.'
                      : 'First-time setup: about 4 minutes on most phones.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white60, fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 20),

                // ★ 強調警告バナー: 「画面ロック禁止・アプリ閉じないで」
                //   Flutter + on-device LLM の制約上、推論は activity が
                //   foreground にある間のみ可能。Activity が裏化されると
                //   Dart isolate が pause され、最悪 OS にプロセス kill される。
                //   ユーザーに事前に明示することで「途中で別アプリを開いて
                //   セットアップが固まる」UX 不具合を防ぐ。
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE65100).withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: const Color(0xFFE65100), width: 1.5),
                  ),
                  child: const Column(
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: Color(0xFFFFB74D), size: 22),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Keep this screen open',
                              style: TextStyle(
                                color: Color(0xFFFFB74D),
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 8),
                      Text(
                        '• Do NOT lock the screen\n'
                        '• Do NOT switch to other apps',
                        textAlign: TextAlign.left,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            height: 1.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),

                // ━━ Phase 1: モデルウォームアップ ━━ (言語切替時は非表示)
                if (!widget.isLanguageSwitch) ...[
                  _phaseRow(
                    icon: Icons.memory,
                    label: 'Loading Gemma 4 model',
                    active: _currentStep == 'warmup' && !_modelReady,
                    done: _modelReady,
                    // 進捗バーは出せないので elapsed + 想定範囲を出す
                    elapsedSeconds: _currentStep == 'warmup' && !_modelReady
                        ? _warmupElapsedSeconds
                        : null,
                    status: _currentStep == 'warmup' && !_modelReady
                        ? _statusFor(_warmupElapsedSeconds,
                            _warmupTypicalMin, _warmupTypicalMax)
                        : null,
                  ),
                  const SizedBox(height: 16),
                ],

                // ━━ Phase 2: UI 翻訳 ━━
                _phaseRow(
                  icon: Icons.translate,
                  label: 'Translating interface',
                  active: _currentStep == 'translating' && !_translationDone,
                  done: _translationDone,
                  progress: _currentStep == 'translating' && !_translationDone
                      ? _translationProgress
                      : null,
                  elapsedSeconds:
                      _currentStep == 'translating' && !_translationDone
                          ? _translationElapsedSeconds
                          : null,
                  status: _currentStep == 'translating' && !_translationDone
                      ? _statusFor(_translationElapsedSeconds,
                          _translationTypicalMin, _translationTypicalMax)
                      : null,
                ),

                if (_hasError) ...[
                  const SizedBox(height: 32),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFB71C1C).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: const Color(0xFFB71C1C), width: 1.2),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'Setup failed',
                          style: TextStyle(
                              color: Color(0xFFB71C1C),
                              fontSize: 15,
                              fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _errorDetail ?? 'Unknown error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: widget.onComplete,
                          child: const Text(
                              'Continue anyway',
                              style: TextStyle(
                                  color: Color(0xFF42A5F5),
                                  fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _phaseRow({
    required IconData icon,
    required String label,
    required bool active,
    required bool done,
    double? progress,
    int? elapsedSeconds,
    String? status,
  }) {
    final color = done
        ? const Color(0xFF66BB6A)
        : active
            ? const Color(0xFF42A5F5)
            : Colors.white24;
    // active で progress が無い場合は indeterminate のリニアバー
    // (進捗は計れないが「動いてる」感を出す)
    final indeterminate = active && progress == null && !done;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 28,
          height: 28,
          child: done
              ? const Icon(Icons.check_circle,
                  color: Color(0xFF66BB6A), size: 26)
              : active
                  ? const CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Color(0xFF42A5F5)),
                    )
                  : Icon(icon, color: color, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      // active 中はラベルにアニメドット（経過秒で 0-3 個変化）
                      active && !done
                          ? '$label${'.' * ((elapsedSeconds ?? 0) % 4)}'
                          : label,
                      style: TextStyle(
                          color: done ? Colors.white : Colors.white70,
                          fontSize: 14,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                  // 経過時間チップ (active 中のみ)
                  if (active && elapsedSeconds != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _formatElapsed(elapsedSeconds),
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontFeatures: [FontFeature.tabularFigures()]),
                      ),
                    ),
                ],
              ),
              if (progress != null) ...[
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: Colors.white12,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(Color(0xFF42A5F5)),
                ),
                const SizedBox(height: 2),
                Text(
                  '${(progress * 100).toInt()}%',
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 11),
                ),
              ] else if (indeterminate) ...[
                // determinate な % は出せないので indeterminate バーで
                // 「処理は流れている」ことを視覚的に示す
                const SizedBox(height: 6),
                const LinearProgressIndicator(
                  minHeight: 3,
                  backgroundColor: Colors.white12,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(Color(0xFF42A5F5)),
                ),
              ],
              if (active && status != null) ...[
                const SizedBox(height: 6),
                Text(
                  status,
                  style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      height: 1.4),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
