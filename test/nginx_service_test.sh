#!/usr/bin/env bash
# =============================================================================
# test/nginx_service_test.sh — nginx.service 健壮性守卫
#
# 背景: 原 nginx.service 缺 Restart= 与 LimitNOFILE。nginx 崩溃/被 OOM kill 后不会
#   自动拉起, 443 静默不通; 高并发下 worker 可能耗尽 FD。
#
# 做法: 静态守卫 config/nginx/nginx.service 含 Restart=on-failure / RestartSec= /
#   LimitNOFILE= (不依赖 jq/root, CI/沙箱均可跑)。
# =============================================================================
set -u

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
SVC="$REPO/config/nginx/nginx.service"

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

echo "=== nginx.service 自恢复测试 ==="
[[ -f "$SVC" ]] || { echo "找不到 $SVC"; exit 2; }

grep -Eq '^Restart=' "$SVC"        && ok "含 Restart="        || bad "缺 Restart="
grep -Eq '^Restart=on-failure' "$SVC" && ok "Restart=on-failure" || bad "Restart 非 on-failure"
grep -Eq '^RestartSec=' "$SVC"     && ok "含 RestartSec="     || bad "缺 RestartSec="
grep -Eq '^LimitNOFILE=' "$SVC"    && ok "含 LimitNOFILE="    || bad "缺 LimitNOFILE="

echo
if [[ $fail -eq 0 ]]; then echo "结果: 全部通过 (rc=0)"; else echo "结果: 存在失败"; fi
exit $fail
