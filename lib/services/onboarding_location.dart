import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'locations.dart';

/// GPS → country name, used once at onboarding to auto-detect where the
/// user really is (Discover's country filter needs the real thing, not the
/// spoken language). Country-level only: [LocationAccuracy.low] and
/// `ACCESS_COARSE_LOCATION` on Android — no need for house-level precision.
///
/// Returns null on ANY failure (permission denied, no GPS fix, geocoding
/// error, or a country outside our curated 40 — see [countryNameForIso2]).
/// The caller falls back to the existing manual [LocationPickerSheet];
/// onboarding must never get stuck on this.
abstract final class OnboardingLocation {
  static Future<String?> detectCountry() async {
    try {
      final status = await Permission.locationWhenInUse.request();
      if (!status.isGranted) return null;

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
        ),
      ).timeout(const Duration(seconds: 8));

      final placemarks = await Geocoding()
          .placemarkFromCoordinates(position.latitude, position.longitude)
          .timeout(const Duration(seconds: 8));
      if (placemarks.isEmpty) return null;

      final iso2 = placemarks.first.isoCountryCode ?? '';
      if (iso2.isEmpty) return null;
      return countryNameForIso2(iso2);
    } catch (_) {
      return null;
    }
  }
}
