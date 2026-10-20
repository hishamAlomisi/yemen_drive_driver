import 'package:flutter/material.dart';

class AppBrandIcon extends StatelessWidget {
  const AppBrandIcon({this.size = 44, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * .27),
        child: Image.asset(
          'assets/images/branding/yemen_drive_logo.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          semanticLabel: 'يمن درايف الكابتن',
        ),
      );
}
