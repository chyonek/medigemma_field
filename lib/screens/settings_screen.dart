import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/terms_translations.dart';
import '../services/gemma_service.dart';
import '../services/model_service.dart';
import '../services/translation_service.dart';
import 'model_download_screen.dart';

/// 設定画面：AI モデルの透明な管理（Chrome AI 問題への対策・GDPR 対応）
///
/// 表示内容：
///  - モデル状態（DL済/未DL）
///  - ファイルサイズ
///  - 保存場所の説明（アプリ専用領域・自動削除）
///  - ダウンロード日時
///  - プライバシー保証宣言
///  - 削除ボタン
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ModelInfo? _info;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    setState(() => _isLoading = true);
    final info = await ModelService.loadModelInfo();
    if (!mounted) return;
    setState(() {
      _info = info;
      _isLoading = false;
    });
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A2E45),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                color: Colors.redAccent, size: 24),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'AIモデルを削除？\nDelete AI model?',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ),
          ],
        ),
        content: const Text(
          '削除すると、次にアプリを使うときに Gemma 4 E2B（約 2.4 GB）の再ダウンロードが必要になります（Wi-Fi 推奨）。\n\n'
          'If deleted, the Gemma 4 E2B model (~2.4 GB) will need to be re-downloaded next time (Wi-Fi recommended).',
          style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル / Cancel',
                style: TextStyle(color: Colors.white60)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除する / Delete',
                style: TextStyle(
                    color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // 永続化されたオフラインモデルもメモリから解放
    await GemmaService.disposeOfflineModel();
    await ModelService.deleteModel();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('AIモデルを削除しました / AI model deleted'),
        backgroundColor: Color(0xFF66BB6A),
      ),
    );
    await _loadInfo();
  }

  Future<void> _redownload() async {
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => ModelDownloadScreen(
          onComplete: () => navigator.pop(),
        ),
      ),
    );
    _loadInfo();
  }

  void _copyPath(String path) {
    Clipboard.setData(ClipboardData(text: path));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('パスをコピー / Path copied:\n$path'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1B2A),
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Settings / 設定',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white))
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _languageCard(),
                    const SizedBox(height: 16),
                    _modelStatusCard(),
                    const SizedBox(height: 16),
                    _privacyCard(),
                    const SizedBox(height: 16),
                    _gdprCard(),
                    const SizedBox(height: 24),
                    _actionButtons(),
                    const SizedBox(height: 24),
                    _aboutCard(),
                  ],
                ),
              ),
            ),
    );
  }

  // ─── 言語カード（規約画面と同じ 10 言語ピッカーを再利用） ───
  // モデル DL 後の動的翻訳の対象言語をここで切替
  Widget _languageCard() {
    final t = TranslationService.instance;
    final currentNative =
        TermsL10n.nativeNames[t.currentLocale.split('-').first] ??
            t.currentLocale;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2E45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: const Color(0xFF42A5F5).withValues(alpha: 0.4),
            width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.language, color: Color(0xFF42A5F5), size: 22),
              SizedBox(width: 10),
              Text(
                'Language / 言語',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Current / 現在',
                        style: TextStyle(
                            color: Colors.white54, fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(currentNative,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _showLanguagePicker,
                icon:
                    const Icon(Icons.swap_horiz, color: Colors.white, size: 18),
                label: const Text('Change / 切替',
                    style: TextStyle(color: Colors.white, fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white24, width: 1.2),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'By default the app uses your phone\'s system language. '
            'Tap "Change" to switch to a different language at any time.\n'
            '通常はスマホの設定言語を自動で使います。'
            '別の言語に切り替えたいときは「切替」を押してください。\n\n'
            'Changing language re-translates the UI via Gemma 4 '
            '(may take a few minutes first time per language).\n'
            '言語切替後、UI を Gemma 4 で再翻訳します'
            '（言語ごとに初回のみ数分かかります）。',
            style:
                TextStyle(color: Colors.white54, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
  }

  Future<void> _showLanguagePicker() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1A2E45),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final codes = TermsL10n.availableLocales();
        final currentCode =
            TranslationService.instance.currentLocale.split('-').first;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Choose language / 言語を選択',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ...codes.map((code) {
                  final selected = code == currentCode;
                  final native = TermsL10n.nativeNames[code] ?? code;
                  final english = TermsL10n.englishNames[code] ?? code;
                  return InkWell(
                    onTap: () => Navigator.pop(ctx, code),
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
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(native,
                                    style: TextStyle(
                                        color: selected
                                            ? const Color(0xFF42A5F5)
                                            : Colors.white,
                                        fontSize: 16,
                                        fontWeight: selected
                                            ? FontWeight.bold
                                            : FontWeight.w500)),
                                if (native != english)
                                  Text(english,
                                      style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 12)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );

    if (selected == null || !mounted) return;
    // 規約画面と同じ override を保存
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('terms_locale_override', selected);
    // 翻訳サービスに反映
    await TranslationService.instance.setLocale(selected);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF1565C0),
        duration: const Duration(seconds: 3),
        content: Text(
          'Language changed to ${TermsL10n.nativeNames[selected]} / 言語を変更しました',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }

  // ─── モデル状態カード ─────────────────────────────────
  Widget _modelStatusCard() {
    final info = _info!;
    final isDownloaded = info.isDownloaded;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2E45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDownloaded
              ? const Color(0xFF66BB6A)
              : const Color(0xFFE65100),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isDownloaded ? Icons.check_circle : Icons.warning_amber_rounded,
                color: isDownloaded
                    ? const Color(0xFF66BB6A)
                    : const Color(0xFFE65100),
                size: 24,
              ),
              const SizedBox(width: 10),
              Text(
                isDownloaded
                    ? 'AIモデル：DL済み / Downloaded'
                    : 'AIモデル：未DL / Not downloaded',
                style: TextStyle(
                  color: isDownloaded
                      ? const Color(0xFF66BB6A)
                      : const Color(0xFFE65100),
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          if (isDownloaded) ...[
            const SizedBox(height: 14),
            _infoRow(Icons.storage,
                'サイズ / Size', info.sizeFormatted),
            _infoRow(
                Icons.folder_outlined, '保存場所 / Storage', info.storageDescription),
            if (info.filePath != null)
              _pathRow(info.filePath!),
            if (info.downloadedAt != null)
              _infoRow(
                Icons.calendar_today_outlined,
                'ダウンロード日時 / Downloaded',
                _formatDate(info.downloadedAt!),
              ),
          ] else ...[
            const SizedBox(height: 8),
            const Text(
              'アプリを使うにはダウンロードが必要です。\n'
              'You need to download the AI model to use this app.',
              style: TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.white54, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11)),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pathRow(String path) {
    return InkWell(
      onTap: () => _copyPath(path),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.code, color: Colors.white54, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ファイルパス / Path  📋',
                      style: TextStyle(
                          color: Colors.white54, fontSize: 11)),
                  const SizedBox(height: 2),
                  Text(
                    path,
                    style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 11,
                        fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  // ─── プライバシー保証カード ─────────────────────────
  Widget _privacyCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF66BB6A).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: const Color(0xFF66BB6A).withValues(alpha: 0.6),
            width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.shield_outlined,
                  color: Color(0xFF66BB6A), size: 22),
              SizedBox(width: 8),
              Text(
                'プライバシー保証 / Privacy guarantee',
                style: TextStyle(
                    color: Color(0xFF66BB6A),
                    fontSize: 15,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _privacyItem('医療データはこの端末の外に出ません'),
          _privacyItem('No medical data leaves this device'),
          const SizedBox(height: 4),
          _privacyItem('AI推論はすべて端末内で実行'),
          _privacyItem('All AI inference runs on-device'),
          const SizedBox(height: 4),
          _privacyItem('外部サーバー・クラウドへの送信ゼロ'),
          _privacyItem('Zero transmission to external servers / cloud'),
          const SizedBox(height: 4),
          _privacyItem('アプリ削除でモデルも自動削除'),
          _privacyItem('Model auto-deleted when app is uninstalled'),
        ],
      ),
    );
  }

  Widget _privacyItem(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check, color: Color(0xFF66BB6A), size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                  color: Colors.white, fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  // ─── GDPR カード ──────────────────────────────────────
  Widget _gdprCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.gavel_outlined,
                  color: Colors.white70, size: 18),
              SizedBox(width: 8),
              Text(
                'GDPR Article 17 — 削除権 / Right to erasure',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'EU GDPR 第17条「削除権」に基づき、ユーザーはいつでも AI モデルを削除できます。'
            '医療データはそもそも端末外に送信されないため、サーバー側で削除すべき個人データは存在しません。\n\n'
            'Per GDPR Article 17, users may delete the AI model at any time. '
            'Medical data never leaves this device, so there is no server-side personal data to erase.',
            style: TextStyle(
                color: Colors.white70, fontSize: 11, height: 1.5),
          ),
        ],
      ),
    );
  }

  // ─── アクションボタン ───────────────────────────────
  Widget _actionButtons() {
    final isDownloaded = _info?.isDownloaded ?? false;
    return Column(
      children: [
        if (isDownloaded)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _confirmDelete,
              icon: const Icon(Icons.delete_outline),
              label: const Text(
                'AIモデルを削除 / Delete AI model',
                style: TextStyle(fontSize: 14),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
                side: const BorderSide(
                    color: Colors.redAccent, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          )
        else
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _redownload,
              icon: const Icon(Icons.download),
              label: const Text(
                'AIモデルをダウンロード / Download AI model',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1976D2),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
      ],
    );
  }

  // ─── About カード ──────────────────────────────────
  Widget _aboutCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'MediGemma Field',
            style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 4),
          Text(
            'Frontier healthcare for those beyond the frontier',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
          SizedBox(height: 8),
          Text(
            '本アプリは Google の Gemma モデルを使用しています。\n'
            'Powered by Google\'s Gemma model.',
            style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }
}
