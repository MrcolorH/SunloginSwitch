import 'package:flutter_test/flutter_test.dart';
import 'package:sunlogin_switch/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SunloginApp());
    expect(find.byType(SunloginApp), findsOneWidget);
  });
}
