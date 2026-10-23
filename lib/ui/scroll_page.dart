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
///
/// 页面若需要**手指/鼠标拖动滚动条**（书签管理页）或要自己跳转到顶/到底，
/// 就把自己的 [controller] 传进来，并把 [interactiveScrollbar] 打开。
class ScrollPage extends StatelessWidget {
  const ScrollPage({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 16, 32),
    this.controller,
    this.interactiveScrollbar = false,
  });

  final List<Widget> children;
  final EdgeInsets padding;

  /// 页面自己的滚动控制器；为 null 时用周围的主控制器（设置页就是这样）。
  ///
  /// 要画常驻、可拖动的滚动条时必须是这个同一个控制器：滚动条只是"另一只手"，
  /// 它和列表必须盯着同一个位置，否则滑块会跑。到顶/到底按钮也靠它。
  final ScrollController? controller;

  /// 把滚动条做成**能用手指/鼠标按住拖动**的滑块，并加宽到能按得住。
  ///
  /// 必须同时给 [controller]：Flutter 的 [Scrollbar] 在 `thumbVisibility` 为真
  /// 时要求一个显式控制器。
  final bool interactiveScrollbar;

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
            controller: controller,
            // Android 上必须显式打开 interactive：否则滑块只是画出来，
            // 手指拖不动。12dp 宽 + 圆角，是让手指按得住的尺寸。
            thumbVisibility: interactiveScrollbar,
            interactive: interactiveScrollbar,
            thickness: interactiveScrollbar ? 12 : null,
            radius: interactiveScrollbar ? const Radius.circular(6) : null,
            child: ListView(
              controller: controller,
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
