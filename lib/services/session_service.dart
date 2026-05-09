import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'gemma_service.dart';

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
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago / ${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours} h ago / ${diff.inHours}時間前';
    return '${diff.inDays} days ago / ${diff.inDays}日前';
  }
}
