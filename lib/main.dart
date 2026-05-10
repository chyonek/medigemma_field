import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/questionnaire_screen.dart';
import 'screens/conversation_screen.dart';
import 'screens/model_download_screen.dart';
import 'screens/post_download_setup_screen.dart';
import 'screens/result_screen.dart';
import 'screens/settings_screen.dart';
import 'services/translation_service.dart';
import 'services/model_service.dart';
import 'services/session_service.dart';
import 'services/connectivity_service.dart';
import 'services/icd_service.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ★ セキュリティ: release ビルドでは debugPrint を no-op に差し替える。
  //   Flutter の debugPrint はデフォルトで release でも動作するため、
  //   患者の主訴・AI raw response・エラースタック等が logcat に残る。
  //   共有端末で `adb logcat` できる環境では医療データが漏れるため
  //   本番ビルドでは完全に黙らせる。kDebugMode/kProfileMode では維持して
  //   開発者体験は損なわない。
  //   OWASP "LLM and Gen AI Data Security Best Practices 2025"
  //   Principle #7 Secure Development & Audit Logging Best Practice 準拠。
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  // ★ Edge-to-edge / SystemUI 設定だけ先に走らせ、すぐ runApp する。
  //   IcdService / TranslationService / FlutterGemma.initialize 等の重い
  //   init は StartupScreen に移して進捗 UI 付きで実行する。
  //   こうしないと OS が low-memory で kill → 再起動した cold start で
  //   Android 12 splash が数十秒残って「固まった」ように見える問題が起きる。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  ));

  runApp(const MediGemmaApp());
}

/// 起動時の重い初期化を 1 か所にまとめる。StartupScreen が進捗を見せながら
/// この Future を await する。プロセス kill → 再起動の cold start でも、
/// Flutter UI が即座に表示されて「splash で固まった」UX を回避する。
Future<void> _bootstrapHeavyInit() async {
  // .env は任意 (開発時の HF token のみ)。
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    debugPrint('[bootstrap] .env not loaded (expected in production): $e');
  }

  // flutter_gemma 0.15.0：アプリ起動時に一度だけ初期化。
  // Gemma 4 は HF トークン不要だが、開発時に .env の HF_TOKEN があれば
  // rate limit 緩和のため使用（任意）。
  final hfToken = dotenv.env['HF_TOKEN']?.trim();
  await FlutterGemma.initialize(
    huggingFaceToken: (hfToken != null && hfToken.isNotEmpty) ? hfToken : null,
    maxDownloadRetries: 10,
  );

  // ICD-11 辞書ロード（assets JSON）+ 通知 + 翻訳キャッシュ初期化。
  // 並列実行で時間短縮 (依存関係なし)。
  await Future.wait([
    IcdService.instance.initialize(),
    NotificationService.initialize(),
    TranslationService.instance.initialize(),
  ]);
}

class MediGemmaApp extends StatelessWidget {
  const MediGemmaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MediGemma Field',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
      ),
      home: const StartupScreen(),
    );
  }
}

// 起動時にオフラインモデルの有無を確認してルーティング
class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  String _status = 'Starting…';
  bool _hasError = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _runBootstrap();
  }

  /// 重い init → モデル状態判定 → 適切な画面へ遷移を一連で実行。
  /// 各段階で _status を更新してユーザーに進捗を見せる。
  Future<void> _runBootstrap() async {
    try {
      setState(() => _status = 'Loading resources…');
      await _bootstrapHeavyInit();

      if (!mounted) return;
      setState(() => _status = 'Checking AI model…');
      final hasModel = await ModelService.isModelDownloaded();

      if (!mounted) return;
      final navigator = Navigator.of(context);

      if (hasModel) {
        navigator.pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
        return;
      }

      // 開発時のみ「スキップ済み」preference 尊重
      if (kDebugMode) {
        final prefs = await SharedPreferences.getInstance();
        final skipped = prefs.getBool('model_download_skipped') ?? false;
        if (skipped) {
          navigator.pushReplacement(
            MaterialPageRoute(builder: (_) => const HomeScreen()),
          );
          return;
        }
      }

      // 必ずダウンロード画面を表示（毎回起動時、モデル無ければ強制）
      navigator.pushReplacement(
        MaterialPageRoute(
          builder: (_) => ModelDownloadScreen(
            onComplete: () => navigator.pushReplacement(
              MaterialPageRoute(
                builder: (_) => PostDownloadSetupScreen(
                  onComplete: () => navigator.pushReplacement(
                    MaterialPageRoute(builder: (_) => const HomeScreen()),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } catch (e, stack) {
      debugPrint('[StartupScreen] bootstrap error: $e\n$stack');
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.health_and_safety,
                  color: Color(0xFF42A5F5), size: 64),
              const SizedBox(height: 24),
              const Text(
                'MediGemma Field',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 32),
              if (!_hasError) ...[
                const CircularProgressIndicator(color: Color(0xFF42A5F5)),
                const SizedBox(height: 20),
                Text(
                  _status,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Please keep the app open',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ] else ...[
                const Icon(Icons.error_outline,
                    color: Color(0xFFE65100), size: 48),
                const SizedBox(height: 12),
                const Text(
                  'Setup failed',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _errorMessage.length > 200
                      ? '${_errorMessage.substring(0, 200)}…'
                      : _errorMessage,
                  style:
                      const TextStyle(color: Colors.white60, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _hasError = false;
                      _errorMessage = '';
                      _status = 'Retrying…';
                    });
                    _runBootstrap();
                  },
                  child: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── ホーム画面 ───────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _hasOfflineModel = true;
  bool _isOnline = false;
  SavedResult? _lastResult;
  final _translation = TranslationService.instance;

  @override
  void initState() {
    super.initState();
    _translation.addListener(_onTranslationChanged);
    _refreshAll();
    // モデルDL済みなら、UI翻訳をバックグラウンドで実行
    _translation.ensureTranslated();
  }

  @override
  void dispose() {
    _translation.removeListener(_onTranslationChanged);
    super.dispose();
  }

  void _onTranslationChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      _checkModelStatus(),
      _checkConnectivity(),
      _loadLastResult(),
    ]);
    // モデル状態変わってたら翻訳再試行
    _translation.ensureTranslated();
  }

  Future<void> _loadLastResult() async {
    final saved = await SessionService.loadLastResult();
    if (mounted) setState(() => _lastResult = saved);
  }

  Future<void> _checkModelStatus() async {
    final hasModel = await ModelService.isModelDownloaded();
    if (mounted) setState(() => _hasOfflineModel = hasModel);
  }

  Future<void> _checkConnectivity() async {
    final online = await ConnectivityService.isOnline();
    if (mounted) setState(() => _isOnline = online);
  }

  Future<void> _endSession() async {
    HapticFeedback.mediumImpact(); // 破壊的アクション開始の触覚
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A2E45),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.delete_outline, color: Colors.redAccent, size: 24),
            SizedBox(width: 10),
            Text(
              'End Session',
              style: TextStyle(color: Colors.white, fontSize: 19),
            ),
          ],
        ),
        content: const Text(
          'All conversation history will be cleared from this device.\n\nすべての会話履歴が端末から消去されます。',
          style: TextStyle(color: Colors.white, fontSize: 15, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel / キャンセル',
                style: TextStyle(color: Colors.white60, fontSize: 15)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Clear & Exit / 消去して終了',
              style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: 15,
                  fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      // 保存された最後の結果を消去
      await SessionService.clearResult();
      if (!mounted) return;
      // ナビゲーションスタックを全消去 → 新しいHomeScreenへ
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    }
  }

  // 警告バナーをタップ → ボトムシートを表示
  void _showOfflineModelInfo() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A2E45),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _OfflineModelBottomSheet(
        onDownload: _openDownloadScreen,
      ),
    );
  }

  // ダウンロード画面へ遷移 → 戻ったらモデル状態を再チェック
  Future<void> _openDownloadScreen() async {
    Navigator.pop(context); // ボトムシートを閉じる
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ModelDownloadScreen(
          onComplete: () => Navigator.pop(context),
        ),
      ),
    );
    _checkModelStatus(); // 戻ってきたら状態を再チェック
  }

  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    _refreshAll(); // 戻ったらモデル状態を再チェック
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      // AppBar に歯車アイコンだけ載せる（透過して目立たない）
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 44,
        actions: [
          IconButton(
            tooltip: 'Settings / 設定',
            icon: const Icon(Icons.settings_outlined,
                color: Colors.white54, size: 22),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        // 文字サイズ大・小画面でもオーバーフローしないようスクロール可能に
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // タイトル
              const Text(
                'MediGemma Field',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _translation.t('app_subtitle'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 15),
              ),
              const SizedBox(height: 12),

              // ステータスインジケーター（モデル DL 済みのときのみ表示）
              // 未 DL 時は下の _SetupRequiredCard が CTA を兼ねるため非表示
              if (_hasOfflineModel) ...[
                _StatusBadge(
                  isOnline: _isOnline,
                  hasOfflineModel: _hasOfflineModel,
                  onTap: _refreshAll,
                ),
                const SizedBox(height: 18),
              ],

              // モデル未DL時：問診票/対話相談カードと前回結果を非表示
              // → 押せても何もできないので隠して、巨大な DL CTA だけを残す
              if (!_hasOfflineModel) ...[
                const SizedBox(height: 16),
                _SetupRequiredCard(onDownload: _openDownloadScreen),
                const SizedBox(height: 24),
              ] else ...[
                // 前回の結果カード（モデル DL 済みのときのみ）
                if (_lastResult != null) ...[
                  _LastResultCard(
                    saved: _lastResult!,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ResultScreen(
                          result: _lastResult!.result,
                          saveOnLoad: false, // 閲覧のみ・タイムスタンプ更新しない
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ] else
                  const SizedBox(height: 28),

                // 2つの入り口ボタン（ガイド形式 vs 自由形式）
                _EntryButton(
                  icon: Icons.assignment_outlined,
                  label: _translation.t('home_questionnaire'),
                  description: _translation.t('home_questionnaire_desc'),
                  color: const Color(0xFF1565C0),
                  onTap: () async {
                    await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const QuestionnaireScreen()));
                    _loadLastResult();
                  },
                ),
                const SizedBox(height: 16),
                _EntryButton(
                  icon: Icons.chat_bubble_outline,
                  label: _translation.t('home_conversation'),
                  description: _translation.t('home_conversation_desc'),
                  color: const Color(0xFF388E3C),
                  onTap: () async {
                    await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ConversationScreen()));
                    _loadLastResult();
                  },
                ),

                const SizedBox(height: 28),

                // セッション終了ボタン（モデル DL 済みのときのみ・履歴あるなら意味がある）
                TextButton.icon(
                  onPressed: _endSession,
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.white60, size: 20),
                  label: Text(
                    _translation.t('home_end_session'),
                    style: const TextStyle(color: Colors.white60, fontSize: 14),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

}

// ─── ステータスバッジ（2状態・ITに詳しくない人向け） ────
class _StatusBadge extends StatelessWidget {
  final bool isOnline;
  final bool hasOfflineModel;
  final VoidCallback onTap;
  const _StatusBadge({
    required this.isOnline,
    required this.hasOfflineModel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = TranslationService.instance;

    // 状態1：モデルDL済み → どこでも使える（緑）
    if (hasOfflineModel) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF66BB6A).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF66BB6A), width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle,
                color: Color(0xFF66BB6A), size: 22),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.t('badge_works_anywhere'),
                    style: const TextStyle(
                        color: Color(0xFF66BB6A),
                        fontSize: 14,
                        fontWeight: FontWeight.bold),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.smartphone,
                          color: const Color(0xFF66BB6A)
                              .withValues(alpha: 0.85),
                          size: 12,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            t.t('badge_works_anywhere_sub'),
                            style: TextStyle(
                                color: const Color(0xFF66BB6A)
                                    .withValues(alpha: 0.85),
                                fontSize: 13,
                                height: 1.3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // 状態2：モデル未DL + オフライン（赤）
    if (!isOnline) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFB71C1C).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: const Color(0xFFB71C1C), width: 1.2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  color: Color(0xFFB71C1C), size: 22),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      t.t('badge_setup_required'),
                      style: const TextStyle(
                          color: Color(0xFFB71C1C),
                          fontSize: 14,
                          fontWeight: FontWeight.bold),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        t.t('badge_setup_tap_offline'),
                        style: const TextStyle(
                            color: Color(0xFFB71C1C),
                            fontSize: 13,
                            height: 1.3),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.refresh,
                  color: Color(0xFFB71C1C), size: 20),
            ],
          ),
        ),
      );
    }

    // 状態3：モデル未DL + オンライン
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFE65100).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE65100), width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.download_for_offline_outlined,
                color: Color(0xFFE65100), size: 22),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.t('badge_setup_required'),
                    style: const TextStyle(
                        color: Color(0xFFE65100),
                        fontSize: 14,
                        fontWeight: FontWeight.bold),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      t.t('badge_setup_tap_online'),
                      style: const TextStyle(
                          color: Color(0xFFE65100),
                          fontSize: 13,
                          height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right,
                color: Color(0xFFE65100), size: 20),
          ],
        ),
      ),
    );
  }
}

// ─── ボトムシート（メリット説明 + ダウンロードボタン）──────
class _OfflineModelBottomSheet extends StatelessWidget {
  final VoidCallback onDownload;
  const _OfflineModelBottomSheet({required this.onDownload});

  Widget _benefit(IconData icon, String english, String local) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFF42A5F5), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(english,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500)),
                Text(local,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // タイトル
          const Text(
            'AIをセットアップする / Set up AI',
            style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Gemma 4 E2B モデル（約 2.4 GB）を一度だけダウンロード。\n'
            'その後は電波がなくても使えます。\n\n'
            'One-time download of Gemma 4 E2B model (~2.4 GB).\n'
            'Works without internet after that.',
            style: TextStyle(color: Colors.white, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 20),

          // メリット一覧
          _benefit(
            Icons.wifi_off,
            'Works without internet',
            'ネットなしで動作',
          ),
          _benefit(
            Icons.lock_outline,
            'All data stays on your device',
            'データが端末外に出ない（GDPR・HIPAA準拠）',
          ),
          _benefit(
            Icons.public_off,
            'Works in conflict zones & refugee camps',
            '紛争地・難民キャンプでも使用可能',
          ),
          _benefit(
            Icons.flash_on,
            'Faster responses — no network delay',
            'ネット遅延なし・高速回答',
          ),

          const SizedBox(height: 24),

          // ダウンロードボタン
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onDownload,
              icon: const Icon(Icons.download, size: 22),
              label: const Text(
                'Download now / 今すぐダウンロード',
                style:
                    TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1976D2),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          // 「あとで」は debug のみ。本番では DL を促すために常に表示しない。
          if (kDebugMode) ...[
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Debug: Later (dev only)',
                    style: TextStyle(
                        color: Colors.white38, fontSize: 11)),
              ),
            ),
          ] else
            const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ─── 前回の結果カード ─────────────────────────────────────
class _LastResultCard extends StatelessWidget {
  final SavedResult saved;
  final VoidCallback onTap;
  const _LastResultCard({required this.saved, required this.onTap});

  Color get _color {
    switch (saved.result.level) {
      case 1: return const Color(0xFF1565C0);
      case 3: return const Color(0xFFB71C1C);
      default: return const Color(0xFFE65100);
    }
  }

  IconData get _icon {
    switch (saved.result.level) {
      case 1: return Icons.check_circle_outline;
      case 3: return Icons.cancel_outlined;
      default: return Icons.warning_amber_outlined;
    }
  }

  String get _levelLabel {
    switch (saved.result.level) {
      case 1: return 'Level 1 — Manage at home';
      case 3: return 'Level 3 — Go to hospital NOW';
      default: return 'Level 2 — See a doctor soon';
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _color.withOpacity(0.6), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ヘッダー行
            Row(
              children: [
                Icon(_icon, color: _color, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _levelLabel,
                    style: TextStyle(
                        color: _color,
                        fontSize: 15,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  SessionService.timeAgo(saved.timestamp),
                  style: const TextStyle(color: Colors.white60, fontSize: 13),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, color: Colors.white60, size: 20),
              ],
            ),
            const SizedBox(height: 10),
            // アクション（要約）
            Text(
              saved.result.action,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white, fontSize: 15, height: 1.4),
            ),
            const SizedBox(height: 8),
            // 医師に見せるヒント
            const Row(
              children: [
                Icon(Icons.local_hospital_outlined,
                    color: Colors.white54, size: 15),
                SizedBox(width: 6),
                Text(
                  'Tap to show your doctor / タップして医師に見せる',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── セットアップ必須カード（モデル未 DL 時の唯一の CTA） ──
// モデルが無いと何もできないので、メニューを隠してこれだけ表示する。
// 「DL するしかない」状況をユーザーにはっきり伝える。
class _SetupRequiredCard extends StatelessWidget {
  final VoidCallback onDownload;
  const _SetupRequiredCard({required this.onDownload});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2E45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: const Color(0xFF42A5F5).withValues(alpha: 0.4), width: 1.5),
      ),
      child: Column(
        children: [
          // アイコン
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF1565C0).withValues(alpha: 0.25),
            ),
            child: const Icon(Icons.cloud_download_outlined,
                color: Color(0xFF42A5F5), size: 36),
          ),
          const SizedBox(height: 14),

          // タイトル
          const Text(
            'AIをセットアップしてください\nSet up the AI to get started',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
                height: 1.4),
          ),
          const SizedBox(height: 10),

          // 説明（一度だけ・Wi-Fi 推奨）
          const Text(
            'Gemma 4 E2B モデル（約 2.4 GB・Wi-Fi 推奨）を一度だけダウンロード。\n'
            'ダウンロード後はネットなしで使えます。\n\n'
            'One-time download of Gemma 4 E2B (~2.4 GB, Wi-Fi recommended).\n'
            'Works without internet after that.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white70, fontSize: 13, height: 1.6),
          ),
          const SizedBox(height: 18),

          // 大きな DL ボタン
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onDownload,
              icon: const Icon(Icons.download, size: 22),
              label: const Text(
                'Download AI / AIをダウンロード',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1976D2),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── エントリーボタン ─────────────────────────────────────
class _EntryButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? description;
  final Color color;
  final VoidCallback onTap;

  const _EntryButton({
    required this.icon,
    required this.label,
    this.description,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (description != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      description!,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
