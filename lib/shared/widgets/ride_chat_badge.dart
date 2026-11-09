import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/services/ride_chat_service.dart';

class RideChatBadge extends StatelessWidget {
  const RideChatBadge({required this.rideId, super.key});
  final int rideId;

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<RideChatService>()) {
      return const Icon(Icons.chat_bubble_outline);
    }
    final chat = Get.find<RideChatService>();
    return Obx(() {
      final count = chat.unreadFor(rideId);
      return Semantics(
        label: count > 0 ? '$count رسائل غير مقروءة' : 'محادثة العميل',
        child: Badge(
          isLabelVisible: count > 0,
          backgroundColor: const Color(0xffd32f2f),
          textColor: Colors.white,
          label: Text(count > 99 ? '99+' : '$count'),
          child: const Icon(Icons.chat_bubble_outline),
        ),
      );
    });
  }
}
