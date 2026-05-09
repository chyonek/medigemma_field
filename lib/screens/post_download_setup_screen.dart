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

  const PostDownloadSetupScreen({super.key, required this.onComplete});

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

  @override
  void initState() {
    super.initState();
    _runSetup();
  }

  @override
  void dispose() {
    ScreenKeepOn.disable().catchError((_) {});
    super.dispose();
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

    try {
      // ── Phase 1: モデル初回ロード（ダミー推論で warm-up） ──
      // 「Gemma 4 を起動中…」を表示しながら、軽いプロンプトで初回 init を発火
      setState(() => _currentStep = 'warmup');
      debugPrint('[PostDLSetup] Phase 1: warming up Gemma 4...');
      await GemmaService.warmUp();
      debugPrint('[PostDLSetup] Phase 1: complete');
      setState(() => _modelReady = true);

      // ── Phase 2: UI 翻訳（必要な場合のみ） ──
      if (needsTranslation) {
        setState(() => _currentStep = 'translating');
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
        title: 'MediGemma Field is ready! / 使用準備完了',
        body: 'Tap to start using the app / タップして開始',
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
                const Text(
                  'Setting up AI for first use\nAI を初回起動中',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      height: 1.4),
                ),
                const SizedBox(height: 12),
                const Text(
                  'This takes 1–2 minutes the first time only.\n'
                  '初回のみ 1〜2 分かかります。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white60, fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 36),

                // ━━ Phase 1: モデルウォームアップ ━━
                _phaseRow(
                  icon: Icons.memory,
                  label: 'Loading Gemma 4 model / Gemma 4 を読み込み',
                  active: _currentStep == 'warmup' && !_modelReady,
                  done: _modelReady,
                ),
                const SizedBox(height: 16),

                // ━━ Phase 2: UI 翻訳 ━━
                _phaseRow(
                  icon: Icons.translate,
                  label: 'Translating interface / UI を翻訳',
                  active: _currentStep == 'translating' && !_translationDone,
                  done: _translationDone,
                  progress: _currentStep == 'translating' && !_translationDone
                      ? _translationProgress
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
                          'Setup failed / セットアップ失敗',
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
                              'Continue anyway / そのまま続ける',
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
  }) {
    final color = done
        ? const Color(0xFF66BB6A)
        : active
            ? const Color(0xFF42A5F5)
            : Colors.white24;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
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
              Text(
                label,
                style: TextStyle(
                    color: done ? Colors.white : Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w500),
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
              ],
            ],
          ),
        ),
      ],
    );
  }
}
