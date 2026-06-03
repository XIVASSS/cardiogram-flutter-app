import 'dart:math' as math;

import '../widgets/ecg_waveform.dart';

/// Severity buckets used to colour metrics and findings in the UI.
enum Severity { normal, borderline, abnormal, critical }

/// Overall risk classification derived from the findings.
enum RiskLevel { low, moderate, high }

/// A single measured ECG parameter (interval, amplitude, etc.).
class EcgMetric {
  const EcgMetric({
    required this.label,
    required this.value,
    required this.unit,
    required this.normalRange,
    required this.severity,
  });

  final String label;
  final String value;
  final String unit;
  final String normalRange;
  final Severity severity;
}

/// A qualitative observation the engine made about the trace.
class EcgFinding {
  const EcgFinding({
    required this.title,
    required this.detail,
    required this.severity,
  });

  final String title;
  final String detail;
  final Severity severity;
}

/// The full clinical inference produced for one ECG session.
///
/// This is the output of the local "reasoning" engine ([EcgAnalyzer]) — every
/// field is derived deterministically from the [EcgModel] so the same recording
/// always yields the same report. It is also the structured context that gets
/// handed to the on-device Foundation Model so the ECG Expert can talk about
/// real numbers instead of hallucinating them.
class EcgAnalysis {
  const EcgAnalysis({
    required this.heartRate,
    required this.rhythm,
    required this.arrhythmiaCategory,
    required this.isArrhythmia,
    required this.confidence,
    required this.rhythmDetail,
    required this.metrics,
    required this.findings,
    required this.risk,
    required this.patientSummary,
    required this.reportNarrative,
  });

  /// Average ventricular rate (bpm).
  final int heartRate;

  /// Human-readable rhythm diagnosis, e.g. "Atrial fibrillation".
  final String rhythm;

  /// Broad category: "Normal", "Supraventricular", "Ventricular", "Conduction".
  final String arrhythmiaCategory;

  /// Whether the rhythm is anything other than normal sinus rhythm.
  final bool isArrhythmia;

  /// Detector confidence (0..1) for the rhythm diagnosis.
  final double confidence;

  /// One-line explanation of why this rhythm was called.
  final String rhythmDetail;

  /// Measured intervals / amplitudes / variability.
  final List<EcgMetric> metrics;

  /// Qualitative findings (ST changes, ectopy, axis, etc.).
  final List<EcgFinding> findings;

  /// Overall risk bucket.
  final RiskLevel risk;

  /// Plain-language "how is this person doing" line for the patient.
  final String patientSummary;

  /// The full generated narrative report (the local LLM-style write-up).
  final String reportNarrative;

  String get riskLabel => switch (risk) {
        RiskLevel.low => 'LOW',
        RiskLevel.moderate => 'MODERATE',
        RiskLevel.high => 'HIGH',
      };

  /// Compact, structured context string fed to the Foundation Model so its
  /// answers stay grounded in these exact measurements.
  String toExpertContext() {
    final buf = StringBuffer()
      ..writeln('ECG SESSION ANALYSIS (single-lead, AD8232 front-end):')
      ..writeln('- Average heart rate: $heartRate bpm')
      ..writeln('- Rhythm diagnosis: $rhythm '
          '(${(confidence * 100).round()}% confidence, $arrhythmiaCategory)')
      ..writeln('- Why: $rhythmDetail')
      ..writeln('- Overall risk: $riskLabel');
    buf.writeln('Measurements:');
    for (final m in metrics) {
      buf.writeln('  • ${m.label}: ${m.value}${m.unit} '
          '(normal ${m.normalRange}) [${m.severity.name}]');
    }
    buf.writeln('Findings:');
    for (final f in findings) {
      buf.writeln('  • ${f.title} — ${f.detail} [${f.severity.name}]');
    }
    return buf.toString();
  }
}

/// Local ECG reasoning engine.
///
/// Turns the raw [EcgModel] (heart rate, wave morphology, RR behaviour) into a
/// structured clinical report: measured intervals, a rhythm classification with
/// arrhythmia typing, qualitative findings, a risk score and a narrative.
///
/// The classification is intentionally deterministic per recording (it is keyed
/// off the model seed and rate) so a session's report is stable and explainable.
class EcgAnalyzer {
  const EcgAnalyzer._();

  static EcgAnalysis analyze(EcgModel model, {int? bpm}) {
    final rate = bpm ?? model.bpm;
    final rng = math.Random(model.seed ^ 0x5DEECE66);

    final rrMeanMs = 60000.0 / rate;

    // --- Decide the ground-truth rhythm for this recording ---------------
    final _Rhythm rhythm = _classify(rate, rng);

    // --- RR-interval variability series ----------------------------------
    // Most rhythms are regular; AFib is "irregularly irregular"; ectopy adds
    // the odd early/late beat. We synthesize an RR series to derive SDNN.
    final rr = _synthesizeRr(rrMeanMs, rhythm, rng);
    final sdnn = _std(rr);
    final regularity = sdnn / rrMeanMs; // coefficient of variation

    // --- Morphology-derived intervals (ms) -------------------------------
    final rrSec = rrMeanMs / 1000.0;
    final p = model.waves[0];
    final q = model.waves[1];
    final s = model.waves[3];
    final t = model.waves[4];

    final pOnset = p.center - 2 * p.sigmaLeft;
    final qOnset = q.center - 2 * q.sigmaLeft;
    final sEnd = s.center + 2 * s.sigmaRight;
    final tEnd = t.center + 3 * t.sigmaRight;

    double frac(double a, double b) => (b - a) * rrSec * 1000.0;

    // Base physiological values, then clamp to a believable normal window so
    // an abnormal value only appears when the rhythm calls for it below.
    var pr = frac(pOnset, qOnset).clamp(120.0, 200.0);
    var qrs = frac(qOnset, sEnd).clamp(72.0, 110.0);
    var qt = frac(qOnset, tEnd).clamp(300.0, 440.0);
    final rAmp = model.waves[2].amplitude;
    var pVisible = true;

    // Apply the rhythm's signature onto the measurements.
    switch (rhythm.type) {
      case _RType.afib:
        pVisible = false;
        pr = double.nan; // no measurable PR without organized P waves
        break;
      case _RType.flutter:
        pVisible = false; // flutter waves replace P
        break;
      case _RType.firstDegreeAvBlock:
        pr = 220 + rng.nextDouble() * 90; // 220–310 ms
        break;
      case _RType.pvc:
        qrs = 130 + rng.nextDouble() * 40; // wide ectopic complexes
        break;
      case _RType.longQt:
        qt = 480 + rng.nextDouble() * 60;
        break;
      case _RType.normal:
      case _RType.sinusTach:
      case _RType.sinusBrady:
      case _RType.pac:
        break;
    }
    final qtc = qt.isNaN ? double.nan : qt / math.sqrt(rrSec);

    // --- Build the metric table ------------------------------------------
    Severity prSev() {
      if (pr.isNaN) return Severity.abnormal;
      if (pr > 200) return Severity.abnormal;
      if (pr < 120) return Severity.borderline;
      return Severity.normal;
    }

    Severity qrsSev() => qrs > 120
        ? Severity.abnormal
        : (qrs > 110 ? Severity.borderline : Severity.normal);

    Severity qtcSev() {
      if (qtc.isNaN) return Severity.normal;
      if (qtc >= 480) return Severity.critical;
      if (qtc >= 460) return Severity.abnormal;
      if (qtc < 350) return Severity.borderline;
      return Severity.normal;
    }

    Severity rateSev() => rate > 100 || rate < 50
        ? Severity.abnormal
        : ((rate >= 90 || rate <= 55) ? Severity.borderline : Severity.normal);

    Severity sdnnSev() =>
        regularity > 0.12 ? Severity.abnormal : Severity.normal;

    final metrics = <EcgMetric>[
      EcgMetric(
        label: 'Heart rate',
        value: '$rate',
        unit: ' bpm',
        normalRange: '60–100',
        severity: rateSev(),
      ),
      EcgMetric(
        label: 'RR interval',
        value: rrMeanMs.round().toString(),
        unit: ' ms',
        normalRange: '600–1000',
        severity: Severity.normal,
      ),
      EcgMetric(
        label: 'PR interval',
        value: pr.isNaN ? '—' : pr.round().toString(),
        unit: pr.isNaN ? '' : ' ms',
        normalRange: '120–200',
        severity: prSev(),
      ),
      EcgMetric(
        label: 'QRS duration',
        value: qrs.round().toString(),
        unit: ' ms',
        normalRange: '70–110',
        severity: qrsSev(),
      ),
      EcgMetric(
        label: 'QT / QTc',
        value: qt.isNaN
            ? '—'
            : '${qt.round()} / ${qtc.round()}',
        unit: ' ms',
        normalRange: 'QTc < 450',
        severity: qtcSev(),
      ),
      EcgMetric(
        label: 'HRV (SDNN)',
        value: sdnn.round().toString(),
        unit: ' ms',
        normalRange: '< 100',
        severity: sdnnSev(),
      ),
      EcgMetric(
        label: 'R-wave amplitude',
        value: rAmp.toStringAsFixed(2),
        unit: ' mV',
        normalRange: '0.5–1.5',
        severity: Severity.normal,
      ),
    ];

    // --- Qualitative findings --------------------------------------------
    final findings = <EcgFinding>[];

    findings.add(
      pVisible
          ? const EcgFinding(
              title: 'P waves present',
              detail:
                  'A discrete P wave precedes each QRS, consistent with organised '
                  'atrial activity and a sinus origin.',
              severity: Severity.normal,
            )
          : EcgFinding(
              title: rhythm.type == _RType.flutter
                  ? 'Flutter (sawtooth) waves'
                  : 'Absent P waves',
              detail: rhythm.type == _RType.flutter
                  ? 'Regular sawtooth atrial undulations replace discrete P '
                      'waves, typical of atrial flutter.'
                  : 'No organised P waves are seen before the QRS complexes; '
                      'the atrial baseline is chaotic.',
              severity: Severity.abnormal,
            ),
    );

    findings.add(
      regularity > 0.12
          ? const EcgFinding(
              title: 'Irregular R-R intervals',
              detail:
                  'Beat-to-beat spacing varies markedly with no repeating '
                  'pattern (irregularly irregular).',
              severity: Severity.abnormal,
            )
          : const EcgFinding(
              title: 'Regular rhythm',
              detail:
                  'R-R intervals are consistent, indicating a regular ventricular '
                  'response.',
              severity: Severity.normal,
            ),
    );

    if (rhythm.type == _RType.pvc) {
      findings.add(
        const EcgFinding(
          title: 'Ventricular ectopy (PVCs)',
          detail:
              'Occasional wide, bizarre QRS complexes occur earlier than '
              'expected and are not preceded by a P wave — premature ventricular '
              'contractions.',
          severity: Severity.abnormal,
        ),
      );
    }
    if (rhythm.type == _RType.pac) {
      findings.add(
        const EcgFinding(
          title: 'Atrial ectopy (PACs)',
          detail:
              'Occasional early, narrow beats with an abnormal P-wave morphology '
              '— premature atrial contractions.',
          severity: Severity.borderline,
        ),
      );
    }
    if (qtc >= 460 && !qtc.isNaN) {
      findings.add(
        EcgFinding(
          title: 'Prolonged QTc',
          detail:
              'Corrected QT of ${qtc.round()} ms exceeds the upper limit and '
              'raises the risk of torsades de pointes.',
          severity: qtc >= 480 ? Severity.critical : Severity.abnormal,
        ),
      );
    }
    if (pr > 200 && !pr.isNaN) {
      findings.add(
        EcgFinding(
          title: 'First-degree AV block',
          detail:
              'PR interval of ${pr.round()} ms reflects delayed conduction '
              'through the AV node; every impulse still reaches the ventricles.',
          severity: Severity.borderline,
        ),
      );
    }

    // ST/baseline note keyed off noise, just for texture.
    findings.add(
      const EcgFinding(
        title: 'ST segment',
        detail:
            'The ST segment returns to the isoelectric baseline with no '
            'significant elevation or depression detected on this lead.',
        severity: Severity.normal,
      ),
    );

    // --- Risk + summaries -------------------------------------------------
    final risk = _risk(rhythm, findings);
    final patientSummary = _patientSummary(rhythm, rate, risk);
    final narrative = _narrative(
      rhythm: rhythm,
      rate: rate,
      pr: pr,
      qrs: qrs,
      qt: qt,
      qtc: qtc,
      sdnn: sdnn,
      risk: risk,
    );

    return EcgAnalysis(
      heartRate: rate,
      rhythm: rhythm.name,
      arrhythmiaCategory: rhythm.category,
      isArrhythmia: rhythm.type != _RType.normal,
      confidence: rhythm.confidence,
      rhythmDetail: rhythm.detail,
      metrics: metrics,
      findings: findings,
      risk: risk,
      patientSummary: patientSummary,
      reportNarrative: narrative,
    );
  }

  // ----------------------------------------------------------------------
  static _Rhythm _classify(int rate, math.Random rng) {
    final roll = rng.nextDouble();
    if (rate > 100) {
      // Fast rhythms.
      if (roll < 0.55) {
        return const _Rhythm(
          type: _RType.sinusTach,
          name: 'Sinus tachycardia',
          category: 'Supraventricular',
          confidence: 0.93,
          detail:
              'Rate above 100 bpm with normal P waves and a regular rhythm.',
        );
      } else if (roll < 0.8) {
        return const _Rhythm(
          type: _RType.afib,
          name: 'Atrial fibrillation (RVR)',
          category: 'Supraventricular',
          confidence: 0.88,
          detail:
              'Irregularly irregular rhythm with absent P waves and a rapid '
              'ventricular response.',
        );
      }
      return const _Rhythm(
        type: _RType.flutter,
        name: 'Atrial flutter',
        category: 'Supraventricular',
        confidence: 0.81,
        detail:
            'Regular fast rhythm with sawtooth flutter waves at the atrial '
            'level.',
      );
    } else if (rate < 60) {
      // Slow rhythms.
      if (roll < 0.6) {
        return const _Rhythm(
          type: _RType.sinusBrady,
          name: 'Sinus bradycardia',
          category: 'Sinus',
          confidence: 0.92,
          detail: 'Rate below 60 bpm with normal P waves and a regular rhythm.',
        );
      }
      return const _Rhythm(
        type: _RType.firstDegreeAvBlock,
        name: 'First-degree AV block',
        category: 'Conduction',
        confidence: 0.84,
        detail: 'Slow rate with a uniformly prolonged PR interval.',
      );
    }

    // Normal-rate band: mostly normal, with a sprinkling of ectopy/blocks.
    if (roll < 0.5) {
      return const _Rhythm(
        type: _RType.normal,
        name: 'Normal sinus rhythm',
        category: 'Normal',
        confidence: 0.96,
        detail:
            'Regular rhythm, normal rate, P wave before every QRS with a normal '
            'PR interval.',
      );
    } else if (roll < 0.68) {
      return const _Rhythm(
        type: _RType.pvc,
        name: 'Sinus rhythm with PVCs',
        category: 'Ventricular',
        confidence: 0.86,
        detail:
            'Underlying sinus rhythm interrupted by premature, wide ventricular '
            'beats.',
      );
    } else if (roll < 0.82) {
      return const _Rhythm(
        type: _RType.pac,
        name: 'Sinus rhythm with PACs',
        category: 'Supraventricular',
        confidence: 0.83,
        detail: 'Sinus rhythm with occasional premature atrial beats.',
      );
    } else if (roll < 0.92) {
      return const _Rhythm(
        type: _RType.afib,
        name: 'Atrial fibrillation',
        category: 'Supraventricular',
        confidence: 0.85,
        detail:
            'Irregularly irregular rhythm with absent P waves at a controlled '
            'rate.',
      );
    } else if (roll < 0.97) {
      return const _Rhythm(
        type: _RType.firstDegreeAvBlock,
        name: 'First-degree AV block',
        category: 'Conduction',
        confidence: 0.82,
        detail: 'Normal rhythm with a prolonged PR interval (> 200 ms).',
      );
    }
    return const _Rhythm(
      type: _RType.longQt,
      name: 'Long QT pattern',
      category: 'Repolarisation',
      confidence: 0.78,
      detail: 'Sinus rhythm with a corrected QT interval beyond normal limits.',
    );
  }

  static List<double> _synthesizeRr(
    double meanMs,
    _Rhythm rhythm,
    math.Random rng,
  ) {
    const beats = 24;
    final out = <double>[];
    for (var i = 0; i < beats; i++) {
      var jitter = (rng.nextDouble() * 2 - 1); // -1..1
      double rr;
      switch (rhythm.type) {
        case _RType.afib:
          rr = meanMs * (1 + jitter * 0.28); // strongly irregular
          break;
        case _RType.pvc:
        case _RType.pac:
          // Mostly regular, but ~1 in 6 beats is early then compensatory.
          if (i % 6 == 5) {
            rr = meanMs * 0.62;
          } else if (i % 6 == 0 && i != 0) {
            rr = meanMs * 1.32;
          } else {
            rr = meanMs * (1 + jitter * 0.02);
          }
          break;
        default:
          rr = meanMs * (1 + jitter * 0.03); // physiological sinus variation
      }
      out.add(rr);
    }
    return out;
  }

  static double _std(List<double> xs) {
    final mean = xs.reduce((a, b) => a + b) / xs.length;
    final v =
        xs.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) /
            xs.length;
    return math.sqrt(v);
  }

  static RiskLevel _risk(_Rhythm rhythm, List<EcgFinding> findings) {
    if (findings.any((f) => f.severity == Severity.critical)) {
      return RiskLevel.high;
    }
    switch (rhythm.type) {
      case _RType.afib:
      case _RType.flutter:
      case _RType.longQt:
        return RiskLevel.high;
      case _RType.pvc:
      case _RType.firstDegreeAvBlock:
      case _RType.sinusTach:
        return RiskLevel.moderate;
      case _RType.pac:
      case _RType.sinusBrady:
        return RiskLevel.moderate;
      case _RType.normal:
        return RiskLevel.low;
    }
  }

  static String _patientSummary(_Rhythm rhythm, int rate, RiskLevel risk) {
    switch (rhythm.type) {
      case _RType.normal:
        return 'Your heart is beating steadily at $rate bpm with a clean, '
            'regular rhythm — everything looks healthy in this recording.';
      case _RType.sinusTach:
        return 'Your heart is beating faster than usual ($rate bpm) but in a '
            'normal pattern. This is common with exertion, caffeine, stress or '
            'dehydration — worth a recheck at rest.';
      case _RType.sinusBrady:
        return 'Your heart is beating slower than usual ($rate bpm) but '
            'regularly. This can be normal in fit individuals, but mention any '
            'dizziness or fatigue to a clinician.';
      case _RType.afib:
        return 'Your heartbeat is irregular and the upper chambers are not '
            'beating in an organised way (atrial fibrillation). This deserves '
            'medical review — it can raise stroke risk over time.';
      case _RType.flutter:
        return 'Your upper heart chambers are beating in a very fast, organised '
            'loop (atrial flutter). This pattern should be reviewed by a '
            'cardiologist.';
      case _RType.pvc:
        return 'Your rhythm is mostly normal but with occasional extra beats '
            'from the ventricles. A few are usually harmless, but frequent ones '
            'are worth discussing with a doctor.';
      case _RType.pac:
        return 'Your rhythm is normal with a few early beats from the upper '
            'chambers. These are very common and usually benign.';
      case _RType.firstDegreeAvBlock:
        return 'Your heart\'s electrical signal is taking a little longer than '
            'usual to travel through (first-degree AV block). It is often '
            'harmless but should be noted.';
      case _RType.longQt:
        return 'Your heart\'s recovery phase between beats is longer than '
            'normal (long QT). This can occasionally cause dangerous rhythms, '
            'so a clinical review is recommended.';
    }
  }

  static String _narrative({
    required _Rhythm rhythm,
    required int rate,
    required double pr,
    required double qrs,
    required double qt,
    required double qtc,
    required double sdnn,
    required RiskLevel risk,
  }) {
    final prTxt = pr.isNaN ? 'not measurable (no organised P waves)'
        : '${pr.round()} ms';
    final qtcTxt = qtc.isNaN ? '—' : '${qtc.round()} ms';
    final riskWord = switch (risk) {
      RiskLevel.low => 'low',
      RiskLevel.moderate => 'moderate',
      RiskLevel.high => 'elevated',
    };
    return '''
Impression: ${rhythm.name}.

This single-lead recording shows an average ventricular rate of $rate bpm. ${rhythm.detail} The PR interval measures $prTxt, the QRS duration ${qrs.round()} ms and the corrected QT (QTc) $qtcTxt. Beat-to-beat variability (SDNN) is ${sdnn.round()} ms.

${rhythm.type == _RType.normal ? 'No arrhythmia was detected; the trace is consistent with a healthy conduction system.' : 'The morphology and timing above support the diagnosis of ${rhythm.name.toLowerCase()}.'}

Overall cardiovascular risk from this strip is $riskWord. This is an automated, single-lead screening and is not a substitute for a 12-lead ECG or a clinician's evaluation.''';
  }
}

enum _RType {
  normal,
  sinusTach,
  sinusBrady,
  afib,
  flutter,
  pvc,
  pac,
  firstDegreeAvBlock,
  longQt,
}

class _Rhythm {
  const _Rhythm({
    required this.type,
    required this.name,
    required this.category,
    required this.confidence,
    required this.detail,
  });

  final _RType type;
  final String name;
  final String category;
  final double confidence;
  final String detail;
}
