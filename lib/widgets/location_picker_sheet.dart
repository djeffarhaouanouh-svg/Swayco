import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/locations.dart';
import '../theme/swayco_theme.dart';

/// Cascading country → city picker sheet. Pops `(country, city)` on pick,
/// or null on dismiss. Shared by onboarding (first-run location) and
/// Settings (changing it later) so there's one place that knows the
/// country list, the search, and the free-text fallback for an unlisted
/// city.
class LocationPickerSheet extends StatefulWidget {
  const LocationPickerSheet({
    super.key,
    required this.initialCountry,
    required this.initialCity,
  });
  final String initialCountry;
  final String initialCity;
  @override
  State<LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<LocationPickerSheet> {
  Country? _country;
  bool _onCityStep = false;
  String _search = '';
  final TextEditingController _otherCityCtrl = TextEditingController();

  @override
  void dispose() {
    _otherCityCtrl.dispose();
    super.dispose();
  }

  void _pickCountry(Country c) {
    setState(() {
      _country = c;
      _onCityStep = true;
      _otherCityCtrl.text = c.name == widget.initialCountry
          ? widget.initialCity
          : '';
    });
  }

  void _commitCity(String city) {
    final c = _country;
    if (c == null) return;
    Navigator.of(context).pop((c.name, city.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => Container(
        decoration: const BoxDecoration(
          color: SC.bubbleIn,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: SC.textMuted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
              child: Row(
                children: [
                  if (_onCityStep)
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back_rounded,
                        color: SC.textPrimary,
                      ),
                      onPressed: () => setState(() => _onCityStep = false),
                    )
                  else
                    const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _onCityStep
                          ? '${_country!.flag}  ${_country!.name}'
                          : AppStrings.t('onb_location_label'),
                      style: const TextStyle(
                        color: SC.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _onCityStep
                  ? _buildCityList(scrollController)
                  : _buildCountryList(scrollController),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCountryList(ScrollController sc) {
    final q = _search.trim().toLowerCase();
    final list = q.isEmpty
        ? kCountries
        : kCountries
              .where((c) => c.name.toLowerCase().contains(q))
              .toList(growable: false);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: TextField(
            autofocus: false,
            cursorColor: SC.accent,
            onChanged: (v) => setState(() => _search = v),
            style: const TextStyle(color: SC.textPrimary, fontSize: 15),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, color: SC.textMuted),
              hintText: AppStrings.t('loc_search_country'),
              hintStyle: const TextStyle(color: SC.textMuted),
              filled: true,
              fillColor: SC.bg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: SC.glassBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: SC.glassBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: SC.accent, width: 1.5),
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: sc,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final c = list[i];
              return ListTile(
                leading: Text(c.flag, style: const TextStyle(fontSize: 22)),
                title: Text(
                  c.name,
                  style: const TextStyle(
                    color: SC.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right, color: SC.textMuted),
                onTap: () => _pickCountry(c),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCityList(ScrollController sc) {
    final cities = _country?.cities ?? const <String>[];
    return ListView(
      controller: sc,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        // Always-present free-text fallback for unlisted cities.
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _otherCityCtrl,
                textCapitalization: TextCapitalization.words,
                cursorColor: SC.accent,
                style: const TextStyle(color: SC.textPrimary, fontSize: 15),
                onSubmitted: (v) {
                  if (v.trim().isNotEmpty) _commitCity(v);
                },
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(
                    Icons.edit_location_alt_outlined,
                    color: SC.textMuted,
                  ),
                  hintText: AppStrings.t('loc_other_city_hint'),
                  hintStyle: const TextStyle(color: SC.textMuted),
                  filled: true,
                  fillColor: SC.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: SC.glassBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: SC.glassBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: SC.accent, width: 1.5),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              style: IconButton.styleFrom(
                backgroundColor: SC.accent,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.check_rounded),
              onPressed: () {
                final v = _otherCityCtrl.text.trim();
                if (v.isNotEmpty) _commitCity(v);
              },
            ),
          ],
        ),
        if (cities.isNotEmpty) const SizedBox(height: 8),
        for (final city in cities)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text(
              city,
              style: const TextStyle(
                color: SC.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            trailing:
                city == widget.initialCity &&
                    _country?.name == widget.initialCountry
                ? const Icon(Icons.check_rounded, color: SC.accent)
                : null,
            onTap: () => _commitCity(city),
          ),
      ],
    );
  }
}
