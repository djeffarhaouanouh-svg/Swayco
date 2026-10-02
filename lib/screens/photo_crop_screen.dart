import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';

/// Resize / reframe a picked photo before it is posted: pinch to zoom, drag to
/// position inside a fixed frame of [aspect] (width / height). Pops the cropped
/// JPEG bytes, or null when cancelled.
///
/// Use [PhotoCropScreen.pick] — it returns the original bytes untouched if the
/// image can't be decoded, so a crop bug never blocks posting a photo.
class PhotoCropScreen extends StatefulWidget {
  const PhotoCropScreen({
    super.key,
    required this.bytes,
    required this.aspect,
    required this.maxEdge,
    this.circle = false,
  });

  final Uint8List bytes;
  final double aspect;

  /// Longest edge of the exported image, in px (never upscales).
  final int maxEdge;

  /// Draw a round guide (avatar) instead of a rounded rectangle.
  final bool circle;

  static Future<Uint8List?> pick(
    BuildContext context, {
    required Uint8List bytes,
    required double aspect,
    required int maxEdge,
    bool circle = false,
  }) {
    return Navigator.of(context).push<Uint8List>(
      MaterialPageRoute<Uint8List>(
        fullscreenDialog: true,
        builder: (_) => PhotoCropScreen(
          bytes: bytes,
          aspect: aspect,
          maxEdge: maxEdge,
          circle: circle,
        ),
      ),
    );
  }

  @override
  State<PhotoCropScreen> createState() => _PhotoCropScreenState();
}

class _PhotoCropScreenState extends State<PhotoCropScreen> {
  final _ctrl = TransformationController();
  ui.Image? _image;
  bool _saving = false;
  bool _placed = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() => _image = frame.image);
    } catch (_) {
      // Can't decode here → post the original rather than block the user.
      if (mounted) Navigator.of(context).pop(widget.bytes);
    }
  }

  Future<void> _save(_Layout l) async {
    final image = _image;
    if (image == null || _saving) return;
    setState(() => _saving = true);
    try {
      // Where the whole image sits inside the frame right now (may be smaller
      // than the frame when zoomed out, or overflow it when zoomed in).
      final m = _ctrl.value;
      final placed = MatrixUtils.transformRect(
        m,
        Rect.fromLTWH(0, 0, l.childW, l.childH),
      );
      // Export at the photo's own pixel density (source px per frame px),
      // capped at maxEdge on the long side.
      final scale = m.getMaxScaleOnAxis();
      var outW = l.frameW / (l.base * scale);
      var outH = l.frameH / (l.base * scale);
      final long = outW > outH ? outW : outH;
      if (long > widget.maxEdge) {
        final k = widget.maxEdge / long;
        outW *= k;
        outH *= k;
      }
      outW = outW.roundToDouble().clamp(1, 16384);
      outH = outH.roundToDouble().clamp(1, 16384);
      final k = outW / l.frameW;
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      // Black where the photo doesn't reach the edges of the frame.
      canvas.drawRect(
        Rect.fromLTWH(0, 0, outW, outH),
        Paint()..color = Colors.black,
      );
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTRB(
          placed.left * k,
          placed.top * k,
          placed.right * k,
          placed.bottom * k,
        ),
        Paint()..filterQuality = FilterQuality.high,
      );
      final out = await rec
          .endRecording()
          .toImage(outW.round(), outH.round());
      final data = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = out.width, h = out.height;
      out.dispose();
      if (data == null) throw StateError('no pixels');
      final raw = data.buffer.asUint8List();
      final jpg = await compute(_encodeJpg, (raw, w, h));
      if (!mounted) return;
      Navigator.of(context).pop(jpg);
    } catch (e) {
      debugPrint('photo crop failed: $e');
      // Fall back to the untouched original.
      if (mounted) Navigator.of(context).pop(widget.bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            if (image == null) {
              return const Center(
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              );
            }
            final l = _Layout.compute(
              maxW: box.maxWidth - 32,
              maxH: box.maxHeight - 190,
              aspect: widget.aspect,
              imgW: image.width.toDouble(),
              imgH: image.height.toDouble(),
            );
            if (!_placed) {
              _placed = true;
              // Centre the (cover-fitted) image in the frame.
              _ctrl.value = Matrix4.translationValues(
                -(l.childW - l.frameW) / 2,
                -(l.childH - l.frameH) / 2,
                0,
              );
            }
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: Text(
                          AppStrings.t('cancel'),
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _saving ? null : () => _save(l),
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: SC.accent,
                                ),
                              )
                            : Text(
                                AppStrings.t('save'),
                                style: const TextStyle(
                                  color: SC.accent,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: SizedBox(
                      width: l.frameW,
                      height: l.frameH,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(
                          widget.circle ? l.frameW / 2 : 24,
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            InteractiveViewer(
                          transformationController: _ctrl,
                          constrained: false,
                          // Zoom out down to the whole photo (or further),
                          // zoom in up to 8×, and slide it freely — the
                          // margin lets any edge reach the middle of the frame.
                          minScale: l.minScale,
                          maxScale: 8,
                          boundaryMargin: EdgeInsets.all(
                            l.frameW > l.frameH ? l.frameW : l.frameH,
                          ),
                          child: SizedBox(
                            width: l.childW,
                            height: l.childH,
                            child: RawImage(
                              image: image,
                              fit: BoxFit.fill,
                              filterQuality: FilterQuality.medium,
                            ),
                          ),
                            ),
                            // Où viendront le nom, le lieu et la puce sur la
                            // carte : pour cadrer sans cacher ce qui s'y pose.
                            // Hors export (le JPEG ne reprend que la photo).
                            if (!widget.circle)
                              const IgnorePointer(child: _CardPlaceholders()),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                  child: Text(
                    AppStrings.t('photo_crop_hint'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Emplacements fantômes du bas de la carte Discover, aux mêmes cotes que la
/// vraie carte : dégradé noir, bloc à 20 px des bords / 22 px du bas, nom
/// (28 px) + drapeau, pays - ville (14 px), puce (32 px).
class _CardPlaceholders extends StatelessWidget {
  const _CardPlaceholders();

  @override
  Widget build(BuildContext context) {
    Widget ghost(double w, double h, double a) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: a),
            borderRadius: BorderRadius.circular(999),
          ),
        );
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(0, 0.15),
              end: Alignment.bottomCenter,
              colors: [Color(0x00000000), Color(0xCC000000)],
            ),
          ),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 22,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 31,
                child: Row(
                  children: [
                    ghost(140, 22, 0.35),
                    const SizedBox(width: 10),
                    ghost(24, 24, 0.35),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 17,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ghost(120, 12, 0.25),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: 98,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Uint8List _encodeJpg((Uint8List, int, int) a) {
  final (raw, w, h) = a;
  final image = img.Image.fromBytes(
    width: w,
    height: h,
    bytes: raw.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: 88));
}

class _Layout {
  const _Layout({
    required this.frameW,
    required this.frameH,
    required this.childW,
    required this.childH,
    required this.base,
    required this.minScale,
  });

  final double frameW, frameH;

  /// Zoom-out limit: the whole photo visible (≤ 1), never below 0.3.
  final double minScale;

  /// Size of the image at scale 1 (it exactly covers the frame).
  final double childW, childH;

  /// Displayed px per source px at scale 1.
  final double base;

  factory _Layout.compute({
    required double maxW,
    required double maxH,
    required double aspect,
    required double imgW,
    required double imgH,
  }) {
    var fw = maxW;
    var fh = fw / aspect;
    if (fh > maxH) {
      fh = maxH;
      fw = fh * aspect;
    }
    final base = (fw / imgW) > (fh / imgH) ? fw / imgW : fh / imgH;
    final contain = (fw / imgW) < (fh / imgH) ? fw / imgW : fh / imgH;
    return _Layout(
      minScale: (contain / base).clamp(0.3, 1.0),
      frameW: fw,
      frameH: fh,
      childW: imgW * base,
      childH: imgH * base,
      base: base,
    );
  }
}
