import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:geolocator/geolocator.dart';

import '../models/care_facility.dart';
import '../models/sos_contact.dart';
import '../services/emergency_dialer.dart';
import '../services/nearby_facilities_service.dart';
import '../services/sos_contacts_store.dart';
import '../theme/app_theme.dart';
import '../widgets/ios_status_bar.dart';

class NearbyScreen extends StatefulWidget {
  const NearbyScreen({super.key});

  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen> {
  List<SosContact> _sosContacts = [];
  List<CareFacility> _facilities = [];
  Position? _position;
  bool _loadingFacilities = true;
  String? _facilityError;
  bool _sosBusy = false;

  late final String _emergencyNumber =
      EmergencyDialer.emergencyNumberForLocale();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final contacts = await SosContactsStore.load();
    if (!mounted) return;
    setState(() => _sosContacts = contacts);
    await _refreshFacilities();
  }

  Future<void> _refreshFacilities() async {
    setState(() {
      _loadingFacilities = true;
      _facilityError = null;
      _facilities = [];
    });
    try {
      final pos = await NearbyFacilitiesService.resolvePosition();
      final list = await NearbyFacilitiesService.fetchNear(
        latitude: pos.latitude,
        longitude: pos.longitude,
      );
      if (!mounted) return;
      setState(() {
        _position = pos;
        _facilities = list;
        _loadingFacilities = false;
        _facilityError = list.isEmpty
            ? 'No hospitals or clinics found within 15 km of your location.'
            : null;
      });
    } on NearbyException catch (e) {
      if (!mounted) return;
      setState(() {
        _facilityError = e.message;
        _loadingFacilities = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _facilityError = 'Could not load nearby hospitals. Pull to retry.';
        _loadingFacilities = false;
      });
    }
  }

  Future<void> _addContactFromPhone() async {
    if (_sosContacts.length >= SosContactsStore.maxContacts) {
      _showSnack('You can add up to ${SosContactsStore.maxContacts} SOS contacts.');
      return;
    }
    // Native picker works without full contacts access on iOS/Android.
    final contact = await FlutterContacts.native.showPicker(
      properties: {ContactProperty.phone},
    );
    if (contact == null || !mounted) return;

    final phone = contact.phones.isNotEmpty
        ? contact.phones.first.number
        : null;
    if (phone == null || phone.trim().isEmpty) {
      _showSnack('That contact has no phone number.');
      return;
    }

    final name = contact.displayName?.trim();
    if (name == null || name.isEmpty) {
      _showSnack('That contact has no name.');
      return;
    }

    final id = contact.id;
    if (id == null || id.isEmpty) {
      _showSnack('Could not read that contact.');
      return;
    }

    final entry = SosContact(
      id: id,
      displayName: name,
      phoneNumber: phone,
    );
    if (_sosContacts.any((c) => c.id == entry.id)) {
      _showSnack('${entry.displayName} is already in your SOS list.');
      return;
    }

    final updated = [..._sosContacts, entry];
    await SosContactsStore.save(updated);
    if (!mounted) return;
    setState(() => _sosContacts = updated);
  }

  Future<void> _removeContact(SosContact contact) async {
    final updated = _sosContacts.where((c) => c.id != contact.id).toList();
    await SosContactsStore.save(updated);
    if (!mounted) return;
    setState(() => _sosContacts = updated);
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _confirmSos() async {
    if (_sosContacts.isEmpty) {
      _showSnack('Add at least one SOS contact from your phone first.');
      return;
    }
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text(
          'Send SOS?',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Text(
          'This will call ${EmergencyDialer.emergencyLabel(_emergencyNumber)} '
          'and open a text to your ${_sosContacts.length} SOS contact(s) '
          'with your location.',
          style: const TextStyle(
            color: AppColors.textSecondary,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Send SOS',
              style: TextStyle(color: AppColors.accentPink),
            ),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    await _triggerSos();
  }

  Future<void> _triggerSos() async {
    setState(() => _sosBusy = true);
    try {
      Position? pos = _position;
      if (pos == null) {
        try {
          pos = await NearbyFacilitiesService.currentPosition();
        } catch (_) {}
      }
      final mapsLink = pos != null
          ? 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}'
          : 'Location unavailable';
      final body =
          'SOS from Cardiogram — I may need help. My location: $mapsLink';

      await EmergencyDialer.call(_emergencyNumber);

      final phones = _sosContacts.map((c) => c.phoneNumber).toList();
      await EmergencyDialer.sms(phones: phones, body: body);

      if (!mounted) return;
      _showSnack(
        'Emergency call started. Message composer opened for SOS contacts.',
      );
    } finally {
      if (mounted) setState(() => _sosBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          const IosStatusBar(),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 20, 8),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(
                    Icons.chevron_left_rounded,
                    color: AppColors.textPrimary,
                    size: 30,
                  ),
                ),
                const Expanded(
                  child: Text(
                    'Nearby me',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _loadingFacilities ? null : _refreshFacilities,
                  icon: const Icon(
                    Icons.refresh_rounded,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              color: AppColors.accentPink,
              onRefresh: _refreshFacilities,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                children: [
                  _SosCard(
                    busy: _sosBusy,
                    contactCount: _sosContacts.length,
                    maxContacts: SosContactsStore.maxContacts,
                    onSos: _confirmSos,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'LOCAL AUTHORITIES',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _AuthorityTile(
                    title: EmergencyDialer.emergencyLabel(_emergencyNumber),
                    subtitle: 'Tap to call immediately',
                    icon: Icons.local_police_rounded,
                    onTap: () => EmergencyDialer.call(_emergencyNumber),
                  ),
                  const SizedBox(height: 10),
                  _AuthorityTile(
                    title: 'Ambulance / medical emergency',
                    subtitle: 'Same emergency line in your region',
                    icon: Icons.medical_services_rounded,
                    onTap: () => EmergencyDialer.call(_emergencyNumber),
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'SOS CONTACTS',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                      Text(
                        '${_sosContacts.length}/${SosContactsStore.maxContacts}',
                        style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Choose up to five people from your phone contacts. '
                    'SOS calls emergency services and texts them your location.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_sosContacts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No SOS contacts yet.',
                        style: TextStyle(color: AppColors.textTertiary),
                      ),
                    )
                  else
                    for (final c in _sosContacts)
                      _SosContactTile(
                        contact: c,
                        onCall: () => EmergencyDialer.call(c.phoneNumber),
                        onRemove: () => _removeContact(c),
                      ),
                  const SizedBox(height: 10),
                  _AddContactButton(
                    enabled: _sosContacts.length < SosContactsStore.maxContacts,
                    onTap: _addContactFromPhone,
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    'HOSPITALS & CARE UNITS',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_position != null && !_loadingFacilities && _facilityError == null)
                    Text(
                      'Real hospitals near your GPS location.',
                      style: TextStyle(
                        color: AppColors.textTertiary.withValues(alpha: 0.9),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (_loadingFacilities)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Column(
                        children: [
                          CircularProgressIndicator(
                            color: AppColors.accentPink,
                            strokeWidth: 2.4,
                          ),
                          SizedBox(height: 14),
                          Text(
                            'Using your location to find nearby hospitals…',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (_facilityError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _facilityError!,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          height: 1.4,
                        ),
                      ),
                    )
                  else
                    for (final f in _facilities)
                      _FacilityTile(
                        facility: f,
                        onMaps: () => EmergencyDialer.openMaps(
                          f.latitude,
                          f.longitude,
                          label: f.name,
                        ),
                        onCall: f.phone != null
                            ? () => EmergencyDialer.call(f.phone!)
                            : null,
                      ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SosCard extends StatelessWidget {
  const _SosCard({
    required this.busy,
    required this.contactCount,
    required this.maxContacts,
    required this.onSos,
  });

  final bool busy;
  final int contactCount;
  final int maxContacts;
  final VoidCallback onSos;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFB81835), AppColors.accentPinkDark],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.sos_rounded, color: Colors.white, size: 28),
              SizedBox(width: 10),
              Text(
                'Emergency SOS',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            contactCount == 0
                ? 'Add contacts below, then tap to alert authorities and your network.'
                : '$contactCount of $maxContacts contacts ready.',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: busy ? null : onSos,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                    child: busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: AppColors.accentPink,
                            ),
                          )
                        : const Text(
                            'SEND SOS',
                            style: TextStyle(
                              color: AppColors.accentPinkDark,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthorityTile extends StatelessWidget {
  const _AuthorityTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.divider),
          ),
          child: Row(
            children: [
              Icon(icon, color: AppColors.ecgBlue, size: 26),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.call_rounded,
                color: AppColors.connectedGreen,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SosContactTile extends StatelessWidget {
  const _SosContactTile({
    required this.contact,
    required this.onCall,
    required this.onRemove,
  });

  final SosContact contact;
  final VoidCallback onCall;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.surface,
            child: Icon(
              Icons.person_rounded,
              color: AppColors.textSecondary,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  contact.displayName,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  contact.phoneNumber,
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onCall,
            icon: const Icon(Icons.call_rounded, color: AppColors.connectedGreen),
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(
              Icons.close_rounded,
              color: AppColors.textTertiary,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddContactButton extends StatelessWidget {
  const _AddContactButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled ? onTap : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: enabled ? AppColors.accentPink : AppColors.divider,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.contact_phone_rounded,
                color: enabled ? AppColors.accentPink : AppColors.textTertiary,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'Add from phone contacts',
                style: TextStyle(
                  color: enabled ? AppColors.textPrimary : AppColors.textTertiary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FacilityTile extends StatelessWidget {
  const _FacilityTile({
    required this.facility,
    required this.onMaps,
    this.onCall,
  });

  final CareFacility facility;
  final VoidCallback onMaps;
  final VoidCallback? onCall;

  @override
  Widget build(BuildContext context) {
    final dist = facility.distanceKm < 1
        ? '${(facility.distanceKm * 1000).round()} m'
        : '${facility.distanceKm.toStringAsFixed(1)} km';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.local_hospital_rounded,
                color: AppColors.ecgBlue,
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      facility.name,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${facility.type} · $dist away',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                    if (facility.address != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        facility.address!,
                        style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onMaps,
                  icon: const Icon(Icons.map_rounded, size: 18),
                  label: const Text('Directions'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.divider),
                  ),
                ),
              ),
              if (onCall != null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onCall,
                    icon: const Icon(Icons.call_rounded, size: 18),
                    label: const Text('Call'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.connectedGreen,
                      side: const BorderSide(color: AppColors.divider),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
