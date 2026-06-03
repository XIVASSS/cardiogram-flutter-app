import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';

/// A single (possibly asymmetric) Gaussian deflection of the ECG, expressed in
/// millivolts with its centre/width as a fraction of one cardiac cycle (RR).
///
/// Modeling the ECG as a sum of Gaussian pulses — one per P/Q/R/S/T wave — is a
/// well established technique (Gaussian pulse decomposition). Asymmetric widths
/// let us reproduce e.g. the steeper down‑slope of the T wave.
class EcgWave {
  const EcgWave({
    required this.amplitude,
    required this.center,
    required this.sigmaLeft,
    required this.sigmaRight,
  });

  final double amplitude; // mV (negative for Q/S dips)
  final double center; // 0..1 fraction of the RR interval
  final double sigmaLeft;
  final double sigmaRight;

  double valueAt(double t) {
    final sigma = t < center ? sigmaLeft : sigmaRight;
    final d = (t - center) / sigma;
    return amplitude * math.exp(-0.5 * d * d);
  }
}

/// A complete, randomised ECG generator. Each instance represents one recording
/// session and produces a slightly different — but physiologically plausible —
/// trace (heart rate, wave amplitudes/timing, baseline wander and noise all
/// vary within normal ranges).
///
/// Clinical reference values used (adult sinus rhythm):
///   • P wave   ≤ 0.25 mV, < 0.12 s
///   • PR       0.12–0.20 s
///   • QRS      0.06–0.10 s, tall R wave
///   • T wave   positive, asymmetric, broader than QRS
class EcgModel {
  EcgModel({
    required this.seed,
    required this.heartRate,
    required this.waves,
    required this.baselineAmp,
    required this.respFreq,
    required this.noiseAmp,
    this.adcBits = 12,
    this.adcMid = 2048,
    this.countsPerMv = 820,
    this.motionHrGain = 40,
  });

  final int seed;
  final double heartRate; // resting beats per minute
  final List<EcgWave> waves;
  final double baselineAmp; // mV of respiratory baseline wander
  final double respFreq; // baseline cycles per heart beat
  final double noiseAmp; // mV of high‑frequency noise

  // --- AD8232 analog‑front‑end → ADC characteristics ---
  // The AD8232 outputs an analog single‑lead ECG centred on mid‑rail; a micro‑
  // controller ADC then digitises it to integer counts.
  final int adcBits; // ADC resolution (e.g. 12‑bit = 0..4095)
  final double adcMid; // baseline (isoelectric) ADC count
  final double countsPerMv; // ADC counts per mV of ECG
  final double motionHrGain; // extra bpm at full shake (exertion response)

  /// Builds a new randomised session. Pass a [seed] for reproducibility,
  /// otherwise a time‑based seed makes every session unique.
  factory EcgModel.random([int? seed]) {
    final s = seed ?? (DateTime.now().microsecondsSinceEpoch & 0x7fffffff);
    final rng = math.Random(s);

    double vary(double base, double pct) =>
        base * (1 + (rng.nextDouble() * 2 - 1) * pct);
    double off(double base, double amt) =>
        base + (rng.nextDouble() * 2 - 1) * amt;

    final waves = <EcgWave>[
      // P wave — small, rounded, atrial depolarisation.
      EcgWave(
        amplitude: vary(0.14, 0.30),
        center: off(0.150, 0.012),
        sigmaLeft: vary(0.022, 0.15),
        sigmaRight: vary(0.022, 0.15),
      ),
      // Q wave — small initial negative deflection.
      EcgWave(
        amplitude: -vary(0.11, 0.35),
        center: off(0.288, 0.004),
        sigmaLeft: vary(0.0070, 0.15),
        sigmaRight: vary(0.0070, 0.15),
      ),
      // R wave — tall, sharp ventricular depolarisation.
      EcgWave(
        amplitude: vary(1.10, 0.18),
        center: 0.320,
        sigmaLeft: vary(0.0095, 0.12),
        sigmaRight: vary(0.0095, 0.12),
      ),
      // S wave — negative deflection after R.
      EcgWave(
        amplitude: -vary(0.22, 0.30),
        center: off(0.352, 0.004),
        sigmaLeft: vary(0.0095, 0.15),
        sigmaRight: vary(0.0110, 0.15),
      ),
      // T wave — broad repolarisation, steeper down‑slope (smaller right σ).
      EcgWave(
        amplitude: vary(0.32, 0.28),
        center: off(0.560, 0.020),
        sigmaLeft: vary(0.055, 0.15),
        sigmaRight: vary(0.040, 0.15),
      ),
    ];

    return EcgModel(
      seed: s,
      heartRate: 68 + rng.nextDouble() * 52, // 68–120 bpm
      waves: waves,
      baselineAmp: 0.03 + rng.nextDouble() * 0.04,
      respFreq: 0.16 + rng.nextDouble() * 0.12,
      noiseAmp: 0.006 + rng.nextDouble() * 0.012,
    );
  }

  int get bpm => heartRate.round();

  int get adcLevels => 1 << adcBits;

  /// Heart rate given a [motion] level (0..1). Shaking/movement raises the rate
  /// as if from physical exertion.
  double heartRateFor(double motion) =>
      (heartRate + motion.clamp(0.0, 1.0) * motionHrGain).clamp(40.0, 190.0);

  /// The AD8232 signal digitised to ADC counts at [cycles] (with optional
  /// [motion] artifacts). Quantised to the ADC's integer resolution.
  double sampleAdc(double cycles, {double motion = 0}) {
    final counts = adcMid + sample(cycles, motion: motion) * countsPerMv;
    return counts.clamp(0.0, (adcLevels - 1).toDouble()).roundToDouble();
  }

  double _hash(int n) {
    var x = (n * 374761393 + seed * 668265263) & 0x7fffffff;
    x = ((x ^ (x >> 13)) * 1274126177) & 0x7fffffff;
    return (x & 0xffff) / 65536.0;
  }

  /// Sample the continuous signal at [cycles] cardiac cycles. The integer part
  /// selects the beat (used for beat‑to‑beat variation), the fraction is the
  /// position within that beat.
  ///
  /// [motion] (0 = still, 1 = vigorous) injects realistic motion artifacts —
  /// the same kind of corruption a real wearable ECG/PPG picks up from the
  /// gyroscope/accelerometer when the body moves: low‑frequency baseline
  /// swings, broadband jitter and the occasional sharp movement spike.
  double sample(double cycles, {double motion = 0}) {
    final cycleIndex = cycles.floor();
    final frac = cycles - cycleIndex;

    // Beat‑to‑beat amplitude variation gives the trace a "live" feel.
    final beatScale = 0.92 + 0.16 * _hash(cycleIndex);

    double v = 0;
    for (final w in waves) {
      v += w.valueAt(frac);
    }
    v *= beatScale;

    // Slow respiratory baseline wander.
    v += baselineAmp * math.sin(2 * math.pi * respFreq * cycles);

    // Subtle, phase‑stable noise so the line shimmers without flickering.
    v += noiseAmp * (_hash((cycles * 800).floor()) - 0.5);

    if (motion > 0) {
      final m = motion.clamp(0.0, 1.0);
      // Gentle baseline wander from movement — the QRS complexes stay clearly
      // dominant, so it still reads as a real ECG, just a little restless.
      v +=
          m *
          0.16 *
          math.sin(2 * math.pi * (respFreq * 1.8) * cycles + seed % 7);
      v +=
          m *
          0.08 *
          math.sin(2 * math.pi * (respFreq * 4.1) * cycles + seed % 13);
      // Light broadband jitter.
      v += m * 0.05 * (_hash((cycles * 977).floor()) - 0.5) * 2;
      // Rare, small movement bump.
      final spike = _hash((cycles * 9).floor());
      if (spike > 0.96) {
        v += m * (spike - 0.96) * 2.5 * ((cycleIndex & 1) == 0 ? 1 : -1);
      }
    }

    return v;
  }

  /// Generates a realistic ECG **sample array** (millivolts) for this session.
  ///
  /// [sampleRate] samples per second, [seconds] of recording, and an optional
  /// constant [motion] level (0..1). Motion both adds artifacts and raises the
  /// heart rate.
  List<double> generateWaveform({
    int sampleRate = 250,
    double seconds = 10,
    double motion = 0,
  }) {
    final cyclesPerSecond = heartRateFor(motion) / 60.0;
    final n = (sampleRate * seconds).round();
    final out = List<double>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      final t = i / sampleRate;
      out[i] = sample(t * cyclesPerSecond, motion: motion);
    }
    return out;
  }

  /// Generates the raw **ADC count array** an MCU would read from the AD8232
  /// (integers in 0..adcLevels‑1), the way a real firmware capture looks.
  List<int> generateAdcWaveform({
    int sampleRate = 250,
    double seconds = 10,
    double motion = 0,
  }) {
    final cyclesPerSecond = heartRateFor(motion) / 60.0;
    final n = (sampleRate * seconds).round();
    final out = List<int>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      final t = i / sampleRate;
      out[i] = sampleAdc(t * cyclesPerSecond, motion: motion).toInt();
    }
    return out;
  }
}

/// Convenience: generate a brand‑new, realistic heartwave array.
///
/// A new random session is created each call (unless a [seed] is given), so the
/// waveform differs every time. Pass a [motion] level (0 = still .. 1 =
/// vigorous), e.g. derived from live gyroscope magnitude, to corrupt the trace
/// with movement artifacts.
///
/// ```dart
/// final wave = generateHeartwave(seconds: 8, sampleRate: 250, motion: 0.3);
/// ```
List<double> generateHeartwave({
  int? seed,
  int sampleRate = 250,
  double seconds = 10,
  double motion = 0,
}) {
  return EcgModel.random(
    seed,
  ).generateWaveform(sampleRate: sampleRate, seconds: seconds, motion: motion);
}

/// Paints a scrolling ECG trace from an [EcgModel]. [progress] is the left edge
/// of the visible window, measured in cardiac cycles.
class EcgWaveformPainter extends CustomPainter {
  EcgWaveformPainter({
    required this.model,
    required this.progress,
    required this.color,
    this.beatsPerScreen = 3.5,
    this.strokeWidth = 2.4,
    this.fill = true,
    this.gain = 0.34,
    this.baseline = 0.6,
    this.motion = 0,
    this.digitized = false,
  });

  final EcgModel model;
  final double progress;
  final Color color;
  final double beatsPerScreen;
  final double strokeWidth;
  final bool fill;
  final double gain;
  final double baseline; // vertical position of the isoelectric line (0..1)
  final double motion; // 0..1 live movement level
  final bool digitized; // render the quantised AD8232 ADC signal

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height * baseline;
    final pxPerMv = size.height * gain;
    final path = Path();
    const samples = 360;

    for (int i = 0; i <= samples; i++) {
      final x = size.width * i / samples;
      final cycles = progress + (i / samples) * beatsPerScreen;
      final double signal;
      if (digitized) {
        // Map the quantised ADC counts back around the baseline.
        signal =
            (model.sampleAdc(cycles, motion: motion) - model.adcMid) /
            model.countsPerMv;
      } else {
        signal = model.sample(cycles, motion: motion);
      }
      final y = midY - signal * pxPerMv;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    if (fill) {
      final fillPath = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.26), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size);
      canvas.drawPath(fillPath, fillPaint);
    }

    final glow = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth + 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawPath(path, glow);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant EcgWaveformPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.model != model ||
      old.motion != motion ||
      old.digitized != digitized;
}

/// Paints a static, multi‑beat ECG strip from the digitised AD8232 ADC counts,
/// mapped onto the report's [axisMin]..[axisMax] count axis.
class EcgStripPainter extends CustomPainter {
  EcgStripPainter({
    required this.model,
    required this.color,
    this.beats = 22,
    this.axisMin = 1000,
    this.axisMax = 3000,
  });

  final EcgModel model;
  final Color color;
  final int beats;
  final double axisMin;
  final double axisMax;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    final total = beats * 30;
    final range = axisMax - axisMin;

    for (int i = 0; i <= total; i++) {
      final x = size.width * i / total;
      final cycles = i / 30.0;
      final counts = model.sampleAdc(cycles);
      final norm = ((counts - axisMin) / range).clamp(0.0, 1.0);
      final y = size.height * (1 - norm);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final glow = Paint()
      ..color = color.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawPath(path, glow);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant EcgStripPainter old) =>
      old.color != color || old.model != model;
}

/// A live, scrolling ECG line simulating the AD8232 → ADC capture. The scroll
/// speed tracks the (motion‑boosted) heart rate, so shaking the phone makes the
/// trace beat faster as well as noisier.
class AnimatedEcgLine extends StatefulWidget {
  const AnimatedEcgLine({
    super.key,
    required this.model,
    this.color = AppColors.accentPink,
    this.beatsPerScreen = 3.5,
    this.fill = true,
    this.motion,
    this.digitized = true,
  });

  final EcgModel model;
  final Color color;
  final double beatsPerScreen;
  final bool fill;

  /// Live movement level (0..1), typically driven by the gyroscope. When it
  /// rises, the trace picks up motion artifacts and the heart rate climbs.
  final ValueListenable<double>? motion;

  /// Render the quantised AD8232 ADC signal (vs. the raw analog model).
  final bool digitized;

  @override
  State<AnimatedEcgLine> createState() => _AnimatedEcgLineState();
}

class _AnimatedEcgLineState extends State<AnimatedEcgLine>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 0.0
        : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final motion = widget.motion?.value ?? 0;
    // Advance phase in cardiac cycles at the current heart rate.
    final cyclesPerSecond = widget.model.heartRateFor(motion) / 60.0;
    _progress.value += cyclesPerSecond * dt;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animation = widget.motion == null
        ? _progress
        : Listenable.merge([_progress, widget.motion!]);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        return CustomPaint(
          painter: EcgWaveformPainter(
            model: widget.model,
            progress: _progress.value,
            color: widget.color,
            beatsPerScreen: widget.beatsPerScreen,
            fill: widget.fill,
            motion: widget.motion?.value ?? 0,
            digitized: widget.digitized,
          ),
          size: Size.infinite,
        );
      },
    );
  }
}
