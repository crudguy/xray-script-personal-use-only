#!/usr/bin/env bash
# =============================================================================
# test/ssl_perms_test.sh — service/ssl.sh 私钥权限收紧守卫
#
# 背景: 签发成功后 privkey.pem 原先被显式 chmod 644 (world-readable)。nginx worker 以
#   nginx 身份运行 (config/nginx/conf/nginx.conf 的 `user nginx;`), 属组可读即够用,
#   不必让所有本机用户可读。改为 chown root:nginx + chmod 640; 若主机无 nginx 组
#   (chown 失败), 回退 644 避免 nginx 因读不到私钥而启动失败。
#
# 做法: 静态守卫锁定"640 收紧"与"644 回退"双分支都在源码里 (不依赖运行时 root,
#   CI/沙箱均可跑)。真实权限效果由 ssl_test.sh 的 --issue 链路在真机验证。
# =============================================================================
set -u

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
SRC="$REPO/service/ssl.sh"

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

echo "=== ssl.sh 私钥权限收紧测试 ==="
[[ -f "$SRC" ]] || { echo "找不到 $SRC"; exit 2; }

grep -q "chown root:nginx" "$SRC" && ok "含 chown root:nginx" || bad "缺 chown root:nginx"
grep -q "chmod 640" "$SRC"        && ok "含 chmod 640 (私钥收紧)" || bad "缺 chmod 640"
grep -q "chmod 644" "$SRC"        && ok "含 chmod 644 (回退/公开链)" || bad "缺 chmod 644"

# 关键: 必须同时有 640 (收紧) 与 644 (回退) 两个分支, 不能只剩 644 (回归)
if grep -q "chmod 640" "$SRC" && grep -q "chmod 644" "$SRC"; then
    ok "640 收紧与 644 回退双分支齐备"
else
    bad "640/644 分支不完整"
fi

echo
if [[ $fail -eq 0 ]]; then echo "结果: 全部通过 (rc=0)"; else echo "结果: 存在失败"; fi
exit $fail
