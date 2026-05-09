import 'package:flutter/material.dart';

/// McGill Pain Questionnaire 風の Body Pain Map ウィジェット。
///
/// SVG互換のPath命令を CustomPainter で描画した人体シルエット。
/// 元データは assets/images/body_silhouette.svg（CC0・自作）と同じ。
///
/// **鏡像表示（mirror view）**：画面左 = 患者の左
class BodyDiagram extends StatelessWidget {
  final Set<String> selectedKeys;
  final void Function(String key) onTap;
  final Color accent;

  const BodyDiagram({
    super.key,
    required this.selectedKeys,
    required this.onTap,
    this.accent = const Color(0xFF1565C0),
  });

  // viewBox 100x220 に対応するヒットゾーン（パーセンテージ）
  static const _zones = <_HitZone>[
    _HitZone('head',     top: 0.020, left: 0.380, width: 0.240, height: 0.130),
    _HitZone('neck',     top: 0.135, left: 0.430, width: 0.140, height: 0.040),
    _HitZone('chest',    top: 0.165, left: 0.220, width: 0.560, height: 0.165),
    _HitZone('abdomen',  top: 0.330, left: 0.220, width: 0.560, height: 0.180),
    _HitZone('arm_left', top: 0.205, left: 0.080, width: 0.170, height: 0.345),
    _HitZone('arm_right',top: 0.205, left: 0.750, width: 0.170, height: 0.345),
    _HitZone('leg_left', top: 0.510, left: 0.230, width: 0.260, height: 0.475),
    _HitZone('leg_right',top: 0.510, left: 0.510, width: 0.260, height: 0.475),
  ];

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 100 / 220,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          return Stack(
            children: [
              // ─── ① 体のシルエット（CustomPainter） ─────────
              Positioned.fill(
                child: CustomPaint(
                  painter: _BodyPainter(
                    selected: selectedKeys,
                    accent: accent,
                  ),
                ),
              ),

              // ─── ② タップゾーン ─────────────────────────────
              ..._zones.map((z) {
                return Positioned(
                  left: z.left * w,
                  top: z.top * h,
                  width: z.width * w,
                  height: z.height * h,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => onTap(z.key),
                      borderRadius: BorderRadius.circular(12),
                      splashColor: accent.withValues(alpha: 0.3),
                      child: selectedKeys.contains(z.key)
                          ? Center(
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white,
                                  boxShadow: [
                                    BoxShadow(
                                      color: accent.withValues(alpha: 0.6),
                                      blurRadius: 6,
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  Icons.check,
                                  color: accent,
                                  size: 14,
                                ),
                              ),
                            )
                          : null,
                    ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}

class _HitZone {
  final String key;
  final double top;
  final double left;
  final double width;
  final double height;
  const _HitZone(
    this.key, {
    required this.top,
    required this.left,
    required this.width,
    required this.height,
  });
}

/// SVG (assets/images/body_silhouette.svg) と同じ形状を CustomPaint で描画。
/// viewBox: 0 0 100 220 を Canvas にマッピング。
class _BodyPainter extends CustomPainter {
  final Set<String> selected;
  final Color accent;

  _BodyPainter({required this.selected, required this.accent});

  // viewBox の (vx, vy) を Canvas 座標に変換
  Offset _v(double vx, double vy, Size size) {
    return Offset(vx / 100 * size.width, vy / 220 * size.height);
  }

  Color _fillFor(String key) =>
      selected.contains(key) ? accent : const Color(0xFF2D4A6B);

  @override
  void paint(Canvas canvas, Size size) {
    final outline = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    void drawRegion(Path p, String key) {
      // グラデーション風のフィル
      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: selected.contains(key)
              ? [
                  accent.withValues(alpha: 0.95),
                  accent.withValues(alpha: 0.75),
                ]
              : const [
                  Color(0xFF2D4A6B),
                  Color(0xFF1E3550),
                ],
        ).createShader(p.getBounds());
      canvas.drawPath(p, fillPaint);
      canvas.drawPath(p, outline);
    }

    // ━━ HEAD ━━ ellipse(cx=50, cy=18, rx=11, ry=13.5)
    final headPath = Path()
      ..addOval(Rect.fromCenter(
        center: _v(50, 18, size),
        width: _v(11, 0, size).dx * 2,
        height: _v(0, 13.5, size).dy * 2,
      ));
    drawRegion(headPath, 'head');

    // ━━ NECK ━━ Trapezoid M44.5,30 Q44,33 43.5,36 L56.5,36 Q56,33 55.5,30 Z
    final neckPath = Path()
      ..moveTo(_v(44.5, 30, size).dx, _v(44.5, 30, size).dy)
      ..quadraticBezierTo(
        _v(44, 33, size).dx, _v(44, 33, size).dy,
        _v(43.5, 36, size).dx, _v(43.5, 36, size).dy,
      )
      ..lineTo(_v(56.5, 36, size).dx, _v(56.5, 36, size).dy)
      ..quadraticBezierTo(
        _v(56, 33, size).dx, _v(56, 33, size).dy,
        _v(55.5, 30, size).dx, _v(55.5, 30, size).dy,
      )
      ..close();
    drawRegion(neckPath, 'neck');

    // ━━ CHEST ━━
    // M43.5,36 C36,36 28,39 24,46 C22,52 22,58 22,62 L22,72 L78,72 L78,62
    // C78,58 78,52 76,46 C72,39 64,36 56.5,36 Z
    final chestPath = Path()
      ..moveTo(_v(43.5, 36, size).dx, _v(43.5, 36, size).dy)
      ..cubicTo(
        _v(36, 36, size).dx, _v(36, 36, size).dy,
        _v(28, 39, size).dx, _v(28, 39, size).dy,
        _v(24, 46, size).dx, _v(24, 46, size).dy,
      )
      ..cubicTo(
        _v(22, 52, size).dx, _v(22, 52, size).dy,
        _v(22, 58, size).dx, _v(22, 58, size).dy,
        _v(22, 62, size).dx, _v(22, 62, size).dy,
      )
      ..lineTo(_v(22, 72, size).dx, _v(22, 72, size).dy)
      ..lineTo(_v(78, 72, size).dx, _v(78, 72, size).dy)
      ..lineTo(_v(78, 62, size).dx, _v(78, 62, size).dy)
      ..cubicTo(
        _v(78, 58, size).dx, _v(78, 58, size).dy,
        _v(78, 52, size).dx, _v(78, 52, size).dy,
        _v(76, 46, size).dx, _v(76, 46, size).dy,
      )
      ..cubicTo(
        _v(72, 39, size).dx, _v(72, 39, size).dy,
        _v(64, 36, size).dx, _v(64, 36, size).dy,
        _v(56.5, 36, size).dx, _v(56.5, 36, size).dy,
      )
      ..close();
    drawRegion(chestPath, 'chest');

    // ━━ ABDOMEN ━━
    // M22,72 C21,80 21,88 22,96 C22,102 23,108 24,112 L76,112
    // C77,108 78,102 78,96 C79,88 79,80 78,72 Z
    final abdomenPath = Path()
      ..moveTo(_v(22, 72, size).dx, _v(22, 72, size).dy)
      ..cubicTo(
        _v(21, 80, size).dx, _v(21, 80, size).dy,
        _v(21, 88, size).dx, _v(21, 88, size).dy,
        _v(22, 96, size).dx, _v(22, 96, size).dy,
      )
      ..cubicTo(
        _v(22, 102, size).dx, _v(22, 102, size).dy,
        _v(23, 108, size).dx, _v(23, 108, size).dy,
        _v(24, 112, size).dx, _v(24, 112, size).dy,
      )
      ..lineTo(_v(76, 112, size).dx, _v(76, 112, size).dy)
      ..cubicTo(
        _v(77, 108, size).dx, _v(77, 108, size).dy,
        _v(78, 102, size).dx, _v(78, 102, size).dy,
        _v(78, 96, size).dx, _v(78, 96, size).dy,
      )
      ..cubicTo(
        _v(79, 88, size).dx, _v(79, 88, size).dy,
        _v(79, 80, size).dx, _v(79, 80, size).dy,
        _v(78, 72, size).dx, _v(78, 72, size).dy,
      )
      ..close();
    drawRegion(abdomenPath, 'abdomen');

    // ━━ LEFT ARM ━━
    final armLeftPath = Path()
      ..moveTo(_v(22, 46, size).dx, _v(22, 46, size).dy)
      ..cubicTo(
        _v(18, 49, size).dx, _v(18, 49, size).dy,
        _v(14, 55, size).dx, _v(14, 55, size).dy,
        _v(12, 62, size).dx, _v(12, 62, size).dy,
      )
      ..cubicTo(
        _v(10, 70, size).dx, _v(10, 70, size).dy,
        _v(9, 80, size).dx, _v(9, 80, size).dy,
        _v(9, 90, size).dx, _v(9, 90, size).dy,
      )
      ..cubicTo(
        _v(9, 98, size).dx, _v(9, 98, size).dy,
        _v(10, 106, size).dx, _v(10, 106, size).dy,
        _v(11, 112, size).dx, _v(11, 112, size).dy,
      )
      ..cubicTo(
        _v(12, 116, size).dx, _v(12, 116, size).dy,
        _v(13, 118, size).dx, _v(13, 118, size).dy,
        _v(14, 120, size).dx, _v(14, 120, size).dy,
      )
      ..cubicTo(
        _v(15, 121, size).dx, _v(15, 121, size).dy,
        _v(17, 121, size).dx, _v(17, 121, size).dy,
        _v(18, 120, size).dx, _v(18, 120, size).dy,
      )
      ..cubicTo(
        _v(19, 119, size).dx, _v(19, 119, size).dy,
        _v(20, 117, size).dx, _v(20, 117, size).dy,
        _v(20, 114, size).dx, _v(20, 114, size).dy,
      )
      ..cubicTo(
        _v(21, 108, size).dx, _v(21, 108, size).dy,
        _v(22, 100, size).dx, _v(22, 100, size).dy,
        _v(23, 92, size).dx, _v(23, 92, size).dy,
      )
      ..cubicTo(
        _v(24, 82, size).dx, _v(24, 82, size).dy,
        _v(25, 72, size).dx, _v(25, 72, size).dy,
        _v(24, 62, size).dx, _v(24, 62, size).dy,
      )
      ..cubicTo(
        _v(24, 56, size).dx, _v(24, 56, size).dy,
        _v(23, 50, size).dx, _v(23, 50, size).dy,
        _v(22, 46, size).dx, _v(22, 46, size).dy,
      )
      ..close();
    drawRegion(armLeftPath, 'arm_left');

    // ━━ RIGHT ARM ━━ (mirror of left)
    final armRightPath = Path()
      ..moveTo(_v(78, 46, size).dx, _v(78, 46, size).dy)
      ..cubicTo(
        _v(82, 49, size).dx, _v(82, 49, size).dy,
        _v(86, 55, size).dx, _v(86, 55, size).dy,
        _v(88, 62, size).dx, _v(88, 62, size).dy,
      )
      ..cubicTo(
        _v(90, 70, size).dx, _v(90, 70, size).dy,
        _v(91, 80, size).dx, _v(91, 80, size).dy,
        _v(91, 90, size).dx, _v(91, 90, size).dy,
      )
      ..cubicTo(
        _v(91, 98, size).dx, _v(91, 98, size).dy,
        _v(90, 106, size).dx, _v(90, 106, size).dy,
        _v(89, 112, size).dx, _v(89, 112, size).dy,
      )
      ..cubicTo(
        _v(88, 116, size).dx, _v(88, 116, size).dy,
        _v(87, 118, size).dx, _v(87, 118, size).dy,
        _v(86, 120, size).dx, _v(86, 120, size).dy,
      )
      ..cubicTo(
        _v(85, 121, size).dx, _v(85, 121, size).dy,
        _v(83, 121, size).dx, _v(83, 121, size).dy,
        _v(82, 120, size).dx, _v(82, 120, size).dy,
      )
      ..cubicTo(
        _v(81, 119, size).dx, _v(81, 119, size).dy,
        _v(80, 117, size).dx, _v(80, 117, size).dy,
        _v(80, 114, size).dx, _v(80, 114, size).dy,
      )
      ..cubicTo(
        _v(79, 108, size).dx, _v(79, 108, size).dy,
        _v(78, 100, size).dx, _v(78, 100, size).dy,
        _v(77, 92, size).dx, _v(77, 92, size).dy,
      )
      ..cubicTo(
        _v(76, 82, size).dx, _v(76, 82, size).dy,
        _v(75, 72, size).dx, _v(75, 72, size).dy,
        _v(76, 62, size).dx, _v(76, 62, size).dy,
      )
      ..cubicTo(
        _v(76, 56, size).dx, _v(76, 56, size).dy,
        _v(77, 50, size).dx, _v(77, 50, size).dy,
        _v(78, 46, size).dx, _v(78, 46, size).dy,
      )
      ..close();
    drawRegion(armRightPath, 'arm_right');

    // ━━ LEFT LEG ━━
    final legLeftPath = Path()
      ..moveTo(_v(24, 112, size).dx, _v(24, 112, size).dy)
      ..cubicTo(
        _v(23, 128, size).dx, _v(23, 128, size).dy,
        _v(23, 144, size).dx, _v(23, 144, size).dy,
        _v(25, 160, size).dx, _v(25, 160, size).dy,
      )
      ..cubicTo(
        _v(26, 176, size).dx, _v(26, 176, size).dy,
        _v(28, 192, size).dx, _v(28, 192, size).dy,
        _v(30, 205, size).dx, _v(30, 205, size).dy,
      )
      ..cubicTo(
        _v(31, 208, size).dx, _v(31, 208, size).dy,
        _v(32, 210, size).dx, _v(32, 210, size).dy,
        _v(33, 212, size).dx, _v(33, 212, size).dy,
      )
      ..lineTo(_v(47, 212, size).dx, _v(47, 212, size).dy)
      ..cubicTo(
        _v(47.5, 208, size).dx, _v(47.5, 208, size).dy,
        _v(48, 202, size).dx, _v(48, 202, size).dy,
        _v(48, 196, size).dx, _v(48, 196, size).dy,
      )
      ..cubicTo(
        _v(48, 180, size).dx, _v(48, 180, size).dy,
        _v(47, 164, size).dx, _v(47, 164, size).dy,
        _v(46, 148, size).dx, _v(46, 148, size).dy,
      )
      ..cubicTo(
        _v(45, 136, size).dx, _v(45, 136, size).dy,
        _v(45, 124, size).dx, _v(45, 124, size).dy,
        _v(46, 112, size).dx, _v(46, 112, size).dy,
      )
      ..close();
    drawRegion(legLeftPath, 'leg_left');

    // ━━ RIGHT LEG ━━
    final legRightPath = Path()
      ..moveTo(_v(76, 112, size).dx, _v(76, 112, size).dy)
      ..cubicTo(
        _v(77, 128, size).dx, _v(77, 128, size).dy,
        _v(77, 144, size).dx, _v(77, 144, size).dy,
        _v(75, 160, size).dx, _v(75, 160, size).dy,
      )
      ..cubicTo(
        _v(74, 176, size).dx, _v(74, 176, size).dy,
        _v(72, 192, size).dx, _v(72, 192, size).dy,
        _v(70, 205, size).dx, _v(70, 205, size).dy,
      )
      ..cubicTo(
        _v(69, 208, size).dx, _v(69, 208, size).dy,
        _v(68, 210, size).dx, _v(68, 210, size).dy,
        _v(67, 212, size).dx, _v(67, 212, size).dy,
      )
      ..lineTo(_v(53, 212, size).dx, _v(53, 212, size).dy)
      ..cubicTo(
        _v(52.5, 208, size).dx, _v(52.5, 208, size).dy,
        _v(52, 202, size).dx, _v(52, 202, size).dy,
        _v(52, 196, size).dx, _v(52, 196, size).dy,
      )
      ..cubicTo(
        _v(52, 180, size).dx, _v(52, 180, size).dy,
        _v(53, 164, size).dx, _v(53, 164, size).dy,
        _v(54, 148, size).dx, _v(54, 148, size).dy,
      )
      ..cubicTo(
        _v(55, 136, size).dx, _v(55, 136, size).dy,
        _v(55, 124, size).dx, _v(55, 124, size).dy,
        _v(54, 112, size).dx, _v(54, 112, size).dy,
      )
      ..close();
    drawRegion(legRightPath, 'leg_right');

    // ━━ FEET ━━
    final feetPaint = Paint()
      ..color = const Color(0xFF1E3550)
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(
        center: _v(40, 214, size),
        width: _v(9, 0, size).dx * 2,
        height: _v(0, 3, size).dy * 2,
      ),
      feetPaint,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: _v(40, 214, size),
        width: _v(9, 0, size).dx * 2,
        height: _v(0, 3, size).dy * 2,
      ),
      outline,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: _v(60, 214, size),
        width: _v(9, 0, size).dx * 2,
        height: _v(0, 3, size).dy * 2,
      ),
      feetPaint,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: _v(60, 214, size),
        width: _v(9, 0, size).dx * 2,
        height: _v(0, 3, size).dy * 2,
      ),
      outline,
    );

    // ━━ FACE FEATURES ━━
    final featureFill = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;
    final featureStroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..strokeCap = StrokeCap.round;

    // 眉毛
    canvas.drawLine(
      _v(42.5, 14, size),
      _v(46.5, 13.5, size),
      featureStroke,
    );
    canvas.drawLine(
      _v(53.5, 13.5, size),
      _v(57.5, 14, size),
      featureStroke,
    );
    // 目
    canvas.drawCircle(_v(45.5, 17, size), _v(0.95, 0, size).dx, featureFill);
    canvas.drawCircle(_v(54.5, 17, size), _v(0.95, 0, size).dx, featureFill);
    // 鼻のヒント
    final noseStroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.30)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    canvas.drawLine(_v(50, 19, size), _v(50, 22, size), noseStroke);
    // 口（やわらかい笑み）
    final mouthPath = Path()
      ..moveTo(_v(46, 24, size).dx, _v(46, 24, size).dy)
      ..quadraticBezierTo(
        _v(50, 25.5, size).dx, _v(50, 25.5, size).dy,
        _v(54, 24, size).dx, _v(54, 24, size).dy,
      );
    canvas.drawPath(mouthPath, featureStroke);

    // ━━ 中心線（装飾） ━━
    final centerLine = Paint()
      ..color = Colors.white.withValues(alpha: 0.10)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    canvas.drawLine(
      _v(50, 38, size),
      _v(50, 110, size),
      centerLine,
    );
  }

  @override
  bool shouldRepaint(_BodyPainter old) =>
      old.selected != selected || old.accent != accent;
}
