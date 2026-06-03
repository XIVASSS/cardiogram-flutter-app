import 'dart:async';

import 'package:foundation_models_framework/foundation_models_framework.dart';

import 'ecg_analysis.dart';

/// How the Expert is currently answering.
enum ExpertEngine {
  /// Apple's on-device Foundation Model (Apple Intelligence).
  foundationModel,

  /// Local rule-based fallback used when Apple Intelligence is unavailable.
  onDeviceFallback,
}

/// On-device "ECG Expert".
///
/// Wraps Apple's Foundation Models framework with a session that is grounded in
/// the structured [EcgAnalysis] for the current recording. The report context is
/// re-supplied with every question (not just as session instructions) because
/// the small on-device model otherwise tends to drift away from the real
/// numbers — this keeps every answer tied to *this* patient's strip.
///
/// When Apple Intelligence isn't available (simulator, older OS, or the feature
/// turned off) it transparently falls back to a local responder that reads the
/// same structured analysis, so the feature works everywhere and stays on-topic.
class EcgExpert {
  EcgExpert(this.analysis);

  final EcgAnalysis analysis;

  final FoundationModelsFramework _fm = FoundationModelsFramework.instance;
  LanguageModelSession? _session;
  ExpertEngine _engine = ExpertEngine.onDeviceFallback;
  bool _initialized = false;
  String? _unavailableReason;

  ExpertEngine get engine => _engine;
  String? get unavailableReason => _unavailableReason;

  static const String _persona = '''
You are an on-device cardiology assistant inside the Cardiogram app. You explain a single-lead ECG recording to a layperson in plain, warm language.

Rules:
- Answer ONLY using the "ECG REPORT" data provided in the user's message. Treat those numbers and findings as the absolute source of truth.
- Never invent measurements, rhythms, or values that are not in the report. If the report does not contain something, say so.
- Keep answers to 2–5 sentences unless asked for more detail.
- When something is abnormal, briefly say what it means and the sensible next step.
- When discussing risk, remind the user this is an automated screening, not a diagnosis.
- Never prescribe medication or specific doses.''';

  /// Probe Apple Intelligence and open a session if available.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final availability = await _fm.checkAvailability();
      if (availability.isAvailable) {
        _session = _fm.createSession(
          instructions: _persona,
          guardrailLevel: GuardrailLevel.standard,
        );
        await _session!.prewarm();
        _engine = ExpertEngine.foundationModel;
      } else {
        _engine = ExpertEngine.onDeviceFallback;
        _unavailableReason =
            availability.errorMessage ?? 'Apple Intelligence not available';
      }
    } catch (e) {
      _engine = ExpertEngine.onDeviceFallback;
      _unavailableReason = '$e';
    }
  }

  /// Wraps a question with the full report so the model answers in context.
  String _groundedPrompt(String question) {
    return 'ECG REPORT (the only facts you may use):\n'
        '${analysis.toExpertContext()}\n'
        'Patient question: "$question"\n'
        'Answer the question using only the report above, in 2–5 sentences.';
  }

  /// Stream an answer to [question], token by token.
  Stream<String> ask(String question) async* {
    if (!_initialized) await initialize();

    final session = _session;
    if (_engine == ExpertEngine.foundationModel && session != null) {
      try {
        final stream = session.streamResponse(
          prompt: _groundedPrompt(question),
          options: GenerationOptionsRequest(
            temperature: 0.4,
            maximumResponseTokens: 400,
          ),
        );
        var emittedAnything = false;
        await for (final chunk in stream) {
          if (chunk.hasError) {
            if (!emittedAnything) yield* _fallbackStream(question);
            return;
          }
          final delta = chunk.delta;
          if (delta != null && delta.isNotEmpty) {
            emittedAnything = true;
            yield delta;
          }
        }
        if (!emittedAnything) yield* _fallbackStream(question);
        return;
      } catch (_) {
        yield* _fallbackStream(question);
        return;
      }
    }

    yield* _fallbackStream(question);
  }

  /// Suggested opening questions for the chat UI.
  List<String> get suggestedQuestions => [
        'What does my result mean?',
        analysis.isArrhythmia
            ? 'Is this arrhythmia dangerous?'
            : 'Is my heart rhythm healthy?',
        'What should I do next?',
        'Explain my QT and PR intervals.',
      ];

  Future<void> dispose() async {
    await _session?.dispose();
    _session = null;
  }

  // ---------------------------------------------------------------------
  // Local responder — reads the SAME structured analysis the model would,
  // so even without Apple Intelligence the answers stay tied to the report.
  // ---------------------------------------------------------------------
  Stream<String> _fallbackStream(String question) async* {
    final text = _fallbackAnswer(question);
    for (final word in text.split(' ')) {
      yield '$word ';
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  EcgMetric? _metric(List<String> aliases) {
    for (final m in analysis.metrics) {
      final label = m.label.toLowerCase();
      if (aliases.any(label.contains)) return m;
    }
    return null;
  }

  String _describeMetric(EcgMetric m) {
    final verdict = switch (m.severity) {
      Severity.normal => 'which is within the normal range',
      Severity.borderline => 'which is borderline',
      Severity.abnormal => 'which is outside the normal range',
      Severity.critical => 'which is well outside the normal range',
    };
    return '${m.label} is ${m.value}${m.unit} (normal ${m.normalRange}), $verdict';
  }

  String get _abnormalSummary {
    final flagged = analysis.metrics
        .where((m) => m.severity != Severity.normal)
        .map((m) => '${m.label} ${m.value}${m.unit}')
        .toList();
    if (flagged.isEmpty) return 'Every measured value is within its normal range.';
    return 'The values outside the normal range are: ${flagged.join(', ')}.';
  }

  String _fallbackAnswer(String question) {
    final q = question.toLowerCase();
    final a = analysis;
    final conf = (a.confidence * 100).round();

    // --- Specific metric look-ups ---------------------------------------
    if (_mentions(q, ['qt', 'qtc', 'repolar'])) {
      final m = _metric(['qt']);
      if (m != null) {
        return 'On your report, ${_describeMetric(m)}. The QTc is the time your '
            'heart muscle takes to reset between beats; a longer-than-normal QTc '
            'can raise the risk of unstable rhythms, which is why it is tracked.';
      }
    }
    if (_mentions(q, ['pr interval', 'pr ', 'av node', 'av block', 'conduction'])) {
      final m = _metric(['pr']);
      if (m != null) {
        return 'Your report shows ${_describeMetric(m)}. The PR interval measures '
            'how long the signal takes to travel from the atria through the AV '
            'node to the ventricles. ${a.rhythm.toLowerCase().contains('block') ? a.rhythmDetail : ''}'
                .trim();
      }
    }
    if (_mentions(q, ['qrs', 'ventric'])) {
      final m = _metric(['qrs']);
      if (m != null) {
        return 'Your report lists ${_describeMetric(m)}. The QRS duration is how '
            'quickly the ventricles (the main pumping chambers) depolarise; a wide '
            'QRS suggests the impulse is travelling abnormally.';
      }
    }
    if (_mentions(q, ['hrv', 'variability', 'sdnn'])) {
      final m = _metric(['hrv', 'sdnn']);
      if (m != null) {
        return 'Your heart-rate variability on this strip is ${_describeMetric(m)}. '
            'It reflects how much the spacing between beats changes; high values on '
            'a short strip usually point to an irregular rhythm.';
      }
    }
    if (_mentions(q, ['amplitude', 'r wave', 'r-wave', 'voltage'])) {
      final m = _metric(['amplitude', 'r-wave']);
      if (m != null) {
        return 'Your report shows ${_describeMetric(m)}. The R-wave amplitude is the '
            'height of the main spike of each beat on this single lead.';
      }
    }
    if (_mentions(q, ['rate', 'bpm', 'pulse', 'fast', 'slow', 'beats per'])) {
      return 'Your average heart rate on this recording is ${a.heartRate} bpm '
          '(normal resting is 60–100). ${a.patientSummary}';
    }

    // --- Intent-based answers -------------------------------------------
    if (_mentions(q, ['next', 'should i', 'do now', 'what do i do', 'advice', 'recommend'])) {
      return switch (a.risk) {
        RiskLevel.high =>
          'Because this strip flags ${a.rhythm.toLowerCase()} at an elevated risk '
              'level, the sensible next step is to share this report with a doctor '
              'soon — and seek urgent care if you feel chest pain, severe '
              'breathlessness, fainting or palpitations. This is a single-lead '
              'screening, not a diagnosis.',
        RiskLevel.moderate =>
          'Your rhythm reads as ${a.rhythm.toLowerCase()} (moderate risk). It is '
              'reasonable to repeat the recording at rest, note any symptoms, and '
              'mention it at your next check-up. Seek care sooner if you feel unwell.',
        RiskLevel.low =>
          'Everything on this strip looks healthy, so no specific action is needed '
              'beyond your normal routine. Recording periodically helps build a '
              'baseline you can compare against later.',
      };
    }
    if (_mentions(q, ['danger', 'serious', 'risk', 'worry', 'worried', 'scared', 'bad', 'afraid'])) {
      return 'The overall risk from this recording is ${a.riskLabel.toLowerCase()}, '
          'based on a diagnosis of ${a.rhythm.toLowerCase()} ($conf% confidence). '
          '${a.patientSummary} Keep in mind this is an automated single-lead screen, '
          'so a clinician\'s review is the way to confirm anything.';
    }
    if (_mentions(q, ['why', 'cause', 'reason', 'how come', 'because'])) {
      return 'This rhythm was classified as ${a.rhythm.toLowerCase()} because: '
          '${a.rhythmDetail} $_abnormalSummary';
    }
    if (_mentions(q, ['symptom', 'feel', 'dizzy', 'chest', 'palpitation', 'breath', 'faint', 'tired'])) {
      return a.risk == RiskLevel.low
          ? 'This strip itself looks healthy, but symptoms matter more than a single '
              'reading. If you feel palpitations, dizziness, chest discomfort or '
              'breathlessness, record again during the symptom and tell a clinician.'
          : 'With ${a.rhythm.toLowerCase()} on this strip, symptoms like palpitations, '
              'dizziness, chest discomfort, breathlessness or fainting are worth taking '
              'seriously — record again if they happen and seek medical advice.';
    }
    if (_mentions(q, ['exercise', 'coffee', 'caffeine', 'alcohol', 'lifestyle', 'diet', 'sleep', 'stress', 'prevent'])) {
      return 'General heart-healthy habits — regular activity, good sleep, limiting '
          'excess caffeine and alcohol, and managing stress — support a steady '
          'rhythm. For your specific result (${a.rhythm.toLowerCase()}), a clinician '
          'can give tailored guidance. ${a.patientSummary}';
    }
    if (_mentions(q, ['arrhythmia', 'rhythm', 'afib', 'a-fib', 'fibrillation', 'flutter', 'pvc', 'pac', 'tachy', 'brady', 'normal', 'healthy', 'sinus'])) {
      return a.isArrhythmia
          ? 'Your recording was classified as ${a.rhythm} '
              '(${a.arrhythmiaCategory.toLowerCase()} type, $conf% confidence). '
              '${a.rhythmDetail} ${a.patientSummary}'
          : 'Good news — the rhythm reads as ${a.rhythm.toLowerCase()} with no '
              'arrhythmia detected ($conf% confidence). ${a.rhythmDetail} '
              '${a.patientSummary}';
    }
    if (_mentions(q, ['finding', 'detail', 'list', 'everything', 'all', 'full', 'breakdown'])) {
      final lines = a.findings.map((f) => '• ${f.title}: ${f.detail}').join('\n');
      return 'Here is what I found on your strip:\n$lines\n\nOverall risk: '
          '${a.riskLabel.toLowerCase()}.';
    }

    // --- Default: a real, grounded summary of THIS report ----------------
    return 'Here is your ECG in a nutshell: the rhythm reads as ${a.rhythm.toLowerCase()} '
        '($conf% confidence) at ${a.heartRate} bpm, and the overall risk is '
        '${a.riskLabel.toLowerCase()}. $_abnormalSummary ${a.patientSummary} '
        'You can ask me about your heart rate, PR/QRS/QT intervals, the findings, '
        'or what to do next.';
  }

  bool _mentions(String q, List<String> keywords) =>
      keywords.any(q.contains);
}
