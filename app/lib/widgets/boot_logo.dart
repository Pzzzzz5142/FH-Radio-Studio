import 'package:flutter/material.dart';

/// App logo mark used by the boot screen and compact splash surfaces.
class BootLogoMark extends StatelessWidget {
  const BootLogoMark({super.key, this.size = 30});
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        'assets/images/app_logo.png',
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}
