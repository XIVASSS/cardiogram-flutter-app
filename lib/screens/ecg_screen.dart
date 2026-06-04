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
          SizedBox(
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  left: 4,
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
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _SessionButton(
              recording: _recording,
              timeLabel: _formattedTime,
              onTap: _toggleSession,
            ),
          ),
          Expanded(
            child: _recording
                ? AnimatedEcgLine(
                    model: _model,
                    color: AppColors.accentPink,
                    beatsPerScreen: 3.2,
                    motion: _motion,
                  )
                : Center(
                    child: AnimatedEcgLine(
                      model: _model,
                      color: AppColors.textTertiary,
                      beatsPerScreen: 3.2,
                      motion: _motion,
                      backgroundFillColor: const Color(0xFF2A2A2C),
                    ),
                  ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              8,
              24,
              32 + MediaQuery.paddingOf(context).bottom,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    child: Text(
                      _recording ? '$_bpm' : '0',
                      key: ValueKey(_recording ? _bpm : 0),
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 88,
                        fontWeight: FontWeight.w300,
                        height: 0.95,
                        letterSpacing: -2,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 2, top: 4),
                    child: Text(
                      'BPM',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.8,
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
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: AppColors.accentPink,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    recording
                        ? 'Recording · $timeLabel'
                        : 'Tap to start session',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.1,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                Icon(
                  recording
                      ? Icons.auto_awesome_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
