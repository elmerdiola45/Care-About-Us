import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'login_screen.dart';

void main() {
  FlutterError.onError = (details) {
    if (kDebugMode) {
      FlutterError.dumpErrorToConsole(details, forceReport: true);
    }
  };
  ErrorWidget.builder = (details) {
    if (kDebugMode) {
      FlutterError.dumpErrorToConsole(details, forceReport: true);
    }
    return Scaffold(
      body: Center(
        child: Text(
          'Something went wrong.\nCheck the console for details.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  };
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Care About Us Pharmacy',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E)),
      ),
      home: const LoginScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
