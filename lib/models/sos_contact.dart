/// One person chosen from the device address book for SOS outreach.
class SosContact {
  const SosContact({
    required this.id,
    required this.displayName,
    required this.phoneNumber,
  });

  final String id;
  final String displayName;
  final String phoneNumber;

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'phoneNumber': phoneNumber,
      };

  factory SosContact.fromJson(Map<String, dynamic> json) => SosContact(
        id: json['id'] as String,
        displayName: json['displayName'] as String,
        phoneNumber: json['phoneNumber'] as String,
      );
}
