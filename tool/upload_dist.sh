#!/usr/bin/env bash
# 免密上传发布包到 Web 服务器：分片 scp + 远端重组 + sha256 校验。
#
# 用法：tool/upload_dist.sh dist/xEduBrowser-v1.0.1-20260922-0310.zip
# 环境变量：RELEASE_HOST（默认 192.168.1.120）、RELEASE_USER（默认 yacc）、
#           RELEASE_DEST（默认 /var/www/html）、RELEASE_CHUNK（默认 8m）
#
# 认证走 ssh 公钥（BatchMode=yes，不会提示密码）。
set -euo pipefail

ZIP="${1:?用法: tool/upload_dist.sh <zip 路径>}"
[ -f "$ZIP" ] || { echo "找不到文件：$ZIP" >&2; exit 1; }

HOST="${RELEASE_HOST:-192.168.1.120}"
USER_NAME="${RELEASE_USER:-yacc}"
DEST="${RELEASE_DEST:-/var/www/html}"
CHUNK="${RELEASE_CHUNK:-8m}"

BASE="$(basename "$ZIP")"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$USER_NAME@$HOST")
SCP=(scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

LOCAL_SHA="$(sha256sum "$ZIP" | awk '{print $1}')"
LOCAL_SIZE="$(stat -c%s "$ZIP")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[$(date +%T)] 本地：$BASE  $((LOCAL_SIZE / 1048576))MB  sha256=${LOCAL_SHA:0:16}…"

# 同名文件已是最新就不重复传
REMOTE_SHA="$("${SSH[@]}" "sha256sum '$DEST/$BASE' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$REMOTE_SHA" = "$LOCAL_SHA" ]; then
  echo "[$(date +%T)] 服务器上已存在同样内容，跳过上传"
  exit 0
fi

echo "[$(date +%T)] 清理远端半截文件"
"${SSH[@]}" "rm -f '$DEST/$BASE' '$DEST/$BASE.part*'"

echo "[$(date +%T)] 分片 $CHUNK"
split -b "$CHUNK" -d -a 2 "$ZIP" "$WORK/$BASE.part"
echo "   片数：$(ls -1 "$WORK" | wc -l)"

for f in "$WORK"/*; do
  name="$(basename "$f")"
  size="$(stat -c%s "$f")"
  ok=0
  for try in 1 2 3; do
    echo "[$(date +%T)] 上传 $name ($((size / 1048576))MB) 第 $try 次"
    if timeout 900 "${SCP[@]}" "$f" "$USER_NAME@$HOST:$DEST/" 2>/dev/null; then
      remote="$("${SSH[@]}" "stat -c%s '$DEST/$name'" 2>/dev/null || true)"
      if [ "$remote" = "$size" ]; then ok=1; break; else
        echo "   大小不符（$remote != $size），重试"
        "${SSH[@]}" "rm -f '$DEST/$name'"
      fi
    fi
  done
  [ "$ok" = "1" ] || { echo "上传失败：$name" >&2; exit 2; }
done

echo "[$(date +%T)] 远端重组"
"${SSH[@]}" "cd '$DEST' && cat $BASE.part* > '$BASE' && rm -f $BASE.part*"

REMOTE_SHA="$("${SSH[@]}" "sha256sum '$DEST/$BASE' | awk '{print \$1}'")"
echo "$REMOTE_SHA  $BASE"
if [ "$REMOTE_SHA" != "$LOCAL_SHA" ]; then
  echo "校验失败：远端 sha256 与本地不一致" >&2
  exit 3
fi
echo "[$(date +%T)] ✅ 校验一致"
"${SSH[@]}" "ls -l '$DEST/$BASE'"
echo "[$(date +%T)] 完成"
