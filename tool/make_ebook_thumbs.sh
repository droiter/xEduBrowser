#!/usr/bin/env bash
# 给缺少缩略图的 Flip PDF 电子书补上 files/thumb/*.jpg。
#
# 有些电子书导出时没有生成 thumb 目录（「怪兽的惊喜」「一起动起来！」都是这样），
# 此时 Flip PDF 播放器的加载动画永远不会结束，书签缩略图也截不到真正的封面。
# 本脚本用 JDK 自带的 ImageIO 从 files/mobile/*.jpg 生成缩略图，不需要
# PIL / ImageMagick；已存在的缩略图不会被动。
#
# 用法：
#   tool/make_ebook_thumbs.sh <电子书目录> [更多目录...]
#   tool/make_ebook_thumbs.sh /sdcard/ebooks/一起动起来！
#
# 环境变量：THUMB_WIDTH（默认 200）、THUMB_QUALITY（默认 0.82）
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"

if [ "$#" -lt 1 ]; then
  sed -n '2,12p' "${BASH_SOURCE[0]}"
  exit 2
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
# 电子书目录名基本都是中文：JVM 的 file.encoding / sun.jnu.encoding 跟着 locale 走，
# 在 POSIX/C locale 下会把命令行里的中文路径变成 ??? 而找不到目录，所以强制 UTF-8。
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
# 源码里有中文注释：不指定编码时 javac 会用平台默认（可能是 US-ASCII）而报错。
"$JAVAC" -encoding UTF-8 -d "$BUILD" "$DIR/EbookThumbs.java"

for book in "$@"; do
  "$JAVA" -Dfile.encoding=UTF-8 -Dsun.jnu.encoding=UTF-8 -Djava.awt.headless=true \
    -cp "$BUILD" EbookThumbs \
    "$book" "${THUMB_WIDTH:-200}" "${THUMB_QUALITY:-0.82}"
done
