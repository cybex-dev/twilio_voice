import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const MethodChannel channel = MethodChannel('twilio_voice');

  TestWidgetsFlutterBinding.ensureInitialized();
  var messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (methodCall) async {
      return '42';
    });
  });

  test("Mock Test", () async {
    final result = await channel.invokeMethod("42");
    expect(result, equals("42"));
  });
}
