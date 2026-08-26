// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharmacy_management_system/main.dart';

void main() {
  testWidgets('shows the login screen', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Care About Us Pharmacy'), findsOneWidget);
    expect(find.text('Sign In Securely'), findsOneWidget);
  });
}
