import 'package:connectivity_plus/connectivity_plus.dart';

enum NetworkType {
  none,
  wifi,
  ethernet,
  mobile, // 従量課金 / データ上限の可能性あり
  other, // VPN / Bluetooth テザリング等
}

class ConnectivityService {
  static Future<bool> isOnline() async {
    final result = await Connectivity().checkConnectivity();
    return result.any((r) =>
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.ethernet);
  }

  /// 現在の接続タイプを返す。複数同時 (Wi-Fi + mobile) なら Wi-Fi 優先。
  /// 2.4GB の Gemma モデル DL 前にモバイルデータ警告を出すため。
  static Future<NetworkType> currentType() async {
    final results = await Connectivity().checkConnectivity();
    if (results.contains(ConnectivityResult.wifi)) return NetworkType.wifi;
    if (results.contains(ConnectivityResult.ethernet)) {
      return NetworkType.ethernet;
    }
    if (results.contains(ConnectivityResult.mobile)) return NetworkType.mobile;
    if (results.any((r) => r != ConnectivityResult.none)) {
      return NetworkType.other;
    }
    return NetworkType.none;
  }
}
