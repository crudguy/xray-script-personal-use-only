#!/usr/bin/env bash
# =============================================================================
# test/reality_server_names_test.sh — REALITY serverNames 配置守卫
#
# 背景: handler.sh 在生成 xray 配置注入 realitySettings.serverNames 前, 需校验:
#   - 非空且非占位符 example.com (防手滑把模板占位符写进 config.json);
#   - 非 sni 模板时, serverNames 必须包含 target 域名 (REALITY 要求 SNI 命中其中一个,
#     否则握手失败或把伪装目标暴露成 example.com)。
#
# 做法: 静态守卫锁定 handler.sh 三处 _error 文案; 另用 python 镜像判定逻辑对一组
#   正反样例断言 (不依赖 jq, CI/沙箱均可跑)。逻辑镜像 handler.sh 的守卫, 若后者改了
#   判定规则需同步本测试。
# =============================================================================
set -u

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
H="$REPO/core/handler.sh"

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

echo "=== REALITY serverNames 守卫测试 ==="
grep -q 'REALITY serverNames 为空' "$H"            && ok "守卫: 非空"           || bad "缺 非空守卫"
grep -q 'REALITY serverNames 含占位符 example.com' "$H" && ok "守卫: 非占位符"   || bad "缺 占位符守卫"
grep -q 'REALITY serverNames 必须包含 target 域名' "$H" && ok "守卫: 含 target 域名" || bad "缺 target 一致性守卫"

# python 镜像判定逻辑 (与 handler.sh 守卫保持一致)
"${PY}" - <<'PY'
import json, sys
def valid(names, target, is_sni):
    if not names or names in ('[]', 'null'):
        return False, 'empty'
    if 'example.com' in names:
        return False, 'placeholder'
    if not is_sni:
        try:
            arr = json.loads(names)
        except Exception:
            return False, 'parse'
        if target not in arr:
            return False, 'no-target'
    return True, 'ok'

cases = [
    ('["microsoft.com"]', 'microsoft.com', False, True),   # 正常 vision/fallback
    ('[]', 'x', False, False),                              # 空 -> 拦截
    ('["example.com"]', 'x', False, False),                 # 占位符 -> 拦截
    ('["other.com"]', 'microsoft.com', False, False),       # 不含 target -> 拦截
    ('["microsoft.com"]', 'microsoft.com', True, True),     # sni 不校验 target
]
bad = 0
for names, tgt, sni, exp in cases:
    got, why = valid(names, tgt, sni)
    if got == exp:
        print('  ok   %s tgt=%s sni=%s -> %s' % (names, tgt, sni, why))
    else:
        print('  FAIL %s tgt=%s sni=%s expected %s got %s' % (names, tgt, sni, exp, got))
        bad = 1
sys.exit(bad)
PY
rc=$?
[[ $rc -eq 0 ]] || fail=1

echo
if [[ $fail -eq 0 ]]; then echo "结果: 全部通过 (rc=0)"; else echo "结果: 存在失败"; fi
exit $fail
