import 'package:flutter/material.dart';

import '../ui/scroll_page.dart';
import 'bookmark_manager.dart';

/// 测试钩子：设置页最后那个「打开书签管理」按钮。
const Key openBookmarkManagerKey = ValueKey<String>('settings-open-bookmark-manager');

/// 书签管理独立页：设置页最后的入口点进来，[BookmarkManagerCard] 原样搬到这里。
///
/// 书签条目多、改动又频繁，直接铺在设置页里会把设置页顶得很长：真正要改
/// 设置的人得先滚过一整墙书签。单独一页有自己的滚动区域和返回键，设置页
/// 只留一个入口（并且照样排在最后）。
class BookmarkManagerScreen extends StatelessWidget {
  const BookmarkManagerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('书签管理')),
      body: const ScrollPage(children: <Widget>[BookmarkManagerCard()]),
    );
  }
}
