/// Ages offered by the profile wheel picker.
const int kAgeMin = 15;
const int kAgeMax = 40;

/// Inclusive list `15 … 40` for the age roulette.
/// Written out explicitly — a `const` collection-for over locals isn't a
/// constant expression under dart2js (Railway web build).
const List<int> kAgeOptions = [
  15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
  25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
  35, 36, 37, 38, 39, 40,
];

/// Index of [age] in [kAgeOptions]. Clamps into range when the stored value
/// is outside (legacy rows above 40, or empty → mid-list default 25).
int ageIndex(int? age) {
  if (age == null) {
    // Mid of the wheel — a neutral starting point.
    return kAgeOptions.indexOf(25).clamp(0, kAgeOptions.length - 1);
  }
  final clamped = age.clamp(kAgeMin, kAgeMax);
  return kAgeOptions.indexOf(clamped);
}
