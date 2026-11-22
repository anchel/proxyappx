#!/bin/zsh
# 发布 GitHub Release（make publish 会调用）：打 v<版本> 标签并推送，创建 Release，上传 DMG 和 SHA-256。
#
#   scripts/publish.sh <版本号>
#
# - 新版本：安装包必须从当前 HEAD 的干净工作区构建（make release），且 HEAD 已推送到 origin。
#   脚本在 HEAD 上打标签并创建 Release。
# - 已发布的版本（标签已存在）：安装包必须从标签所指的提交构建，脚本替换 Release 中的
#   DMG 和校验文件，并更新说明里的 SHA-256（例如重新打包、补签 DMG 之后）。
#
# 发布说明写在 docs/release-notes/v<版本>.md；需要 GitHub CLI 已登录（gh auth login）。
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
(cd "$OUT" && shasum -a 256 -c -s "${DMG:t}.sha256") || { echo "DMG 校验和不匹配"; exit 1; }

BUILT_FROM="$(head -1 "$OUT/COMMIT" 2>/dev/null || true)"
[[ "$(wc -l < "$OUT/COMMIT" 2>/dev/null | tr -d ' ')" == "1" ]] \
  || { echo "安装包不是从干净的工作区构建的，请提交改动后重新运行 make release"; exit 1; }

git fetch -q --tags origin
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  TAGGED="$(git rev-parse "$TAG^{commit}")"
  [[ "$BUILT_FROM" == "$TAGGED" ]] \
    || { echo "标签 $TAG 指向 ${TAGGED:0:7}，但安装包是从 ${BUILT_FROM:0:7} 构建的"; exit 1; }
else
  HEAD="$(git rev-parse HEAD)"
  [[ -z "$(git status --porcelain)" ]] || { echo "工作区有未提交的改动，请先提交"; exit 1; }
  [[ "$BUILT_FROM" == "$HEAD" ]] \
    || { echo "安装包不是从当前提交（${HEAD:0:7}）构建的，请重新运行 make release"; exit 1; }
  [[ "$(git rev-parse "origin/$(git branch --show-current)")" == "$HEAD" ]] \
    || { echo "当前提交还没推送到 origin，请先 git push"; exit 1; }
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

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "==> 更新已有的 Release $TAG"
  gh release upload "$TAG" "$DMG" "$DMG.sha256" --clobber
  gh release edit "$TAG" --notes-file "$BODY"
  gh release view "$TAG" --json url --jq .url
else
  gh release create "$TAG" "$DMG" "$DMG.sha256" \
    --title "ProxyAppX $VERSION" --notes-file "$BODY" --verify-tag
fi
