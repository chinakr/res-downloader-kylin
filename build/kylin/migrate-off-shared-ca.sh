#!/usr/bin/env bash
# 把上游那把"全球共用、私钥公开在仓库里"的根证书(CN=gowas.cn)从本机信任链里清出去。
# 换成机器专属 CA 之后，旧根留在信任库里就是纯粹的风险，不会自动消失。
#
#   ./build/kylin/migrate-off-shared-ca.sh           # 只体检，打印发现与待执行命令
#   ./build/kylin/migrate-off-shared-ca.sh --apply   # 顺手清掉用户级 NSS 库里的旧根（免 root）
set -uo pipefail

LEGACY_FP="6E7F9E6BF34F9843853285E0CB7399FA264F834AA1DA0F2EBBE0234546F97DA0"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

fingerprint_of_pem_file() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F'
}

# 合并 bundle 里逐块比对主体名（本机 kysec 不允许脚本往 /tmp 落临时文件，
# 所以用 pkcs7 管道一次读完整份，不做拆块）
bundle_has_legacy() {
  local f="$1"
  [ -r "$f" ] || return 1
  openssl crl2pkcs7 -nocrl -certfile "$f" 2>/dev/null \
    | openssl pkcs7 -print_certs -noout 2>/dev/null | grep -qi 'CN *= *gowas\.cn'
}

echo "== 1. 当前生效的机器 CA =="
if [ -f /etc/res-downloader/ca.crt ]; then
  echo "   系统级 /etc/res-downloader/ca.crt  $(openssl x509 -in /etc/res-downloader/ca.crt -noout -subject | sed 's/subject=//')"
elif [ -f "$HOME/.config/res-downloader/ca.crt" ]; then
  echo "   用户级 ~/.config/res-downloader/ca.crt  $(openssl x509 -in "$HOME/.config/res-downloader/ca.crt" -noout -subject | sed 's/subject=//')"
else
  echo "   (还没生成过：先启动一次 res-downloader，或装带 CA 的 deb)"
fi

echo "== 2. 旧共用根的下落 =="
FOUND=0
for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
         /usr/local/share/ca-certificates/res-downloader.crt \
         /usr/local/share/ca-certificates/res-downloader-local.crt; do
  [ -e "$f" ] || continue
  if [ ! -L "$f" ] && bundle_has_legacy "$f"; then
    echo "   [命中] $f"; FOUND=1
  elif [ -L "$f" ]; then
    echo "   [链接] $f -> $(readlink -f "$f")"
  fi
done

if [ -f /usr/local/share/ca-certificates/res-downloader.crt ] && [ ! -L /usr/local/share/ca-certificates/res-downloader.crt ]; then
  fp=$(fingerprint_of_pem_file /usr/local/share/ca-certificates/res-downloader.crt)
  if [ "$fp" = "$LEGACY_FP" ]; then
    echo "   [命中] /usr/local/share/ca-certificates/res-downloader.crt 仍是旧共用根"; FOUND=1
  fi
fi

NSSDB="$HOME/.pki/nssdb"
if [ -d "$NSSDB" ] && command -v certutil >/dev/null 2>&1; then
  for nick in $(certutil -L -d "sql:$NSSDB" 2>/dev/null | awk 'NR>2{print $1}' | grep -v '^$'); do
    fp=$(certutil -L -d "sql:$NSSDB" -n "$nick" -a 2>/dev/null \
         | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F')
    if [ "$fp" = "$LEGACY_FP" ]; then
      echo "   [命中] NSS 用户库条目 \"$nick\""
      if [ "$APPLY" = 1 ]; then
        certutil -D -d "sql:$NSSDB" -n "$nick" && echo "     → 已删除（Chromium 系浏览器需重启生效）"
      else
        echo "     → 未删除：加 --apply 可清理（这一步不需要 root）"
      fi
      FOUND=1
    fi
  done
fi

[ "$FOUND" = 0 ] && echo "   没有发现旧共用根，本机已干净"

# 光删 bundle 没用：update-ca-certificates 会按投放目录重建它。
# 所以要连带找到"喂进 bundle 的那个源文件"。
find_legacy_sources() {
  for d in /usr/local/share/ca-certificates /usr/share/ca-certificates/mozilla /usr/share/ca-certificates; do
    [ -d "$d" ] || continue
    for f in "$d"/*.crt "$d"/*.pem; do
      [ -e "$f" ] || continue
      fp=$(fingerprint_of_pem_file "$f")
      case "$(basename "$f")" in
        *res-downloader*) echo "$f  (名字命中；指纹 ${fp:-读不到})"; continue ;;
      esac
      if [ "$fp" = "$LEGACY_FP" ]; then
        echo "$f"
      elif [ -z "$fp" ] && [ ! -r "$f" ]; then
        # root 属主 640/750 之类，普通用户读不了，指纹比不了，只能提示人工确认
        echo "$f  (无权限读取，需 sudo openssl x509 -in $f -noout -fingerprint -sha256 核对)"
      fi
    done
  done
}

SOURCES="$(find_legacy_sources)"

echo "== 3. 需要 root 的部分（本脚本不代为执行）=="
if [ -n "$SOURCES" ]; then
  echo "   先删这些投放文件，再重建 bundle，否则下次 update-ca-certificates 又把它加回来："
  echo "$SOURCES" | sed 's/^/     /'
  echo
  echo "   对应命令（去掉备注后可直接粘贴）："
  echo "$SOURCES" | sed 's/  (.*/ /' | tr -s ' ' '\n' | grep '^/' \
    | sed 's/^/     sudo rm -f /'
  echo "     sudo update-ca-certificates --fresh"
else
  cat <<'EOS'
   没找到可读的投放源文件。若 bundle 里确实命中，通常是某个 root 权限文件，
   请逐条核对后删除：
     sudo ls -l /usr/local/share/ca-certificates/
     sudo update-ca-certificates --fresh
EOS
fi
cat <<'EOS'

   注：新版 deb 的 postinst 会用本机 CA 覆盖 /usr/local/share/ca-certificates/res-downloader.crt
   并以 --fresh 重建 bundle，所以在这台机器上「装新包」本身就是迁移。
   若你曾把证书导进手机、平板或别的电脑，那边也要删一次旧根，否则它们仍信任这把私钥公开的根。
   删完重启浏览器（NSS 会缓存信任链）。
EOS

