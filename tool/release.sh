#!/usr/bin/env bash
# 发布一个版本：递增版本号 → 构建 APK → 打包成带版本与时间戳的压缩包。
#
# 约定（每次出版本都必须遵守）：
#   1. 版本号只增不减：默认把 patch 位 +1，构建号（+N）也 +1；
#   2. 压缩包文件名必须同时带版本号与日期时间，便于区分：
#        dist/xEduBrowser-v<版本>-<YYYYMMDD-HHMM>.zip
#   3. 包内附 SHA256SUMS.txt，包外附同名 .sha256。
#
# 用法：
#   tool/release.sh                      # patch +1，构建并打包
#   tool/release.sh --bump minor         # minor +1
#   tool/release.sh --version 1.2.0      # 直接指定版本（构建号仍 +1）
#   tool/release.sh --upload             # 打包后免密上传到 yacc@192.168.1.120:/var/www/html/
#   tool/release.sh --commit --push      # 提交 pubspec 版本改动并打 tag / 推送
#
# 环境变量：FLUTTER_BIN（flutter 可执行文件）、ANDROID_HOME
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUMP="patch"
EXPLICIT=""
DO_UPLOAD=0
DO_COMMIT=0
DO_PUSH=0

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --bump) BUMP="${2:?--bump 需要 patch|minor|major}"; shift 2 ;;
    --version) EXPLICIT="${2:?--version 需要 X.Y.Z}"; shift 2 ;;
    --upload) DO_UPLOAD=1; shift ;;
    --commit) DO_COMMIT=1; shift ;;
    --push) DO_PUSH=1; DO_COMMIT=1; shift ;;
    -h|--help) usage ;;
    *) echo "未知参数：$1（--help 查看用法）" >&2; exit 1 ;;
  esac
done

# --- 1. 版本号：递增 -------------------------------------------------------
CURRENT_LINE="$(grep -E '^version:[[:space:]]*' pubspec.yaml | head -1)"
CURRENT="${CURRENT_LINE#version:}"
CURRENT="$(echo "$CURRENT" | tr -d '[:space:]')"
CUR_SEM="${CURRENT%%+*}"
CUR_BUILD="${CURRENT##*+}"
[ "$CUR_BUILD" = "$CURRENT" ] && CUR_BUILD=0

if [ -n "$EXPLICIT" ]; then
  NEW_SEM="$EXPLICIT"
else
  IFS=. read -r MA MI PA <<< "$CUR_SEM"
  case "$BUMP" in
    patch) PA=$((PA + 1)) ;;
    minor) MI=$((MI + 1)); PA=0 ;;
    major) MA=$((MA + 1)); MI=0; PA=0 ;;
    *) echo "未知递增方式：$BUMP（可选 patch|minor|major）" >&2; exit 1 ;;
  esac
  NEW_SEM="$MA.$MI.$PA"
fi
NEW_BUILD=$((CUR_BUILD + 1))
NEW_VERSION="$NEW_SEM+$NEW_BUILD"

# 只增不减：拒绝比当前版本更低的版本号（同版本重新出版本仅递增构建号）
NEWEST="$(printf '%s\n%s\n' "$CUR_SEM" "$NEW_SEM" | sort -V | tail -1)"
if [ "$NEWEST" != "$NEW_SEM" ]; then
  echo "拒绝发布：新版本 $NEW_SEM 低于当前版本 $CUR_SEM（版本号只能递增）" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M)"
ZIP_NAME="xEduBrowser-v${NEW_SEM}-${STAMP}.zip"

echo "== 版本：$CURRENT → $NEW_VERSION"
sed -i "s|^version:.*|version: $NEW_VERSION|" pubspec.yaml
grep -E '^version:' pubspec.yaml

# --- 2. 构建 --------------------------------------------------------------
FLUTTER_BIN="${FLUTTER_BIN:-}"
if [ -z "$FLUTTER_BIN" ]; then
  if command -v flutter >/dev/null 2>&1; then FLUTTER_BIN="$(command -v flutter)";
  elif [ -x /root/flutter/bin/flutter ]; then FLUTTER_BIN=/root/flutter/bin/flutter;
  else echo "找不到 flutter，请设置 FLUTTER_BIN" >&2; exit 1; fi
fi

# 容器/CI 里 HTTP_PROXY 会劫持本地回环，导致 flutter 构建失败
run_flutter() {
  env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
    NO_PROXY=127.0.0.1,localhost "$FLUTTER_BIN" "$@"
}

echo "== 构建通用包（含全部 ABI）"
run_flutter build apk --release
echo "== 构建分 ABI 包"
run_flutter build apk --release --split-per-abi

# --- 3. 打包（带版本与时间戳）---------------------------------------------
APK_DIR="build/app/outputs/flutter-apk"
DIST="$ROOT/dist"
rm -rf "$DIST/staging"
mkdir -p "$DIST/staging"
cp "$APK_DIR/app-arm64-v8a-release.apk" "$APK_DIR/app-armeabi-v7a-release.apk" \
   "$APK_DIR/app-x86_64-release.apk" "$APK_DIR/app-release.apk" "$DIST/staging/"

(
  cd "$DIST/staging"
  sha256sum ./*.apk > SHA256SUMS.txt
  sha256sum -c SHA256SUMS.txt >/dev/null
  rm -f "$DIST/$ZIP_NAME"
  zip -q -j "$DIST/$ZIP_NAME" ./*.apk SHA256SUMS.txt
)
sha256sum "$DIST/$ZIP_NAME" | awk '{print $1}' > "$DIST/$ZIP_NAME.sha256"
rm -rf "$DIST/staging"

echo
echo "== 产物"
ls -lh "$DIST/$ZIP_NAME" | awk '{print "   " $9 "  " $5}'
echo "   sha256: $(cat "$DIST/$ZIP_NAME.sha256")"

# --- 4. 可选：提交 / 打 tag / 上传 ----------------------------------------
if [ "$DO_COMMIT" = "1" ]; then
  git add pubspec.yaml
  git commit -q -m "release: v$NEW_SEM (build $NEW_BUILD)"
  git tag -f "v$NEW_SEM" >/dev/null
  echo "== 已提交并打 tag v$NEW_SEM"
  if [ "$DO_PUSH" = "1" ]; then
    env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
      git push -q origin HEAD && \
    env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
      git push -q -f origin "v$NEW_SEM"
    echo "== 已推送到 origin"
  fi
fi

if [ "$DO_UPLOAD" = "1" ]; then
  "$ROOT/tool/upload_dist.sh" "$DIST/$ZIP_NAME"
fi

echo
echo "完成：v$NEW_SEM (build $NEW_BUILD) → $ZIP_NAME"
