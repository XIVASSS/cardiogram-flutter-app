import 'package:speech_to_text/speech_to_text.dart';

/// Thin wrapper around [SpeechToText] for on-device dictation.
///
/// Prefers Apple's on-device recogniser (no audio leaves the phone) and surfaces
/// partial transcripts live so the Expert chat can show what you're saying as
/// you speak.
class SpeechInput {
  final SpeechToText _speech = SpeechToText();
  bool _available = false;
  bool _initialized = false;

  bool get isAvailable => _available;
  bool get isListening => _speech.isListening;

  /// Request permission and probe recogniser availability. Safe to call twice.
  Future<bool> initialize({void Function(String status)? onStatus}) async {
    if (_initialized) return _available;
    _initialized = true;
    try {
      _available = await _speech.initialize(
        onStatus: (s) => onStatus?.call(s),
        onError: (_) {},
      );
    } catch (_) {
      _available = false;
    }
    return _available;
  }

  /// Start listening. [onPartial] fires with the running transcript; [onFinal]
  /// fires once with the completed utterance.
  Future<void> start({
    required void Function(String transcript) onPartial,
    required void Function(String transcript) onFinal,
  }) async {
    if (!_available) return;
    await _speech.listen(
      onResult: (result) {
        if (result.finalResult) {
          onFinal(result.recognizedWords);
        } else {
          onPartial(result.recognizedWords);
        }
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        onDevice: true,
        listenMode: ListenMode.dictation,
        cancelOnError: true,
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> stop() async {
    if (_speech.isListening) await _speech.stop();
  }

  Future<void> cancel() async {
    if (_speech.isListening) await _speech.cancel();
  }
}
