/// Hospital, clinic, or other care location shown on the Nearby screen.
class CareFacility {
  const CareFacility({
    required this.name,
    required this.type,
    required this.latitude,
    required this.longitude,
    required this.distanceKm,
    this.address,
    this.phone,
  });

  final String name;
  final String type;
  final double latitude;
  final double longitude;
  final double distanceKm;
  final String? address;
  final String? phone;
}
