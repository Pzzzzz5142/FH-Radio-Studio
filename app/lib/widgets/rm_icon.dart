import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 把原型 ui.jsx 里的 `<Icon name="..."/>` 名字映射到 Lucide IconData。
///
/// 设计原型用 stroke style 内联 SVG —— Lucide 风格最接近。
/// 个别名字与 lucide 不一致时在这里做映射。
class RmIcon extends StatelessWidget {
  const RmIcon(this.name, {super.key, this.size = 14, this.color});

  final String name;
  final double size;
  final Color? color;

  static IconData? resolve(String name) {
    switch (name) {
      case 'dashboard':
        return LucideIcons.layoutDashboard;
      case 'swap':
        return LucideIcons.arrowLeftRight;
      case 'list':
        return LucideIcons.listMusic;
      case 'loop':
        return LucideIcons.repeat;
      case 'history':
        return LucideIcons.history;
      case 'settings':
        return LucideIcons.settings;
      case 'play':
        return LucideIcons.play;
      case 'pause':
        return LucideIcons.pause;
      case 'check':
        return LucideIcons.check;
      case 'x':
        return LucideIcons.x;
      case 'arrow-right':
        return LucideIcons.arrowRight;
      case 'chevron-left':
        return LucideIcons.chevronLeft;
      case 'folder':
        return LucideIcons.folder;
      case 'plus':
        return LucideIcons.plus;
      case 'warn':
        return LucideIcons.triangleAlert;
      case 'danger':
        return LucideIcons.circleAlert;
      case 'info':
        return LucideIcons.info;
      case 'search':
        return LucideIcons.search;
      case 'drag':
        return LucideIcons.gripVertical;
      case 'zoom-in':
        return LucideIcons.zoomIn;
      case 'zoom-out':
        return LucideIcons.zoomOut;
      case 'skip-back':
        return LucideIcons.skipBack;
      case 'skip-fwd':
        return LucideIcons.skipForward;
      case 'lock':
        return LucideIcons.lock;
      case 'unlock':
        return LucideIcons.lockOpen;
      case 'shield':
        return LucideIcons.shield;
      case 'trash':
        return LucideIcons.trash2;
      case 'undo':
        return LucideIcons.rotateCcw;
      case 'refresh':
        return LucideIcons.refreshCw;
      case 'wrench':
        return LucideIcons.wrench;
      case 'copy':
        return LucideIcons.copy;
      case 'import':
        return LucideIcons.download;
      case 'export':
        return LucideIcons.upload;
      case 'dot':
        return LucideIcons.dot;
      case 'command':
        return LucideIcons.command;
      case 'spark':
        return LucideIcons.sparkles;
      case 'music':
        return LucideIcons.music;
      case 'file':
        return LucideIcons.fileText;
      case 'crosshair':
        return LucideIcons.crosshair;
      case 'chevron-up':
        return LucideIcons.chevronUp;
      case 'chevron-down':
        return LucideIcons.chevronDown;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final data = resolve(name) ?? LucideIcons.circle;
    return Icon(data, size: size, color: color);
  }
}
