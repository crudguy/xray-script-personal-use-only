#!/usr/bin/env bash
# =============================================================================
# test/tfo_test.sh — xray freedom outbound 的 TCP Fast Open (TFO) 优化守卫
#
# 背景: outbound(freedom) 是 xray 出站 (服务器 -> 目标网站) 方向, 启用 sockopt.tcpFastOpen
#   可省一次 RTT (对服务器侧主动建连收益明显); 需配合 handler_net_tune 的
#   net.ipv4.tcp_fastopen=3 (客户端+服务端均启用)。
#
# 做法:
#   - 用 python 解析 config/xray/*.json, 断言每个 protocol=freedom 的 outbound 都含
#     sockopt.tcpFastOpen === true (不依赖 jq, CI/沙箱均可跑)。
#   - 静态守卫 handler.sh 的 net_tune 已登记 tcp_fastopen 键且目标值=3。
#
# 依赖: python3 (缺失则 rc=3 SKIP, 与 ssl_test 的 jq 缺失处理一致)。
# =============================================================================
set -u

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"

PY=''
for c in "${PYTHON:-}" python3 python; do
    command -v "$c" >/dev/null 2>&1 && PY="$c" && break
done
if [[ -z "${PY}" ]]; then
    echo "前置依赖缺失: python3 (请安装 python3 或 export PYTHON=<python路径>)"
    exit 3
fi

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

echo "=== xray freedom TFO 测试 ==="

"${PY}" - <<'PY' "$REPO"
import json, glob, sys
repo = sys.argv[1]
files = sorted(glob.glob(repo + '/config/xray/*.json'))
missing = []
for f in files:
    cfg = json.load(open(f))
    directs = [o for o in cfg.get('outbounds', []) if o.get('protocol') == 'freedom']
    for o in directs:
        so = o.get('sockopt') or {}
        if so.get('tcpFastOpen') is not True:
            missing.append((f, o.get('tag')))
if missing:
    for f, tag in missing:
        print('  FAIL %s outbound[%s] 缺少 sockopt.tcpFastOpen=true' % (f, tag))
    sys.exit(1)
print('  ok   %d 个 xray 模板的 direct(freedom) outbound 均含 sockopt.tcpFastOpen=true' % len(files))
PY
rc=$?
[[ $rc -eq 0 ]] || fail=1

# 静态守卫: handler.sh 的 net_tune 已登记 tcp_fastopen 键 + 目标值 3
if grep -q "net.ipv4.tcp_fastopen" "$REPO/core/handler.sh"; then
    ok "handler.sh net_tune 含 net.ipv4.tcp_fastopen 键"
else
    bad "handler.sh net_tune 缺 net.ipv4.tcp_fastopen 键"
fi
if grep -Eq "tcp_fastopen.*'3'|'3'.*tcp_fastopen" "$REPO/core/handler.sh"; then
    ok "handler.sh net_tune 的 tcp_fastopen 目标值=3"
else
    bad "handler.sh net_tune 的 tcp_fastopen 目标值非 3"
fi

echo
if [[ $fail -eq 0 ]]; then echo "结果: 全部通过 (rc=0)"; else echo "结果: 存在失败"; fi
exit $fail
