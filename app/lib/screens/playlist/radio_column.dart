import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/radio_library.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_chip.dart';
import '../../widgets/rm_icon.dart';

/// playlist 看板的一列 — 支持三种 mode：
/// - customRadio: 接受拖入 + 显示 pool 中分配的歌
/// - builtinRadio: 半透明斜条纹背景 + 拖入弹切换警告
/// - pool: 虚线边 + 接受 unassign
enum ColumnKind { customRadio, builtinRadio, pool }

/// 列容器。拖拽接受与悬停高亮（`DragTarget` + overlay）由外层主屏处理；
/// 本 widget 只负责列的静态外观。
class PlaylistColumn extends StatefulWidget {
  const PlaylistColumn({
    super.key,
    required this.kind,
    required this.header,
    required this.children,
    this.emptyText,
  }) : itemCount = children.length,
       itemBuilder = null;

  const PlaylistColumn.builder({
    super.key,
    required this.kind,
    required this.header,
    required this.itemCount,
    required this.itemBuilder,
    this.emptyText,
  }) : children = const [];

  /// 普通电台列 (custom or builtin)
  factory PlaylistColumn.radio({
    required RadioStation radio,
    required bool isCustom,
    required int count,
    int? capacity,
    required List<Widget> children,
    VoidCallback? onRestoreBuiltin,
  }) {
    return PlaylistColumn(
      kind: isCustom ? ColumnKind.customRadio : ColumnKind.builtinRadio,
      header: _RadioHeader(
        radio: radio,
        isCustom: isCustom,
        count: count,
        capacity: capacity ?? radio.slot,
        onRestoreBuiltin: onRestoreBuiltin,
      ),
      emptyText: isCustom ? '空 · 拖入池中曲目' : '无原版数据',
      children: children,
    );
  }

  factory PlaylistColumn.poolBuilder({
    required int count,
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
  }) {
    return PlaylistColumn.builder(
      kind: ColumnKind.pool,
      header: _PoolHeader(count: count),
      emptyText: '没有导入歌曲',
      itemCount: itemCount,
      itemBuilder: itemBuilder,
    );
  }

  final ColumnKind kind;
  final Widget header;
  final List<Widget> children;
  final int itemCount;
  final IndexedWidgetBuilder? itemBuilder;
  final String? emptyText;

  @override
  State<PlaylistColumn> createState() => _PlaylistColumnState();
}

class _PlaylistColumnState extends State<PlaylistColumn> {
  bool _ctrlPressed = HardwareKeyboard.instance.isControlPressed;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    final next = HardwareKeyboard.instance.isControlPressed;
    if (next != _ctrlPressed && mounted) {
      setState(() => _ctrlPressed = next);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final builtin = widget.kind == ColumnKind.builtinRadio;
    final pool = widget.kind == ColumnKind.pool;

    final Color bg = pool ? rm.raised : rm.panel;
    final Color borderColor = pool ? Colors.transparent : rm.border;

    final borderRadius = BorderRadius.circular(RmTokens.rLg);
    final content = Container(
      constraints: const BoxConstraints(minHeight: 480),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: borderRadius,
        border: Border.all(color: borderColor),
      ),
      child: Stack(
        children: [
          if (builtin)
            Positioned.fill(
              child: CustomPaint(
                painter: _DiagonalStripePainter(
                  color: rm.border.withAlpha(150),
                ),
              ),
            ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: rm.border)),
                ),
                child: widget.header,
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: rm.border)),
                ),
                child: _meta(context),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: widget.itemCount == 0
                      ? _empty(context)
                      : ListView.separated(
                          primary: false,
                          physics: builtin && !_ctrlPressed
                              ? const NeverScrollableScrollPhysics()
                              : const ClampingScrollPhysics(),
                          itemCount: widget.itemCount,
                          separatorBuilder: (_, _) => const SizedBox(height: 4),
                          itemBuilder: (context, i) {
                            final itemBuilder = widget.itemBuilder;
                            if (itemBuilder != null) {
                              return itemBuilder(context, i);
                            }
                            return widget.children[i];
                          },
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (!pool) return content;
    return CustomPaint(
      foregroundPainter: _DashedRRectPainter(
        color: rm.borderStrong,
        radius: RmTokens.rLg,
      ),
      child: content,
    );
  }

  Widget _meta(BuildContext context) {
    return widget.header is _RadioHeader
        ? Text(
            '${(widget.header as _RadioHeader).count} / ${(widget.header as _RadioHeader).capacity}',
            style: RmText.mono(10.5, color: context.rm.fg3),
          )
        : Text(
            '${(widget.header as _PoolHeader).count} 首',
            style: RmText.mono(10.5, color: context.rm.fg3),
          );
  }

  Widget _empty(BuildContext context) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 20),
      child: Center(
        child: Text(
          widget.emptyText ?? '',
          style: RmText.mono(11.5, color: rm.fg4),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _RadioHeader extends StatelessWidget {
  const _RadioHeader({
    required this.radio,
    required this.isCustom,
    required this.count,
    required this.capacity,
    this.onRestoreBuiltin,
  });

  final RadioStation radio;
  final bool isCustom;
  final int count;
  final int capacity;
  final VoidCallback? onRestoreBuiltin;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: rm.raised,
                border: Border.all(color: rm.border),
                borderRadius: BorderRadius.circular(5),
              ),
              alignment: Alignment.center,
              child: Text(
                radio.code,
                style: RmText.mono(
                  10,
                  weight: FontWeight.w700,
                  color: _swatchColor(rm, radio.hue),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    radio.name,
                    style: RmText.sans(
                      13,
                      weight: FontWeight.w600,
                      color: rm.fg,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    radio.genre,
                    style: RmText.mono(10.5, color: rm.fg3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            isCustom
                ? const RmChip(
                    label: 'custom',
                    variant: RmChipVariant.accent,
                    showDot: true,
                  )
                : const RmChip(
                    label: 'builtin',
                    variant: RmChipVariant.muted,
                    leading: RmIcon('lock', size: 9),
                  ),
            if (isCustom && onRestoreBuiltin != null) ...[
              const SizedBox(width: 4),
              RmButton.icon(
                onPressed: onRestoreBuiltin,
                icon: const RmIcon('undo', size: 12),
                variant: RmButtonVariant.ghost,
                tooltip: '恢复当前列表为 builtin',
              ),
            ],
          ],
        ),
      ],
    );
  }

  Color _swatchColor(RmTheme rm, String hue) {
    switch (hue) {
      case 'lime':
        return const Color(0xFF23A136);
      case 'cyan':
        return const Color(0xFF008DA4);
      case 'orange':
        return const Color(0xFFD75C00);
      case 'magenta':
        return const Color(0xFFBD2099);
      case 'red':
        return rm.danger;
      case 'violet':
        return const Color(0xFF6F4DBF);
      case 'yellow':
        return const Color(0xFFA68000);
      case 'teal':
        return const Color(0xFF008B83);
    }
    return rm.fg;
  }
}

class _PoolHeader extends StatelessWidget {
  const _PoolHeader({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: rm.raised,
                border: Border.all(color: rm.border),
                borderRadius: BorderRadius.circular(5),
              ),
              alignment: Alignment.center,
              child: RmIcon('music', size: 12, color: rm.fg2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '池子',
                    style: RmText.sans(
                      13,
                      weight: FontWeight.w600,
                      color: rm.fg,
                    ),
                  ),
                  Text(
                    '全部曲目 · 配置完善靠前',
                    style: RmText.mono(10.5, color: rm.fg3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DiagonalStripePainter extends CustomPainter {
  const _DiagonalStripePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const gap = 14.0;
    for (double x = -size.height; x < size.width + size.height; x += gap) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DiagonalStripePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rect = Offset.zero & size;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius)),
      );
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + 5).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += 9;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.radius != radius;
  }
}
