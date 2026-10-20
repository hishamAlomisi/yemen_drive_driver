import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../../core/services/theme_service.dart';
import '../../../shared/widgets/app_brand_icon.dart';
import '../controllers/driver_controller.dart';
import '../driver_routes.dart';

const forest = Color(0xFF102F2B);
const copper = Color(0xFFD8AE7D);

class DriverBrand extends StatelessWidget {
  const DriverBrand({this.light = false, this.compact = false, super.key});
  final bool light;
  final bool compact;
  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppBrandIcon(),
          const SizedBox(width: 11),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'يمن درايف',
                style: TextStyle(
                  fontSize: 20,
                  height: 1.25,
                  color: light
                      ? Colors.white
                      : Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (!compact)
                Text(
                  'شريك الطريق',
                  style: TextStyle(
                    fontSize: 11,
                    color: light
                        ? copper
                        : Theme.of(context).colorScheme.secondary,
                  ),
                ),
            ],
          ),
        ],
      );
}

/// Abstract brand artwork; this is not the live navigation map.
class JourneyArtwork extends StatelessWidget {
  const JourneyArtwork({super.key});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: CustomPaint(painter: _JourneyPainter(), size: Size.infinite),
      );
}

class _JourneyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 400, size.height / 230);
    final line = Paint()
      ..color = copper.withValues(alpha: .1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i < 7; i++) {
      final x = i * 73.0 - 30;
      canvas.drawPath(
        Path()
          ..moveTo(x, -20)
          ..cubicTo(x + 100, 70, x - 70, 140, x + 40, 260),
        line,
      );
    }
    for (var i = 0; i < 5; i++) {
      final y = i * 60.0;
      canvas.drawPath(
        Path()
          ..moveTo(-30, y)
          ..cubicTo(120, y + 40, 240, y - 45, 430, y + 10),
        line,
      );
    }
    final skyline = Paint()
      ..color = copper.withValues(alpha: .2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (var i = 0; i < 5; i++) {
      final x = 26.0 + i * 43;
      final top = 105.0 - (i % 3) * 17;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(x, top, x + 29, 210),
          const Radius.circular(6),
        ),
        skyline,
      );
      for (var row = 0; row < 3; row++) {
        for (var col = 0; col < 2; col++) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x + 6 + col * 11, top + 12 + row * 25, 6, 11),
              const Radius.circular(3),
            ),
            skyline,
          );
        }
      }
    }
    final route = Path()
      ..moveTo(355, 36)
      ..lineTo(300, 36)
      ..quadraticBezierTo(280, 36, 280, 56)
      ..lineTo(280, 138)
      ..quadraticBezierTo(280, 164, 252, 164)
      ..lineTo(170, 164)
      ..quadraticBezierTo(145, 164, 145, 190);
    canvas.drawPath(
      route,
      Paint()
        ..color = copper.withValues(alpha: .07)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 24
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      route,
      Paint()
        ..color = copper
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
    for (final point in [const Offset(355, 36), const Offset(145, 190)]) {
      canvas.drawCircle(
        point,
        13,
        Paint()..color = copper.withValues(alpha: .15),
      );
      canvas.drawCircle(point, 5, Paint()..color = copper);
      canvas.drawCircle(point, 2, Paint()..color = forest);
    }
    canvas.save();
    canvas.translate(280, 98);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-10, -19, 20, 38),
        const Radius.circular(7),
      ),
      Paint()..color = const Color(0xFFF4EEE2),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-7, -9, 14, 15),
        const Radius.circular(4),
      ),
      Paint()..color = forest,
    );
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class DriverHero extends StatelessWidget {
  const DriverHero({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.compact = false,
    super.key,
  });
  final String eyebrow, title, subtitle;
  final Widget? trailing;
  final bool compact;
  @override
  Widget build(BuildContext context) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: forest,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: Opacity(opacity: .25, child: const JourneyArtwork()),
            ),
            Padding(
              padding: EdgeInsets.all(compact ? 20 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.auto_awesome_outlined,
                        color: copper,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          eyebrow,
                          style: const TextStyle(color: copper, fontSize: 12),
                        ),
                      ),
                      if (trailing != null) trailing!,
                    ],
                  ),
                  SizedBox(height: compact ? 8 : 16),
                  Text(
                    title,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: compact ? 24 : 30,
                      height: 1.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFFBED0C8),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

class DriverEmptyState extends StatelessWidget {
  const DriverEmptyState({
    required this.title,
    required this.message,
    this.icon = Icons.route_outlined,
    this.action,
    super.key,
  });
  final String title, message;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: .07),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 36,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 7),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (action != null) ...[const SizedBox(height: 14), action!],
          ],
        ),
      );
}

class RideRoute extends StatelessWidget {
  const RideRoute({required this.ride, super.key});
  final Map<String, Object?> ride;
  @override
  Widget build(BuildContext context) => Column(
        children: [
          _point(
            context,
            'نقطة الانطلاق',
            '${ride['pickupDisplayName'] ?? ride['pickupAddress'] ?? 'غير محددة'}',
            false,
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 7),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Container(
                height: 16,
                width: 1,
                color: Theme.of(context).dividerColor,
              ),
            ),
          ),
          _point(
            context,
            'الوجهة',
            '${ride['destinationDisplayName'] ?? ride['destinationAddress'] ?? 'غير محددة'}',
            true,
          ),
        ],
      );
  Widget _point(
    BuildContext context,
    String label,
    String value,
    bool destination,
  ) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Icon(
              destination
                  ? Icons.location_on_rounded
                  : Icons.radio_button_checked,
              size: 16,
              color: destination
                  ? Theme.of(context).colorScheme.secondary
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontSize: 10),
                ),
                Text(
                  value,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      );
}

class DriverBottomBar extends StatelessWidget {
  const DriverBottomBar({required this.index, super.key});
  final int index;
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          border:
              Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (value) {
            if (value == 3) {
              showDriverProfile(context);
              return;
            }
            if (value == index) return;
            final destination = [
              DriverRoutes.home,
              DriverRoutes.history,
              DriverRoutes.wallet,
            ][value];
            // Keep the root route and its live session alive between tabs.
            var found = false;
            Get.until((route) {
              found = route.settings.name == destination;
              return found || route.isFirst;
            });
            if (!found) Get.toNamed<void>(destination);
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.grid_view_outlined),
              selectedIcon: Icon(Icons.grid_view_rounded),
              label: 'الرئيسية',
            ),
            NavigationDestination(
              icon: Icon(Icons.route_outlined),
              selectedIcon: Icon(Icons.route_rounded),
              label: 'رحلاتي',
            ),
            NavigationDestination(
              icon: Icon(Icons.account_balance_wallet_outlined),
              selectedIcon: Icon(Icons.account_balance_wallet_rounded),
              label: 'المحفظة',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              label: 'حسابي',
            ),
          ],
        ),
      );
}

void showDriverProfile(BuildContext context) {
  final controller = Get.find<DriverController>();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: DriverBrand()),
            const SizedBox(height: 24),
            Obx(
              () => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(
                  backgroundColor: forest,
                  foregroundColor: copper,
                  child: Icon(Icons.person_outline_rounded),
                ),
                title: Text(
                  '${controller.profile.value?['displayName'] ?? 'السائق'}',
                ),
                subtitle: Text(
                  '${controller.profile.value?['serviceNameAr'] ?? 'حساب السائق'}',
                ),
              ),
            ),
            const Divider(),
            if (Get.isRegistered<ThemeService>())
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dark_mode_outlined),
                title: const Text('المظهر'),
                trailing: const Icon(Icons.contrast_rounded),
                onTap: () => Get.find<ThemeService>().toggle(),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.my_location_rounded),
              title: const Text('تحديث موقعي'),
              onTap: () {
                Navigator.pop(context);
                controller.updateLocation();
              },
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                controller.signOut();
              },
              icon: const Icon(Icons.logout_rounded),
              label: const Text('تسجيل الخروج'),
            ),
          ],
        ),
      ),
    ),
  );
}
