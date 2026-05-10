import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 通知サービス (LINE 風 heads-up / lock-screen 対応)
///
/// 2026-05-11 実装切替:
/// flutter_local_notifications の plugin loader 問題を回避するため、
/// MethodChannel 経由で MainActivity.kt のネイティブ実装を呼ぶ。
/// IMPORTANCE_HIGH + VISIBILITY_PUBLIC で：
///   - 画面 ON → 上から heads-up でポップ
///   - 画面 OFF → 振動 + 通知音 + ロック画面に全文表示
///   - タップ → MainActivity に戻る
///   - AutoCancel (タップで消える)
///
/// 主な用途:
///   - DL 完了 → 「タップしてセットアップを続ける」
///   - Setup 完了 → 「使用準備完了。タップで開始」
///
/// POST_NOTIFICATIONS 許可は MainActivity.onCreate で先取りリクエスト済。
/// ユーザーが拒否した場合は native 側で silently skip (例外を投げない)。
class NotificationService {
  // Dart ↔ Native の MethodChannel 名 (MainActivity.kt と一致させる)
  static const _channel = MethodChannel('medigemma.notifications');

  // 通知 ID 定数 (各画面で一貫した ID を使う)
  static const idDownloadComplete = 1001;
  static const idSetupComplete = 1002;

  static Future<void> initialize() async {
    debugPrint(
        '[NotificationService] init (native MethodChannel)');
  }

  /// 後方互換のためのスタブ。許可リクエスト自体は MainActivity.onCreate で済んでいる。
  static Future<bool> requestPermissionIfNeeded() async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('isPermissionGranted') ?? false;
      return granted;
    } catch (e) {
      debugPrint('[NotificationService] permission check failed: $e');
      return false;
    }
  }

  /// 通知を表示する (LINE 風 heads-up + lock screen)
  /// id を同じにすると上書き (重複しない)。
  static Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    debugPrint('[NotificationService] show: id=$id "$title"');
    try {
      await _channel.invokeMethod('show', {
        'id': id,
        'title': title,
        'body': body,
      });
    } catch (e) {
      // 許可なし・チャンネル未初期化等の例外は flow を止めない
      debugPrint('[NotificationService] show failed: $e');
    }
  }

  /// 特定 ID の通知をキャンセル
  static Future<void> cancel(int id) async {
    try {
      await _channel.invokeMethod('cancel', {'id': id});
    } catch (e) {
      debugPrint('[NotificationService] cancel failed: $e');
    }
  }

  /// 全通知をキャンセル
  static Future<void> cancelAll() async {
    try {
      await _channel.invokeMethod('cancelAll');
    } catch (e) {
      debugPrint('[NotificationService] cancelAll failed: $e');
    }
  }
}
