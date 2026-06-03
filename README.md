# Cardiogram

A Flutter mobile app that recreates the **Cardiogram** portable‑ECG companion UI — a heart‑rate / ECG monitor with a live waveform, session recording, and a post‑session report.

Design inspired by the [Cardiogram portable ECG device](https://www.instructables.com/Cardiogram-a-Portable-ECG-Device-for-Daily-Use-on-/).

## Screens

| Home | ECG / Session | Session Report |
| --- | --- | --- |
| "Check my Heart Rate" landing with connection status, history CTA, and quick links. | Live, animated ECG trace with a real‑time BPM readout and a Session control. | Post‑session summary with a blue ECG chart, average BPM, pattern detection, and activity rings. |

## Features

- Animated, ECG‑accurate waveform (custom `CustomPainter` rendering PQRST complexes) with a soft neon glow.
- Faux iOS status bar with a green "Dynamic Island" connected indicator.
- Apple‑activity‑style concentric progress rings (animated).
- Live BPM readout that subtly fluctuates while a session is active.
- Dark theme using the Inter typeface (via `google_fonts`).

## Project structure

```
lib/
  main.dart                     # App entry + theme wiring
  theme/app_theme.dart          # Colors, typography, ThemeData
  widgets/
    ios_status_bar.dart         # Faux iOS status bar + Dynamic Island pill
    ecg_waveform.dart           # ECG signal generator + painters + animated line
    progress_rings.dart         # Animated activity rings
  screens/
    home_screen.dart            # "Check my Heart Rate"
    ecg_screen.dart             # Live ECG / Session
    report_screen.dart          # Session Report
```

## Running

```bash
flutter pub get
flutter run            # pick an iOS Simulator / Android emulator / device
```

### Preview a specific screen

The app starts on the Home screen. To jump straight to a screen (useful for screenshots):

```bash
flutter run --dart-define=START=ecg      # ECG / Session screen
flutter run --dart-define=START=report   # Session Report screen
```

## Notes

- The in‑app status bar is a marketing‑style mock to match the reference design; on a physical device it sits beneath the real OS status bar.
- Heart‑rate values are simulated — wire in `flutter_blue_plus` / HealthKit / a sensor stream to drive the waveform and BPM from real data.
