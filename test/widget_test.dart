import 'package:flutter_test/flutter_test.dart';
import 'package:yemen_drive_driver/app/app.dart';

void main() {
  testWidgets('driver app widget bootstraps', (tester) async {
    await tester.pumpWidget(const EasyRideApp());
    expect(find.byType(EasyRideApp), findsOneWidget);
  });
}
