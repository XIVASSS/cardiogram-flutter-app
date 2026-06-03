import '../widgets/ecg_waveform.dart';

/// One completed ECG session saved for the history list.
class SessionRecord {
  const SessionRecord({
    required this.id,
    required this.recordedAt,
    required this.modelSeed,
    required this.avgBpm,
    required this.durationSeconds,
  });

  final String id;
  final DateTime recordedAt;
  final int modelSeed;
  final int avgBpm;
  final int durationSeconds;

  EcgModel get model => EcgModel.random(modelSeed);
}
