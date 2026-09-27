import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// 设置类页面共用的滚动容器（设置页、书签管理页）。
///
/// 平板上外接鼠标是很常见的用法，所以这里把滚动做成"鼠标也能用"：
///
/// * 滚轮 / 触控板上下滚 —— Flutter 的 [Scrollable] 本来就会处理
///   `PointerScrollEvent`，无需额外代码；
/// * 按住鼠标左键拖动也能滚 —— 需要把鼠标加进 `dragDevices`，默认只认触摸；
/// * 右侧常驻滚动条 —— 鼠标用户能一眼看到自己在哪儿。
class ScrollPage extends StatelessWidget {
  const ScrollPage({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 16, 32),
  });

  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: const <PointerDeviceKind>{
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTheme.contentMaxWidth),
          child: Scrollbar(
            child: ListView(
              // 内容比屏幕短时也要能拖动：滚轮/拖动不会因为"没得滚"而弹回。
              physics: const AlwaysScrollableScrollPhysics(),
              padding: padding,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}
