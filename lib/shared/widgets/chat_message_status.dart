import 'package:flutter/material.dart';

/// A receipt is shown only when its server timestamp is present.
class ChatMessageStatus extends StatelessWidget {
  const ChatMessageStatus({required this.message, this.color, super.key});
  final Map<String, Object?> message;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final pending = message['pending'] == true;
    final failed = message['failed'] == true;
    final read = message['readAtUtc'] != null;
    final delivered = message['deliveredAtUtc'] != null;
    final label = failed
        ? 'تعذر الإرسال'
        : pending
            ? 'جارٍ الإرسال'
            : read
                ? 'تمت القراءة'
                : delivered
                    ? 'تم الوصول'
                    : 'تم الإرسال';
    final icon = failed
        ? Icons.error_outline
        : pending
            ? Icons.schedule_rounded
            : read || delivered
                ? Icons.done_all_rounded
                : Icons.done_rounded;
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: Icon(icon,
            size: 17,
            color: read
                ? const Color(0xff80d8ff)
                : failed
                    ? Colors.amberAccent
                    : color),
      ),
    );
  }
}
