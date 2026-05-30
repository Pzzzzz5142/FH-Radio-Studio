import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../core/system_audio_output.dart';
import '../state/studio_state.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import 'rm_button.dart';
import 'rm_icon.dart';

Future<double?> showPackageLoudnessDialog(
  BuildContext context, {
  required double referenceMedianLufs,
  required double initialOffsetLu,
  required double previewInputLufs,
  String? previewSource,
  String? previewTitle,
  String? previewArtist,
  double? currentPackageOffsetLu,
}) {
  return showDialog<double>(
    context: context,
    barrierColor: RmTokens.modalBackdrop,
    builder: (context) => PackageLoudnessDialog(
      referenceMedianLufs: referenceMedianLufs,
      initialOffsetLu: initialOffsetLu,
      previewInputLufs: previewInputLufs,
      previewSource: previewSource,
      previewTitle: previewTitle,
      previewArtist: previewArtist,
      currentPackageOffsetLu: currentPackageOffsetLu,
    ),
  );
}

class PackageLoudnessDialog extends StatefulWidget {
  const PackageLoudnessDialog({
    super.key,
    required this.referenceMedianLufs,
    required this.initialOffsetLu,
    required this.previewInputLufs,
    this.previewSource,
    this.previewTitle,
    this.previewArtist,
    this.currentPackageOffsetLu,
  });

  final double referenceMedianLufs;
  final double initialOffsetLu;
  final double previewInputLufs;
  final String? previewSource;
  final String? previewTitle;
  final String? previewArtist;
  final double? currentPackageOffsetLu;

  @override
  State<PackageLoudnessDialog> createState() => _PackageLoudnessDialogState();
}

class _PackageLoudnessDialogState extends State<PackageLoudnessDialog> {
  late double _offsetLu;

  @override
  void initState() {
    super.initState();
    _offsetLu = _nearestPackageLoudnessOffset(widget.initialOffsetLu);
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final targetLufs = widget.referenceMedianLufs + _offsetLu;
    final selectedOption = _loudnessOptionForOffset(_offsetLu);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      child: Container(
        width: 640,
        decoration: BoxDecoration(
          color: rm.panel,
          border: Border.all(color: rm.borderStrong),
          borderRadius: BorderRadius.circular(RmTokens.rXl),
          boxShadow: RmTokens.modal,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: rm.accent.bg,
                      border: Border.all(color: rm.accent.ring),
                      borderRadius: BorderRadius.circular(RmTokens.rMd),
                    ),
                    child: RmIcon('volume', size: 18, color: rm.accent.base),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '响度战争',
                              style: RmText.sans(
                                11,
                                weight: FontWeight.w600,
                                letterSpacing: 0,
                                color: rm.accent.base,
                              ),
                            ),
                            Container(
                              width: 3,
                              height: 3,
                              margin: const EdgeInsets.symmetric(horizontal: 8),
                              decoration: BoxDecoration(
                                color: rm.accent.base.withAlpha(150),
                                shape: BoxShape.circle,
                              ),
                            ),
                            Text(
                              'LOUDNESS WAR',
                              style: RmText.mono(
                                10.5,
                                weight: FontWeight.w500,
                                letterSpacing: 0,
                                color: rm.accent.base,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '准备包响度',
                          style: RmText.sans(
                            19,
                            weight: FontWeight.w600,
                            letterSpacing: 0,
                            height: 1.2,
                            color: rm.fg,
                          ),
                        ),
                        const SizedBox(height: 6),
                        RichText(
                          text: TextSpan(
                            style: RmText.sans(13, color: rm.fg2, height: 1.6),
                            children: [
                              const TextSpan(
                                text:
                                    '直接对齐原版电台的中位数，自定义歌进游戏后却总会莫名偏小一点。嫌大随手就能在游戏里拧小，',
                              ),
                              TextSpan(
                                text: '嫌小却得拉低其它音量、再顶高总音量才补得回来。',
                                style: TextStyle(
                                  color: rm.fg,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        RichText(
                          text: TextSpan(
                            style: RmText.sans(13, color: rm.fg2, height: 1.6),
                            children: const [
                              TextSpan(
                                text:
                                    '所以推荐现在就抬一点 —— 从 +3 开始试听微调，让你的歌略微压过原版、又不至于突兀。',
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  RmButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const RmIcon('x', size: 13),
                    variant: RmButtonVariant.ghost,
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 6, 22, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _LoudnessSnapSlider(
                    referenceMedianLufs: widget.referenceMedianLufs,
                    offsetLu: _offsetLu,
                    currentPackageOffsetLu: widget.currentPackageOffsetLu,
                    onChanged: (value) {
                      setState(() => _offsetLu = value);
                    },
                  ),
                  const SizedBox(height: 14),
                  _LoudnessPreviewPlayer(
                    source: widget.previewSource,
                    title: widget.previewTitle,
                    artist: widget.previewArtist,
                    inputLufs: widget.previewInputLufs,
                    offsetLu: _offsetLu,
                    targetLufs: targetLufs,
                  ),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.only(top: 16),
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 18),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: rm.border)),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    rm.panel,
                    Color.alphaBlend(rm.bg.withAlpha(120), rm.panel),
                  ],
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '将以 ${selectedOption.label} 重打包 · 写入前还会再问一次',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RmText.mono(
                        10.5,
                        weight: FontWeight.w500,
                        letterSpacing: 0,
                        color: rm.fg4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  RmButton(
                    onPressed: () => Navigator.of(context).pop(),
                    label: '取消',
                  ),
                  const SizedBox(width: 8),
                  RmButton(
                    onPressed: () => Navigator.of(context).pop(_offsetLu),
                    variant: RmButtonVariant.primary,
                    trailing: const RmIcon('arrow-right', size: 12),
                    label: '准备电台包',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoudnessOption {
  const _LoudnessOption({
    required this.offsetLu,
    required this.blurb,
    this.recommended = false,
  });

  final double offsetLu;
  final String blurb;
  final bool recommended;

  String get label => '+${offsetLu.toStringAsFixed(0)} LU';
}

const _loudnessOptions = [
  _LoudnessOption(offsetLu: 0.0, blurb: '跟原版中位数一样'),
  _LoudnessOption(offsetLu: 1.0, blurb: '轻轻抬一点'),
  _LoudnessOption(offsetLu: 2.0, blurb: '更容易听见'),
  _LoudnessOption(offsetLu: 3.0, blurb: '推荐起步', recommended: true),
  _LoudnessOption(offsetLu: 4.0, blurb: '再响一些'),
  _LoudnessOption(offsetLu: 5.0, blurb: '更靠前'),
  _LoudnessOption(offsetLu: 6.0, blurb: '听感差不多翻倍！'),
];

_LoudnessOption _loudnessOptionForOffset(double offsetLu) {
  final index = _loudnessIndexForOffset(offsetLu);
  return _loudnessOptions[index];
}

int _loudnessIndexForOffset(double offsetLu) {
  final normalized = normalizePackageLoudnessOffsetLu(offsetLu);
  var bestIndex = 0;
  var bestDistance = double.infinity;
  for (var i = 0; i < _loudnessOptions.length; i += 1) {
    final distance = (_loudnessOptions[i].offsetLu - normalized).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      bestIndex = i;
    }
  }
  return bestIndex;
}

class _LoudnessSnapSlider extends StatelessWidget {
  const _LoudnessSnapSlider({
    required this.referenceMedianLufs,
    required this.offsetLu,
    this.currentPackageOffsetLu,
    required this.onChanged,
  });

  final double referenceMedianLufs;
  final double offsetLu;
  final double? currentPackageOffsetLu;
  final ValueChanged<double> onChanged;

  void _selectIndex(int index) {
    final clamped = index.clamp(0, _loudnessOptions.length - 1).toInt();
    onChanged(_loudnessOptions[clamped].offsetLu);
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final index = _loudnessIndexForOffset(offsetLu);
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _selectIndex(index - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _selectIndex(index + 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.home) {
      _selectIndex(0);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.end) {
      _selectIndex(_loudnessOptions.length - 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final option = _loudnessOptionForOffset(offsetLu);
    final targetLufs = referenceMedianLufs + option.offsetLu;
    return Focus(
      canRequestFocus: true,
      onKeyEvent: (_, event) => _handleKey(event),
      child: Builder(
        builder: (context) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    option.label,
                    style: RmText.mono(
                      22,
                      weight: FontWeight.w600,
                      letterSpacing: 0,
                      height: 1,
                      color: rm.accent.base,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '→ ${_formatLufs(targetLufs)} LUFS',
                    style: RmText.mono(12, letterSpacing: 0, color: rm.fg3),
                  ),
                  if (option.recommended) ...[
                    const SizedBox(width: 10),
                    const _RecommendedPill(),
                  ],
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      option.blurb,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: RmText.sans(12.5, color: rm.fg2),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _LoudnessSliderTrack(
                referenceMedianLufs: referenceMedianLufs,
                selectedIndex: _loudnessIndexForOffset(offsetLu),
                currentPackageIndex: currentPackageOffsetLu == null
                    ? null
                    : _loudnessIndexForOffset(currentPackageOffsetLu!),
                onSelectIndex: (index) {
                  FocusScope.of(context).requestFocus(Focus.of(context));
                  _selectIndex(index);
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LoudnessSliderTrack extends StatefulWidget {
  const _LoudnessSliderTrack({
    required this.referenceMedianLufs,
    required this.selectedIndex,
    required this.currentPackageIndex,
    required this.onSelectIndex,
  });

  final double referenceMedianLufs;
  final int selectedIndex;
  final int? currentPackageIndex;
  final ValueChanged<int> onSelectIndex;

  @override
  State<_LoudnessSliderTrack> createState() => _LoudnessSliderTrackState();
}

class _LoudnessSliderTrackState extends State<_LoudnessSliderTrack> {
  static const _trackInset = 14.0;
  static const _trackCenterY = 28.0;
  static const _trackHeight = 4.0;
  static const _trackTop = _trackCenterY - _trackHeight / 2;
  bool _dragging = false;

  void _selectFromPosition(Offset localPosition, double width) {
    final trackWidth = math.max(1.0, width - _trackInset * 2);
    final fraction = ((localPosition.dx - _trackInset) / trackWidth)
        .clamp(0.0, 1.0)
        .toDouble();
    final index = (fraction * (_loudnessOptions.length - 1)).round();
    widget.onSelectIndex(index);
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final selectedIndex = widget.selectedIndex
        .clamp(0, _loudnessOptions.length - 1)
        .toInt();
    final fillFraction = selectedIndex / (_loudnessOptions.length - 1);
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final trackWidth = math.max(1.0, width - _trackInset * 2);
            double nodeX(int index) {
              return _trackInset +
                  trackWidth * index / (_loudnessOptions.length - 1);
            }

            return MouseRegion(
              cursor: _dragging
                  ? SystemMouseCursors.grabbing
                  : SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  _selectFromPosition(details.localPosition, width);
                },
                onHorizontalDragStart: (details) {
                  setState(() => _dragging = true);
                  _selectFromPosition(details.localPosition, width);
                },
                onHorizontalDragUpdate: (details) {
                  _selectFromPosition(details.localPosition, width);
                },
                onHorizontalDragEnd: (_) => setState(() => _dragging = false),
                onHorizontalDragCancel: () => setState(() => _dragging = false),
                child: SizedBox(
                  height: 48,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: _trackInset,
                        right: _trackInset,
                        top: _trackTop,
                        child: Container(
                          height: _trackHeight,
                          decoration: BoxDecoration(
                            color: rm.border,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      Positioned(
                        left: _trackInset,
                        top: _trackTop,
                        child: AnimatedContainer(
                          duration: _dragging
                              ? Duration.zero
                              : const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          width: trackWidth * fillFraction,
                          height: _trackHeight,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                rm.accent.base.withAlpha(150),
                                rm.accent.base,
                              ],
                            ),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      for (var i = 0; i < _loudnessOptions.length; i += 1)
                        _SliderNode(
                          left: nodeX(i),
                          top: _trackCenterY,
                          active: i <= selectedIndex,
                          selected: i == selectedIndex,
                          recommended: _loudnessOptions[i].recommended,
                          currentPackage: i == widget.currentPackageIndex,
                          onTap: () => widget.onSelectIndex(i),
                        ),
                      AnimatedPositioned(
                        duration: _dragging
                            ? Duration.zero
                            : const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        left: nodeX(selectedIndex) - 11,
                        top: _trackCenterY - 11,
                        child: Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: rm.panel,
                            shape: BoxShape.circle,
                            border: Border.all(color: rm.accent.base, width: 2),
                            boxShadow: [
                              BoxShadow(color: rm.accent.bg, spreadRadius: 4),
                              BoxShadow(
                                color: rm.accent.base.withAlpha(65),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: rm.accent.base,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 2),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final trackWidth = math.max(1.0, width - _trackInset * 2);
            double nodeX(int index) {
              return _trackInset +
                  trackWidth * index / (_loudnessOptions.length - 1);
            }

            return SizedBox(
              height: 38,
              child: Stack(
                children: [
                  for (var i = 0; i < _loudnessOptions.length; i += 1)
                    _SliderLabel(
                      left: nodeX(i),
                      selected: i == selectedIndex,
                      option: _loudnessOptions[i],
                      targetLufs:
                          widget.referenceMedianLufs +
                          _loudnessOptions[i].offsetLu,
                      onTap: () => widget.onSelectIndex(i),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _SliderNode extends StatelessWidget {
  const _SliderNode({
    required this.left,
    required this.top,
    required this.active,
    required this.selected,
    required this.recommended,
    required this.currentPackage,
    required this.onTap,
  });

  final double left;
  final double top;
  final bool active;
  final bool selected;
  final bool recommended;
  final bool currentPackage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Positioned(
      left: left - 11,
      top: top - 11,
      width: 22,
      height: 22,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            if (currentPackage)
              const Positioned(
                top: -22,
                child: _CurrentPackagePill(compact: true),
              )
            else if (recommended)
              const Positioned(
                top: -22,
                child: _RecommendedPill(compact: true),
              ),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: selected ? 0 : 1,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: active ? rm.accent.base : rm.panel,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: active ? rm.accent.base : rm.borderStrong,
                    width: 2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliderLabel extends StatelessWidget {
  const _SliderLabel({
    required this.left,
    required this.selected,
    required this.option,
    required this.targetLufs,
    required this.onTap,
  });

  final double left;
  final bool selected;
  final _LoudnessOption option;
  final double targetLufs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final primary = selected ? rm.accent.base : rm.fg3;
    final secondary = selected
        ? Color.lerp(rm.accent.base, rm.fg3, 0.35)!
        : rm.fg4;
    return Positioned(
      left: left - 28,
      top: 0,
      width: 56,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '+${option.offsetLu.toStringAsFixed(0)}',
                style: RmText.mono(
                  12,
                  weight: FontWeight.w600,
                  letterSpacing: 0,
                  color: primary,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                _formatLufsShort(targetLufs),
                style: RmText.mono(10, letterSpacing: 0, color: secondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecommendedPill extends StatelessWidget {
  const _RecommendedPill({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 7,
        vertical: compact ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: compact ? rm.accent.bg : rm.accent.base,
        borderRadius: BorderRadius.circular(999),
        border: compact ? Border.all(color: rm.accent.ring) : null,
      ),
      child: Text(
        '推荐',
        style: RmText.mono(
          compact ? 9 : 9.5,
          weight: FontWeight.w600,
          letterSpacing: 0,
          color: compact ? rm.accent.base : rm.accent.onAccent,
        ),
      ),
    );
  }
}

class _CurrentPackagePill extends StatelessWidget {
  const _CurrentPackagePill({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 7,
        vertical: compact ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: compact ? rm.raised : rm.fg2,
        borderRadius: BorderRadius.circular(999),
        border: compact ? Border.all(color: rm.borderStrong) : null,
      ),
      child: Text(
        '当前准备包',
        style: RmText.mono(
          compact ? 9 : 9.5,
          weight: FontWeight.w600,
          letterSpacing: 0,
          color: compact ? rm.fg2 : rm.panel,
        ),
      ),
    );
  }
}

class _LoudnessPreviewPlayer extends StatefulWidget {
  const _LoudnessPreviewPlayer({
    required this.source,
    required this.title,
    required this.artist,
    required this.inputLufs,
    required this.offsetLu,
    required this.targetLufs,
  });

  final String? source;
  final String? title;
  final String? artist;
  final double inputLufs;
  final double offsetLu;
  final double targetLufs;

  @override
  State<_LoudnessPreviewPlayer> createState() => _LoudnessPreviewPlayerState();
}

class _LoudnessPreviewPlayerState extends State<_LoudnessPreviewPlayer> {
  Player? _player;
  SystemAudioOutputFollower? _audioOutputFollower;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _playingSub;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _loaded = false;
  bool _loading = false;
  bool _loadFailed = false;
  bool _initialSeekDone = false;

  @override
  void initState() {
    super.initState();
    if (_hasPreviewSource) {
      unawaited(_ensureLoaded());
    }
  }

  @override
  void didUpdateWidget(covariant _LoudnessPreviewPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.offsetLu != widget.offsetLu) {
      unawaited(_setPreviewVolume());
    }
    if (oldWidget.inputLufs != widget.inputLufs ||
        oldWidget.targetLufs != widget.targetLufs) {
      unawaited(_setPreviewVolume());
    }
    if (oldWidget.source != widget.source) {
      _resetPlayer();
      if (_hasPreviewSource) {
        unawaited(_ensureLoaded());
      }
    }
  }

  @override
  void dispose() {
    _resetPlayer();
    super.dispose();
  }

  bool get _hasPreviewSource {
    final source = widget.source?.trim();
    return source != null && source.isNotEmpty && File(source).existsSync();
  }

  Future<void> _ensureLoaded() async {
    if (_loaded || _loading || !_hasPreviewSource) return;
    _loading = true;
    final player = _player ??= Player();
    _audioOutputFollower ??= followSystemAudioOutput(player);
    _positionSub ??= player.stream.position.listen((position) {
      if (mounted) setState(() => _position = position);
    });
    _durationSub ??= player.stream.duration.listen((duration) {
      if (!mounted) return;
      setState(() => _duration = duration);
      if (!_initialSeekDone && duration > Duration.zero) {
        unawaited(_seekToMiddle(duration));
      }
    });
    _playingSub ??= player.stream.playing.listen((playing) {
      if (mounted) setState(() => _playing = playing);
    });
    try {
      if (mounted) setState(() => _loadFailed = false);
      await _setPreviewVolume();
      await player.open(
        Media(Uri.file(widget.source!.trim()).toString()),
        play: false,
      );
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _duration = player.state.duration;
      });
      if (player.state.duration > Duration.zero) {
        unawaited(_seekToMiddle(player.state.duration));
      }
    } on Object {
      if (!mounted) return;
      setState(() {
        _loaded = false;
        _loadFailed = true;
      });
    } finally {
      _loading = false;
    }
  }

  Future<void> _setPreviewVolume() async {
    final player = _player;
    if (player == null) return;
    await player.setVolume(
      previewMpvVolume(
        targetLufs: widget.targetLufs,
        inputLufs: widget.inputLufs,
      ),
    );
  }

  Future<void> _seekToMiddle(Duration duration) async {
    final player = _player;
    if (player == null || duration <= Duration.zero || _initialSeekDone) return;
    _initialSeekDone = true;
    final next = Duration(
      milliseconds: (duration.inMilliseconds * 0.5).round(),
    );
    if (mounted) setState(() => _position = next);
    await player.seek(next);
  }

  Future<void> _toggle() async {
    if (!_hasPreviewSource) return;
    await _ensureLoaded();
    final player = _player;
    if (player == null || !_loaded) return;
    if (_playing) {
      await player.pause();
      return;
    }
    if (_duration > Duration.zero &&
        _position >= _duration - const Duration(milliseconds: 100)) {
      await player.seek(Duration.zero);
    }
    await player.play();
  }

  void _resetPlayer() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _positionSub = null;
    _durationSub = null;
    _playingSub = null;
    _audioOutputFollower?.dispose();
    _audioOutputFollower = null;
    final player = _player;
    _player = null;
    if (player != null) {
      unawaited(player.dispose());
    }
    _position = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    _loaded = false;
    _loading = false;
    _loadFailed = false;
    _initialSeekDone = false;
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final hasPreview = _hasPreviewSource && !_loadFailed;
    final hint = _loadFailed
        ? '预览音频打不开；仍可直接选择目标响度。'
        : '先去播放列表给电台分配一首 custom 歌，再回来选响度。';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _PreviewPlayButton(
            playing: _playing,
            enabled: hasPreview,
            onPressed: () => unawaited(_toggle()),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _PreviewTrackLine(
                        hasPreview: hasPreview,
                        title: widget.title,
                        artist: widget.artist,
                      ),
                    ),
                    if (hasPreview) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: rm.raised,
                          border: Border.all(color: rm.border),
                          borderRadius: BorderRadius.circular(RmTokens.rXs),
                        ),
                        child: Text(
                          'PREVIEW',
                          style: RmText.mono(
                            9.5,
                            weight: FontWeight.w600,
                            letterSpacing: 0,
                            color: rm.fg3,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 7),
                if (hasPreview)
                  Row(
                    children: [
                      Expanded(
                        child: _PreviewVuStrip(
                          playing: _playing,
                          seed: _position.inMilliseconds ~/ 120,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                        style: RmText.mono(11, letterSpacing: 0, color: rm.fg3),
                      ),
                    ],
                  )
                else
                  Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: RmText.sans(11.5, color: rm.fg3),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          _LufsReadout(targetLufs: widget.targetLufs),
        ],
      ),
    );
  }
}

class _PreviewTrackLine extends StatelessWidget {
  const _PreviewTrackLine({
    required this.hasPreview,
    required this.title,
    required this.artist,
  });

  final bool hasPreview;
  final String? title;
  final String? artist;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    if (!hasPreview) {
      return Text(
        '无可预览音频',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: RmText.sans(13, weight: FontWeight.w500, color: rm.fg3),
      );
    }
    final cleanTitle = _cleanPreviewText(title) ?? '自建歌曲预览';
    final cleanArtist = _cleanPreviewText(artist);
    if (cleanArtist == null) {
      return Text(
        cleanTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: RmText.sans(13, weight: FontWeight.w500, color: rm.fg),
      );
    }
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: RmText.sans(13, weight: FontWeight.w500, color: rm.fg),
        children: [
          TextSpan(
            text: cleanArtist,
            style: TextStyle(color: rm.fg3),
          ),
          TextSpan(
            text: ' / ',
            style: TextStyle(color: rm.fg4),
          ),
          TextSpan(text: cleanTitle),
        ],
      ),
    );
  }
}

class _PreviewPlayButton extends StatelessWidget {
  const _PreviewPlayButton({
    required this.playing,
    required this.enabled,
    required this.onPressed,
  });

  final bool playing;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final bg = enabled ? rm.accent.base : rm.raised;
    final fg = enabled ? rm.accent.onAccent : rm.fg4;
    final border = enabled ? rm.accent.base : rm.borderStrong;
    final button = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: enabled ? onPressed : null,
        child: Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            border: Border.all(
              color: border,
              style: enabled ? BorderStyle.solid : BorderStyle.solid,
            ),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: rm.accent.base.withAlpha(70),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: RmIcon(playing ? 'pause' : 'play', size: 20, color: fg),
        ),
      ),
    );
    return Tooltip(
      message: enabled ? (playing ? '暂停预览' : '播放预览') : '无可预览音频',
      child: button,
    );
  }
}

class _PreviewVuStrip extends StatelessWidget {
  const _PreviewVuStrip({required this.playing, required this.seed});

  final bool playing;
  final int seed;

  static const _barCount = 56;

  double _heightFor(int index) {
    final baseSeed = playing ? seed : 1;
    final phase = math.sin((index + baseSeed) * 0.83) * 0.5 + 0.5;
    final phase2 = math.cos((index + baseSeed) * 1.47) * 0.5 + 0.5;
    final base = 0.18 + phase * 0.55 + phase2 * 0.24;
    return base.clamp(0.14, 1.0).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return SizedBox(
      height: 18,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < _barCount; i += 1) ...[
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  height: 18 * _heightFor(i),
                  decoration: BoxDecoration(
                    color: playing
                        ? rm.accent.base.withAlpha(215)
                        : rm.borderStrong,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ),
            if (i != _barCount - 1) const SizedBox(width: 2),
          ],
        ],
      ),
    );
  }
}

class _LufsReadout extends StatelessWidget {
  const _LufsReadout({required this.targetLufs});

  final double targetLufs;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final color = targetLufs >= -19
        ? rm.warn
        : targetLufs <= -24
        ? rm.fg2
        : rm.fg;
    return SizedBox(
      width: 94,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _formatLufs(targetLufs),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: RmText.mono(
              22,
              weight: FontWeight.w600,
              letterSpacing: 0,
              height: 1,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '目标文件 LUFS',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: RmText.mono(
              9.5,
              weight: FontWeight.w500,
              letterSpacing: 0,
              color: rm.fg3,
            ),
          ),
        ],
      ),
    );
  }
}

double _nearestPackageLoudnessOffset(double value) {
  final normalized = normalizePackageLoudnessOffsetLu(value);
  return kPackageLoudnessOffsetOptions.reduce((best, option) {
    return (option - normalized).abs() < (best - normalized).abs()
        ? option
        : best;
  });
}

@visibleForTesting
const double previewVolumeMinGainDb = -48.0;

@visibleForTesting
const double previewVolumeMaxGainDb = 8.0;

// libmpv (player/audio.c:audio_update_volume) 把 `volume` 属性立方化：
//   amplitude = (volume / 100)^3
// 所以为了得到 gainDb 的衰减/增益，需要反推：
//   volume = 100 * 10^(gainDb / 60)
// （等价于 100 * (10^(gainDb/20))^(1/3)）。
// 走线性 100 * 10^(gainDb/20) 会让 mpv 多衰减 3 倍 dB。
@visibleForTesting
double previewMpvVolume({
  required double targetLufs,
  required double inputLufs,
}) {
  if (!targetLufs.isFinite || !inputLufs.isFinite) return 100.0;
  final gainDb = (targetLufs - inputLufs)
      .clamp(previewVolumeMinGainDb, previewVolumeMaxGainDb)
      .toDouble();
  return 100.0 * math.pow(10.0, gainDb / 60.0).toDouble();
}

String _formatLufs(double value) => value.toStringAsFixed(1);

String _formatLufsShort(double value) {
  final rounded = value.roundToDouble();
  if ((value - rounded).abs() < 0.05) {
    return rounded.toStringAsFixed(0);
  }
  return value.toStringAsFixed(1);
}

String? _cleanPreviewText(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

String _formatDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
