import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/ecg_screen.dart';
import 'screens/home_screen.dart';
import 'screens/report_screen.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.background,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const CardiogramApp());
}

class CardiogramApp extends StatelessWidget {
  const CardiogramApp({super.key});

  static const _start = String.fromEnvironment('START');

  Widget get _home {
    switch (_start) {
      case 'ecg':
        return const EcgScreen();
      case 'report':
        return const ReportScreen();
      default:
        return const HomeScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cardiogram',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: _home,
    );
  }
}
