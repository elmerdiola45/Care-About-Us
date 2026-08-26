import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'login_screen.dart';
import 'common/session.dart';
import 'common/app_route_observer.dart';
import 'pharmacist/pages/home_dashboard_screen.dart';
import 'admin/pages/admin_dashboard_page.dart';

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
      home: const AuthGate(),
      debugShowCheckedModeBanner: false,
      navigatorObservers: [appRouteObserver],
    );
  }
}

/// Bootstraps the app on launch/refresh by trying to restore a previously
/// logged-in session (see AppSession.restore()) before deciding whether to
/// land on a dashboard or the login screen — so a valid token isn't thrown
/// away just because the page reloaded.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final Future<bool> _restoreFuture;

  @override
  void initState() {
    super.initState();
    _restoreFuture = AppSession.instance.restore();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _restoreFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final restored = snapshot.data ?? false;
        final session = AppSession.instance;

        if (restored && session.userType == 'dispenser') {
          return HomeDashboardScreen(
            staffName: session.staffName ?? '',
            branchName: session.branchName ?? '',
            token: session.token ?? '',
            userType: session.userType,
          );
        }

        if (restored && session.userType == 'admin') {
          return AdminDashboardPage(
            token: session.token ?? '',
            userType: session.userType,
          );
        }

        // Nothing restored, or an unrecognized userType — don't guess
        // which dashboard to show. Clear whatever partial session state
        // exists so the app doesn't limp along half-authenticated.
        session.clear();
        return const LoginScreen();
      },
    );
  }
}
