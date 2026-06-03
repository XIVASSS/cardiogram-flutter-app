import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../models/care_facility.dart';

/// Finds hospitals and clinics near the user via OpenStreetMap (Overpass).
class NearbyFacilitiesService {
  NearbyFacilitiesService._();

  static const _radiusMeters = 12000;

  static Future<Position> currentPosition() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      throw const NearbyException(
        'Turn on Location Services to find care nearby.',
      );
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const NearbyException(
        'Location permission is required for Nearby me.',
      );
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 12),
      ),
    );
  }

  /// Uses GPS when available; falls back to last known or a demo point (simulator).
  static Future<Position> currentPositionOrFallback() async {
    try {
      return await currentPosition();
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return last;
      return Position(
        latitude: 37.7749,
        longitude: -122.4194,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
    }
  }

  static Future<List<CareFacility>> fetchNear({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final fromApi = await _fetchOverpass(latitude, longitude);
      if (fromApi.isNotEmpty) return fromApi;
    } catch (_) {
      // Fall through to demo facilities when offline or API unavailable.
    }
    return _demoFacilities(latitude, longitude);
  }

  static Future<List<CareFacility>> _fetchOverpass(
    double lat,
    double lon,
  ) async {
    final query = '''
[out:json][timeout:20];
(
  nwr["amenity"~"hospital|clinic|doctors"](around:$_radiusMeters,$lat,$lon);
);
out center 20;
''';
    final uri = Uri.parse(
      'https://overpass-api.de/api/interpreter?data=${Uri.encodeComponent(query)}',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 22));
    if (response.statusCode != 200) {
      throw NearbyException(
        'Could not load facilities (${response.statusCode}).',
      );
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final elements = data['elements'] as List<dynamic>? ?? [];

    final facilities = <CareFacility>[];
    for (final raw in elements) {
      final map = raw as Map<String, dynamic>;
      final tags = map['tags'] as Map<String, dynamic>? ?? {};
      final name = (tags['name'] as String?)?.trim();
      if (name == null || name.isEmpty) continue;

      final center = map['center'] as Map<String, dynamic>?;
      final facilityLat = (center?['lat'] ?? map['lat']) as num?;
      final facilityLon = (center?['lon'] ?? map['lon']) as num?;
      if (facilityLat == null || facilityLon == null) continue;

      final amenity = tags['amenity'] as String? ?? 'hospital';
      final type = switch (amenity) {
        'clinic' => 'Clinic',
        'doctors' => 'Care unit',
        _ => 'Hospital',
      };
      final dist = _distanceKm(
        lat,
        lon,
        facilityLat.toDouble(),
        facilityLon.toDouble(),
      );
      final address = _formatAddress(tags);
      final phone = (tags['phone'] as String?) ?? tags['contact:phone'] as String?;

      facilities.add(
        CareFacility(
          name: name,
          type: type,
          latitude: facilityLat.toDouble(),
          longitude: facilityLon.toDouble(),
          distanceKm: dist,
          address: address,
          phone: phone?.trim(),
        ),
      );
    }

    facilities.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
    return facilities.take(15).toList();
  }

  static String? _formatAddress(Map<String, dynamic> tags) {
    final parts = <String>[
      if (tags['addr:street'] != null) '${tags['addr:street']}',
      if (tags['addr:city'] != null) '${tags['addr:city']}',
    ].where((p) => p.trim().isNotEmpty);
    if (parts.isEmpty) return null;
    return parts.join(', ');
  }

  static double _distanceKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    return Geolocator.distanceBetween(lat1, lon1, lat2, lon2) / 1000;
  }

  static List<CareFacility> _demoFacilities(double lat, double lon) {
    const offsets = [
      (0.012, 0.008, 'City Heart Hospital', 'Hospital', 1.2),
      (-0.009, 0.014, 'Northside Cardiac Clinic', 'Clinic', 1.8),
      (0.018, -0.006, 'Riverside Urgent Care', 'Care unit', 2.4),
      (-0.015, -0.011, 'Community Medical Center', 'Hospital', 3.1),
    ];
    return offsets
        .map(
          (o) => CareFacility(
            name: o.$3,
            type: o.$4,
            latitude: lat + o.$1,
            longitude: lon + o.$2,
            distanceKm: o.$5,
            address: 'Near your current location',
          ),
        )
        .toList();
  }
}

class NearbyException implements Exception {
  const NearbyException(this.message);
  final String message;

  @override
  String toString() => message;
}
