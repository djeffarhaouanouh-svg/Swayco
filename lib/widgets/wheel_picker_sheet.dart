import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';

/// Feuille à roulette : un titre, une colonne de valeurs qui défile sous un
/// cadre cyan, un bouton Enregistrer. Le format est imposé par la liste — on ne
/// tape rien, donc rien à valider.
///
/// Rend l'INDICE choisi, `-1` si on a touché « Supprimer » ([allowClear]), et
/// `null` si la feuille a été refermée sans rien décider.
Future<int?> showWheelPicker({
  required BuildContext context,
  required String title,
  required List<String> labels,
  String emoji = '',
  int initialIndex = 0,
  bool allowClear = false,
}) {
  if (labels.isEmpty) return Future<int?>.value();
  return showModalBottomSheet<int>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _WheelPickerSheet(
      title: title,
      labels: labels,
      emoji: emoji,
      initialIndex: initialIndex.clamp(0, labels.length - 1),
      allowClear: allowClear,
    ),
  );
}

class _WheelPickerSheet extends StatefulWidget {
  const _WheelPickerSheet({
    required this.title,
    required this.labels,
    required this.emoji,
    required this.initialIndex,
    required this.allowClear,
  });

  final String title;
  final List<String> labels;
  final String emoji;
  final int initialIndex;
  final bool allowClear;

  @override
  State<_WheelPickerSheet> createState() => _WheelPickerSheetState();
}

class _WheelPickerSheetState extends State<_WheelPickerSheet> {
  late int _index = widget.initialIndex;
  late final FixedExtentScrollController _ctrl =
      FixedExtentScrollController(initialItem: widget.initialIndex);

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
                    if (widget.emoji.isNotEmpty) ...[
                      Text(widget.emoji, style: const TextStyle(fontSize: 18)),
                      const SizedBox(width: 10),
                    ],
                    Text(
                      widget.title,
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
                    // Le cadre qui marque la ligne sélectionnée.
                    Center(
                      child: Container(
                        height: 40,
                        margin: const EdgeInsets.symmetric(horizontal: 40),
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
                        childCount: widget.labels.length,
                        builder: (ctx, i) {
                          final selected = i == _index;
                          return Center(
                            child: Text(
                              widget.labels[i],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: selected ? SC.textPrimary : SC.textMuted,
                                fontSize: selected ? 20 : 17,
                                fontWeight:
                                    selected ? FontWeight.w700 : FontWeight.w500,
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
                    if (widget.allowClear) ...[
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(-1),
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
                        onPressed: () => Navigator.of(context).pop(_index),
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
