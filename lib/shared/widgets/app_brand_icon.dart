import 'package:flutter/material.dart';

class AppBrandIcon extends StatelessWidget {
  const AppBrandIcon({this.size = 44, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
        'assets/images/branding/brand_logo.webp',
        width: size,
        height: size,
        fit: BoxFit.contain,
        semanticLabel: 'يمن درايف الكابتن',
      );
}
