// 画面消灯防止 — モデル DL 中 (~2.4GB / 数分) のジョブ kill 回避用
//
// 背景: Android は app.visibility=false になると WorkManager の DL job を
// 「重要ではない」と判断して kill する (本ログで JobCancellationException 確認)。
// → DL 中は wakelock を取って画面を ON で保つ。
// → DL 完了 / Setup 完了で必ず disable する (バッテリー保護)。
//
// 注: foreground service を使う方法もあるが、background_downloader 側に
// foreground 通知の制御があるため、ここでは画面 ON にすれば十分という判断。

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class ScreenKeepOn {
  static Future<void> enable() async {
    try {
      await WakelockPlus.enable();
      debugPrint('[ScreenKeepOn] wakelock enabled');
    } catch (e) {
      debugPrint('[ScreenKeepOn] enable failed: $e');
    }
  }

  static Future<void> disable() async {
    try {
      await WakelockPlus.disable();
      debugPrint('[ScreenKeepOn] wakelock disabled');
    } catch (e) {
      debugPrint('[ScreenKeepOn] disable failed: $e');
    }
  }
}
