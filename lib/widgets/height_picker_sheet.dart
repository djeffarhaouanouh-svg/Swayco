import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/fact_emojis.dart';
import '../services/units.dart';
import '../theme/swayco_theme.dart';

/// Roulette de taille. Rend les centimètres choisis, `0` pour effacer la
/// valeur, et `null` si on referme sans rien décider.
///
/// C'est le sélecteur qui impose le format : la liste est graduée en pieds et
/// pouces pour un profil américain, en centimètres partout ailleurs, mais elle
/// rend toujours des centimètres — la base n'a qu'une unité.
Future<int?> showHeightPicker(
  BuildContext context, {
  required String country,
  int? current,
}) {
  return showModalBottomSheet<int>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _HeightPickerSheet(country: country, current: current),
  );
}

class _HeightPickerSheet extends StatefulWidget {
  const _HeightPickerSheet({required this.country, this.current});

  final String country;
  final int? current;

  @override
  State<_HeightPickerSheet> createState() => _HeightPickerSheetState();
}

class _HeightPickerSheetState extends State<_HeightPickerSheet> {
  late final List<int> _values = heightWheelValues(widget.country);
  late int _index = _initialIndex();
  late final FixedExtentScrollController _ctrl =
      FixedExtentScrollController(initialItem: _index);

  /// La valeur actuelle si elle existe, sinon 170 cm — le milieu crédible,
  /// pour que la roulette n'ouvre pas sur 120 cm.
  int _initialIndex() {
    final target = widget.current ?? 170;
    var best = 0;
    var bestGap = 9999;
    for (final (i, v) in _values.indexed) {
      final gap = (v - target).abs();
      if (gap < bestGap) {
        bestGap = gap;
        best = i;
      }
    }
    return best;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: ColoredBox(
        color: SC.bg,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      kFactEmojiHeight,
                      style: TextStyle(fontSize: 18),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      AppStrings.t('info_height'),
                      style: const TextStyle(
                        color: SC.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 190,
                child: Stack(
                  children: [
                    // Le liseré qui marque la ligne sélectionnée.
                    Center(
                      child: Container(
                        height: 40,
                        margin: const EdgeInsets.symmetric(horizontal: 60),
                        decoration: BoxDecoration(
                          color: SC.accent.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: SC.accent.withValues(alpha: 0.35),
                          ),
                        ),
                      ),
                    ),
                    ListWheelScrollView.useDelegate(
                      controller: _ctrl,
                      itemExtent: 40,
                      diameterRatio: 1.6,
                      physics: const FixedExtentScrollPhysics(),
                      onSelectedItemChanged: (i) => setState(() => _index = i),
                      childDelegate: ListWheelChildBuilderDelegate(
                        childCount: _values.length,
                        builder: (ctx, i) {
                          final selected = i == _index;
                          return Center(
                            child: Text(
                              formatHeight(
                                _values[i],
                                country: widget.country,
                              ),
                              style: TextStyle(
                                color: selected
                                    ? SC.textPrimary
                                    : SC.textMuted,
                                fontSize: selected ? 20 : 17,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Row(
                  children: [
                    if (widget.current != null) ...[
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(0),
                          child: Text(
                            AppStrings.t('delete'),
                            style: const TextStyle(color: SC.textMuted),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        onPressed: () =>
                            Navigator.of(context).pop(_values[_index]),
                        child: Text(AppStrings.t('save')),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
