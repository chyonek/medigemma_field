import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/connectivity_service.dart';
import '../services/screen_keep_on.dart';
import '../l10n/terms_translations.dart';
import '../services/model_service.dart';
import '../services/notification_service.dart';

class ModelDownloadScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const ModelDownloadScreen({super.key, required this.onComplete});

  @override
  State<ModelDownloadScreen> createState() => _ModelDownloadScreenState();
}

class _ModelDownloadScreenState extends State<ModelDownloadScreen> {
  double _progress = 0;
  String _status = '';
  bool _isDownloading = false;
  bool _hasError = false;
  bool _termsAccepted = false;

  // サーバー側ファイルサイズ（HEAD リクエストで動的取得・取れなければ null）
  int? _remoteSizeBytes;

  // 表示言語（手動切替可能。システム言語 → fallback で英語）
  String _localeCode = 'en';
  TermsL10n _l10n = TermsL10n.forLocale('en');
  bool _showEnglishAlongside = false;

  static const _gemmaTermsUrl = 'https://ai.google.dev/gemma/terms';
  static const _gemmaPolicyUrl =
      'https://ai.google.dev/gemma/prohibited_use_policy';
  static const _localeOverrideKey = 'terms_locale_override';

  @override
  void initState() {
    super.initState();
    _initLocale();
    // 規約同意は毎回明示的にチェックしてもらう（事前 ON は dark pattern）
    // 過去の同意は内部記録のみ・UI には反映しない
    _termsAccepted = false;
    // サーバー側のファイルサイズを HEAD リクエストで取得（バックグラウンド）
    _fetchRemoteSize();
  }

  @override
  void dispose() {
    // 万一 wakelock が ON のまま画面破棄されたら必ず OFF
    ScreenKeepOn.disable().catchError((_) {});
    super.dispose();
  }

  Future<void> _fetchRemoteSize() async {
    final size = await ModelService.fetchRemoteModelSizeBytes();
    if (!mounted) return;
    setState(() => _remoteSizeBytes = size);
  }

  // 表示言語を決定：
  //   1. ユーザーが過去に手動選択した言語があればそれ
  //   2. システム言語がアプリの対応リスト内ならそれ
  //   3. それ以外は英語
  Future<void> _initLocale() async {
    final prefs = await SharedPreferences.getInstance();
    final manualOverride = prefs.getString(_localeOverrideKey);
    String chosen;

    if (manualOverride != null &&
        TermsL10n.availableLocales().contains(manualOverride)) {
      chosen = manualOverride;
    } else {
      final system = ui.PlatformDispatcher.instance.locale.languageCode
          .toLowerCase()
          .split('_')
          .first
          .split('-')
          .first;
      chosen = TermsL10n.availableLocales().contains(system) ? system : 'en';
    }
    if (!mounted) return;
    setState(() {
      _localeCode = chosen;
      _l10n = TermsL10n.forLocale(chosen);
      _showEnglishAlongside = chosen != 'en';
    });
  }

  Future<void> _selectLocale(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localeOverrideKey, code);
    if (!mounted) return;
    setState(() {
      _localeCode = code;
      _l10n = TermsL10n.forLocale(code);
      _showEnglishAlongside = code != 'en';
    });
  }

  void _showLanguagePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A2E45),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _LanguagePickerSheet(
        currentCode: _localeCode,
        onSelect: (code) {
          Navigator.pop(ctx);
          _selectLocale(code);
        },
      ),
    );
  }

  Future<void> _persistTermsAcceptance() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('gemma_terms_accepted_v1', true);
  }

  // ─── ネットワーク警告ダイアログ ───────────────────────────────
  // 「モバイルデータでも続行する？」の確認。
  // CLAUDE.md ターゲットの 10 言語で静的提供 (DL 前のため Gemma 動的翻訳不可)。
  Future<bool?> _showMobileDataWarning(NetworkType type) {
    final isMobile = type == NetworkType.mobile;
    final sizeMb = (_remoteSizeBytes ?? 2588147712) ~/ (1024 * 1024);
    final title = isMobile ? _l10n.mobileDataTitle : _l10n.noWifiTitle;
    final body = isMobile
        ? _l10n.mobileDataMessage.replaceAll('{MB}', sizeMb.toString())
        : _l10n.noWifiMessage;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B2738),
        icon: Icon(
          isMobile ? Icons.signal_cellular_alt : Icons.warning_amber_rounded,
          color: const Color(0xFFE65100),
          size: 36,
        ),
        title: Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: Text(
          body,
          style: const TextStyle(
              color: Colors.white70, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              _l10n.cancel,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              _l10n.continueAnyway,
              style: const TextStyle(color: Color(0xFFE65100)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showNoConnectionDialog() {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B2738),
        icon: const Icon(Icons.signal_wifi_off,
            color: Color(0xFFB71C1C), size: 36),
        title: Text(
          _l10n.noConnectionTitle,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: Text(
          _l10n.noConnectionMessage,
          style: const TextStyle(
              color: Colors.white70, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(_l10n.ok,
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // Monotonic 進捗追跡（リトライで一時的に 0% に戻ってもユーザーには見せない）
  // flutter_gemma の smart_downloader は再試行時に一時的に 0% を発火するが、
  // その瞬間に UI が「やり直し」のように見えてしまうため、最大値を保持する
  int _maxProgressSeen = 0;

  Future<void> _startDownload() async {
    debugPrint('[DL Screen] _startDownload invoked');
    if (!_termsAccepted) return;

    // ★ 2.4GB を従量課金で食わせない: モバイル / その他接続なら警告ダイアログ。
    //   海外ユーザー (本アプリのターゲット) は特にデータ料金が高い (GSMA 2025)。
    final netType = await ConnectivityService.currentType();
    if (!mounted) return;
    if (netType == NetworkType.none) {
      await _showNoConnectionDialog();
      return;
    }
    if (netType != NetworkType.wifi && netType != NetworkType.ethernet) {
      final proceed = await _showMobileDataWarning(netType);
      if (proceed != true) {
        debugPrint('[DL Screen] User cancelled download due to mobile data');
        return;
      }
    }

    await _persistTermsAcceptance();

    // ★ POST_NOTIFICATIONS runtime 許可を「先に await」する。
    //   Android 13+ ではこれが無いと background_downloader の foreground
    //   service が notification を出せず → 通常 WorkManager job に降格 →
    //   裏化時に kill されて DL が 4-10% で止まる (Pixel 6a 実測)。
    //   await することでユーザーがダイアログに応答するまで DL を始めない。
    //   拒否されても DL 自体は試行するが UX としては不安定になる。
    final notifGranted =
        await NotificationService.requestPermissionIfNeeded();
    debugPrint('[DL Screen] notification permission granted: $notifGranted');
    if (!mounted) return;

    // 画面消灯防止 ON（DL 中はずっと・終了時に必ず OFF）
    try {
      await ScreenKeepOn.enable();
      debugPrint('[DL Screen] wakelock enabled');
    } catch (e) {
      debugPrint('[DL Screen] wakelock enable failed: $e');
    }

    _maxProgressSeen = 0;
    setState(() {
      _isDownloading = true;
      _hasError = false;
      _status = _l10n.downloading;
      _progress = 0;
    });

    try {
      await for (final rawProgress in ModelService.downloadModel()) {
        if (!mounted) return;
        // monotonic：一度上がった % は下げない（retry 時の一時的 0% を吸収）
        final progress = rawProgress > _maxProgressSeen
            ? rawProgress
            : _maxProgressSeen;
        if (progress > _maxProgressSeen) _maxProgressSeen = progress;
        if (rawProgress != progress) {
          debugPrint(
              '[DL Screen] suppressed regression $rawProgress% → keeping $_maxProgressSeen%');
        }
        if (progress == 0 || progress >= 100 || progress % 10 == 0) {
          debugPrint('[DL Screen] stream progress: $progress%');
        }
        setState(() => _progress = progress / 100.0);
      }
      debugPrint('[DL Screen] stream loop EXITED normally');

      if (!mounted) return;
      setState(() {
        _status = _l10n.complete;
        _isDownloading = false;
      });

      // DL 完了通知（画面消灯中でもユーザーに伝わる）
      // 行動誘導型: 単に「完了」より「タップして続ける」を強調
      NotificationService.show(
        id: NotificationService.idDownloadComplete,
        title: 'Tap to continue setup',
        body:
            'Download done. ~3 more minutes to finish. Keep app open.',
      );

      debugPrint('[DL Screen] calling widget.onComplete() → navigation');
      widget.onComplete();
    } catch (e, st) {
      debugPrint('[DL Screen] CAUGHT exception: $e');
      debugPrint('[DL Screen] type: ${e.runtimeType}\nstack: $st');
      if (!mounted) return;
      setState(() {
        _status = _friendlyError(e);
        _isDownloading = false;
        _hasError = true;
      });
    } finally {
      // wakelock OFF（成功・失敗いずれも）
      try {
        await ScreenKeepOn.disable();
        debugPrint('[DL Screen] wakelock disabled');
      } catch (_) {}
    }
  }

  void _copyUrl(String url, String label) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${_l10n.urlCopied}\n$url'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _friendlyError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('socket') ||
        s.contains('network') ||
        s.contains('host') ||
        s.contains('connection')) {
      return 'Connection failed. Check Wi-Fi.';
    }
    if (s.contains('401') ||
        s.contains('403') ||
        s.contains('unauthor') ||
        s.contains('forbidden')) {
      return 'Access denied. The Gemma model on Hugging Face requires '
          'license acceptance from a Hugging Face account.';
    }
    if (s.contains('space') ||
        s.contains('disk') ||
        s.contains('storage') ||
        s.contains('enospc')) {
      return 'Not enough storage. Free up at least 1 GB.';
    }
    if (s.contains('timeout')) {
      return 'Download timed out. Try again on a stable Wi-Fi.';
    }
    return 'Download failed. Tap retry.\n($e)';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      // ★ ボタンを画面下部に常時固定（スクロール下に隠れない）
      bottomNavigationBar: _isDownloading ? null : _stickyBottomBar(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ━━ 言語ピッカー（右上・タップで切替） ━━
              if (!_isDownloading)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _showLanguagePicker,
                    icon: const Icon(Icons.language,
                        color: Colors.white70, size: 20),
                    label: Text(
                      TermsL10n.nativeNames[_localeCode] ?? _localeCode,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: const BorderSide(
                            color: Colors.white24, width: 1),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 16),

              // ヘッダー
              const Center(
                child: Icon(Icons.medical_services,
                    color: Color(0xFF42A5F5), size: 56),
              ),
              const SizedBox(height: 16),
              // タイトル（システム言語 + 英語併記）
              Text(
                _showEnglishAlongside
                    ? '${_l10n.title}\n${TermsL10n.forLocale("en").title}'
                    : _l10n.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _l10n.subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white70, fontSize: 14, height: 1.5),
              ),
              const SizedBox(height: 24),

              // ━━ なぜこのセットアップ?（一回きり・メリット説明） ━━
              if (!_isDownloading) _whyCard(),
              if (!_isDownloading) const SizedBox(height: 16),

              // ━━ メリット一覧 ━━
              _benefitRow(Icons.wifi_off, _l10n.benefitOffline),
              _benefitRow(Icons.lock_outline, _l10n.benefitPrivacy),
              _benefitRow(Icons.payments_outlined, _l10n.benefitNoCost),
              const SizedBox(height: 24),

              // ━━ ダウンロード進捗 or 規約セクション ━━
              if (_isDownloading) ..._downloadingSection(),
              if (!_isDownloading) ..._setupSection(),

              // ステータスメッセージ
              if (_status.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _hasError
                        ? const Color(0xFFB71C1C).withValues(alpha: 0.12)
                        : Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _hasError ? Colors.redAccent : Colors.white,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ─── 「なぜセットアップが必要？」 説明カード ───────────────────
  // ユーザーフィードバック: 何のための DL かが伝わらないと不安。
  // 一回きり・メリット・端末完結を 1 カードで端的に説明。
  Widget _whyCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1B2738),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: const Color(0xFF42A5F5).withValues(alpha: 0.25), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline,
                  color: Color(0xFF42A5F5), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _l10n.whyDownloadTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _l10n.whyDownloadBody,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _benefitRow(IconData icon, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF42A5F5), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  // ─── ダウンロード前のセットアップ画面 ─────────────────────
  List<Widget> _setupSection() {
    final enL10n = TermsL10n.forLocale('en');
    return [
      // ━━ 透明性カード：何を DL するかを明示 ━━
      _modelTransparencyCard(),
      const SizedBox(height: 12),

      // ━━ Gemma 利用規約セクション ━━
      Container(
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
                const Icon(Icons.gavel_outlined,
                    color: Colors.white70, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _showEnglishAlongside
                        ? '${_l10n.termsTitle} / ${enL10n.termsTitle}'
                        : _l10n.termsTitle,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 規約本文（システム言語）
            Text(
              _l10n.termsBody,
              style: const TextStyle(
                  color: Colors.white, fontSize: 12, height: 1.5),
            ),
            // 英語併記（システム言語が英語以外の場合）
            if (_showEnglishAlongside) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  enL10n.termsBody,
                  style: const TextStyle(
                      color: Colors.white60, fontSize: 11, height: 1.5),
                ),
              ),
            ],
            const SizedBox(height: 12),
            // 規約 URL（タップでコピー）
            _urlRow(_l10n.urlTermsLabel, _gemmaTermsUrl),
            const SizedBox(height: 6),
            _urlRow(_l10n.urlPolicyLabel, _gemmaPolicyUrl),
          ],
        ),
      ),
      const SizedBox(height: 12),

      // ━━ 同意チェックボックス ━━
      InkWell(
        key: const ValueKey('agree_checkbox_row'),
        onTap: () => setState(() => _termsAccepted = !_termsAccepted),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: _termsAccepted,
                  onChanged: (v) =>
                      setState(() => _termsAccepted = v ?? false),
                  activeColor: const Color(0xFF42A5F5),
                  side:
                      const BorderSide(color: Colors.white54, width: 1.5),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _showEnglishAlongside
                      ? '${_l10n.agreeCheckbox}\n${enL10n.agreeCheckbox}'
                      : _l10n.agreeCheckbox,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13, height: 1.4),
                ),
              ),
            ],
          ),
        ),
      ),
      // ★ ボタンは _stickyBottomBar() に移動（画面下部に常時固定）
    ];
  }

  // ─── 画面下部に固定するダウンロードボタンバー ──────────────
  // スクロールしても常に表示されるため、長文の規約を読まないと
  // ボタンが見えない問題を解消
  Widget _stickyBottomBar() {
    final enL10n = TermsL10n.forLocale('en');
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        color: Color(0xFF0D1B2A),
        border: Border(top: BorderSide(color: Colors.white12, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_termsAccepted)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _l10n.checkboxRequired,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 11),
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                key: const ValueKey('download_button'),
                onPressed: _termsAccepted ? _startDownload : null,
                icon: const Icon(Icons.download, size: 22),
                label: Text(
                  _hasError
                      ? _l10n.retryButton
                      : (_showEnglishAlongside
                          ? '${_l10n.downloadButton}\n${enL10n.downloadButton}'
                          : _l10n.downloadButton),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1976D2),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.white12,
                  disabledForegroundColor: Colors.white24,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            if (kDebugMode) ...[
              const SizedBox(height: 4),
              TextButton(
                onPressed: () async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('model_download_skipped', true);
                  widget.onComplete();
                },
                child: const Text(
                  'Debug: Skip (dev only)',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ─── ダウンロード中の表示 ────────────────────────────────
  List<Widget> _downloadingSection() {
    // GB / GB 形式で単位を統一（一般ユーザー向け・MB/GB 切替で混乱しない）
    String? bytesProgress;
    if (_remoteSizeBytes != null && _remoteSizeBytes! > 0) {
      final downloaded = (_remoteSizeBytes! * _progress).round();
      bytesProgress =
          '${ModelService.formatBytesAsGB(downloaded)} / ${ModelService.formatBytesAsGB(_remoteSizeBytes)}';
    }

    return [
      const SizedBox(height: 8),
      LinearProgressIndicator(
        value: _progress,
        backgroundColor: Colors.white12,
        minHeight: 8,
        valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF42A5F5)),
      ),
      const SizedBox(height: 12),
      Text(
        '${(_progress * 100).toStringAsFixed(1)}%',
        textAlign: TextAlign.center,
        style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold),
      ),
      if (bytesProgress != null) ...[
        const SizedBox(height: 4),
        Text(
          bytesProgress,
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Colors.white70, fontSize: 13, fontFamily: 'monospace'),
        ),
      ],
      const SizedBox(height: 16),
      // ★ DL 中は foreground service が裏化耐性を持つので「別作業 OK」と伝える。
      //   Post-DL Setup の方で keep-open を強調する。
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF1976D2).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: const Color(0xFF42A5F5).withValues(alpha: 0.5), width: 1),
        ),
        child: const Column(
          children: [
            Row(
              children: [
                Icon(Icons.info_outline,
                    color: Color(0xFF42A5F5), size: 22),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'You can use other apps during download',
                    style: TextStyle(
                      color: Color(0xFF42A5F5),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 6),
            Text(
              'Download continues in the background.\n'
              'We\'ll show a notification when it\'s done.',
              textAlign: TextAlign.left,
              style: TextStyle(
                  color: Colors.white70, fontSize: 12, height: 1.5),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Text(
        _showEnglishAlongside
            ? '${_l10n.keepOpen}\n${TermsL10n.forLocale("en").keepOpen}'
            : _l10n.keepOpen,
        textAlign: TextAlign.center,
        style: const TextStyle(
            color: Colors.white60, fontSize: 12, height: 1.4),
      ),
    ];
  }

  // ─── 透明性カード：何が・どこから・どれくらいのサイズで DL されるか ──
  Widget _modelTransparencyCard() {
    final sizeText = _remoteSizeBytes != null
        ? ModelService.formatBytes(_remoteSizeBytes)
        : '~2.4 GB';
    final sizeNote = _remoteSizeBytes != null
        ? '(verified from server)'
        : '(estimate — fetching actual size...)';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF42A5F5).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: const Color(0xFF42A5F5).withValues(alpha: 0.4), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.info_outline,
                  color: Color(0xFF42A5F5), size: 18),
              SizedBox(width: 8),
              Text(
                'What will be downloaded?',
                style: TextStyle(
                    color: Color(0xFF42A5F5),
                    fontSize: 13,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _transparencyRow('Model', 'Gemma 4 E2B (int4 LiteRT-LM)'),
          _transparencyRow('Source', 'huggingface.co/litert-community'),
          _transparencyRow('License', 'Apache 2.0 (anonymous download)'),
          _transparencyRow('Size', '$sizeText  $sizeNote'),
          _transparencyRow('Stored at', 'App-private storage (auto-removed on uninstall)'),
        ],
      ),
    );
  }

  Widget _transparencyRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(label,
                style: const TextStyle(
                    color: Colors.white54, fontSize: 11)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    color: Colors.white, fontSize: 12, height: 1.4)),
          ),
        ],
      ),
    );
  }

  // ─── URL 行（タップでクリップボードにコピー） ─────────────
  Widget _urlRow(String label, String url) {
    return InkWell(
      onTap: () => _copyUrl(url, label),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          children: [
            const Icon(Icons.link,
                color: Color(0xFF42A5F5), size: 14),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '$label: $url',
                style: const TextStyle(
                    color: Color(0xFF42A5F5),
                    fontSize: 11,
                    decoration: TextDecoration.underline),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.copy, color: Colors.white38, size: 13),
          ],
        ),
      ),
    );
  }
}

// ─── 言語ピッカー（ボトムシート） ─────────────────────────
// 規約画面の表示言語を任意に切り替えるための UI
class _LanguagePickerSheet extends StatelessWidget {
  final String currentCode;
  final void Function(String) onSelect;
  const _LanguagePickerSheet({
    required this.currentCode,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final codes = TermsL10n.availableLocales();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ハンドル
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Choose language',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),
            ...codes.map((code) {
              final selected = code == currentCode;
              final native = TermsL10n.nativeNames[code] ?? code;
              final english = TermsL10n.englishNames[code] ?? code;
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => onSelect(code),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF42A5F5)
                              .withValues(alpha: 0.18)
                          : Colors.transparent,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          selected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color: selected
                              ? const Color(0xFF42A5F5)
                              : Colors.white54,
                          size: 22,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                native,
                                style: TextStyle(
                                  color: selected
                                      ? const Color(0xFF42A5F5)
                                      : Colors.white,
                                  fontSize: 16,
                                  fontWeight: selected
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                ),
                              ),
                              if (native != english)
                                Text(
                                  english,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Text(
                          code,
                          style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                              fontFamily: 'monospace'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
