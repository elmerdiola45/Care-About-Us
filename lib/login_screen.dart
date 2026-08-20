import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pharmacy_management_system/common/session.dart';
import 'package:pharmacy_management_system/common/services/app_config.dart';
import 'package:pharmacy_management_system/common/widgets/tap_target.dart';
import 'pharmacist/pages/home_dashboard_screen.dart';
import 'admin/pages/admin_dashboard_page.dart';

class LoginColors {
  static const tealDark = Color(0xFF0B4F4A);
  static const teal = Color(0xFF0F766E);
  static const tealLight = Color(0xFF14B8A6);
  static const bg = Colors.white;
  static const inputBg = Color(0xFFF3F4F6);
  static const textPrimary = Color(0xFF1F2937);
  static const textSecondary = Color(0xFF6B7280);
  static const textFaint = Color(0xFF9CA3AF);
  static const green = Color(0xFF22C55E);
}

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

      final response = await http.post(
        Uri.parse('${AppConfig.baseUrl}$endpoint'),
        headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
        body: jsonEncode(body),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final data = decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
        final token = data['token']?.toString() ?? '';
        final userType = data['user_type']?.toString() ?? '';

        final userObj = data['dispenser'] ?? data['pharmacist'] ?? {};
        final userId = userObj is Map ? (userObj['dispenser_id'] ?? userObj['pharmacist_id']) : null;
        final pharmacyId = userObj is Map ? userObj['pharmacy_id'] : null;
        AppSession.instance.setUser(
          id: userId?.toString() ?? '',
          type: userType,
          pharmacyId: pharmacyId?.toString(),
          token: token,
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
      backgroundColor: LoginColors.bg,
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
                            style: TextStyle(color: LoginColors.teal, fontSize: 13.5, fontWeight: FontWeight.w600),
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
          colors: [LoginColors.tealDark, LoginColors.teal],
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
                  decoration: const BoxDecoration(color: LoginColors.green, shape: BoxShape.circle),
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
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: LoginColors.inputBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(child: _roleTab('Pharmacy Assistant', LoginRole.assistant)),
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
      borderRadius: BorderRadius.circular(9),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          boxShadow: selected
              ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 6, offset: const Offset(0, 1))]
              : null,
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? LoginColors.teal : LoginColors.textFaint,
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
        color: LoginColors.textSecondary,
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    );
  }

  InputDecoration _inputDecoration({required IconData icon, Widget? suffix}) {
    return InputDecoration(
      prefixIcon: Icon(icon, color: LoginColors.textFaint, size: 20),
      suffixIcon: suffix,
      filled: true,
      fillColor: LoginColors.inputBg,
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
        borderSide: const BorderSide(color: LoginColors.teal, width: 1.5),
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
      style: const TextStyle(color: LoginColors.textPrimary, fontSize: 14.5),
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
      style: const TextStyle(color: LoginColors.textPrimary, fontSize: 14.5),
      decoration: _inputDecoration(
        icon: Icons.lock_outline,
        suffix: IconButton(
          icon: Icon(
            _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            color: LoginColors.textFaint,
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
          backgroundColor: LoginColors.tealDark,
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
          style: TextStyle(color: LoginColors.textFaint, fontSize: 11.5),
          textAlign: TextAlign.center,
        ),
        SizedBox(height: 2),
        Text(
          'Care About Us Pharmacy · v2.4.1 · Build 20250705',
          style: TextStyle(color: LoginColors.textFaint, fontSize: 11.5),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
