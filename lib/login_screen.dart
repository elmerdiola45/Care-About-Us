import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pharmacy_management_system/common/session.dart';
import 'package:pharmacy_management_system/common/services/app_config.dart';
import 'package:pharmacy_management_system/common/theme/app_colors.dart';
import 'package:pharmacy_management_system/common/widgets/tap_target.dart';
import 'pharmacist/pages/home_dashboard_screen.dart';
import 'admin/pages/admin_dashboard_page.dart';

enum LoginRole { assistant, admin }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  LoginRole _role = LoginRole.assistant;
  bool _obscurePassword = true;
  bool _isSubmitting = false;
  String? _errorMessage;

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _showForgotPasswordDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Forgot Password?'),
        content: const Text(
          'For security, password resets are handled by your pharmacy '
          'Admin. Please contact your Admin and ask them to reset your '
          'password from the Staff Management screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Pulls a display name out of the dispenser/pharmacist object the login
  /// endpoint returns. Returns null (not a placeholder) when nothing
  /// usable is present, so the dashboard can decide how to render that.
  static String? _extractStaffName(Map<String, dynamic> u) {
    String s(dynamic v) => (v?.toString() ?? '').trim();

    final first = [
      s(u['dispenser_first_name']),
      s(u['pharmacist_first_name']),
      s(u['first_name']),
    ].firstWhere((v) => v.isNotEmpty, orElse: () => '');
    final last = [
      s(u['dispenser_last_name']),
      s(u['pharmacist_last_name']),
      s(u['last_name']),
    ].firstWhere((v) => v.isNotEmpty, orElse: () => '');

    final full = '$first $last'.trim();
    if (full.isNotEmpty) return full;

    final name = s(u['name']);
    return name.isNotEmpty ? name : null;
  }

  Future<void> _handleSignIn() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final email = _emailController.text.trim();
    final password = _passwordController.text;

    try {
      final endpoint =
          _role == LoginRole.assistant ? '/dispenser/login' : '/admin/login';

      final Map<String, String> body = {'email': email, 'password': password};

      final response = await http
          .post(
            Uri.parse('${AppConfig.baseUrl}$endpoint'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final data = decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
        final token = data['token']?.toString() ?? '';
        final userType = data['user_type']?.toString() ?? '';

        final userObj = data['dispenser'] ?? data['pharmacist'] ?? {};
        final userMap = userObj is Map
            ? Map<String, dynamic>.from(userObj)
            : <String, dynamic>{};
        final userId = userMap['dispenser_id'] ?? userMap['pharmacist_id'];
        final pharmacyId = userMap['pharmacy_id'];
        AppSession.instance.setUser(
          id: userId?.toString() ?? '',
          type: userType,
          pharmacyId: pharmacyId?.toString(),
          token: token,
          // The login response already carries the real name — capture it
          // here so the dashboard never has to show a "Pharmacist"
          // placeholder while a second /me-style request resolves.
          staffName: _extractStaffName(userMap),
        );

        setState(() => _isSubmitting = false);

        if (_role == LoginRole.assistant) {
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => HomeDashboardScreen(token: token, userType: userType),
            ),
          );
        } else {
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => AdminDashboardPage(token: token, userType: userType),
            ),
          );
        }
      } else {
        String message = 'Invalid credentials';
        try {
          final data = jsonDecode(response.body);
          if (data is Map && data['message'] != null) {
            message = data['message'].toString();
          }
        } catch (_) {}
        setState(() {
          _isSubmitting = false;
          _errorMessage = message;
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _errorMessage =
            'Server is starting up. Please try again in a moment.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _errorMessage = 'Could not connect to server. Is the backend running?';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 600;
            return SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: isWide ? 480 : double.infinity),
                  child: Column(
                    children: [
                      _buildHeader(isWide),
                      Padding(
                        padding: EdgeInsets.fromLTRB(isWide ? 32 : 24, 28, isWide ? 32 : 24, 20),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildRoleToggle(),
                      const SizedBox(height: 24),
                      _buildFieldLabel('EMAIL ADDRESS'),
                      const SizedBox(height: 8),
                      _buildEmailField(),
                      const SizedBox(height: 18),
                      _buildFieldLabel('PASSWORD'),
                      const SizedBox(height: 8),
                      _buildPasswordField(),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _showForgotPasswordDialog,
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 0),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text(
                            'Forgot Password?',
                            style: TextStyle(color: AppColors.teal, fontSize: 13.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      _buildSignInButton(isWide),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      const Divider(height: 1, color: Color(0xFFE5E7EB)),
                      const SizedBox(height: 16),
                              _buildFooter(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(bool isWide) {
    final iconSize = isWide ? 80.0 : 64.0;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: isWide ? 56 : 44, horizontal: isWide ? 32 : 24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.loginGradientDark, AppColors.teal],
        ),
      ),
      child: Column(
        children: [
          Container(
            width: iconSize,
            height: iconSize,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(Icons.shield_outlined, color: Colors.white, size: 30),
          ),
          const SizedBox(height: 18),
          const Text(
            'Care About Us Pharmacy',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(color: AppColors.accentGreen, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: const Text(
                    'RA 10918 Pharmacy Act Compliant',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoleToggle() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(child: _roleTab('Pharmacy Assistant', LoginRole.assistant)),
          const SizedBox(width: 6),
          Expanded(child: _roleTab('Pharmacist / Admin', LoginRole.admin)),
        ],
      ),
    );
  }

  Widget _roleTab(String label, LoginRole role) {
    final selected = _role == role;
    return TapTarget(
      onTap: () => setState(() => _role = role),
      semanticLabel: label,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          boxShadow: selected
              ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 6, offset: const Offset(0, 1))]
              : null,
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? AppColors.teal : AppColors.textFaint,
            fontWeight: FontWeight.w700,
            fontSize: 13.5,
          ),
        ),
      ),
    );
  }

  Widget _buildFieldLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    );
  }

  InputDecoration _inputDecoration({required IconData icon, Widget? suffix}) {
    return InputDecoration(
      prefixIcon: Icon(icon, color: AppColors.textFaint, size: 20),
      suffixIcon: suffix,
      filled: true,
      fillColor: AppColors.bg,
      contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.teal, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.redAccent, width: 1),
      ),
    );
  }

  Widget _buildEmailField() {
    return TextFormField(
      controller: _emailController,
      keyboardType: TextInputType.emailAddress,
      style: const TextStyle(color: AppColors.textPrimary, fontSize: 14.5),
      decoration: _inputDecoration(icon: Icons.mail_outline),
      validator: (value) {
        if (value == null || value.trim().isEmpty) return 'Email is required';
        if (!value.contains('@')) return 'Enter a valid email';
        return null;
      },
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordController,
      obscureText: _obscurePassword,
      style: const TextStyle(color: AppColors.textPrimary, fontSize: 14.5),
      decoration: _inputDecoration(
        icon: Icons.lock_outline,
        suffix: IconButton(
          icon: Icon(
            _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            color: AppColors.textFaint,
            size: 20,
          ),
          tooltip: _obscurePassword ? 'Show password' : 'Hide password',
          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
        ),
      ),
      validator: (value) {
        if (value == null || value.isEmpty) return 'Password is required';
        return null;
      },
    );
  }

  Widget _buildSignInButton(bool isWide) {
    return SizedBox(
      height: isWide ? 58 : 54,
      child: ElevatedButton(
        onPressed: _isSubmitting ? null : _handleSignIn,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.loginGradientDark,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
        ),
        child: _isSubmitting
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Text('Sign In Securely', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  SizedBox(width: 8),
                  Icon(Icons.arrow_forward, size: 18),
                ],
              ),
      ),
    );
  }

  Widget _buildFooter() {
    return Column(
      children: const [
        Text(
          'Secured · DoH-accredited e-prescription system',
          style: TextStyle(color: AppColors.textFaint, fontSize: 11.5),
          textAlign: TextAlign.center,
        ),
        SizedBox(height: 2),
        Text(
          'Care About Us Pharmacy · v2.4.1 · Build 20250705',
          style: TextStyle(color: AppColors.textFaint, fontSize: 11.5),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
