#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_sni_config_arm_test.sh
# 测试目标: handler_sni_config (SNI 装配 / 非 SNI 收尾) 这条零覆盖臂的**分派层 +
#           调用顺序层**回归。
#
# 为什么需要本测试 (审计背景):
#   这个函数是「改一次 tag, 动一整套现场」的开关: 同一个入口既负责给非 SNI 模式**停掉
#   Nginx 让出 443**, 又负责给 SNI 模式**串起 换域 -> 同步自定义站点 -> 重建 stream ->
#   拉起 Web**。两侧都零覆盖时, 最典型的翻车方式是"顺序错了"而不是"少了调用":
#     - change_domain 的 'domain'/'cdn' 顺序反了 -> CDN 证书先签、主域后签, 后签的那次
#       会顶掉前一次写进 nginx.conf 的站点名, 留下一个指向旧域名的活站点。
#     - 自定义站点同步放在 handler_web 之后 -> stream 已按旧清单重建完毕并 reload, 新站
#       点的 443 分流根本没进去, 而 nginx 已经"起来了", 现象是抽查时才发现的漏站。
#     - 非 SNI 分支忘了停 nginx -> xray 直听 443 与 nginx 抢端口, 整个模式切换起不来。
#   第二参 'n' 也是硬契约: SNI 装配发生在证书还没签的时候, 若在此处 stop 证书服务会
#   把既有续期任务拆掉, 用户下次到期不续。
#
# 锁定不变量:
#   [A] 分支选择: 由 .xray.tag 驱动, 大小写不敏感
#     T1  mkcp   -> handler_nginx_stop
#     T2  vision -> handler_nginx_stop
#     T3  xhttp  -> handler_nginx_stop
#     T4  trojan -> handler_nginx_stop
#     T5  fallback -> handler_nginx_stop
#     T6  大写 tag (MKCP / Vision) 同样走非 SNI 分支 (case 用 ${CONFIG_TAG,,})
#     T7  大写 SNI (Sni) 同样走 SNI 分支
#   [B] 非 SNI 分支的副作用面
#     T8  只有 NGINX_STOP: 不换域 / 不同步站点 / 不重建 stream / 不拉 web
#   [C] 未知 / 缺失 tag
#     T9  tag 键缺失 -> 零动作, rc 0 (case 无 default, 不能误停 nginx)
#     T10 tag 为 null -> 零动作
#     T11 tag 是未知值 (xtls) -> 零动作
#   [D] SNI 分支的调用顺序 (本测试最要紧的一条)
#     T12 顺序恒为 change_domain('domain','n') -> change_domain('cdn','n')
#     T13 第二参恒为 'n' (装配期不得拆证书续期)
#     T14 收尾必调 handler_web
#     T15 web 入参原样透传
#     T16 web 入参缺省 -> 传空串 (由 handler_web 内部再回落 normal)
#     T17 SNI 分支不停 nginx (Nginx 正是 SNI 模式的载体)
#   [E] 自定义站点同步门控
#     T18 有站点 -> 提示 syncing + sync + rebuild, 且整体在 handler_web **之前**
#     T19 空数组 -> 不 sync / 不 rebuild / 无 syncing 提示
#     T20 custom_sites 键缺失 -> 同上 (// [] 兜底)
#     T21 custom_sites 被写成字符串 -> 按 0 处理 (旧写法 length=字符数 会拿垃圾去 sync)
#     T22 .nginx 不是对象 (jq 直接失败) -> 按 0 处理且不崩 (旧写法会 bash 语法错误)
#     T23 sync 用的必须是**当前** SCRIPT_CONFIG
#   [F] 失败即中断
#     T24 sync 失败 -> _error "failed to sync custom sites", 且不 rebuild / 不调 web
#
# 实现备注:
#   - 被测函数在失败路径经 _error **exit 1**, 一律在子 shell 里跑, 调用轨迹 / 退出码经
#     **文件**回传。
#   - 调用轨迹统一压成 "步骤序列" 再比对, 这样"调用对了但顺序错了"也能被抓出来
#     (逐个 assert_contains 只能证明"调用过", 证不了顺序)。
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$REPO"

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available in this environment"
    exit 0
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1 (期望 [$3] 实际 [$2])"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1 (未包含 [$3]，实际 [$2])"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1 (不应包含 [$3]，实际 [$2])"; fi; }
count_lines() { # $1=pattern (允许以 - 开头) $2=文件
    if [[ -f "$2" ]]; then
        grep -c -- "$1" "$2" || true
    else
        printf '0'
    fi
}
extract_fn() { awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' "$1"; }
line_no() { # $1=文件 $2=目标行 -> 首个匹配行号 (0=无)
    if [[ -f "$1" ]]; then
        grep -n -F -m1 -- "$2" "$1" | cut -d: -f1 || true
    else
        printf '0'
    fi
}
getfile() { if [[ -f "$1" ]]; then cat "$1"; else printf ''; fi; }

echo "==== handler_sni_config_arm_test ===="

SB=".workbuddy/tmp/snicfg_arm.$$"

sni_fn="$(extract_fn core/handler.sh handler_sni_config)"
assert_contains "T0 handler_sni_config 抽取成功" "$sni_fn" 'function handler_sni_config'

mk_sandbox() {
    rm -rf "$SB"
    mkdir -p "$SB"
}
mk_sandbox

# 造一份脚本配置: $1=tag (空 = 不写 .xray.tag) $2=custom_sites 的 JSON 片段 (空 = 不写)
sc_make() {
    local tag="$1"
    local sites="$2"
    local xray='{}'
    [[ -n "$tag" ]] && xray="$(printf '{"tag":"%s"}' "$tag")"
    local nginx='{}'
    [[ -n "$sites" ]] && nginx="$(printf '{"domain":"a.example.com","cdn":"cdn.example.com","custom_sites":%s}' "$sites")"
    printf '{"version":"v-test","xray":%s,"nginx":%s}' "$xray" "$nginx"
}

# ---------------------------------------------------------------------------
# 驱动: handler_sni_config
# 环境变量:
#   SNI_SC        脚本配置 (必填)
#   SNI_WEB       web 入参
#   SNI_FAIL_SYNC 1 = sync_custom_sites_config 失败
# ---------------------------------------------------------------------------
run_sni() {
    rm -f "$SB/plog" "$SB/rc" "$SB/out"
    (
        # shellcheck disable=SC2034
        CUR_FILE='handler'
        # shellcheck disable=SC2034
        SCRIPT_CONFIG="${SNI_SC:-}"
        # shellcheck disable=SC2034
        GREEN='' YELLOW='' RED='' NC=''
        _i18n() { printf '%s' "${1#.}"; }
        _error() { printf 'ERROR:%s\n' "$*" >>"$SB/plog"; exit 1; }
        handler_nginx_stop() { printf 'NGINX_STOP\n' >>"$SB/plog"; }
        handler_change_domain() { printf 'CD:%s|%s\n' "${1:-}" "${2:-}" >>"$SB/plog"; }
        sync_custom_sites_config() {
            printf 'SYNC:%s\n' "${1:-}" >>"$SB/plog"
            [[ "${SNI_FAIL_SYNC:-0}" == '0' ]]
        }
        rebuild_stream_config() { printf 'REBUILD\n' >>"$SB/plog"; }
        handler_web() { printf 'WEB:%s\n' "${1:-}" >>"$SB/plog"; }
        eval "$sni_fn"
        handler_sni_config "${SNI_WEB:-}" >"$SB/out" 2>&1
        printf '0' >"$SB/rc"
    ) || true
}

# 调用轨迹压成 "步骤>步骤" 序列 —— 顺序错也能被抓出来
steps() { grep -oE '^(NGINX_STOP|CD:[a-z]+\|[a-z]*|SYNC|REBUILD|WEB)' "$SB/plog" 2>/dev/null | tr '\n' '>' || true; }
plog() { getfile "$SB/plog"; }
outp() { getfile "$SB/out"; }
rc() { getfile "$SB/rc"; }

# ---------------------------------------------------------------------------
# [A] 非 SNI tag -> 只停 nginx
# ---------------------------------------------------------------------------
for tag in mkcp vision xhttp trojan fallback; do
    SNI_SC="$(sc_make "$tag" '')" run_sni
    assert_eq "A ${tag}: 步骤序列" "$(steps)" 'NGINX_STOP>'
    assert_eq "A ${tag}: rc 0" "$(rc)" '0'
done

SNI_SC="$(sc_make 'MKCP' '')" run_sni
assert_eq "T6 大写 MKCP 走非 SNI 分支" "$(steps)" 'NGINX_STOP>'
SNI_SC="$(sc_make 'Vision' '')" run_sni
assert_eq "T6 大写 Vision 走非 SNI 分支" "$(steps)" 'NGINX_STOP>'
SNI_SC="$(sc_make 'FALLBACK' '')" run_sni
assert_eq "T6 大写 FALLBACK 走非 SNI 分支" "$(steps)" 'NGINX_STOP>'

# ---------------------------------------------------------------------------
# [B] 非 SNI 分支的副作用面 (以 vision 为代表)
# ---------------------------------------------------------------------------
SNI_SC="$(sc_make 'vision' '[{"domain":"s1.example.com"}]')" run_sni
assert_not_contains "T8 非 SNI: 不换域" "$(plog)" 'CD:'
assert_not_contains "T8 非 SNI: 不同步自定义站点" "$(plog)" 'SYNC'
assert_not_contains "T8 非 SNI: 不重建 stream" "$(plog)" 'REBUILD'
assert_not_contains "T8 非 SNI: 不拉 web" "$(plog)" 'WEB'
assert_eq "T8 非 SNI: 恰好一次 NGINX_STOP" "$(count_lines 'NGINX_STOP' "$SB/plog")" '1'

# ---------------------------------------------------------------------------
# [C] 未知 / 缺失 tag -> 零动作
# ---------------------------------------------------------------------------
SNI_SC="$(sc_make '' '[{"domain":"s1.example.com"}]')" run_sni
assert_eq "T9 tag 缺失: 零动作" "$(steps)" ''
assert_eq "T9 tag 缺失: rc 0" "$(rc)" '0'

SNI_SC='{"xray":{"tag":null},"nginx":{"custom_sites":[{"domain":"s1.example.com"}]}}' run_sni
assert_eq "T10 tag=null: 零动作" "$(steps)" ''
assert_eq "T10 tag=null: rc 0" "$(rc)" '0'

SNI_SC="$(sc_make 'xtls' '[{"domain":"s1.example.com"}]')" run_sni
assert_eq "T11 未知 tag: 零动作" "$(steps)" ''
assert_eq "T11 未知 tag: rc 0" "$(rc)" '0'

# ---------------------------------------------------------------------------
# [D] SNI 分支的调用顺序
# ---------------------------------------------------------------------------
SC_SNI_EMPTY="$(sc_make 'sni' '[]')"
SNI_SC="$SC_SNI_EMPTY" run_sni
assert_eq "T12 SNI: domain 先于 cdn" "$(steps)" 'CD:domain|n>CD:cdn|n>WEB>'
assert_eq "T12 SNI: domain 行号 < cdn 行号" "$([[ "$(line_no "$SB/plog" 'CD:domain')" -lt "$(line_no "$SB/plog" 'CD:cdn')" ]] && echo yes || echo no)" 'yes'
assert_eq "T13 SNI: 两次 change_domain 的第二参都是 n" "$(count_lines '|n' "$SB/plog")" '2'
assert_eq "T14 SNI: 收尾调 handler_web" "$(count_lines 'WEB' "$SB/plog")" '1'
assert_not_contains "T17 SNI: 不停 nginx" "$(plog)" 'NGINX_STOP'
assert_eq "T17 SNI: rc 0" "$(rc)" '0'

SNI_SC="$(sc_make 'Sni' '[]')" run_sni
assert_eq "T7 大写 Sni 走 SNI 分支" "$(steps)" 'CD:domain|n>CD:cdn|n>WEB>'

SNI_WEB='normal' SNI_SC="$SC_SNI_EMPTY" run_sni
assert_eq "T15 web 入参透传" "$(count_lines 'WEB:normal' "$SB/plog")" '1'
SNI_WEB='custom' SNI_SC="$SC_SNI_EMPTY" run_sni
assert_eq "T15 web 入参透传(非 normal)" "$(count_lines 'WEB:custom' "$SB/plog")" '1'
SNI_WEB='' SNI_SC="$SC_SNI_EMPTY" run_sni
assert_eq "T16 web 入参缺省 -> 传空串" "$(count_lines 'WEB:' "$SB/plog")" '1'
assert_eq "T16 web 入参缺省: 不带 normal" "$(count_lines 'WEB:normal' "$SB/plog")" '0'

# ---------------------------------------------------------------------------
# [E] 自定义站点同步门控
# ---------------------------------------------------------------------------
SC_SNI_SITES="$(sc_make 'sni' '[{"domain":"s1.example.com"},{"domain":"s2.example.com"}]')"
SNI_WEB='' SNI_FAIL_SYNC=0 SNI_SC="$SC_SNI_SITES" run_sni
assert_eq "T18 有站点: 步骤序列 (sync/rebuild 在 web 之前)" "$(steps)" 'CD:domain|n>CD:cdn|n>SYNC>REBUILD>WEB>'
assert_contains "T18 有站点: 打印 syncing 提示" "$(outp)" 'custom_sites.syncing'
assert_eq "T18 有站点: sync 一次" "$(count_lines 'SYNC:' "$SB/plog")" '1'
assert_eq "T18 有站点: rebuild 一次" "$(count_lines 'REBUILD' "$SB/plog")" '1'
assert_eq "T18 有站点: rc 0" "$(rc)" '0'

SNI_WEB='' SNI_FAIL_SYNC=0 SNI_SC="$SC_SNI_EMPTY" run_sni
assert_not_contains "T19 空数组: 不 sync" "$(plog)" 'SYNC'
assert_not_contains "T19 空数组: 不 rebuild" "$(plog)" 'REBUILD'
assert_not_contains "T19 空数组: 无 syncing 提示" "$(outp)" 'custom_sites.syncing'

SNI_WEB='' SNI_FAIL_SYNC=0 SNI_SC="$(sc_make 'sni' '')" run_sni
assert_not_contains "T20 custom_sites 键缺失: 不 sync" "$(plog)" 'SYNC'
assert_not_contains "T20 custom_sites 键缺失: 不 rebuild" "$(plog)" 'REBUILD'
assert_eq "T20 custom_sites 键缺失: rc 0" "$(rc)" '0'

# 字符串型 custom_sites: 旧写法 length=字符数(非 0) -> 会拿垃圾去 sync
SNI_WEB='' SNI_FAIL_SYNC=0 SNI_SC="$(sc_make 'sni' '"oops"')" run_sni
assert_not_contains "T21 custom_sites 是字符串: 不 sync" "$(plog)" 'SYNC'
assert_not_contains "T21 custom_sites 是字符串: 不 rebuild" "$(plog)" 'REBUILD'
assert_eq "T21 custom_sites 是字符串: rc 0" "$(rc)" '0'

# .nginx 不是对象: jq 直接失败 -> 旧写法会退化成 bash 语法错误并带崩整个流程
SNI_WEB='' SNI_FAIL_SYNC=0 SNI_SC='{"xray":{"tag":"sni"},"nginx":"oops"}' run_sni
assert_not_contains "T22 .nginx 非对象: 不 sync" "$(plog)" 'SYNC'
assert_not_contains "T22 .nginx 非对象: 不 rebuild" "$(plog)" 'REBUILD'
assert_eq "T22 .nginx 非对象: rc 0 (不得被算术错误带崩)" "$(rc)" '0'
assert_not_contains "T22 .nginx 非对象: 无 bash 语法错误" "$(outp)" 'syntax error'

# sync 收到的必须是当前 SCRIPT_CONFIG
SNI_WEB='' SNI_FAIL_SYNC=0 SNI_SC="$SC_SNI_SITES" run_sni
assert_contains "T23 sync 收到当前 SCRIPT_CONFIG" "$(plog)" "SYNC:$SC_SNI_SITES"

# ---------------------------------------------------------------------------
# [F] 失败即中断
# ---------------------------------------------------------------------------
SNI_WEB='' SNI_FAIL_SYNC=1 SNI_SC="$SC_SNI_SITES" run_sni
assert_contains "T24 sync 失败: _error" "$(plog)" 'ERROR:failed to sync custom sites'
assert_not_contains "T24 sync 失败: 不 rebuild" "$(plog)" 'REBUILD'
assert_not_contains "T24 sync 失败: 不调 web" "$(plog)" 'WEB'
assert_eq "T24 sync 失败: 非零退出" "$(rc)" ''

# ---------------------------------------------------------------------------
# 负向校验 (NEG): 把源码改坏, 确认上面的断言真的会红
# ---------------------------------------------------------------------------
if [[ -z "${SKIP_NEG:-}" && -x /tmp/shellcheck ]]; then :; fi # 占位: NEG 不依赖 shellcheck
if [[ -z "${SKIP_NEG:-}" ]]; then
    gen_neg() { # $1=变异名
        python3 - "$1" <<'PY'
import sys, pathlib

TARGET = 'handler_sni_config'


def fn_body(text):
    # 抽出目标函数体 —— 用于确认变异真的落在它身上
    out, g = [], False
    for line in text.splitlines():
        if line.startswith('function %s() {' % TARGET):
            g = True
        if g:
            out.append(line)
        if g and line == '}':
            break
    return '\n'.join(out)


src = pathlib.Path('core/handler.sh').read_text()
mode = sys.argv[1]
s = src
if mode == 'no_nginx_stop':
    s = s.replace("""    mkcp | vision | xhttp | trojan | fallback)
        # 对于非 SNI 配置，停止 Nginx 服务
        handler_nginx_stop
        ;;""", """    mkcp | vision | xhttp | trojan | fallback)
        ;;""", 1)
elif mode == 'tag_no_lower':
    # 注: `case "${CONFIG_TAG,,}" in` 全仓有 15 处, 必须带上下文明确定位到本函数,
    #     否则改坏的是别的函数 —— 变体跑出来"全绿"会伪装成"断言恒绿"的假信号。
    s = s.replace("""    case "${CONFIG_TAG,,}" in
    mkcp | vision | xhttp | trojan | fallback)
        # 对于非 SNI 配置，停止 Nginx 服务
        handler_nginx_stop
        ;;""", """    case "${CONFIG_TAG}" in
    mkcp | vision | xhttp | trojan | fallback)
        # 对于非 SNI 配置，停止 Nginx 服务
        handler_nginx_stop
        ;;""", 1)
elif mode == 'cdn_before_domain':
    s = s.replace("""        handler_change_domain 'domain' 'n'
        handler_change_domain 'cdn' 'n'""", """        handler_change_domain 'cdn' 'n'
        handler_change_domain 'domain' 'n'""", 1)
elif mode == 'stop_cert_y':
    s = s.replace("""        handler_change_domain 'domain' 'n'
        handler_change_domain 'cdn' 'n'""", """        handler_change_domain 'domain' 'y'
        handler_change_domain 'cdn' 'y'""", 1)
elif mode == 'no_web':
    s = s.replace("""        # 对于 SNI 配置，调用 handler_web 配置 Web 服务
        handler_web "${web}\"""", """        :""", 1)
elif mode == 'no_sync':
    s = s.replace("""            sync_custom_sites_config "${SCRIPT_CONFIG}" || _error "failed to sync custom sites"
            rebuild_stream_config "${SCRIPT_CONFIG}\"""", """            rebuild_stream_config "${SCRIPT_CONFIG}\"""", 1)
elif mode == 'sync_after_web':
    s = s.replace("""            sync_custom_sites_config "${SCRIPT_CONFIG}" || _error "failed to sync custom sites"
            rebuild_stream_config "${SCRIPT_CONFIG}"
        fi
        # 对于 SNI 配置，调用 handler_web 配置 Web 服务
        handler_web "${web}\"""", """            rebuild_stream_config "${SCRIPT_CONFIG}"
        fi
        # 对于 SNI 配置，调用 handler_web 配置 Web 服务
        handler_web "${web}"
        sync_custom_sites_config "${SCRIPT_CONFIG}" || _error "failed to sync custom sites\"""", 1)
elif mode == 'no_count_guard':
    s = s.replace("""        local custom_sites_count
        custom_sites_count="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.custom_sites | if type == "array" then length else 0 end' || echo 0)"
        [[ "${custom_sites_count}" =~ ^[0-9]+$ ]] || custom_sites_count=0
        if ((custom_sites_count > 0)); then""", """        if (( $(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.custom_sites // [] | length') > 0 )); then""", 1)
elif mode == 'sync_fail_no_error':
    s = s.replace("""            sync_custom_sites_config "${SCRIPT_CONFIG}" || _error "failed to sync custom sites\"""", """            sync_custom_sites_config "${SCRIPT_CONFIG}" || true""", 1)
elif mode == 'web_no_arg':
    s = s.replace("""        handler_web "${web}\"""", """        handler_web""", 1)
else:
    raise SystemExit('unknown mode: ' + mode)
if s == src:
    raise SystemExit('改写未生效 (原文未命中): ' + mode)
if fn_body(s) == fn_body(src):
    raise SystemExit('改写未落在 %s 上 (锚点命中了别处): %s' % (TARGET, mode))
pathlib.Path('core/_neg_handler.sh').write_text(s)
PY
        sed 's#core/handler.sh#core/_neg_handler.sh#g' test/handler_sni_config_arm_test.sh >test/neg_tmp_snicfg_arm_test.sh
    }

    neg_run() { # $1=说明 $2=期望 all-pass|has-fail
        local out
        out="$(cd "$REPO" && SKIP_NEG=1 bash "test/neg_tmp_snicfg_arm_test.sh" 2>&1 || true)"
        local n
        n="$(printf '%s\n' "$out" | grep -c '\[FAIL\]' || true)"
        if [[ "$2" == 'all-pass' ]]; then
            [[ "$n" == '0' ]] && ok || bad "NEG $1 基线应全绿, 实际 $n 条 FAIL"
        else
            [[ "$n" != '0' ]] && ok || bad "NEG $1 应检出失败, 实际 0 条 (断言恒绿!)"
        fi
    }

    for spec in \
        'no_nginx_stop|非 SNI 分支不停 nginx' \
        'tag_no_lower|tag 不做小写归一' \
        'cdn_before_domain|cdn 抢在 domain 之前' \
        'stop_cert_y|装配期去拆证书续期' \
        'no_web|SNI 收尾不拉 web' \
        'no_sync|漏同步自定义站点' \
        'sync_after_web|站点同步放到 web 之后' \
        'no_count_guard|去掉计数兜底' \
        'sync_fail_no_error|sync 失败不中断' \
        'web_no_arg|web 入参不透传'; do
        m="${spec%%|*}"
        d="${spec#*|}"
        if gen_neg "$m" 2>/dev/null; then neg_run "$d" 'has-fail'; else bad "NEG 改写未生效: $m"; fi
    done

    rm -f core/_neg_handler.sh test/neg_tmp_snicfg_arm_test.sh
fi

rm -rf "$SB"

echo "---"
echo "==== handler_sni_config_arm_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" == '0' ]]
