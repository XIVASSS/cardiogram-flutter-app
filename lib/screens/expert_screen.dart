import 'package:flutter/material.dart';

import '../services/ecg_analysis.dart';
import '../services/ecg_expert.dart';
import '../services/speech_input.dart';
import '../theme/app_theme.dart';
import '../widgets/ios_status_bar.dart';

/// Conversational, voice-enabled ECG Expert.
///
/// Speak or type a question and an on-device model (Apple Foundation Models when
/// available, otherwise a local responder) answers using the structured
/// [EcgAnalysis] for this recording.
class ExpertScreen extends StatefulWidget {
  const ExpertScreen({super.key, required this.analysis});

  final EcgAnalysis analysis;

  @override
  State<ExpertScreen> createState() => _ExpertScreenState();
}

class _ChatMessage {
  _ChatMessage({required this.fromUser, this.text = ''});
  final bool fromUser;
  String text;
}

class _ExpertScreenState extends State<ExpertScreen> {
  late final EcgExpert _expert = EcgExpert(widget.analysis);
  final SpeechInput _speech = SpeechInput();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  final List<_ChatMessage> _messages = [];
  bool _busy = false;
  bool _listening = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _expert.initialize();
    await _speech.initialize(
      onStatus: (s) {
        if (mounted && (s == 'done' || s == 'notListening')) {
          setState(() => _listening = false);
        }
      },
    );
    if (!mounted) return;
    setState(() => _ready = true);
    // Greet with the report summary up front.
    final greeting = _expert.engine == ExpertEngine.foundationModel
        ? 'Hi — I\'ve reviewed your ECG with Apple Intelligence on this device. '
            '${widget.analysis.patientSummary} Ask me anything about it.'
        : 'Hi — I\'ve reviewed your ECG on-device. '
            '${widget.analysis.patientSummary} Ask me anything about it.';
    setState(() => _messages.add(_ChatMessage(fromUser: false, text: greeting)));
  }

  @override
  void dispose() {
    _expert.dispose();
    _speech.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent + 120,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send(String raw) async {
    final question = raw.trim();
    if (question.isEmpty || _busy) return;
    _input.clear();
    final answer = _ChatMessage(fromUser: false);
    setState(() {
      _messages.add(_ChatMessage(fromUser: true, text: question));
      _messages.add(answer);
      _busy = true;
    });
    _scrollToBottom();

    try {
      await for (final delta in _expert.ask(question)) {
        if (!mounted) return;
        setState(() => answer.text += delta);
        _scrollToBottom();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleMic() async {
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }
    if (!_speech.isAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Microphone or speech recognition is unavailable.'),
        ),
      );
      return;
    }
    setState(() => _listening = true);
    await _speech.start(
      onPartial: (t) => setState(() => _input.text = t),
      onFinal: (t) {
        setState(() => _listening = false);
        if (t.trim().isNotEmpty) _send(t);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          const IosStatusBar(),
          _header(),
          Expanded(
            child: !_ready
                ? const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.accentPink,
                      strokeWidth: 2.4,
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _Bubble(message: _messages[i]),
                  ),
          ),
          if (_ready && _messages.length <= 1) _suggestions(),
          _composer(),
        ],
      ),
    );
  }

  Widget _header() {
    final fm = _expert.engine == ExpertEngine.foundationModel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 20, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(
              Icons.chevron_left_rounded,
              color: AppColors.textPrimary,
              size: 30,
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ECG Expert',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: AppColors.connectedGreen,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    fm ? 'Apple Intelligence · on-device' : 'On-device model',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const Spacer(),
          Icon(
            Icons.monitor_heart_rounded,
            color: AppColors.accentPink.withValues(alpha: 0.9),
            size: 24,
          ),
        ],
      ),
    );
  }

  Widget _suggestions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final q in _expert.suggestedQuestions)
            InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => _send(q),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Text(
                  q,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _composer() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        12 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 4,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
              textInputAction: TextInputAction.send,
              onSubmitted: _send,
              decoration: InputDecoration(
                hintText: _listening ? 'Listening…' : 'Ask the ECG Expert…',
                hintStyle: const TextStyle(color: AppColors.textTertiary),
                filled: true,
                fillColor: AppColors.card,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _MicButton(active: _listening, onTap: _toggleMic),
          const SizedBox(width: 8),
          _SendButton(
            enabled: !_busy,
            onTap: () => _send(_input.text),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final _ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final user = message.fromUser;
    final empty = message.text.isEmpty;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          gradient: user
              ? const LinearGradient(
                  colors: [AppColors.accentPink, AppColors.accentPinkDark],
                )
              : null,
          color: user ? null : AppColors.card,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(user ? 18 : 4),
            bottomRight: Radius.circular(user ? 4 : 18),
          ),
          border: user ? null : Border.all(color: AppColors.divider),
        ),
        child: empty
            ? const SizedBox(
                width: 26,
                height: 16,
                child: _TypingDots(),
              )
            : Text(
                message.text,
                style: TextStyle(
                  color: user ? Colors.white : AppColors.textPrimary,
                  fontSize: 14.5,
                  height: 1.4,
                ),
              ),
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = (_c.value + i * 0.2) % 1.0;
            final o = 0.35 + 0.65 * (1 - (t - 0.5).abs() * 2).clamp(0.0, 1.0);
            return Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
              child: Opacity(
                opacity: o,
                child: const CircleAvatar(
                  radius: 3,
                  backgroundColor: AppColors.textSecondary,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: active ? AppColors.accentPink : AppColors.card,
          shape: BoxShape.circle,
          border: Border.all(
            color: active ? AppColors.accentPink : AppColors.divider,
          ),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: AppColors.accentPink.withValues(alpha: 0.5),
                    blurRadius: 16,
                  ),
                ]
              : null,
        ),
        child: Icon(
          active ? Icons.mic_rounded : Icons.mic_none_rounded,
          color: active ? Colors.white : AppColors.textSecondary,
          size: 22,
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: enabled ? onTap : null,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.accentPink, AppColors.accentPinkDark],
          ),
          shape: BoxShape.circle,
        ),
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: const Icon(
            Icons.arrow_upward_rounded,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }
}
