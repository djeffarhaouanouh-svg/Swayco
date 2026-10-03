import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

/// Feuille à roulette (direction 8c) : titre, colonne de valeurs sous un cadre
/// jaune, bouton Enregistrer. Rend l'INDICE choisi, `-1` si « Supprimer »
/// ([allowClear]), `null` si la feuille est refermée. Même signature qu'avant.
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
    barrierColor: PopupTokens.scrim,
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
    return PopupSurface(
      sheet: true,
      washHeight: 110,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const PopupHandle(),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (widget.emoji.isNotEmpty) ...[
                      Text(widget.emoji, style: const TextStyle(fontSize: 18)),
                      const SizedBox(width: 10),
                    ],
                    Flexible(
                      child: PopupTitle(
                        widget.title,
                        fontSize: 17,
                        highlightLast: false,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 190,
                child: Stack(
                  children: [
                    Center(
                      child: Container(
                        height: 40,
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        decoration: BoxDecoration(
                          color: SC.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: SC.accentFg.withValues(alpha: 0.5),
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
                              style: GoogleFonts.dmSans(
                                color: selected
                                    ? PopupTokens.ink
                                    : SC.fg.withValues(alpha: 0.5),
                                fontSize: selected ? 21 : 17,
                                fontWeight: selected
                                    ? FontWeight.w800
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
              const SizedBox(height: 12),
              Row(
                children: [
                  if (widget.allowClear) ...[
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(-1),
                        child: Text(
                          AppStrings.t('delete'),
                          style: TextStyle(
                            color: SC.fg.withValues(alpha: 0.6),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    flex: 2,
                    child: PopupButton(
                      label: AppStrings.t('save'),
                      height: 54,
                      onPressed: () => Navigator.of(context).pop(_index),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

