#!/usr/bin/env bash
# 把这个 fork 推到发布仓库（remote 名 fork）。安全预检 + 显式确认，不代填凭据。
#
# remote 布局：upstream = https://github.com/putyy/res-downloader（其 push 地址已置为
# 不可用域名，防止误推上游）；fork = https://github.com/chinakr/res-downloader-kylin
#
#   ./build/kylin/publish-fork.sh                 # 用已配好的 fork remote 预检并推送
#   ./build/kylin/publish-fork.sh --check         # 只预检
#   ./build/kylin/publish-fork.sh <仓库地址> [分支=master] [--check]   # 换/首次设定地址
#
# 凭据建议：HTTPS 用 fine-grained Personal Access Token，权限只给这一个仓库的
# Contents: Read and write；不要用带 admin/repo 全量权限的经典 token，
# 也不要把 token 写进 remote URL（那会明文留在 .git/config 里）。
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REMOTE=fork
URL=""; BRANCH=""; CHECK_ONLY=0
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=1 ;;
    *://*)    URL="$a" ;;
    *)       BRANCH="$a" ;;
  esac
done
cd "$SRC"
# 默认推当前分支：v4 线是 kylin-v4，不该去改写 fork 上那条对应 3.x 的 master
BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
# “待推提交”的基线：v4 线跟着 upstream/release/v4.0，3.x 线跟着 upstream/master
BASE=""
for ref in upstream/release/v4.0 upstream/master; do
  if git rev-parse --verify -q "$ref" >/dev/null; then BASE="$ref"; break; fi
done
[ -n "$BASE" ] || BASE="$(git merge-base HEAD "$REMOTE/$BRANCH" 2>/dev/null || echo HEAD)"
if [ -z "$URL" ]; then
  URL="$(git remote get-url "$REMOTE" 2>/dev/null || true)"
  [ -n "$URL" ] || { echo "未指定仓库地址，且本机没有 $REMOTE remote"; exit 2; }
  echo "使用已配置的 $REMOTE remote: $URL"
fi
command -v git >/dev/null || { echo "本机没有 git"; exit 1; }

fail() { echo "✗ $*"; exit 1; }
ok()  { echo "✓ $*"; }

echo "== 1. 安全与隐私预检"
[ -n "$(git status --porcelain)" ] && fail "工作区有未提交改动，先提交或还原"
ok "工作区干净"

if [ -e .git/shallow ]; then
  echo "  提示：仓库仍是浅克隆，推上去会缺历史。先执行： git fetch --unshallow upstream"
  exit 1
fi
ok "历史完整（$(git rev-list --count HEAD) 个提交）"

# 本机用户名/主机名绝不能出现在跟踪内容或提交元数据里。
# 敏感字面量不写进脚本（否则脚本自己会被自己的扫描命中），改为运行时取本机身份。
ME_USER="$(id -un)"
ME_HOST="$(hostname 2>/dev/null || echo unknown)"
PRIV_PATTERN="/home/${ME_USER}|${ME_USER}@|${ME_HOST}"

echo "  扫描口径: 本机用户 ${ME_USER}、主机 ${ME_HOST}"
if git grep -nI -E "$PRIV_PATTERN" -- . | head -5 | grep -q .; then
  fail "跟踪文件里仍有本机标识（见上），先清掉"
fi
if git log --all --format='%ae %ce' | grep -qE "${ME_USER}@|${ME_HOST}"; then
  fail "提交作者/提交者里仍有本机标识，需 filter-branch 改写"
fi
ok "无本机用户名/主机名残留"

# 构建产物与凭据类文件不得入库
if git ls-files | grep -qE '^(dist/|bin/)|\.(deb|key|pem|p12)$|\.npmrc|\.netrc|id_rsa'; then
  git ls-files | grep -E '^(dist/|bin/)|\.(deb|key|pem|p12)$|\.npmrc|\.netrc|id_rsa' | head -5
  fail "仓库里含构建产物或私钥类文件"
fi
ok "无构建产物/私钥入库（deb 请发 GitHub Releases，不要提交进仓库）"

# fork 声明与许可必须存在，且 LICENSE 未被改动
[ -f FORK-NOTES.md ] || fail "缺 FORK-NOTES.md（fork 说明与改动清单）"
git diff --quiet "$BASE" -- LICENSE || fail "LICENSE 被改动过，Apache-2.0 要求原样保留"
ok "FORK-NOTES.md 就位，LICENSE 未改动"

case "$URL" in
  *://*:*@*) fail "remote 地址里带凭据会被明文写进 .git/config，请去掉 user:token@" ;;
esac

echo "== 2. 将要推送的提交（相对上游）"
git log --oneline --format="  %h %an %s" $BASE..HEAD
echo "  共 $(git rev-list --count $BASE..HEAD) 个"

echo "== 3. 目标"
echo "  remote: $REMOTE → $URL"
echo "  分支:   $BRANCH"
# 只有本机自己加的 remote 才在收尾时清掉。之前无条件 remove，
# 结果 --check 会把用户已经配好的 fork remote 一起删掉。
ADDED_REMOTE=0
EXISTING="$(git remote get-url "$REMOTE" 2>/dev/null || true)"
if [ -z "$EXISTING" ]; then
  git remote add "$REMOTE" "$URL"
  ADDED_REMOTE=1
elif [ "$EXISTING" != "$URL" ]; then
  echo "  已有 $REMOTE remote（$EXISTING），按传入地址更新为 $URL"
  git remote set-url "$REMOTE" "$URL"
fi

# 只读探测：拿不到 fork 的分支就没法判断能不能快进；禁掉交互式凭据提示，
# 免得在未登录环境下挂住。
echo "== 4. 能否快进（fork 是从上游建的，上游若有新提交需要先变基）"
if GIT_TERMINAL_PROMPT=0 git fetch -q "$REMOTE" "$BRANCH" 2>/dev/null; then
  # 显式 fetch 单分支只更新 FETCH_HEAD，用它判断祖先关系最稳
  if git merge-base --is-ancestor FETCH_HEAD HEAD; then
    ok "fork 的 $BRANCH 是当前历史的祖先，可以直接快进推送"
  else
    echo "  fork/$BRANCH 上有我们没有的提交（上游在克隆之后又推进了）。先变基："
    echo "    git fetch $REMOTE $BRANCH && git rebase FETCH_HEAD"
    echo "  变基后重跑本脚本。"
    exit 1
  fi
else
  echo "  读不到 $REMOTE/$BRANCH（仓库还没建、地址不对，或需要凭据）。"
  echo "  需要凭据时先设置好再跑，或直接在终端里 push。"
fi

if [ "$CHECK_ONLY" = 1 ]; then
  echo
  echo "预检通过（--check 模式，不推送）。准备好凭据后去掉 --check 即可推送。"
  if [ "$ADDED_REMOTE" = 1 ]; then
    git remote remove "$REMOTE" 2>/dev/null || true
    echo "  （临时添加的 $REMOTE remote 已清理）"
  fi
  exit 0
fi

printf '\n确认推送？输入 yes 继续: '
read -r ANSWER
[ "$ANSWER" = "yes" ] || { echo "已取消（remote $REMOTE 已配置，可稍后手动 git push）"; exit 1; }

git push -u "$REMOTE" "$BRANCH"
ok "已推送"

cat <<'EOS'

下一步建议：
1. 到 fork 的 Settings → General 里勾选 "Create a fork of upstream" 之外的描述，
   把 About 写清「非官方麒麟适配分支」，并保留上游链接。
2. 若要发二进制：在 Releases 上传 dist/*.deb 并附校验值，说明它构建自哪个标记：
     sha256sum dist/*.deb
     构建标记见包名（build<提交数>-<短哈希>）
   同时在 Release 说明里重复一次 MITM 根证书与「仅供学习研究、禁止商用」的提示。
3. 凭据留在 credential helper 的缓存里即可，不要写进任何文件：
     git config --global credential.helper 'cache --timeout=3600'
EOS
