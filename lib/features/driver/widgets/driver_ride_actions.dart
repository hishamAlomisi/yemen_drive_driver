import 'package:flutter/material.dart';

/// Compact horizontal actions that keep long Arabic labels readable.
class DriverRideActions extends StatelessWidget {
  const DriverRideActions({required this.actions, super.key});
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, constraints) {
      final columns = constraints.maxWidth < 240
          ? 2
          : constraints.maxWidth >= 340
              ? 4
              : 3;
      final width = (constraints.maxWidth - 6 * (columns - 1)) / columns;
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final action in actions) SizedBox(width: width, child: action)
        ],
      );
    });
  }
}

class DriverRideAction extends StatelessWidget {
  const DriverRideAction({
    required this.onPressed,
    required this.icon,
    required this.label,
    this.outlined = false,
    super.key,
  });
  final VoidCallback? onPressed;
  final Widget icon;
  final Widget label;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final height = 32 + 3 * MediaQuery.textScalerOf(context).scale(11) * 1.3;
    final style = ButtonStyle(
      padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 4, vertical: 5)),
      minimumSize: WidgetStatePropertyAll(Size(0, height)),
      maximumSize: const WidgetStatePropertyAll(Size.infinite),
      fixedSize: WidgetStatePropertyAll(Size.fromHeight(height)),
      textStyle: WidgetStatePropertyAll(
          Theme.of(context).textTheme.labelLarge?.copyWith(
                fontSize: 11,
                height: 1.3,
                fontWeight: FontWeight.w600,
              )),
    );
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconTheme.merge(data: const IconThemeData(size: 18), child: icon),
        const SizedBox(height: 4),
        DefaultTextStyle.merge(
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            child: label),
      ],
    );
    return outlined
        ? OutlinedButton(onPressed: onPressed, style: style, child: child)
        : FilledButton(onPressed: onPressed, style: style, child: child);
  }
}
