import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../services/session_history.dart';
import '../theme/app_theme.dart';
import '../widgets/ecg_waveform.dart';
import '../widgets/ios_status_bar.dart';
import 'home_screen.dart';
import 'report_screen.dart';

class EcgScreen extends StatefulWidget {
  const EcgScreen({super.key});

  @override
  State<EcgScreen> createState() => _EcgScreenState();
}

class _EcgScreenState extends State<EcgScreen> {
  // Every session lasts exactly one minute.
  static const int _sessionSeconds = 60;

  // A fresh, unique ECG recording for every session.
  late final EcgModel _model = EcgModel.random();
  late bool _recording = true;
  late int _bpm = _model.bpm;
  // Continuous, smoothed BPM the display eases toward (avoids jumpy digits).
  late double _bpmValue = _model.heartRate;
  // Slow heart-rate-variability wander so the number breathes, not dances.
  double _wander = 0;
  Timer? _bpmTimer;
  Timer? _sessionTimer;
  int _secondsLeft = _sessionSeconds;
  final _rng = math.Random();

  // Live movement level (0 = still .. 1 = vigorous) from the gyroscope.
  final ValueNotifier<double> _motion = ValueNotifier<double>(0);
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  @override
  void initState() {
    super.initState();
    _startBpmJitter();
    _startSessionCountdown();
    _startGyro();
  }

  void _startSessionCountdown() {
    _sessionTimer?.cancel();
    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_recording) return;
      setState(() => _secondsLeft -= 1);
      if (_secondsLeft <= 0) _finishSession();
    });
  }

  void _startGyro() {
    // Optional override for testing on devices without a gyroscope
    // (e.g. the iOS Simulator): `flutter run --dart-define=MOTION=0.6`.
    final forced = double.tryParse(const String.fromEnvironment('MOTION'));
    if (forced != null && forced > 0) {
      _motion.value = forced.clamp(0.0, 1.0);
      return;
    }
    try {
      _gyroSub = gyroscopeEventStream().listen((e) {
        // Rotational speed magnitude (rad/s) → normalised movement level.
        final mag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
        // Deadzone: ignore small hand tremor / sensor noise so a steady hold
        // reads as a clean ECG; only deliberate movement registers.
        final target = ((mag - 1.2) / 8.0).clamp(0.0, 1.0);
        // Ease in quickly, decay slowly back to a clean trace.
        final k = target > _motion.value ? 0.2 : 0.06;
        _motion.value = _motion.value + (target - _motion.value) * k;
      }, onError: (_) {});
    } catch (_) {
      // Gyroscope unavailable (e.g. simulator/desktop); stays at 0.
    }
  }

  void _startBpmJitter() {
    _bpmTimer?.cancel();
    // Update often, but move gently: the BPM glides toward the movement-driven
    // target instead of snapping, so the number reads like a real monitor.
    _bpmTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || !_recording) return;
      // Movement-driven resting target (shake the phone → higher BPM).
      final target = _model.heartRateFor(_motion.value);
      // Gentle physiological wander: a small, mean-reverting random walk
      // (heart-rate variability) rather than a jumpy ±2 every tick.
      _wander += (_rng.nextDouble() * 2 - 1) * 0.35;
      _wander = (_wander * 0.9).clamp(-1.8, 1.8);
      // Low-pass filter the displayed value toward target + wander.
      final desired = target + _wander;
      _bpmValue += (desired - _bpmValue) * 0.12;
      final next = _bpmValue.round();
      if (next != _bpm) setState(() => _bpm = next);
    });
  }

  @override
  void dispose() {
    _bpmTimer?.cancel();
    _sessionTimer?.cancel();
    _gyroSub?.cancel();
    _motion.dispose();
    super.dispose();
  }

  void _finishSession() {
    if (!_recording) return;
    _sessionTimer?.cancel();
    _bpmTimer?.cancel();
    setState(() => _recording = false);
    final elapsed = _sessionSeconds - _secondsLeft;
    SessionHistory.instance.add(
      modelSeed: _model.seed,
      avgBpm: _bpm,
      durationSeconds: elapsed.clamp(1, _sessionSeconds),
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReportScreen(
          model: _model,
          avgBpm: _bpm,
          recordedAt: DateTime.now(),
        ),
      ),
    );
  }

  void _onBack() {
    final navigator = Navigator.of(context);
    // Pop when launched from the home flow; otherwise (e.g. ECG opened as the
    // first route via START=ecg) there's nothing to pop, so go home instead.
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    }
  }

  void _toggleSession() {
    if (_recording) {
      // Finish the session early and show the report for THIS recording.
      _finishSession();
    } else {
      // Resume starts a fresh one-minute session.
      setState(() {
        _recording = true;
        _secondsLeft = _sessionSeconds;
        _startBpmJitter();
        _startSessionCountdown();
      });
    }
  }

  String get _formattedTime {
    final m = _secondsLeft ~/ 60;
    final s = _secondsLeft % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          const IosStatusBar(),
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              onPressed: _onBack,
              icon: const Icon(
                Icons.chevron_left_rounded,
                color: AppColors.textPrimary,
                size: 30,
              ),
            ),
          ),
          const Text(
            'ECG',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _SessionButton(
              recording: _recording,
              timeLabel: _formattedTime,
              onTap: _toggleSession,
            ),
          ),
          Expanded(
            child: _recording
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 30),
                    child: AnimatedEcgLine(
                      model: _model,
                      color: AppColors.accentPink,
                      beatsPerScreen: 3.4,
                      motion: _motion,
                    ),
                  )
                : const Center(
                    child: Text(
                      'Session paused',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 24, bottom: 48),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      '$_bpm',
                      key: ValueKey(_bpm),
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 80,
                        fontWeight: FontWeight.w300,
                        height: 1.0,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 4, top: 2),
                    child: Text(
                      'BPM',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 1,
                      ),
                    ),
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

class _SessionButton extends StatelessWidget {
  const _SessionButton({
    required this.recording,
    required this.timeLabel,
    required this.onTap,
  });

  final bool recording;
  final String timeLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.accentPink, AppColors.accentPinkDark],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: AppColors.accentPink.withValues(alpha: 0.45),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
            child: Row(
              children: [
                Text(
                  recording ? 'Session' : 'Resume',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (recording) ...[
                  const SizedBox(width: 10),
                  Text(
                    timeLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
                const Spacer(),
                Icon(
                  recording
                      ? Icons.monitor_heart_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
