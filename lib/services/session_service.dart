import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'gemma_service.dart';

// ─── 医療セッション履歴の保存 ─────────────────────────────────
//
// at-rest 暗号化は Android File-Based Encryption (FBE) に委譲。
// Android 7+ では app-private storage (SharedPreferences の保存先含む)
// が端末の hardware-backed Keystore key で自動暗号化されており、
// 端末をロックしている限り別アプリ・root 化していない adb backup から
// 読めない。さらに本アプリは:
//   - android:allowBackup="false"        (Google Drive 同期防止)
//   - data_extraction_rules で D2D 拒否  (機種変更時転送防止)
//   - アンインストール時に自動削除 (GDPR Art.17)
// により at-rest 露出面を最小化している。
//
// 当初 flutter_secure_storage で application-level の二重暗号化を
// 計画したが、wakelock_plus との依存衝突で kernel_snapshot ビルド
// エラーが発生したため defer (security_plan.md に記録)。

class SavedResult {
  final TriageResult result;
  final DateTime timestamp;
  const SavedResult({required this.result, required this.timestamp});
}

class SessionService {
  static const _key = 'last_triage_result';

  /// トリアージ結果を保存（結果画面表示時に自動呼び出し）
  static Future<void> saveResult(TriageResult result) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        'level': result.level,
        'summary': result.summary,
        'action': result.action,
        'possibleConditions': result.possibleConditions,
        'details': result.details,
        'languageCode': result.languageCode,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  /// 前回の結果を読み込む（ホーム画面で使用）
  static Future<SavedResult?> loadLastResult() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_key);
    if (data == null) return null;
    try {
      final map = jsonDecode(data) as Map<String, dynamic>;
      return SavedResult(
        result: TriageResult(
          level: map['level'] as int,
          summary: (map['summary'] as String?) ?? '',
          action: map['action'] as String,
          possibleConditions: (map['possibleConditions'] as String?) ?? '',
          details: map['details'] as String,
          rawResponse: '',
          languageCode: (map['languageCode'] as String?) ?? 'en-US',
        ),
        timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      );
    } catch (_) {
      return null;
    }
  }

  /// セッション終了時に消去
  static Future<void> clearResult() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  /// 経過時間の表示文字列
  static String timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now / たった今';
    if (diff.inMinutes < 60) {
      return '${diff.inMinutes} min ago / ${diff.inMinutes}分前';
    }
    if (diff.inHours < 24) {
      return '${diff.inHours} h ago / ${diff.inHours}時間前';
    }
    return '${diff.inDays} days ago / ${diff.inDays}日前';
  }
}
