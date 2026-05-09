import 'package:flutter/foundation.dart';

/// ローカル通知サービス（スタブ実装）
///
/// flutter_local_notifications パッケージが Flutter plugin loader と互換性問題が
/// あったため、ハッカソン提出までは画面消灯防止（wakelock）のみで対応する。
/// インターフェースは残してあるので、後日 awesome_notifications 等の代替パッケージで
/// 簡単に差し替え可能。
///
/// 現在の代替挙動：debugPrint で「通知が出るはずだった」内容をログに残すだけ。
class NotificationService {
  // 通知 ID 定数（呼出側が参照するため）
  static const idDownloadComplete = 1001;
  static const idSetupComplete = 1002;

  static Future<void> initialize() async {
    debugPrint('[NotificationService] stub mode (no actual notifications)');
  }

  static Future<bool> requestPermissionIfNeeded() async {
    return false;
  }

  static Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    debugPrint('[NotificationService] (stub) would show: $title - $body');
  }

  static Future<void> cancelAll() async {}
}
