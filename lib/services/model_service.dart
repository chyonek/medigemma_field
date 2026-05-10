import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Gemma 4 E2B モデル設定 ──────────────────────────────────
//
// 2026-05-09 完全オフライン Gemma 4 採用：
// - litert-community/gemma-4-E2B-it-litert-lm（Apache 2.0・公開）
// - 匿名 DL 可能（HF トークン不要・2026-05-09 検証済み）
// - .litertlm 形式（旧 .task 廃止）
// - ファイルサイズ：約 2.4 GB（int4 量子化）
// - flutter_gemma 0.15.0 の installModel ビルダー API を使用

const _modelUrl =
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';

// モデル ID（FileNameUtils.getBaseName で拡張子除去後の名前）
const _modelId = 'gemma-4-E2B-it';
const _modelFilename = 'gemma-4-E2B-it.litertlm';

const _downloadDateKey = 'model_downloaded_at';

/// モデル情報（Settings 画面で表示）
class ModelInfo {
  final bool isDownloaded;
  final int? sizeBytes;
  final String? filePath;
  final DateTime? downloadedAt;

  const ModelInfo({
    required this.isDownloaded,
    this.sizeBytes,
    this.filePath,
    this.downloadedAt,
  });

  /// ファイルサイズを人間可読な形式に（678 MB / 1.2 GB 等）
  String get sizeFormatted {
    if (sizeBytes == null) return '—';
    final bytes = sizeBytes!;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// パスを「ユーザーが理解できる形式」に
  String get storageDescription {
    if (filePath == null) return '—';
    return 'App-private storage / アプリ専用領域\n(自動削除：アプリのアンインストール時)';
  }

  /// モデル名（Settings 画面で「使用中のモデル」を見せたい時用）
  String get modelName => 'Gemma 4 E2B (int4 LiteRT-LM)';
}

class ModelService {
  /// モデルがダウンロード済みか
  /// 0.15.0: FlutterGemma.hasActiveModel() で active inference model 有無を判定
  ///
  /// ⚠️ アプリ再起動時、ファイルは存在するが active 状態が消えていることがある。
  /// その場合 `isModelInstalled()` で disk 上のファイル存在を確認し、
  /// 自動的に再 activate (installModel = no-op + setActive) する。
  /// → 再起動時に DL 画面に戻る UX 不具合を防ぐ。
  static Future<bool> isModelDownloaded() async {
    if (FlutterGemma.hasActiveModel()) return true;

    // active で無いが、ファイルが install 済みなら再 activate を試みる
    try {
      final installed = await FlutterGemma.isModelInstalled(_modelFilename);
      if (!installed) return false;

      debugPrint(
          '[ModelService] Model file exists but inactive — re-activating...');
      // 再 activate は no-op (ファイル存在検出後の active 化のみ) なので
      // foreground 指定は不要だが、明示的に false を渡して挙動を統一。
      await FlutterGemma.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      ).fromNetwork(_modelUrl, foreground: false).install();
      debugPrint('[ModelService] Re-activation complete');
      return FlutterGemma.hasActiveModel();
    } catch (e) {
      debugPrint('[ModelService] Re-activation failed: $e');
      return false;
    }
  }

  /// HuggingFace のサーバー側ファイルサイズを HEAD リクエストで取得（バイト単位）
  /// 取得失敗時は null を返す（呼び出し側でフォールバック表示）
  ///
  /// HEAD リクエストはペイロードを送らない軽量な確認用 HTTP メソッド。
  /// 通信コストはほぼゼロだが、オフライン時は失敗する。
  static Future<int?> fetchRemoteModelSizeBytes() async {
    try {
      final client = HttpClient();
      // 30 秒タイムアウト（モバイル回線が遅くてもこれくらいで応答が来るはず）
      client.connectionTimeout = const Duration(seconds: 30);
      try {
        final req = await client.openUrl('HEAD', Uri.parse(_modelUrl));
        // HuggingFace は HEAD でも 302 リダイレクトすることがある
        req.followRedirects = true;
        req.maxRedirects = 5;
        final resp = await req.close().timeout(const Duration(seconds: 30));
        final size = resp.contentLength;
        // dart:io の HttpClient は一部の Cloudfront レスポンスで -1 を返すことがある
        if (size <= 0) {
          debugPrint(
              '[ModelService.fetchRemoteModelSizeBytes] WARN: contentLength is $size');
          return null;
        }
        debugPrint(
            '[ModelService.fetchRemoteModelSizeBytes] $size bytes (~${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB)');
        return size;
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      debugPrint('[ModelService.fetchRemoteModelSizeBytes] failed: $e');
      return null;
    }
  }

  /// バイト数を人間可読形式に整形
  /// 例: 2580000000 → "2.40 GB"
  static String formatBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return '—';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// バイト数を GB 単位で必ず表示（進捗表示用・分子分母の単位を揃える）
  /// 例: 1000000 → "0.00 GB"、 2580000000 → "2.40 GB"
  static String formatBytesAsGB(int? bytes) {
    if (bytes == null || bytes <= 0) return '0.00 GB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// モデルの詳細情報を取得（Settings 画面用）
  /// 0.15.0: getStorageInfo で全体ストレージ情報を取得
  static Future<ModelInfo> loadModelInfo() async {
    final isDownloaded = await isModelDownloaded();
    if (!isDownloaded) {
      return const ModelInfo(isDownloaded: false);
    }

    int? sizeBytes;
    try {
      // flutter_gemma の管理しているストレージ統計から合計サイズ取得
      final stats =
          await FlutterGemmaPlugin.instance.modelManager.getStorageInfo();
      sizeBytes = stats.totalSizeBytes;
    } catch (e) {
      debugPrint('[ModelService.loadModelInfo] storage info failed: $e');
    }

    DateTime? downloadedAt;
    try {
      final prefs = await SharedPreferences.getInstance();
      final ts = prefs.getInt(_downloadDateKey);
      if (ts != null) {
        downloadedAt = DateTime.fromMillisecondsSinceEpoch(ts);
      }
    } catch (_) {}

    return ModelInfo(
      isDownloaded: true,
      sizeBytes: sizeBytes,
      // 0.15.0 では具体的なファイルパスは内部管理のため抽象表記のみ
      filePath: 'app-private/$_modelFilename',
      downloadedAt: downloadedAt,
    );
  }

  /// ダウンロード進捗を Stream で返す（0〜100 の整数）
  /// 0.15.0: installModel ビルダー API を使用
  /// HF トークン不要（Gemma 4 は Apache 2.0 ・匿名 DL 可能）
  static Stream<int> downloadModel() {
    debugPrint('[ModelService.downloadModel] called — creating controller');
    // broadcast にして単一購読制限を回避（万一 await for が二重に走っても安全）
    final controller = StreamController<int>.broadcast();
    int lastProgress = 0;
    int progressEmits = 0;

    Future<void> runInstall() async {
      debugPrint('[ModelService.downloadModel] runInstall: starting install()');
      try {
        // ★ Android 13+ で foreground service を確実に起動するための通知設定。
        //   SmartDownloader は runInForeground=Config.always を設定するだけで、
        //   肝心の TaskNotificationConfig を登録していない。
        //   通知設定がないと Android JobScheduler は foreground service として
        //   起動せず、通常 WorkManager job に降格 → 裏化時に kill される
        //   (Pixel 6a で 6-10% 付近で再現・2026-05-11)。
        //   FileDownloader は singleton なので、ここで直接 configureNotification()
        //   を呼べば SmartDownloader 内部の DL タスクもこの通知を使う。
        FileDownloader().configureNotification(
          running: const TaskNotification(
            'Downloading AI model',
            'Tap to return to MediGemma · keep app open',
          ),
          complete: const TaskNotification(
            'Download complete — tap to continue setup',
            'AI setup will take ~3 more minutes. Keep app open.',
          ),
          error: const TaskNotification(
            'Download failed',
            'Tap to retry.',
          ),
          progressBar: true,
        );
        debugPrint(
            '[ModelService.downloadModel] notification config registered for foreground service');

        // ★ foreground: true を明示。
        //   AUTO モード (file size >500MB で auto foreground) では実際の DL 開始
        //   タイミングと foreground service 昇格にラグがあり、起動直後に Activity
        //   が裏化すると WorkManager job が kill される (Pixel 6a で 10% 付近で
        //   発生確認・2026-05-11)。
        //   2.4GB の DL は確実に foreground 必須なので AUTO に頼らず明示する。
        //   AndroidManifest.xml の FOREGROUND_SERVICE / FOREGROUND_SERVICE_DATA_SYNC
        //   権限と組み合わせて常時 foreground 通知を維持し、
        //   バックグラウンド化・スリープ中も DL 継続。
        await FlutterGemma.installModel(
          modelType: ModelType.gemma4,
          fileType: ModelFileType.litertlm,
        )
            .fromNetwork(_modelUrl, foreground: true)
            .withProgress((p) {
          lastProgress = p;
          progressEmits++;
          if (!controller.isClosed) controller.add(p);
        }).install();
        debugPrint(
            '[ModelService.downloadModel] install() resolved successfully (lastProgress=$lastProgress, emits=$progressEmits)');

        // ダウンロード完了タイムスタンプ保存
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt(
              _downloadDateKey, DateTime.now().millisecondsSinceEpoch);
          debugPrint(
              '[ModelService.downloadModel] timestamp saved to SharedPreferences');
        } catch (e, st) {
          debugPrint(
              '[ModelService.downloadModel] WARN: timestamp save failed: $e\n$st');
          // 失敗してもクリティカルでないので継続
        }

        // 100% 未到達の場合のみ 100 を流す（重複発火を避ける）
        if (!controller.isClosed && lastProgress < 100) {
          debugPrint(
              '[ModelService.downloadModel] forcing final 100% emit (was $lastProgress)');
          controller.add(100);
        }
        debugPrint(
            '[ModelService.downloadModel] success — about to close stream');
      } catch (e, st) {
        debugPrint('[ModelService.downloadModel] ERROR caught: $e');
        debugPrint(
            '[ModelService.downloadModel] error type: ${e.runtimeType}');
        debugPrint('[ModelService.downloadModel] stack: $st');
        if (!controller.isClosed) controller.addError(e, st);
      } finally {
        if (!controller.isClosed) {
          await controller.close();
          debugPrint('[ModelService.downloadModel] stream closed');
        }
      }
    }

    // unawaited 起動。ストリームは即座に返す。
    runInstall();

    return controller.stream;
  }

  /// モデルを削除（GDPR Article 17 削除権対応）
  /// 0.15.0: FlutterGemma.uninstallModel(modelId) を使用
  static Future<void> deleteModel() async {
    try {
      await FlutterGemma.uninstallModel(_modelFilename);
    } catch (e) {
      // モデルが見つからない等のエラーは無視（既に削除されている可能性）
      debugPrint('[ModelService.deleteModel] uninstall warning: $e');
    }

    // 関連メタデータも削除
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_downloadDateKey);
    // 翻訳キャッシュもクリア（モデル無しでは AI 翻訳できないため）
    final keys = prefs.getKeys().where((k) =>
        k.startsWith('ui_translations_') ||
        k.startsWith('model_download_skipped'));
    for (final k in keys) {
      await prefs.remove(k);
    }
  }
}

