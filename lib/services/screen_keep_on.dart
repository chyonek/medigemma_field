// 画面消灯防止のスタブ実装
//
// wakelock_plus パッケージが現在 Flutter plugin loader と互換性問題を起こしている
// ため、一旦 no-op 実装にしている。互換性問題が解決したら wakelock_plus に戻す。
//
// インターフェースを統一しておけば、呼出側を変更せずに実装を差し替えられる。
import 'package:flutter/foundation.dart';

class ScreenKeepOn {
  static Future<void> enable() async {
    debugPrint('[ScreenKeepOn] (stub) wakelock would be enabled');
  }

  static Future<void> disable() async {
    debugPrint('[ScreenKeepOn] (stub) wakelock would be disabled');
  }
}
