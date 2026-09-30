import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/locations.dart';
import '../services/onboarding_location.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

/// Sélecteur pays → ville (direction 8c). Renvoie `(pays, ville)` ou null.
/// Mêmes paramètres et même logique qu'avant ; seul l'habillage change.
class LocationPickerSheet extends StatefulWidget {
  const LocationPickerSheet({
    super.key,
    required this.initialCountry,
    required this.initialCity,
    this.showDetect = false,
  });
  final String initialCountry;
  final String initialCity;
  final bool showDetect;
  @override
  State<LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<LocationPickerSheet> {
  Country? _country;
  bool _onCityStep = false;
  String _search = '';
  bool _locating = false;
  bool _detectFailed = false;
  final TextEditingController _otherCityCtrl = TextEditingController();

  Future<void> _detect() async {
    if (_locating) return;
    setState(() {
      _locating = true;
      _detectFailed = false;
    });
    final country = await OnboardingLocation.detectCountry();
    if (!mounted) return;
    if (country == null) {
      setState(() {
        _locating = false;
        _detectFailed = true;
      });
      return;
    }
    Navigator.of(context).pop((
      country,
      country == widget.initialCountry ? widget.initialCity : '',
    ));
  }

  @override
  void dispose() {
    _otherCityCtrl.dispose();
    super.dispose();
  }

  void _pickCountry(Country c) {
    setState(() {
      _country = c;
      _onCityStep = true;
      _otherCityCtrl.text =
          c.name == widget.initialCountry ? widget.initialCity : '';
    });
  }

  void _commitCity(String city) {
    final c = _country;
    if (c == null) return;
    Navigator.of(context).pop((c.name, city.trim()));
  }

  static OutlineInputBorder _b(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: c, width: w),
      );

  InputDecoration _field(String hint, IconData icon) => InputDecoration(
        isDense: true,
        prefixIcon: Icon(icon, color: SC.textMuted),
        hintText: hint,
        hintStyle: const TextStyle(color: SC.textMuted),
        filled: true,
        fillColor: PopupTokens.ghost,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: _b(PopupTokens.ghostBorder),
        enabledBorder: _b(PopupTokens.ghostBorder),
        focusedBorder: _b(SC.accent, 1.5),
      );

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => PopupSurface(
        sheet: true,
        washHeight: 110,
        child: SizedBox.expand(
          child: Column(
            children: [
              const SizedBox(height: 12),
              const PopupHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
                child: Row(
                  children: [
                    if (_onCityStep)
                      IconButton(
                        icon: const Icon(
                          Icons.arrow_back_rounded,
                          color: Colors.white,
                        ),
                        onPressed: () => setState(() => _onCityStep = false),
                      )
                    else
                      const SizedBox(width: 12),
                    Expanded(
                      child: PopupTitle(
                        _onCityStep
                            ? '${_country!.flag}  ${_country!.name}'
                            : AppStrings.t('onb_location_label'),
                        fontSize: 18,
                        textAlign: TextAlign.start,
                        highlightLast: false,
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
            cursorColor: SC.accent,
            onChanged: (v) => setState(() => _search = v),
            style: SCText.subtitle.copyWith(fontSize: 15),
            decoration: _field(AppStrings.t('loc_search_country'), Icons.search),
          ),
        ),
        if (widget.showDetect && q.isEmpty) ...[
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: _locating
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: SC.accent,
                    ),
                  )
                : const Icon(Icons.my_location_rounded, color: SC.accent),
            title: Text(
              AppStrings.t('onb_location_autodetect'),
              style: SCText.subtitle.copyWith(
                color: SC.accent,
                fontWeight: FontWeight.w800,
              ),
            ),
            subtitle: _detectFailed
                ? Text(
                    AppStrings.t('loc_detect_failed'),
                    style: const TextStyle(color: SC.textMuted, fontSize: 12),
                  )
                : null,
            onTap: _detect,
          ),
          const Divider(height: 1, color: PopupTokens.border),
        ],
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
                  style: SCText.subtitle.copyWith(fontWeight: FontWeight.w700),
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
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _otherCityCtrl,
                textCapitalization: TextCapitalization.words,
                cursorColor: SC.accent,
                style: SCText.subtitle.copyWith(fontSize: 15),
                onSubmitted: (v) {
                  if (v.trim().isNotEmpty) _commitCity(v);
                },
                decoration: _field(
                  AppStrings.t('loc_other_city_hint'),
                  Icons.edit_location_alt_outlined,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              style: IconButton.styleFrom(
                backgroundColor: SC.accent,
                foregroundColor: SC.onAccent,
                minimumSize: const Size(48, 48),
              ),
              icon: const Icon(Icons.check_rounded),
              onPressed: () {
                final v = _otherCityCtrl.text.trim();
                if (v.isNotEmpty) _commitCity(v);
              },
            ),
          ],
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          title: Text(
            AppStrings.t('loc_skip_city'),
            style: SCText.subtitle.copyWith(
              color: SC.textMuted,
              fontWeight: FontWeight.w700,
            ),
          ),
          trailing: const Icon(Icons.chevron_right, color: SC.textMuted),
          onTap: () => _commitCity(''),
        ),
        if (cities.isNotEmpty) const SizedBox(height: 8),
        for (final city in cities)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text(
              city,
              style: SCText.subtitle.copyWith(fontWeight: FontWeight.w700),
            ),
            trailing: city == widget.initialCity &&
                    _country?.name == widget.initialCountry
                ? const Icon(Icons.check_rounded, color: SC.accent)
                : null,
            onTap: () => _commitCity(city),
          ),
      ],
    );
  }
}

