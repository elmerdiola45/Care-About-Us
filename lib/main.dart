import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'login_screen.dart';
import 'common/services/app_config.dart';
import 'common/session.dart';
import 'common/app_route_observer.dart';
import 'common/theme/app_theme.dart';
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
      theme: buildAppTheme(),
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
    _restoreFuture = _restoreAndCheck();
  }

  /// Login tokens expire on the backend (config/sanctum.php), so a stored
  /// one may already be dead. Ask /me once: a 401 means "expired", so drop
  /// to the login screen instead of opening a dashboard where every call
  /// fails. Any other outcome — including no connection or a cold Render
  /// start timing out — keeps the session, so being offline never logs
  /// anyone out.
  Future<bool> _restoreAndCheck() async {
    final restored = await AppSession.instance.restore();
    if (!restored) return false;

    try {
      final response = await http
          .get(
            Uri.parse('${AppConfig.baseUrl}/me'),
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Bearer ${AppSession.instance.token}',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 401) return false;
    } catch (_) {
      // Unreachable server — keep the session (see above).
    }
    return true;
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

        // Both admin-role and pharmacist-role accounts log in through the
        // "Pharmacist / Admin" tab and land on AdminDashboardPage; the
        // backend reports either as user_type 'pharmacist' (see
        // AuthController::pharmacistLogin), so accept both here or a refresh
        // would drop a valid pharmacist/admin session back to login.
        if (restored &&
            (session.userType == 'admin' || session.userType == 'pharmacist')) {
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
