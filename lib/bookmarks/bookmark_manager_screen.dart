import 'package:flutter/material.dart';

import '../ui/scroll_page.dart';
import 'bookmark_manager.dart';

/// 测试钩子：设置页最后那个「打开书签管理」按钮。
const Key openBookmarkManagerKey = ValueKey<String>('settings-open-bookmark-manager');

/// 测试钩子：书签管理页的「到顶」按钮。
const Key bookmarkManagerScrollTopKey = ValueKey<String>('bookmark-manager-scroll-top');

/// 测试钩子：书签管理页的「到底」按钮。
const Key bookmarkManagerScrollBottomKey =
    ValueKey<String>('bookmark-manager-scroll-bottom');

/// 书签管理独立页：设置页最后的入口点进来，[BookmarkManagerCard] 原样搬到这里。
///
/// 书签条目多、改动又频繁，直接铺在设置页里会把设置页顶得很长：真正要改
/// 设置的人得先滚过一整墙书签。单独一页有自己的滚动区域和返回键，设置页
/// 只留一个入口（并且照样排在最后）。
///
/// 这一页自己拿着 [ScrollController]：右侧常驻的滚动条要能**用手指拖动**，
/// 右下角还有一对「到顶 / 到底」浮动按钮——分类一多、每个分类又只铺 10 个，
/// 想回到最上面或直接跳到末尾都用得上。
class BookmarkManagerScreen extends StatefulWidget {
  const BookmarkManagerScreen({super.key});

  @override
  State<BookmarkManagerScreen> createState() => _BookmarkManagerScreenState();
}

class _BookmarkManagerScreenState extends State<BookmarkManagerScreen> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _scrollTo(double offset) async {
    if (!_controller.hasClients) return;
    await _controller.animateTo(
      offset,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _scrollToTop() => _scrollTo(0);

  Future<void> _scrollToBottom() async {
    if (!_controller.hasClients) return;
    await _scrollTo(_controller.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('书签管理')),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ScrollPage(
              controller: _controller,
              interactiveScrollbar: true,
              children: const <Widget>[BookmarkManagerCard()],
            ),
          ),
          // 与首页书签墙同一套做法：表头会随滚动移出屏幕，所以「到顶 / 到底」
          // 做成随时可点的浮动按钮。
          Positioned(
            right: 20,
            bottom: 20,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FloatingActionButton.small(
                  key: bookmarkManagerScrollTopKey,
                  // 两个浮动按钮不参与 Hero 动画：默认 tag 相同，页面跳转时会撞成
                  // "multiple heroes share the same tag"。
                  heroTag: null,
                  tooltip: '到顶',
                  onPressed: _scrollToTop,
                  child: const Icon(Icons.vertical_align_top),
                ),
                const SizedBox(height: 10),
                FloatingActionButton.small(
                  key: bookmarkManagerScrollBottomKey,
                  heroTag: null,
                  tooltip: '到底',
                  onPressed: _scrollToBottom,
                  child: const Icon(Icons.vertical_align_bottom),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
