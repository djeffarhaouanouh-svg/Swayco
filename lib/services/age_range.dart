/// Ages offered by the profile wheel picker.
const int kAgeMin = 15;
const int kAgeMax = 40;

/// Inclusive list `15 … 40` for the age roulette.
const List<int> kAgeOptions = [
  for (var a = kAgeMin; a <= kAgeMax; a++) a,
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
