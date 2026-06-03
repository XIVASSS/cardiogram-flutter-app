import '../models/session_record.dart';

/// In-memory store of completed sessions (newest first).
class SessionHistory {
  SessionHistory._();

  static final SessionHistory instance = SessionHistory._();

  final List<SessionRecord> _records = [];
  bool _seeded = false;

  List<SessionRecord> get records {
    ensureSeeded();
    return List.unmodifiable(_records);
  }

  void ensureSeeded() {
    if (_seeded) return;
    _seeded = true;
    if (_records.isNotEmpty) return;

    final now = DateTime.now();
    _records.addAll([
      SessionRecord(
        id: 'seed-1',
        recordedAt: now.subtract(const Duration(days: 2, hours: 3)),
        modelSeed: 42891,
        avgBpm: 72,
        durationSeconds: 60,
      ),
      SessionRecord(
        id: 'seed-2',
        recordedAt: now.subtract(const Duration(days: 5, hours: 8)),
        modelSeed: 91024,
        avgBpm: 88,
        durationSeconds: 58,
      ),
      SessionRecord(
        id: 'seed-3',
        recordedAt: now.subtract(const Duration(days: 12, hours: 2)),
        modelSeed: 156703,
        avgBpm: 64,
        durationSeconds: 60,
      ),
    ]);
    _sortNewestFirst();
  }

  void add({
    required int modelSeed,
    required int avgBpm,
    required int durationSeconds,
    DateTime? recordedAt,
  }) {
    ensureSeeded();
    final record = SessionRecord(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      recordedAt: recordedAt ?? DateTime.now(),
      modelSeed: modelSeed,
      avgBpm: avgBpm,
      durationSeconds: durationSeconds,
    );
    _records.insert(0, record);
    _sortNewestFirst();
  }

  void _sortNewestFirst() {
    _records.sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
  }
}
