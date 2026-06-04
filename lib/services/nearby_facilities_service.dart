import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../models/care_facility.dart';

/// Finds hospitals and clinics near the user using GPS + map/place APIs
/// (Photon, Nominatim, Overpass). Works on Android and iOS.
class NearbyFacilitiesService {
  NearbyFacilitiesService._();

  static const _radiusMeters = 15000;
  static const _maxResults = 20;

  static const _userAgent =
      'Cardiogram/1.0 (Flutter; nearby healthcare; contact@cardiogram.app)';

  static const _requestHeaders = {
    'User-Agent': _userAgent,
    'Accept': 'application/json',
    'Accept-Encoding': 'gzip, deflate',
  };

  static const _overpassEndpoints = [
    'https://overpass.kumi.systems/api/interpreter',
    'https://lz4.overpass-api.de/api/interpreter',
  ];

  /// Requests location permission and returns the current GPS fix.
  static Future<Position> currentPosition() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      throw const NearbyException(
        'Turn on Location Services to find hospitals near you.',
      );
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw const NearbyException(
        'Allow location access so we can find hospitals near you.',
      );
    }
    if (permission == LocationPermission.deniedForever) {
      throw const NearbyException(
        'Location is blocked. Enable it in Settings → Cardiogram → Location.',
      );
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 20),
      ),
    );
  }

  /// GPS fix: live position, then recent last-known (no fake coordinates).
  static Future<Position> resolvePosition() async {
    try {
      return await currentPosition();
    } on NearbyException {
      rethrow;
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        final age = DateTime.now().difference(last.timestamp);
        if (age.inHours < 24) return last;
      }
      throw const NearbyException(
        'Could not get your location. Enable GPS and try again.',
      );
    }
  }

  /// Loads real nearby hospitals/clinics using the device location.
  static Future<List<CareFacility>> fetchNear({
    required double latitude,
    required double longitude,
  }) async {
    final merged = <CareFacility>[];
    final errors = <String>[];

    for (final loader in [
      _fetchPhoton,
      _fetchNominatim,
      _fetchOverpass,
    ]) {
      try {
        final batch = await loader(latitude, longitude);
        merged.addAll(batch);
        if (_dedupeSortFilter(merged, latitude, longitude).length >= _maxResults) {
          break;
        }
      } on NearbyException catch (e) {
        errors.add(e.message);
      } catch (_) {
        errors.add('lookup failed');
      }
    }

    final results = _dedupeSortFilter(merged, latitude, longitude);
    if (results.isNotEmpty) {
      return results.take(_maxResults).toList();
    }

    if (errors.isNotEmpty) {
      throw const NearbyException(
        'Could not load hospitals. Check internet and pull to retry.',
      );
    }
    throw NearbyException(
      'No hospitals or clinics found within ${_radiusMeters ~/ 1000} km.',
    );
  }

  /// Photon (Komoot) — fast OSM place search, no API key.
  static Future<List<CareFacility>> _fetchPhoton(double lat, double lon) async {
    final facilities = <CareFacility>[];
    const searches = [
      (query: 'hospital', type: 'Hospital', osmTag: 'amenity:hospital'),
      (query: 'clinic', type: 'Clinic', osmTag: 'amenity:clinic'),
      (query: 'doctor', type: 'Care unit', osmTag: 'amenity:doctors'),
    ];

    for (final search in searches) {
      final uri = Uri.https('photon.komoot.io', '/api/', {
        'q': search.query,
        'lat': lat.toString(),
        'lon': lon.toString(),
        'limit': '15',
        'lang': 'en',
        'osm_tag': search.osmTag,
      });

      final response = await http
          .get(uri, headers: _requestHeaders)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) continue;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final features = data['features'] as List<dynamic>? ?? [];

      for (final raw in features) {
        final feature = raw as Map<String, dynamic>;
        final props = feature['properties'] as Map<String, dynamic>? ?? {};
        if (!_isHealthcareOsm(props)) continue;

        final geom = feature['geometry'] as Map<String, dynamic>?;
        final coords = geom?['coordinates'] as List<dynamic>?;
        if (coords == null || coords.length < 2) continue;

        final facilityLon = (coords[0] as num).toDouble();
        final facilityLat = (coords[1] as num).toDouble();
        final dist = _distanceKm(lat, lon, facilityLat, facilityLon);
        if (dist * 1000 > _radiusMeters) continue;

        final name = (props['name'] as String?)?.trim();
        if (name == null || name.isEmpty) continue;

        facilities.add(
          CareFacility(
            name: name,
            type: _typeFromPhoton(props, search.type),
            latitude: facilityLat,
            longitude: facilityLon,
            distanceKm: dist,
            address: _addressFromPhoton(props),
          ),
        );
      }
    }

    if (facilities.isEmpty) {
      throw NearbyException('Photon returned no results');
    }
    return facilities;
  }

  static bool _isHealthcareOsm(Map<String, dynamic> props) {
    final key = props['osm_key'] as String?;
    final value = props['osm_value'] as String?;
    final type = props['type'] as String?;

    if (key == 'amenity' &&
        const {'hospital', 'clinic', 'doctors'}.contains(value)) {
      return true;
    }
    if (key == 'healthcare' &&
        const {'hospital', 'clinic', 'centre', 'doctor', 'yes'}
            .contains(value)) {
      return true;
    }
    if (type == 'house' || type == 'street') return false;
    if (key == 'amenity' || key == 'healthcare') return true;

    final ext = props['osm_value'] as String? ?? '';
    return ext.contains('hospital') ||
        ext.contains('clinic') ||
        ext.contains('doctor');
  }

  static String _typeFromPhoton(
    Map<String, dynamic> props,
    String fallback,
  ) {
    final value = props['osm_value'] as String?;
    return switch (value) {
      'hospital' => 'Hospital',
      'clinic' => 'Clinic',
      'doctors' => 'Care unit',
      'centre' => 'Care centre',
      'doctor' => 'Care unit',
      _ => fallback,
    };
  }

  static String? _addressFromPhoton(Map<String, dynamic> props) {
    final street = props['street'] as String?;
    final housenumber = props['housenumber'] as String?;
    final city = props['city'] as String?;
    final postcode = props['postcode'] as String?;

    final line1 = [
      if (housenumber != null && street != null) '$housenumber $street',
      if (housenumber == null && street != null) street,
    ].join(' ').trim();

    final line2 = [city, postcode]
        .whereType<String>()
        .where((p) => p.trim().isNotEmpty)
        .join(' ');

    if (line1.isEmpty && line2.isEmpty) return null;
    if (line1.isEmpty) return line2;
    if (line2.isEmpty) return line1;
    return '$line1, $line2';
  }

  /// Nominatim (OpenStreetMap search) — backup place API.
  static Future<List<CareFacility>> _fetchNominatim(
    double lat,
    double lon,
  ) async {
    final facilities = <CareFacility>[];
    const tags = ['hospital', 'clinic', 'doctors'];

    for (final tag in tags) {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'format': 'json',
        'amenity': tag,
        'lat': lat.toString(),
        'lon': lon.toString(),
        'limit': '12',
        'addressdetails': '1',
        'extratags': '1',
      });

      final response = await http
          .get(uri, headers: _requestHeaders)
          .timeout(const Duration(seconds: 18));

      if (response.statusCode != 200) continue;

      final list = jsonDecode(response.body) as List<dynamic>;
      for (final raw in list) {
        final item = raw as Map<String, dynamic>;
        final name =
            (item['name'] as String?)?.trim() ??
            (item['display_name'] as String?)?.split(',').first.trim();
        if (name == null || name.isEmpty) continue;

        final facilityLat = double.tryParse(item['lat'] as String? ?? '');
        final facilityLon = double.tryParse(item['lon'] as String? ?? '');
        if (facilityLat == null || facilityLon == null) continue;

        final dist = _distanceKm(lat, lon, facilityLat, facilityLon);
        if (dist * 1000 > _radiusMeters) continue;

        final type = switch (tag) {
          'hospital' => 'Hospital',
          'clinic' => 'Clinic',
          _ => 'Care unit',
        };

        facilities.add(
          CareFacility(
            name: name,
            type: type,
            latitude: facilityLat,
            longitude: facilityLon,
            distanceKm: dist,
            address: item['display_name'] as String?,
          ),
        );
      }
    }

    if (facilities.isEmpty) {
      throw NearbyException('Nominatim returned no results');
    }
    return facilities;
  }

  /// Overpass — detailed OSM query (slower, used last).
  static Future<List<CareFacility>> _fetchOverpass(
    double lat,
    double lon,
  ) async {
    final query = '''
[out:json][timeout:20];
(
  nwr["amenity"="hospital"](around:$_radiusMeters,$lat,$lon);
  nwr["amenity"="clinic"](around:$_radiusMeters,$lat,$lon);
  nwr["amenity"="doctors"](around:$_radiusMeters,$lat,$lon);
  nwr["healthcare"](around:$_radiusMeters,$lat,$lon);
);
out center $_maxResults;
''';

    for (final endpoint in _overpassEndpoints) {
      try {
        final response = await _requestOverpass(endpoint, query);
        return _parseOverpassElements(
          jsonDecode(response.body) as Map<String, dynamic>,
          lat,
          lon,
        );
      } catch (_) {
        continue;
      }
    }
    throw NearbyException('Overpass unavailable');
  }

  static List<CareFacility> _parseOverpassElements(
    Map<String, dynamic> data,
    double lat,
    double lon,
  ) {
    final elements = data['elements'] as List<dynamic>? ?? [];
    final facilities = <CareFacility>[];

    for (final raw in elements) {
      final map = raw as Map<String, dynamic>;
      final tags = map['tags'] as Map<String, dynamic>? ?? {};

      final center = map['center'] as Map<String, dynamic>?;
      final facilityLat = (center?['lat'] ?? map['lat']) as num?;
      final facilityLon = (center?['lon'] ?? map['lon']) as num?;
      if (facilityLat == null || facilityLon == null) continue;

      final name = _resolveName(tags);
      if (name == null) continue;

      facilities.add(
        CareFacility(
          name: name,
          type: _resolveType(tags),
          latitude: facilityLat.toDouble(),
          longitude: facilityLon.toDouble(),
          distanceKm: _distanceKm(
            lat,
            lon,
            facilityLat.toDouble(),
            facilityLon.toDouble(),
          ),
          address: _formatAddress(tags),
          phone: _resolvePhone(tags),
        ),
      );
    }
    return facilities;
  }

  static Future<http.Response> _requestOverpass(
    String endpoint,
    String query,
  ) async {
    final uri = Uri.parse(endpoint);
    final timeout = const Duration(seconds: 25);

    final attempts = <Future<http.Response> Function()>[
      () => http.post(
        uri,
        headers: {
          ..._requestHeaders,
          'Content-Type': 'text/plain; charset=utf-8',
        },
        body: query,
      ),
      () => http.get(
        Uri.parse('$endpoint?data=${Uri.encodeComponent(query)}'),
        headers: _requestHeaders,
      ),
    ];

    for (final attempt in attempts) {
      final response = await attempt().timeout(timeout);
      if (response.statusCode == 200) return response;
    }
    throw NearbyException('Overpass HTTP error');
  }

  static List<CareFacility> _dedupeSortFilter(
    List<CareFacility> input,
    double lat,
    double lon,
  ) {
    final seen = <String>{};
    final out = <CareFacility>[];

    for (final f in input) {
      if (f.distanceKm * 1000 > _radiusMeters) continue;
      final key =
          '${f.name.toLowerCase()}@${f.latitude.toStringAsFixed(4)},${f.longitude.toStringAsFixed(4)}';
      if (seen.contains(key)) continue;
      seen.add(key);
      out.add(f);
    }

    out.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
    return out;
  }

  static String? _resolveName(Map<String, dynamic> tags) {
    for (final key in ['name', 'name:en', 'official_name', 'operator']) {
      final value = (tags[key] as String?)?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  static String? _resolvePhone(Map<String, dynamic> tags) {
    final phone =
        (tags['phone'] as String?) ??
        tags['contact:phone'] as String? ??
        tags['contact:mobile'] as String?;
    return phone?.trim().isEmpty == true ? null : phone?.trim();
  }

  static String _resolveType(Map<String, dynamic> tags) {
    final healthcare = tags['healthcare'] as String?;
    final amenity = tags['amenity'] as String?;

    if (healthcare == 'hospital' || amenity == 'hospital') return 'Hospital';
    if (healthcare == 'clinic' || amenity == 'clinic') return 'Clinic';
    if (healthcare == 'centre') return 'Care centre';
    if (healthcare == 'doctor' || amenity == 'doctors') return 'Care unit';

    return switch (amenity) {
      'clinic' => 'Clinic',
      'doctors' => 'Care unit',
      'hospital' => 'Hospital',
      _ => 'Healthcare facility',
    };
  }

  static String? _formatAddress(Map<String, dynamic> tags) {
    final street = tags['addr:street'] as String?;
    final housenumber = tags['addr:housenumber'] as String?;
    final city =
        (tags['addr:city'] as String?) ??
        tags['addr:town'] as String? ??
        tags['addr:suburb'] as String?;
    final postcode = tags['addr:postcode'] as String?;

    final line1 = [
      if (housenumber != null && street != null) '$housenumber $street',
      if (housenumber == null && street != null) street,
    ].where((p) => p.trim().isNotEmpty).join(' ');

    final line2 = [city, postcode]
        .whereType<String>()
        .where((p) => p.trim().isNotEmpty)
        .join(' ');

    if (line1.isEmpty && line2.isEmpty) return null;
    if (line1.isEmpty) return line2;
    if (line2.isEmpty) return line1;
    return '$line1, $line2';
  }

  static double _distanceKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    return Geolocator.distanceBetween(lat1, lon1, lat2, lon2) / 1000;
  }
}

class NearbyException implements Exception {
  const NearbyException(this.message);
  final String message;

  @override
  String toString() => message;
}
