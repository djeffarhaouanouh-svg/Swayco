import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/giphy_api.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

/// Ouvre le sélecteur de GIF et rend celui qu'on a touché (null si on ferme).
Future<GiphyGif?> showGifPicker(BuildContext context) {
  return showModalBottomSheet<GiphyGif>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (_) => const _GifPickerSheet(),
  );
}

class _GifPickerSheet extends StatefulWidget {
  const _GifPickerSheet();

  @override
  State<_GifPickerSheet> createState() => _GifPickerSheetState();
}

class _GifPickerSheetState extends State<_GifPickerSheet> {
  static const _pageSize = 30;

  final _query = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;

  List<GiphyGif> _gifs = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _exhausted = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _exhausted = false;
    });
    final res = await GiphyApi.search(_query.text, limit: _pageSize);
    if (!mounted) return;
    setState(() {
      _gifs = res;
      _loading = false;
      _exhausted = res.length < _pageSize;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted || _loading) return;
    setState(() => _loadingMore = true);
    final res = await GiphyApi.search(
      _query.text,
      limit: _pageSize,
      offset: _gifs.length,
    );
    if (!mounted) return;
    setState(() {
      _gifs = [..._gifs, ...res];
      _loadingMore = false;
      _exhausted = res.length < _pageSize;
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final left = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (left < 600) _loadMore();
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 320), _load);
  }

  List<List<GiphyGif>> get _columns {
    final left = <GiphyGif>[];
    final right = <GiphyGif>[];
    for (final (i, g) in _gifs.indexed) {
      (i.isEven ? left : right).add(g);
    }
    return [left, right];
  }

  static OutlineInputBorder _b(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: c, width: w),
      );

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: FractionallySizedBox(
        heightFactor: 0.82,
        child: PopupSurface(
          sheet: true,
          washHeight: 110,
          child: SizedBox.expand(
            child: Column(
              children: [
                const SizedBox(height: 12),
                const PopupHandle(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: TextField(
                    controller: _query,
                    onChanged: _onQueryChanged,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _load(),
                    cursorColor: SC.accentFg,
                    style: SCText.subtitle.copyWith(fontSize: 15),
                    decoration: InputDecoration(
                      hintText: AppStrings.t('gif_search_hint'),
                      hintStyle: TextStyle(color: SC.textMuted),
                      prefixIcon: Icon(Icons.search, color: SC.textMuted),
                      isDense: true,
                      filled: true,
                      fillColor: PopupTokens.ghost,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      border: _b(PopupTokens.ghostBorder),
                      enabledBorder: _b(PopupTokens.ghostBorder),
                      focusedBorder: _b(SC.accent, 1.5),
                    ),
                  ),
                ),
                Expanded(child: _buildBody()),
                // Attribution : Giphy l'exige dès qu'on affiche son catalogue.
                Padding(
                  padding: EdgeInsets.only(
                    top: 6,
                    bottom: 8 + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: Text(
                    'POWERED BY GIPHY',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
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

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(color: SC.accentFg, strokeWidth: 2),
      );
    }
    if (_gifs.isEmpty) {
      return Center(
        child: Text(
          AppStrings.t('gif_none'),
          style: SCText.subtitle.copyWith(color: SC.textMuted, fontSize: 14),
        ),
      );
    }
    final cols = _columns;
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, col) in cols.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: Column(
                  children: [
                    for (final gif in col)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _GifTile(
                          gif: gif,
                          onTap: () => Navigator.of(context).pop(gif),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
        if (_loadingMore)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: CircularProgressIndicator(color: SC.accentFg, strokeWidth: 2),
            ),
          ),
      ],
    );
  }
}

class _GifTile extends StatelessWidget {
  const _GifTile({required this.gif, required this.onTap});

  final GiphyGif gif;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: gif.aspect,
          child: ColoredBox(
            color: PopupTokens.ghost,
            child: Image.network(
              gif.previewUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Center(
                child: Icon(Icons.broken_image_outlined, color: SC.textMuted),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

