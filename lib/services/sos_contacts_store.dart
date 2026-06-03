import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/sos_contact.dart';

/// Persists up to five SOS contacts on device.
class SosContactsStore {
  SosContactsStore._();

  static const _key = 'sos_contacts_v1';
  static const maxContacts = 5;

  static Future<List<SosContact>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => SosContact.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> save(List<SosContact> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = contacts.take(maxContacts).toList();
    await prefs.setString(
      _key,
      jsonEncode(trimmed.map((c) => c.toJson()).toList()),
    );
  }
}
