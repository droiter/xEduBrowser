import 'package:flutter/material.dart';

/// 应用主题：Material 3 亮色 / 暗色两套配色，针对**平板**优化。
///
/// 界面文字全部为简体中文，因此这里显式声明中文字体回退链
/// （`Noto Sans SC` 等），避免部分 Android 设备上出现方块字形。
///
/// 使用方式（应用外壳）：
/// ```dart
/// MaterialApp(theme: AppTheme.light, darkTheme: AppTheme.dark)
/// ```
abstract final class AppTheme {
  /// 冷静的蓝绿色种子色。
  static const Color seedColor = Color(0xFF0E6E78);

  /// 中文字体回退链，按优先级排列。
  static const List<String> cjkFontFallback = <String>[
    'Noto Sans SC',
    'Noto Sans CJK SC',
    'Source Han Sans SC',
    'Noto Sans CJK',
    'PingFang SC',
    'Microsoft YaHei',
    'Heiti SC',
    'sans-serif',
  ];

  /// 宽屏（横屏平板 / 大屏）阈值，用于自适应布局。
  static const double wideBreakpoint = 900;

  /// 内容最大宽度：超大平板上居中显示，避免一行文字过长。
  static const double contentMaxWidth = 1120;

  /// 等宽字体，用于展示网址与规则文本。
  static const String monoFontFamily = 'monospace';

  static const List<String> monoFontFallback = <String>[
    'Roboto Mono',
    'Droid Sans Mono',
    'Courier New',
    'monospace',
  ];

  static final ThemeData light = _build(Brightness.light);
  static final ThemeData dark = _build(Brightness.dark);

  /// 依据主题自动选择亮色或暗色。
  static ThemeData of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// 当前是否宽屏（平板横屏）布局。
  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= wideBreakpoint;

  static ThemeData _build(Brightness brightness) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );

    final ThemeData base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // 平板：comfortable（比默认更紧凑），一屏能看到更多规则。
      visualDensity: VisualDensity.comfortable,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarThemeData(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 2,
        toolbarHeight: 64,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
          fontFamilyFallback: cjkFontFallback,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 15),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: scheme.outlineVariant,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(96, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(88, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(64, 40),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: 10,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      ),
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: scheme.outlineVariant,
      ),
      chipTheme: ChipThemeData(
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      dialogTheme: DialogThemeData(
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        showDragHandle: true,
        clipBehavior: Clip.antiAlias,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        insetPadding: EdgeInsets.all(16),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.secondaryContainer,
        minWidth: 84,
        labelType: NavigationRailLabelType.all,
        selectedLabelTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontSize: 12,
          color: scheme.onSurfaceVariant,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.comfortable,
          textStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ),
      ),
      tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    );

    // 中文字体回退链：正文与标题统一应用。
    final TextTheme textTheme = base.textTheme.apply(
      fontFamily: 'Noto Sans SC',
      fontFamilyFallback: cjkFontFallback,
    );
    final TextTheme sized = textTheme.copyWith(
      // 平板上正文略大一点，方便阅读。
      bodyLarge: textTheme.bodyLarge?.copyWith(fontSize: 16, height: 1.5),
      bodyMedium: textTheme.bodyMedium?.copyWith(fontSize: 15, height: 1.5),
      titleMedium: textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
      titleSmall: textTheme.titleSmall?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
    );

    return base.copyWith(textTheme: sized);
  }
}

/// 等宽文本样式（网址、规则），自动适配当前主题。
TextStyle monoStyle(BuildContext context, {double fontSize = 13, Color? color}) {
  final ThemeData theme = Theme.of(context);
  return TextStyle(
    fontFamily: AppTheme.monoFontFamily,
    fontFamilyFallback: AppTheme.monoFontFallback,
    fontSize: fontSize,
    height: 1.4,
    color: color ?? theme.colorScheme.onSurface,
  );
}

/// 语义色板，用于 [RuleChip] 与状态提示。
enum ChipTone {
  /// 中性信息。
  neutral,

  /// 允许 / 生效。
  allow,

  /// 拒绝 / 拦截。
  deny,

  /// 警告：规则永不生效、权限缺失等。
  warning,

  /// 强调：主题色。
  accent,
}

/// 小圆角标签，用于显示名单类型、允许/拒绝、警告等。
class RuleChip extends StatelessWidget {
  const RuleChip(
    this.label, {
    super.key,
    this.tone = ChipTone.neutral,
    this.icon,
    this.monospace = false,
  });

  final String label;
  final ChipTone tone;
  final IconData? icon;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool isDark = theme.brightness == Brightness.dark;

    final Color foreground;
    switch (tone) {
      case ChipTone.allow:
        foreground = isDark ? const Color(0xFF7BD9A2) : const Color(0xFF1B6B3A);
      case ChipTone.deny:
        foreground = isDark ? const Color(0xFFFFA79A) : const Color(0xFF9B2C1F);
      case ChipTone.warning:
        foreground = isDark ? const Color(0xFFF2C75C) : const Color(0xFF8A5A00);
      case ChipTone.accent:
        foreground = scheme.primary;
      case ChipTone.neutral:
        foreground = scheme.onSurfaceVariant;
    }
    final Color background = tone == ChipTone.accent
        ? scheme.primaryContainer.withValues(alpha: 0.55)
        : foreground.withValues(alpha: isDark ? 0.20 : 0.10);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: foreground.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                fontFamily: monospace ? AppTheme.monoFontFamily : null,
                fontFamilyFallback: monospace ? AppTheme.monoFontFallback : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 可换行、可复制的规则 / 网址文本。长字符串不会被裁掉。
class PatternText extends StatelessWidget {
  const PatternText(
    this.text, {
    super.key,
    this.selectable = true,
    this.fontSize = 13,
    this.color,
    this.maxLines,
  });

  final String text;
  final bool selectable;
  final double fontSize;
  final Color? color;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = monoStyle(context, fontSize: fontSize, color: color);
    if (!selectable) {
      return Text(text, style: style, softWrap: true, maxLines: maxLines);
    }
    return SelectableText(text, style: style, maxLines: maxLines);
  }
}

/// 空状态占位：图标 + 标题 + 说明 + 可选操作按钮。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  /// 紧凑模式：用于卡片内部的小块空状态。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 24,
            vertical: compact ? 20 : 48,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                icon,
                size: compact ? 32 : 52,
                color: theme.colorScheme.outline,
              ),
              SizedBox(height: compact ? 8 : 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              if (message != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (action != null) ...<Widget>[
                const SizedBox(height: 20),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 带标题的分组卡片，设置页与规则页复用。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.children = const <Widget>[],
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(icon, size: 20, color: theme.colorScheme.primary),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title, style: theme.textTheme.titleMedium),
                      if (subtitle != null) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...<Widget>[
                  const SizedBox(width: 8),
                  trailing!,
                ],
              ],
            ),
            if (children.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              ...children,
            ],
          ],
        ),
      ),
    );
  }
}

/// 统一的提示条（成功 / 失败），自动替换上一条。
void showAppSnackBar(BuildContext context, String message, {bool isError = false}) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(color: isError ? scheme.onErrorContainer : null),
        ),
        backgroundColor: isError ? scheme.errorContainer : null,
        duration: Duration(seconds: isError ? 5 : 3),
      ),
    );
}

/// 解释一段文字的小图标行，设置项说明复用。
class HintText extends StatelessWidget {
  const HintText(this.text, {super.key, this.icon = Icons.info_outline, this.tone});

  final String text;
  final IconData icon;
  final ChipTone? tone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = switch (tone) {
      ChipTone.warning => theme.colorScheme.error,
      ChipTone.deny => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
