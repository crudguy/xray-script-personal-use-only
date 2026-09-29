#!/usr/bin/env bash
# =============================================================================
# 测试名称: audit_fixes_test.sh
# 测试目标: 锁定 2026-09-28 全库审计 (code-audit-2026-09-28.md) 的修复点 ——
#           防止"同类缺陷"回潮:
#
#   B1 行为 —— urlencode 多字节按 UTF-8 字节编码 (jq @uri); ASCII 输出与旧实现逐字节一致
#   B2 行为 —— generate_target 空池/缺 .target 返回空串且 rc=0, 不再以 jq rc=5 炸掉调用方
#   B3 静态+行为 —— generate_password 字符集不含 `@ %` (分享链接 userinfo/query 的坏字符)
#   B4 行为 —— share.sh 的空 shortIds/serverNames 守卫: 空数组/缺失键返回空串, 流程不崩
#   B5 行为 —— resolve_domain 落变量比对: dig 有输出=0 / 无输出=1
#   B6 行为 —— _public_ip_has_v6_route: 有默认路由=0 / 无=1 / 缺 ip 命令=0 (保守)
#   B7 静态 —— handler.sh 两处判据改为内建比对 (SIGPIPE 约定), 管道 grep 已清除
#   B8 行为 —— Clash YAML 的节点名/密码转义 `"` (用户可控字符串)
#   NEG 负向 —— (a) 把空集守卫变异回 `.[$r % length?]` → B4 必须复现崩溃;
#               (b) 把 @uri 变异为 @text → B1 必须变红。两条都用 cmp 自证变异落地。
#
# 运行: bash test/audit_fixes_test.sh
# =============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s%s\n' "$1" "${2:+ ($2)}"; }
assert_eq() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got=$(printf '%q' "$2") want=$(printf '%q' "$3")"; fi
}
assert_contains() {
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing $(printf '%q' "$3")"; fi
}

SB="$ROOT/.workbuddy/tmp/audit_fixes.$$"
rm -rf "$SB" 2>/dev/null || true
mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

SHARE='core/share.sh'
GEN='core/generate.sh'
COMMON='core/_common.sh'
CHECK='core/check.sh'
HANDLER='core/handler.sh'

fn_of() { # $1=file $2=fn
    awk -v fn="$2" 'index($0, "function " fn "() {") == 1 { f=1 } f { print } f && /^}$/ { exit }' "$1"
}

# share.sh 特化版: 函数体内含以 "EOF" 结尾的 heredoc (JSON 模板), 其列首 `}` 是
#   **内容**而不是函数尾 —— 简单版 fn_of 会在那里提前截断, 抽出的函数缺了 heredoc
#   终止符 (症状: bash 报 "here-document delimited by end-of-file")。
#   规则: 见到 <<EOF 即进入 heredoc, 之后必须先见到 EOF 行才允许按 `^}$` 收尾。
fn_of_heredoc() { # $1=file $2=fn
    awk -v fn="$2" '
        index($0, "function " fn "() {") == 1 { f=1 }
        f && /<<-?EOF/ { heredoc=1 }
        f && $0 == "EOF" { seen=1 }
        f { print }
        f && /^}$/ && (!heredoc || seen) { exit }
    ' "$1"
}

echo "==== audit_fixes_test ===="

# ---------------------------------------------------------------------------
# B1: urlencode (多字节 + ASCII 回归)
# ---------------------------------------------------------------------------
build_urlencode_runner() { # $1=share 源 (可变异) $2=输出
    {
        printf '%s\n' 'set -Eeuo pipefail'
        fn_of_heredoc "$1" 'urlencode'
        printf '%s\n' 'printf "%s\\n" "$(urlencode)"'
    } >"$2"
}
build_urlencode_runner "$SHARE" "$SB/ue_runner.sh"

echo "-- [B1] urlencode: 多字节按 UTF-8 字节编码 --"
out="$(printf '节点A' | bash "$SB/ue_runner.sh" 2>&1)"
assert_eq "B1 多字节: 节点A -> UTF-8 百分号编码" "$out" '%E8%8A%82%E7%82%B9A'
out="$(printf 'abc123.~_-' | bash "$SB/ue_runner.sh" 2>&1)"
assert_eq "B1 ASCII 回归: 保留字符集不编码" "$out" 'abc123.~_-'
out="$(printf 'a b/c?d=e&f' | bash "$SB/ue_runner.sh" 2>&1)"
assert_eq "B1 保留字与分隔符: 空格与 / ? = & 全编码" "$out" 'a%20b%2Fc%3Fd%3De%26f'

# ---------------------------------------------------------------------------
# B2: generate_target (空池/缺 .target 不崩)
# ---------------------------------------------------------------------------
build_target_runner() { # $1=config 路径 $2=输出
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' "SCRIPT_CONFIG_PATH='$1'"
        fn_of "$GEN" 'generate_random'
        fn_of "$GEN" 'generate_target'
        printf '%s\n' 'out="$(generate_target)"'
        printf '%s\n' 'printf "RC=%s OUT=%s\\n" "$?" "$out"'
    } >"$2"
}
CFGO="$SB/cfg-origin.json"
CFGE="$SB/cfg-empty.json"
printf '%s' '{"target":{"a.example.com":["a.example.com"],"b.example.com":["b.example.com"]}}' >"$CFGO"
printf '%s' '{}' >"$CFGE"

echo "-- [B2] generate_target: 空集守卫 --"
build_target_runner "$CFGO" "$SB/gt_runner.sh"
out="$(bash "$SB/gt_runner.sh" 2>&1)"
assert_contains "B2 有预设: rc=0 且随机命中候选之一" "$out" 'RC=0'
if [[ "$out" == *'OUT=a.example.com'* || "$out" == *'OUT=b.example.com'* ]]; then
    ok "B2 有预设: 输出为候选键之一"
else
    bad "B2 有预设: 输出不是候选键 ($out)"
fi
build_target_runner "$CFGE" "$SB/gt_runner2.sh"
out="$(bash "$SB/gt_runner2.sh" 2>&1)"
assert_eq "B2 缺 .target: 空串且 rc=0 (不再 jq rc=5 崩溃)" "$out" 'RC=0 OUT='

# ---------------------------------------------------------------------------
# B3: generate_password 字符集不含 @ %
# ---------------------------------------------------------------------------
echo "-- [B3] generate_password: 字符集 --"
if grep -qF "tr -dc '0-9a-zA-Z!\$*'" "$GEN" && ! grep -qF '0-9a-zA-Z!@' "$GEN"; then
    ok "B3 静态: 字符串已剔除 @ 与 %"
else
    bad "B3 静态: 字符集仍含 @ 或 % (分享链接坏字符回归)"
fi
pw_bad=0
for _ in $(seq 1 20); do
    pw="$(bash "$GEN" --password 2>/dev/null || true)"
    if [[ -z "$pw" || "$pw" == *'@'* || "$pw" == *'%'* ]]; then
        pw_bad=1
    fi
done
if [[ $pw_bad -eq 0 ]]; then
    ok "B3 行为: 20 个样本均无 @ % 且非空"
else
    bad "B3 行为: 样本中出现坏字符/空串"
fi

# ---------------------------------------------------------------------------
# B4: share.sh 空集守卫 (get_reality_down_json / get_fallback_xhttp_share_link)
# ---------------------------------------------------------------------------
build_reality_runner() { # $1=share 源 $2=输出 $3=XRAY_CONFIG 内容
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' 'declare -A CLIENT_CONFIG=()'
        printf '%s\n' "declare SCRIPT_CONFIG='{\"nginx\":{\"domain\":\"d.example.com\"},\"xray\":{\"publicKey\":\"PBK\",\"path\":\"/p\"}}'"
        printf '%s\n' "declare XRAY_CONFIG=\$'$(printf '%s' "$3" | sed "s/'/'\\\\''/g")'"
        printf '%s\n' 'declare SHARE_FP="chrome" XHTTP_EXTRA="" XHTTP_EXTRA_ENCODED=""'
        fn_of_heredoc "$1" 'urlencode'
        fn_of_heredoc "$1" 'get_reality_down_json'
        printf '%s\n' 'get_reality_down_json'
        printf '%s\n' 'printf "RC=%s SHORTID_EMPTY=%s\\n" "$?" "$(grep -c "\"shortId\": \"\"" <<<"$XHTTP_EXTRA")"'
    } >"$2"
}
XCFG_EMPTY='{"inbounds":[null,{"streamSettings":{"realitySettings":{"serverNames":["d.example.com"],"shortIds":[]}},"settings":{"clients":[{"id":"u"}]}}]}'
XCFG_MISSING='{"inbounds":[null,{"streamSettings":{"realitySettings":{}},"settings":{"clients":[{"id":"u"}]}}]}'

echo "-- [B4] share.sh 空集守卫 --"
build_reality_runner "$SHARE" "$SB/rel_runner.sh" "$XCFG_EMPTY"
out="$(bash "$SB/rel_runner.sh" 2>&1 || true)"
assert_contains "B4 空 shortIds: rc=0 (不再 jq rc=5 崩溃)" "$out" 'RC=0'
assert_contains "B4 空 shortIds: shortId 兜为空串" "$out" 'SHORTID_EMPTY=1'
build_reality_runner "$SHARE" "$SB/rel_runner2.sh" "$XCFG_MISSING"
out="$(bash "$SB/rel_runner2.sh" 2>&1 || true)"
assert_contains "B4 缺 realitySettings.shortIds: 同样 rc=0" "$out" 'RC=0'

# ---------------------------------------------------------------------------
# B5: resolve_domain (落变量比对)
# ---------------------------------------------------------------------------
build_dns_runner() { # $1=check 源 $2=输出
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' 'dig() { printf "%s" "${DIG_OUT:-}"; }'
        fn_of "$1" 'resolve_domain'
        printf '%s\n' 'if resolve_domain x.example.com; then printf "RESOLVED\\n"; else printf "UNRESOLVED\\n"; fi'
    } >"$2"
}
build_dns_runner "$CHECK" "$SB/dns_runner.sh"
echo "-- [B5] resolve_domain --"
out="$(DIG_OUT='1.2.3.4' bash "$SB/dns_runner.sh" 2>&1)"
assert_eq "B5 dig 有记录: 判解析成功" "$out" 'RESOLVED'
out="$(DIG_OUT='' bash "$SB/dns_runner.sh" 2>&1)"
assert_eq "B5 dig 无输出: 判解析失败" "$out" 'UNRESOLVED'

# ---------------------------------------------------------------------------
# B6: _public_ip_has_v6_route (三种情形)
# ---------------------------------------------------------------------------
build_v6rt_runner() { # $1=common 源 $2=输出
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' 'cmd_exists() { [[ "${HAS_IP:-1}" == "1" ]]; }'
        printf '%s\n' 'ip() { printf "%s" "${IP_OUT:-}"; }'
        fn_of "$1" '_public_ip_has_v6_route'
        printf '%s\n' 'if _public_ip_has_v6_route; then printf "HAS_ROUTE\\n"; else printf "NO_ROUTE\\n"; fi'
    } >"$2"
}
build_v6rt_runner "$COMMON" "$SB/v6rt_runner.sh"
echo "-- [B6] _public_ip_has_v6_route --"
out="$(IP_OUT='default dev eth0 metric 1024' bash "$SB/v6rt_runner.sh" 2>&1)"
assert_eq "B6 有默认路由: 判有 v6 出口" "$out" 'HAS_ROUTE'
out="$(IP_OUT='' bash "$SB/v6rt_runner.sh" 2>&1)"
assert_eq "B6 无输出: 判无 v6 出口" "$out" 'NO_ROUTE'
out="$(HAS_IP=0 bash "$SB/v6rt_runner.sh" 2>&1)"
assert_eq "B6 缺 ip 命令: 保守判有 (与函数头注释一致)" "$out" 'HAS_ROUTE'

# ---------------------------------------------------------------------------
# B7: handler.sh 两处判据改为内建比对 (静态)
# ---------------------------------------------------------------------------
echo "-- [B7] handler.sh 内建比对 --"
if ! grep -qF '${out}" | grep -qi' "$HANDLER" && grep -qF '${out,,}' "$HANDLER"; then
    ok "B7 _xray_config_probe: 管道 grep 已替换为内建比对"
else
    bad "B7 _xray_config_probe: 仍用管道 grep (SIGPIPE 残留)"
fi
if ! grep -qF '${err}" | grep -qiE' "$HANDLER" && grep -qF 'local err_lc="${err,,}"' "$HANDLER"; then
    ok "B7 finalmask 自愈判据: 同样改为内建比对"
else
    bad "B7 finalmask 自愈判据: 仍用管道 grep"
fi

# ---------------------------------------------------------------------------
# B8: clash_build_proxy 的 YAML 双引号转义
# ---------------------------------------------------------------------------
build_clash_runner() { # $1=share 源 $2=输出
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' 'declare CLASH_PROXIES="" CLASH_NAMES=()'
        printf '%s\n' 'declare SHARE_FP="chrome" XHTTP_EXTRA_ENCODED=""'
        fn_of_heredoc "$1" 'clash_build_proxy'
        printf '%s\n' 'clash_build_proxy "$1"'
        printf '%s\n' 'printf "NAME=%s\\n" "${CLASH_NAMES[0]}"'
        printf '%s\n' 'printf "%s\\n" "$CLASH_PROXIES"'
    } >"$2"
}
build_clash_runner "$SHARE" "$SB/clash_runner.sh"
echo "-- [B8] clash_build_proxy: YAML 双引号转义 --"
node_json="$(jq -nc --arg tag 'a"b' --arg user 'p"w' '{scheme:"trojan",user:$user,host:"h",port:443,type:"tcp",security:"none",sni:"",pbk:"",sid:"",fp:"",flow:"",path:"",seed:"",tag:$tag,link:""}')"
out="$(bash "$SB/clash_runner.sh" "$node_json" 2>&1 || true)"
assert_contains "B8 节点名转义: CLASH_NAMES 存转义后的引号" "$out" 'NAME=a\"b'
assert_contains "B8 proxies 段: name 行含转义引号" "$out" 'name: "a\"b"'
assert_contains "B8 proxies 段: password 行含转义引号" "$out" 'password: "p\"w"'

# ---------------------------------------------------------------------------
# NEG 负向校验
# ---------------------------------------------------------------------------
echo "-- [NEG] 负向校验 --"
SHARE_BAK="$SB/_share_orig.sh"
cp "$SHARE" "$SHARE_BAK"

neg_mutate() { # $1=mode $2=输出
    python3 - "$SHARE_BAK" "$2" "$1" <<'PY'
import pathlib
import sys

# argv: [0]='-' [1]=源文件 [2]=输出文件 [3]=mode
src = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
out_path = sys.argv[2]
mode = sys.argv[3]
if mode == 'restore_mod_zero':
    # 把 get_reality_down_json 的守卫变异回除零写法 (审计前的原样)
    old = """        ((.inbounds[$i].streamSettings.realitySettings.shortIds?) // []) as $si
        | if ($si | length) == 0 then "" else $si[$random % ($si | length)] end
    ')"
"""
    new = """        .inbounds[$i].streamSettings.realitySettings.shortIds | .[$random % length?]'
)"
"""
elif mode == 'urlencode_no_uri':
    old = "    jq -rn --arg s \"${input}\" '$s | @uri'"
    new = "    jq -rn --arg s \"${input}\" '$s | @text'"
else:
    raise SystemExit('unknown mode: ' + mode)
if old not in src:
    raise SystemExit('NEG 改写未命中 (实现已演进, 需更新锚点): ' + mode)
src = src.replace(old, new, 1)
pathlib.Path(out_path).write_text(src, encoding='utf-8')
PY
}

# (a) 恢复除零写法 -> B4 的空 shortIds 场景必须复现崩溃 (jq rc=5)
if neg_mutate 'restore_mod_zero' "$SB/_share_neg_a.sh"; then
    if cmp -s "$SHARE_BAK" "$SB/_share_neg_a.sh"; then
        bad "NEG(a) 变异未落地 (文件与原文一致)"
    else
        ok "NEG(a) 变异已落地"
        build_reality_runner "$SB/_share_neg_a.sh" "$SB/rel_neg.sh" "$XCFG_EMPTY"
        out="$(bash "$SB/rel_neg.sh" 2>&1 || true)"
        if [[ "$out" != *'RC=0'* ]]; then
            ok "NEG(a) 破损版: 空 shortIds 复现崩溃 (证明 B4 非恒真)"
        else
            bad "NEG(a) 破损版仍 rc=0 —— 守护无效"
        fi
    fi
else
    bad "NEG(a) 改写未生效"
fi

# (b) @uri 换成 @text (原样透传) -> B1 的多字节断言必须变红
if neg_mutate 'urlencode_no_uri' "$SB/_share_neg_b.sh"; then
    if cmp -s "$SHARE_BAK" "$SB/_share_neg_b.sh"; then
        bad "NEG(b) 变异未落地 (文件与原文一致)"
    else
        ok "NEG(b) 变异已落地"
        build_urlencode_runner "$SB/_share_neg_b.sh" "$SB/ue_neg.sh"
        out="$(printf '节点A' | bash "$SB/ue_neg.sh" 2>&1 || true)"
        if [[ "$out" != '%E8%8A%82%E7%82%B9A' ]]; then
            ok "NEG(b) 破损版: 多字节断言变红 (证明 B1 非恒真)"
        else
            bad "NEG(b) 破损版输出仍正确 —— 守护无效"
        fi
    fi
else
    bad "NEG(b) 改写未生效"
fi

echo
echo "==== audit_fixes_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
