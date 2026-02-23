import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// On-device storage service — no sign-in required.
class LocalStorageService {
  static const _profileKey = 'user_profile';
  static Database? _db;

  // ── Database ──────────────────────────────────────────────────────────────

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'physioai.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE exercises (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            type     TEXT NOT NULL,
            score    REAL NOT NULL,
            metadata TEXT,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE daily_checkins (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            data     TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
      },
    );
  }

  // ── User Profile (SharedPreferences) ─────────────────────────────────────

  Future<void> saveUserProfile(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = await getUserProfile() ?? {};
      existing.addAll(data);
      await prefs.setString(_profileKey, jsonEncode(existing));
    } catch (e) {
      debugPrint('saveUserProfile error: $e');
    }
  }

  Future<Map<String, dynamic>?> getUserProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_profileKey);
      if (raw == null) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('getUserProfile error: $e');
      return null;
    }
  }

  Future<String?> getUserName() async {
    final profile = await getUserProfile();
    return profile?['fullName'] as String?;
  }

  // ── Exercise Progress ─────────────────────────────────────────────────────

  Future<void> saveExerciseProgress({
    required String exerciseType,
    required double score,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final db = await database;
      await db.insert('exercises', {
        'type': exerciseType,
        'score': score,
        'metadata': jsonEncode(metadata ?? {}),
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('saveExerciseProgress error: $e');
    }
  }

  /// Returns all exercise records, newest first.
  Future<List<Map<String, dynamic>>> getExerciseHistory() async {
    try {
      final db = await database;
      final rows = await db.query('exercises', orderBy: 'created_at DESC');
      return rows.map((row) {
        final decoded = Map<String, dynamic>.from(row);
        decoded['metadata'] = jsonDecode(row['metadata'] as String? ?? '{}');
        return decoded;
      }).toList();
    } catch (e) {
      debugPrint('getExerciseHistory error: $e');
      return [];
    }
  }

  /// Stream-like getter: returns a Future of the last [limit] entries.
  Future<List<Map<String, dynamic>>> getRecentProgress({int limit = 7}) async {
    try {
      final db = await database;
      final rows = await db.query(
        'exercises',
        orderBy: 'created_at DESC',
        limit: limit,
      );
      return rows.map((row) {
        final decoded = Map<String, dynamic>.from(row);
        decoded['metadata'] = jsonDecode(row['metadata'] as String? ?? '{}');
        return decoded;
      }).toList();
    } catch (e) {
      debugPrint('getRecentProgress error: $e');
      return [];
    }
  }

  Future<double> getOverallProgress() async {
    try {
      final db = await database;
      final rows = await db.query('exercises', columns: ['score']);
      if (rows.isEmpty) return 0.0;
      final total = rows.fold<double>(
        0.0,
        (sum, row) => sum + (row['score'] as num).toDouble(),
      );
      return total / rows.length;
    } catch (e) {
      debugPrint('getOverallProgress error: $e');
      return 0.0;
    }
  }

  Future<Map<String, double>> getProgressByExerciseType() async {
    try {
      final db = await database;
      final rows = await db.query('exercises', columns: ['type', 'score']);
      final Map<String, List<double>> buckets = {};
      for (final row in rows) {
        final type = row['type'] as String;
        final score = (row['score'] as num).toDouble();
        buckets.putIfAbsent(type, () => []).add(score);
      }
      return buckets.map(
        (key, values) =>
            MapEntry(key, values.reduce((a, b) => a + b) / values.length),
      );
    } catch (e) {
      debugPrint('getProgressByExerciseType error: $e');
      return {};
    }
  }

  // ── Daily Check-ins ───────────────────────────────────────────────────────

  Future<void> saveDailyCheckIn(Map<String, dynamic> data) async {
    try {
      final db = await database;
      await db.insert('daily_checkins', {
        'data': jsonEncode(data),
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('saveDailyCheckIn error: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getCheckInHistory() async {
    try {
      final db = await database;
      final rows = await db.query('daily_checkins', orderBy: 'created_at DESC');
      return rows.map((row) {
        return jsonDecode(row['data'] as String) as Map<String, dynamic>;
      }).toList();
    } catch (e) {
      debugPrint('getCheckInHistory error: $e');
      return [];
    }
  }

  // ── Utility ───────────────────────────────────────────────────────────────

  Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_profileKey);
      final db = await database;
      await db.delete('exercises');
      await db.delete('daily_checkins');
    } catch (e) {
      debugPrint('clearAll error: $e');
    }
  }
}
