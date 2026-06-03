import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/ios_status_bar.dart';
import 'ecg_screen.dart';
import 'history_screen.dart';
import 'nearby_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  void _openSession(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const EcgScreen()));
  }

  void _openHistory(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const HistoryScreen()));
  }

  void _openNearby(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const NearbyScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.1, -0.75),
            radius: 1.1,
            colors: [AppColors.homeGlow, AppColors.background],
            stops: [0.0, 0.55],
          ),
        ),
        child: Column(
          children: [
            const IosStatusBar(),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: AppColors.connectedGreen,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.connectedGreen.withValues(
                            alpha: 0.6,
                          ),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    'Cardiogram connected.',
                    style: TextStyle(
                      color: AppColors.connectedGreen.withValues(alpha: 0.95),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: IntrinsicHeight(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Cardiogram',
                                style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 18),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Expanded(
                                    child: Text(
                                      'Check\nmy Heart\nRate',
                                      style: TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 46,
                                        height: 1.04,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: -1.2,
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(top: 10),
                                    child: IconButton(
                                      onPressed: () => _openSession(context),
                                      icon: const Icon(
                                        Icons.arrow_forward_rounded,
                                        color: AppColors.accentPink,
                                        size: 30,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              const SizedBox(
                                width: 230,
                                child: Text(
                                  'Check your current heart rate and view all your recorded data under the history tab.',
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 13.5,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 26),
                              _HistoryButton(
                                onTap: () => _openHistory(context),
                              ),
                              const Spacer(),
                              _ListRow(
                                title: 'Nearby me',
                                subtitle:
                                    'Hospitals and care units near you, plus SOS to five contacts and local emergency services.',
                                onTap: () => _openNearby(context),
                              ),
                              const SizedBox(height: 4),
                              const Divider(
                                color: AppColors.divider,
                                height: 1,
                              ),
                              const SizedBox(height: 4),
                              _ListRow(
                                title: 'Preferences',
                                subtitle:
                                    'App settings and device connection options.',
                                onTap: () {},
                              ),
                              const SizedBox(height: 24),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryButton extends StatelessWidget {
  const _HistoryButton({required this.onTap});

  final VoidCallback onTap;

  static const _radius = BorderRadius.all(Radius.circular(30));

  @override
  Widget build(BuildContext context) {
    // Shadow + gradient on a Container (not Ink) so the glow follows the
    // pill shape — Ink paints box shadows on a rectangle and bleeds at corners.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: _radius,
        onTap: onTap,
        splashColor: Colors.white24,
        highlightColor: Colors.white12,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: _radius,
            gradient: const LinearGradient(
              colors: [AppColors.accentPink, AppColors.accentPinkDark],
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.accentPink.withValues(alpha: 0.35),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'My History',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_rounded,
                color: Colors.white,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textSecondary,
              size: 26,
            ),
          ],
        ),
      ),
    );
  }
}
