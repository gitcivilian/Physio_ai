import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local authentication service.
/// Email/password only, stored locally.
class LocalAuthService {
  static const _usersKey = 'local_auth_users';
  static const _currentUserKey = 'local_auth_current_user';

  String _hash(String password) {
    final bytes = utf8.encode(password);
    return sha256.convert(bytes).toString();
  }

  Future<Map<String, String>> _getUsers() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_usersKey);
    if (json == null) return {};
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveUsers(Map<String, String> users) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_usersKey, jsonEncode(users));
  }

  Future<void> signUp({
    required String email,
    required String password,
    String? fullName,
  }) async {
    final key = email.trim().toLowerCase();
    final users = await _getUsers();
    if (users.containsKey(key)) throw Exception('Email is already registered');
    users[key] = jsonEncode({
      'hash': _hash(password),
      'fullName': fullName?.trim() ?? '',
    });
    await _saveUsers(users);
  }

  Future<void> signIn({required String email, required String password}) async {
    final key = email.trim().toLowerCase();
    final users = await _getUsers();
    final data = users[key];
    if (data == null) throw Exception('No user found with this email');
    final map = jsonDecode(data) as Map<String, dynamic>;
    if ((map['hash'] as String?) != _hash(password)) {
      throw Exception('Incorrect password');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_currentUserKey, key);
  }

  Future<void> signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_currentUserKey);
  }

  Future<String?> get currentUserEmail async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_currentUserKey);
  }
}
