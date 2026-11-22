#!/bin/zsh
# 发布 GitHub Release（make publish 会调用）：打 v<版本> 标签并推送，创建 Release，上传 DMG 和 SHA-256。
#
#   scripts/publish.sh <版本号>
#
# 前提：已运行 make release，且构建所用的提交就是当前 HEAD、工作区干净、已推送到 origin；
# 发布说明写在 docs/release-notes/v<版本>.md；GitHub CLI 已登录（gh auth login）。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

VERSION="${1:?用法：scripts/publish.sh <版本号>}"
TAG="v$VERSION"
OUT="$ROOT/build/release"
DMG="$OUT/ProxyAppX-$VERSION.dmg"
NOTES="docs/release-notes/$TAG.md"

[[ -f "$DMG" && -f "$DMG.sha256" ]] || { echo "找不到 ${DMG:t}，请先运行 make release"; exit 1; }
[[ -f "$NOTES" ]] || { echo "缺少发布说明 $NOTES"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "工作区有未提交的改动，请先提交"; exit 1; }

HEAD="$(git rev-parse HEAD)"
[[ "$(head -1 "$OUT/COMMIT" 2>/dev/null)" == "$HEAD" && "$(wc -l < "$OUT/COMMIT" | tr -d ' ')" == "1" ]] \
  || { echo "安装包不是从当前提交（${HEAD:0:7}）的干净工作区构建的，请重新运行 make release"; exit 1; }
(cd "$OUT" && shasum -a 256 -c -s "${DMG:t}.sha256") || { echo "DMG 校验和不匹配"; exit 1; }

git fetch -q origin
[[ "$(git rev-parse "origin/$(git branch --show-current)")" == "$HEAD" ]] \
  || { echo "当前提交还没推送到 origin，请先 git push"; exit 1; }

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [[ "$(git rev-parse "$TAG^{commit}")" == "$HEAD" ]] || { echo "标签 $TAG 已存在且不指向当前提交"; exit 1; }
else
  git tag -a "$TAG" -m "ProxyAppX $VERSION"
fi
git push -q origin "refs/tags/$TAG"

# 发布说明末尾附上 SHA-256（DMG 在提交之后才构建，校验和无法事先写进仓库）
BODY="$OUT/release-notes-$TAG.md"
{
  cat "$NOTES"
  print -r -- ""
  print -r -- "## SHA-256"
  print -r -- '```'
  cat "$DMG.sha256"
  print -r -- '```'
} > "$BODY"

gh release create "$TAG" "$DMG" "$DMG.sha256" \
  --title "ProxyAppX $VERSION" --notes-file "$BODY" --verify-tag
