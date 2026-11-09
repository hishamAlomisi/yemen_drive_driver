import 'package:flutter/services.dart';

class ChatMessageSound {
  static const _channel = MethodChannel('yemendrive/chat_sound');

  static Future<void> play() async {
    try {
      await _channel.invokeMethod<void>('playIncoming');
    } on MissingPluginException {
      // Non-Android builds can use the platform alert where available.
      await SystemSound.play(SystemSoundType.alert);
    } on PlatformException {
      // Sound settings must never interrupt message rendering or receipts.
    }
  }
}
