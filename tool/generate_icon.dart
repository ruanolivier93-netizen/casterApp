// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';
import 'package:image/image.dart' as img;

/// Generates the RL Caster app icon:
///   Deep purple-blue background + white circle ring + white play triangle.
void main() {
  Directory('assets').createSync(recursive: true);

  const size = 1024;
  final bg = img.ColorRgba8(75, 90, 230, 255); // #4B5AE6 — deep purple-blue
  final white = img.ColorRgba8(255, 255, 255, 255);

  // ── Full icon (iOS + legacy Android) ──────────────────────────────────────
  final full = img.Image(width: size, height: size);
  img.fill(full, color: bg);
  _drawSymbol(full, white, 512, 512, 1.0);
  File('assets/app_icon.png').writeAsBytesSync(img.encodePng(full));
  print('OK  assets/app_icon.png');

  // ── Adaptive foreground (transparent bg, 68% scale for safe zone) ─────────
  final fg = img.Image(width: size, height: size);
  img.fill(fg, color: img.ColorRgba8(0, 0, 0, 0));
  _drawSymbol(fg, white, 512, 512, 0.68);
  File('assets/app_icon_foreground.png').writeAsBytesSync(img.encodePng(fg));
  print('OK  assets/app_icon_foreground.png');
}

// ── Icon content ──────────────────────────────────────────────────────────────

void _drawSymbol(img.Image image, img.Color color, int cx, int cy, double s) {
  // Bold circle ring
  _ring(image, cx, cy, (400 * s).round(), (344 * s).round(), color);

  // Play triangle (optically centered — shifted right because the visual
  // weight of a right-pointing triangle leans left).
  _filledTriangle(
    image,
    cx + (-120 * s), cy + (-240 * s), // top-left
    cx + (-120 * s), cy + (240 * s), // bottom-left
    cx + (230 * s), cy.toDouble(), // right tip
    color,
  );

  // Three signal arcs radiating from the circle's right edge — gives it
  // the "casting" look and distinguishes it from a generic play button.
  final arcCx = (cx + (400 * s)).round();
  _arc(image, arcCx, cy, (36 * s).round(), (22 * s).round(), color);
  _arc(image, arcCx, cy, (64 * s).round(), (50 * s).round(), color);
  _arc(image, arcCx, cy, (92 * s).round(), (78 * s).round(), color);
}

// ── Drawing primitives ────────────────────────────────────────────────────────

void _ring(img.Image image, int cx, int cy, int oR, int iR, img.Color c) {
  final oR2 = oR * oR;
  final iR2 = iR * iR;
  for (int y = max(0, cy - oR); y <= min(image.height - 1, cy + oR); y++) {
    for (int x = max(0, cx - oR); x <= min(image.width - 1, cx + oR); x++) {
      final d = (x - cx) * (x - cx) + (y - cy) * (y - cy);
      if (d <= oR2 && d >= iR2) image.setPixel(x, y, c);
    }
  }
}

void _filledTriangle(img.Image image, double x1, double y1, double x2,
    double y2, double x3, double y3, img.Color c) {
  final yMin = max(0, [y1, y2, y3].reduce(min).floor());
  final yMax = min(image.height - 1, [y1, y2, y3].reduce(max).ceil());
  final xMin = max(0, [x1, x2, x3].reduce(min).floor());
  final xMax = min(image.width - 1, [x1, x2, x3].reduce(max).ceil());
  for (int y = yMin; y <= yMax; y++) {
    for (int x = xMin; x <= xMax; x++) {
      if (_inTri(x.toDouble(), y.toDouble(), x1, y1, x2, y2, x3, y3)) {
        image.setPixel(x, y, c);
      }
    }
  }
}

bool _inTri(double px, double py, double x1, double y1, double x2, double y2,
    double x3, double y3) {
  final d1 = (px - x2) * (y1 - y2) - (x1 - x2) * (py - y2);
  final d2 = (px - x3) * (y2 - y3) - (x2 - x3) * (py - y3);
  final d3 = (px - x1) * (y3 - y1) - (x3 - x1) * (py - y1);
  return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0));
}

/// Draws a right-facing arc (quarter circle, ±55°) from the given center.
void _arc(img.Image image, int cx, int cy, int oR, int iR, img.Color c) {
  final oR2 = oR * oR;
  final iR2 = iR * iR;
  const limitDeg = 55.0;
  final limitRad = limitDeg * pi / 180;
  for (int y = max(0, cy - oR); y <= min(image.height - 1, cy + oR); y++) {
    for (int x = max(0, cx); x <= min(image.width - 1, cx + oR); x++) {
      final dx = x - cx;
      final dy = y - cy;
      final d = dx * dx + dy * dy;
      if (d > oR2 || d < iR2) continue;
      final angle = atan2(dy.toDouble(), dx.toDouble());
      if (angle.abs() <= limitRad) image.setPixel(x, y, c);
    }
  }
}
