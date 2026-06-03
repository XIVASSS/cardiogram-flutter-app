import 'dart:ui' as ui;

import 'package:url_launcher/url_launcher.dart';

/// Maps locale to the primary public emergency number.
class EmergencyDialer {
  EmergencyDialer._();

  static String emergencyNumberForLocale([ui.Locale? locale]) {
    final country = (locale ?? ui.PlatformDispatcher.instance.locale)
        .countryCode
        ?.toUpperCase();
    return switch (country) {
      'GB' || 'UK' => '999',
      'AU' => '000',
      'NZ' => '111',
      'IN' => '112',
      'DE' || 'FR' || 'IT' || 'ES' => '112',
      _ => '911',
    };
  }

  static String emergencyLabel(String number) => switch (number) {
        '999' => 'Emergency services (999)',
        '112' => 'Emergency services (112)',
        '000' => 'Emergency services (000)',
        '111' => 'Emergency services (111)',
        _ => 'Emergency services (911)',
      };

  static Future<bool> call(String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (digits.isEmpty) return false;
    final uri = Uri(scheme: 'tel', path: digits);
    if (!await canLaunchUrl(uri)) return false;
    return launchUrl(uri);
  }

  static Future<bool> sms({
    required List<String> phones,
    required String body,
  }) async {
    final cleaned = phones
        .map((p) => p.replaceAll(RegExp(r'[^\d+]'), ''))
        .where((p) => p.isNotEmpty);
    if (cleaned.isEmpty) return false;
    final uri = Uri(
      scheme: 'sms',
      path: cleaned.join(','),
      queryParameters: body.isNotEmpty ? {'body': body} : null,
    );
    if (!await canLaunchUrl(uri)) return false;
    return launchUrl(uri);
  }

  static Future<bool> openMaps(double lat, double lon, {String? label}) async {
    final q = label != null && label.isNotEmpty
        ? Uri.encodeComponent(label)
        : '$lat,$lon';
    final uri = Uri.parse('https://maps.apple.com/?q=$q&ll=$lat,$lon');
    if (await canLaunchUrl(uri)) {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    final google = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$lat,$lon',
    );
    if (!await canLaunchUrl(google)) return false;
    return launchUrl(google, mode: LaunchMode.externalApplication);
  }
}
