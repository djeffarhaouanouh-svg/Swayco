import 'package:flutter/material.dart';
import 'package:flag_border_kit/flag_border_kit.dart';

/// Démo : le contour « 2a » appliqué à tous les pays disponibles.
/// L'intérieur (ici un simple Image.network) est un placeholder — dans ton
/// app tu passes ta vraie carte comme `child`.
void main() => runApp(const FlagBorderDemoApp());

class FlagBorderDemoApp extends StatelessWidget {
  const FlagBorderDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0B0D),
      ),
      home: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Wrap(
              spacing: 24,
              runSpacing: 24,
              alignment: WrapAlignment.center,
              children: [
                for (final country in FlagCountry.values)
                  SizedBox(
                    width: 320,
                    child: FlagBorder(
                      country: country,
                      // 👇 Remplace ce child par TA carte (photo + overlay).
                      child: AspectRatio(
                        aspectRatio: 320 / 452,
                        child: Container(
                          color: const Color(0xFF111111),
                          alignment: Alignment.bottomLeft,
                          padding: const EdgeInsets.all(18),
                          child: Text(
                            country.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
