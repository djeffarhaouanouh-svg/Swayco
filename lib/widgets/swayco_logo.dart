import 'package:flutter/material.dart';

/// Brand mark — cyan Ø from [assets/test-logo.png].
class SwaycoLogo extends StatelessWidget {
  const SwaycoLogo({
    super.key,
    this.height = 28,
    this.width,
  });

  final double height;
  final double? width;

  static const asset = 'assets/test-logo.png';

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      height: height,
      width: width,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  }
}
