#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_misc_arms_test.sh
# 测试目标: handler.sh 里四条**长期零覆盖**的分派臂的行为回归。
#
# 为什么需要本测试: 全仓审计发现 handler.sh 的分派臂中约 2/3 在测试里从未出现
#   (2026-09-24 审计时的比例; 此后陆续补测, 比例在下降, 故不再写死臂数绝对数)。
#   其中这四条风险与可测性都靠前, 却一条断言都没有 ——
#     handler_remove_certificate   移除证书 -> 站点 HTTPS 立即失效 (有二次确认, 取消路径必须一次不写)
#     handler_reset_script_config  重置脚本配置 -> 字段保留清单写错即丢数据 (version/warp/rules 等)
#     handler_geodata_cron         增删 crontab 条目 -> 写错会污染用户既有 crontab
#     handler_check_sni_ports      端口预检自愈 -> 让位/回滚逻辑写错会把 xray 停那儿起不来
#   静态检查 (bash -n / shellcheck) 抓不到"取消却已经动手""非法入参却照常重置""复检失败没回滚"
#   这类语义错误。
#
# 锁定不变量:
#   T1 reset_script_config —— 默认/nginx/大小写/非法入参 四类, 校验保留字段清单与 persist 次数;
#                             **非法入参不得调用 reset_json_fields** (否则等于按未知目标乱重置)
#   T2 remove_certificate  —— 取消 (n/N/空/EOF) 一次都不碰 ssl; y/YES 才调 --stop-renew;
#                             ssl 失败 -> rc=1 且不打印 success; 成功 -> 打印 success
#   T3 geodata_cron        —— 未装 Xray 只提示不碰 crontab; quick/常规 × 已有/无条目 四态
#   T4 check_sni_ports     —— 预检通过即返回; 非自家占用 -> _error; 自家占用+复检通过 -> 只 stop 不 start;
#                             自家占用+复检仍失败 -> **回滚 start** 后再 _error
#
# 实现: 从 core/handler.sh 抽**真实函数体** (不另写实现, 避免漂移); 桩件走 heredoc 注入,
#   被管道调用的桩 (crontab) 用**文件**留痕而非变量 (右侧是子 shell, 变量改不回父进程)。
#   子脚本刻意不带 set -e: 本用例验的是**控制流选哪条分支**, 不是 set -e 的交互。
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$REPO"
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1 (期望 [$3] 实际 [$2])"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1 (未包含 [$3]，实际 [$2])"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1 (不应包含 [$3]，实际 [$2])"; fi; }
assert_absent() { if [[ ! -e "$2" ]]; then ok; else bad "$1 (文件竟然存在: $2)"; fi; }

SB="$REPO/.workbuddy/tmp/handler_misc.$$"
rm -rf "$SB" 2>/dev/null || true
mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT
# 导出: 部分桩件用**引号型 heredoc** 生成 (内部 ${SB} 留到运行时求值), 子脚本经环境变量拿到它。
export SB

CALL_LOG="${SB}/call.log"
export CALL_LOG

extract_fn() { # $1=fn
    awk -v fn="$1" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' core/handler.sh
}

reset_fn="$(extract_fn handler_reset_script_config)"
cert_fn="$(extract_fn handler_remove_certificate)"
geo_fn="$(extract_fn handler_geodata_cron)"
sni_fn="$(extract_fn handler_check_sni_ports)"
for v in reset_fn cert_fn geo_fn sni_fn; do
    if [[ -z "${!v}" ]]; then bad "抽取 $v 失败"; fi
done
if [[ "$FAIL" -gt 0 ]]; then echo "==== handler_misc_arms_test: PASS=$PASS FAIL=$FAIL ===="; exit 1; fi

# ---------------------------------------------------------------------------
echo "== 静态契约 =="
assert_contains "S1 reset 保留 xray 的 version/warp/rules" "$reset_fn" "'version' 'warp' 'rules'"
assert_contains "S2 reset 保留 nginx 的 ca/ca_server" "$reset_fn" "'ca' 'ca_server'"
assert_contains "S3 reset 用 ,, 折叠大小写" "$reset_fn" '${TARGET_CONFIG,,}'
assert_contains "S4 cert 有二次确认" "$cert_fn" 'confirm,,'
assert_contains "S5 cert 用 exec_read 取域名" "$cert_fn" "exec_read 'remove-cert'"
assert_contains "S6 cert 调 --stop-renew" "$cert_fn" "'--stop-renew'"
assert_contains "S7 geodata 未安装要提示 (不静默)" "$geo_fn" 'geodata.not_installed'
assert_contains "S8 geodata 写 cron 前 chmod a+x" "$geo_fn" 'chmod a+x'
assert_contains "S9 sni 端口先跑预检" "$sni_fn" "exec_check '--sni-ports'"
assert_contains "S10 sni 自愈前判定端口归属" "$sni_fn" "port_held_by_xray '443'"

# ---------------------------------------------------------------------------
echo "== T1: handler_reset_script_config =="
# ---------------------------------------------------------------------------
cat > "${SB}/stubs_reset.sh" <<'STUBS'
CUR_FILE='handler'
_i18n() { printf '%s' "${1:-}"; }
_error() { printf 'ERROR:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; printf 'ERROR:%s\n' "$*" >&2; exit 1; }
reset_json_fields() {
    printf 'RESET:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"
    printf '%s' "${1:-{}}
"
}
persist_script_config() { printf 'PERSIST\n' >> "${CALL_LOG:-/dev/null}"; return 0; }
SCRIPT_CONFIG='{}'
STUBS

run_reset() { # $1=目标 (空串=不传参)
    local target="$1"
    : > "$CALL_LOG"
    {
        cat "${SB}/stubs_reset.sh"
        printf '%s\n' "$reset_fn"
        if [[ -z "$target" ]]; then
            printf 'handler_reset_script_config\n'
        else
            printf 'handler_reset_script_config %q\n' "$target"
        fi
    } > "${SB}/reset.sh"
    RC=0
    "$BASH_BIN" "${SB}/reset.sh" > "${SB}/o" 2> "${SB}/e" || RC=$?
    RES_LINES="$(grep -c '^RESET:' "$CALL_LOG" 2>/dev/null || true)"
    PERSIST_LINES="$(grep -c '^PERSIST' "$CALL_LOG" 2>/dev/null || true)"
    RES_ARGS="$(grep '^RESET:' "$CALL_LOG" 2>/dev/null | head -1 || true)"
}

run_reset ''
assert_eq "T1a 默认目标 rc=0" "$RC" "0"
assert_eq "T1a 默认按 xray 重置一次" "$RES_LINES" "1"
assert_contains "T1a 默认保留 version/warp/rules" "$RES_ARGS" 'xray version warp rules'
assert_eq "T1a persist 一次" "$PERSIST_LINES" "1"
run_reset 'nginx'
assert_contains "T1b nginx 保留 ca/ca_server" "$RES_ARGS" 'nginx version ca ca_server'

run_reset 'XRAY'
assert_contains "T1c 大写 XRAY 归一到 xray" "$RES_ARGS" 'xray version warp rules'

run_reset 'Nginx'
assert_contains "T1d 混合大小写 Nginx 归一" "$RES_ARGS" 'nginx version ca ca_server'

run_reset 'bogus'
assert_eq "T1e 非法目标不调 reset_json_fields" "$RES_LINES" "0"
assert_eq "T1e 非法目标仍 persist (与旧行为一致)" "$PERSIST_LINES" "1"
assert_eq "T1e 非法目标 rc=0" "$RC" "0"
# ---------------------------------------------------------------------------
echo "== T2: handler_remove_certificate =="
# ---------------------------------------------------------------------------
cat > "${SB}/stubs_cert.sh" <<'STUBS'
GREEN=''; YELLOW=''; RED=''; NC=''
CUR_FILE='handler'
_i18n() { printf '%s' "${1:-}"; }
_i18n_sub() { printf 'SUB[%s]' "${1:-}"; }
exec_read() { printf 'READ:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; }
declare -A CONFIG_DATA=([remove-cert]='example.com')
exec_ssl() {
    printf 'SSL:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"
    return "${STUB_SSL_RC:-0}"
}
STUBS

run_cert() { # $1=stdin 内容 (回给 read)
    local answer="$1"
    : > "$CALL_LOG"
    {
        cat "${SB}/stubs_cert.sh"
        printf '%s\n' "$cert_fn"
        printf 'handler_remove_certificate\n'
    } > "${SB}/cert.sh"
    RC=0
    printf '%s' "$answer" | "$BASH_BIN" "${SB}/cert.sh" > "${SB}/o" 2> "${SB}/e" || RC=$?
    CERT_ERR="$(cat "${SB}/e")"
    SSL_LINES="$(grep -c '^SSL:' "$CALL_LOG" 2>/dev/null || true)"
    SSL_ARGS="$(grep '^SSL:' "$CALL_LOG" 2>/dev/null | head -1 || true)"
    READ_LINES="$(grep -c '^READ:' "$CALL_LOG" 2>/dev/null || true)"
}

STUB_SSL_RC=0 run_cert 'n
'
assert_eq "T2a 回 n: 不调 exec_ssl" "$SSL_LINES" "0"
assert_eq "T2a 回 n: rc=0 (取消非错误)" "$RC" "0"
assert_contains "T2a 回 n: 打印 cancelled" "$CERT_ERR" 'cancelled'
assert_eq "T2a 仍先读了域名" "$READ_LINES" "1"
run_cert 'N
'
assert_eq "T2b 回 N: 不调 exec_ssl (大小写不敏感)" "$SSL_LINES" "0"
assert_eq "T2b 回 N: rc=0" "$RC" "0"
run_cert ''
assert_eq "T2c 直接 EOF: 不调 exec_ssl" "$SSL_LINES" "0"
assert_eq "T2c 直接 EOF: rc=0 (EOF 不得当确认)" "$RC" "0"
run_cert 'y
'
assert_eq "T2d 回 y: 调 exec_ssl 一次" "$SSL_LINES" "1"
assert_contains "T2d 回 y: --stop-renew" "$SSL_ARGS" '--stop-renew'
assert_contains "T2d 回 y: 带 --domain=" "$SSL_ARGS" '--domain=example.com'
assert_contains "T2d 回 y: 打印 success" "$CERT_ERR" 'success'
assert_eq "T2d 回 y: rc=0" "$RC" "0"
run_cert 'YES
'
assert_eq "T2e 回 YES: 大写 yes 同样生效" "$SSL_LINES" "1"
STUB_SSL_RC=1 run_cert 'y
'
assert_eq "T2f ssl 失败: rc=1" "$RC" "1"
assert_not_contains "T2f ssl 失败: 不打印 success" "$CERT_ERR" 'success'
assert_contains "T2f ssl 失败: 打印 fail" "$CERT_ERR" 'fail'

# ---------------------------------------------------------------------------
echo "== T3: handler_geodata_cron =="
# ---------------------------------------------------------------------------
cat > "${SB}/geodata.sh" <<EOF
#!/usr/bin/env bash
printf 'GEODATA_RAN\\n' >> '${SB}/geo.log'
EOF
chmod +x "${SB}/geodata.sh"

cat > "${SB}/stubs_geo.sh" <<STUBS
GREEN=''; YELLOW=''; NC=''
CUR_FILE='handler'
_i18n() { printf '%s' "\${1:-}"; }
GEODATA_PATH='${SB}/geodata.sh'
crontab() {
    if [[ "\${1:-}" == '-l' ]]; then
        if [[ -f '${SB}/cron.tab' ]]; then cat '${SB}/cron.tab'; else return 1; fi
    else
        # 原子替换: 截断式写入会让并发读取的 crontab -l 丢掉既有条目, 故先写临时文件再 mv。
        cat > '${SB}/cron.tab.new' && mv '${SB}/cron.tab.new' '${SB}/cron.tab'
    fi
}
STUBS

run_geodata() { # $1=IS_QUICK $2=SCRIPT_CONFIG $3=预置 cron 内容 (空=无)
    local quick="$1" cfg="$2" preset="$3"
    : > "$CALL_LOG"
    rm -f "${SB}/geo.log"
    if [[ -n "$preset" ]]; then printf '%s\n' "$preset" > "${SB}/cron.tab"; else rm -f "${SB}/cron.tab"; fi
    {
        cat "${SB}/stubs_geo.sh"
        printf 'SCRIPT_CONFIG=%q\n' "$cfg"
        printf '%s\n' "$geo_fn"
        printf 'handler_geodata_cron %s\n' "$quick"
    } > "${SB}/geo_run.sh"
    RC=0
    "$BASH_BIN" "${SB}/geo_run.sh" > "${SB}/o" 2> "${SB}/e" || RC=$?
    GEO_ERR="$(cat "${SB}/e")"
    GEO_CRON="$(cat "${SB}/cron.tab" 2>/dev/null || true)"
    GEO_CRON_EXISTS=0
    if [[ -f "${SB}/cron.tab" ]]; then GEO_CRON_EXISTS=1; fi
    GEO_RAN=0
    if [[ -f "${SB}/geo.log" ]]; then GEO_RAN=1; fi
}

GEODATA_PATH_ESC="${SB}/geodata.sh"

run_geodata 0 '{"xray":{"version":""}}' ''
assert_contains "T3a 未装 Xray: 提示 not_installed" "$GEO_ERR" 'geodata.not_installed'
assert_eq "T3a 未装 Xray: 不写 crontab" "$GEO_CRON_EXISTS" "0"
assert_eq "T3a 未装 Xray: 不跑 geodata" "$GEO_RAN" "0"
run_geodata 1 '{"xray":{"version":"26.3.27"}}' ''
assert_eq "T3b quick: 写入 crontab" "$GEO_CRON_EXISTS" "1"
assert_contains "T3b quick: 条目指向 geodata.sh" "$GEO_CRON" "$GEODATA_PATH_ESC"
assert_contains "T3b quick: 每天 6:30" "$GEO_CRON" '30 6 * * *'
assert_eq "T3b quick: 立即跑一次 geodata" "$GEO_RAN" "1"
run_geodata 0 '{"xray":{"version":"26.3.27"}}' ''
assert_eq "T3c 无条目+常规: 也安装" "$GEO_CRON_EXISTS" "1"
assert_contains "T3c 常规安装: 条目指向 geodata.sh" "$GEO_CRON" "$GEODATA_PATH_ESC"

run_geodata 0 '{"xray":{"version":"26.3.27"}}' "30 6 * * * ${SB}/geodata.sh >/dev/null 2>&1"
assert_eq "T3d 已有条目+常规: 认为已开, 走移除" "$GEO_CRON_EXISTS" "1"
assert_not_contains "T3d 已有条目+常规: geodata 条目被摘掉" "$GEO_CRON" "$GEODATA_PATH_ESC"
assert_contains "T3d 打印 close_cron" "$GEO_ERR" 'geodata.close_cron'

run_geodata 0 '{"xray":{"version":"26.3.27"}}' '0 3 * * * /usr/bin/other-job'
assert_eq "T3e 有他人条目: 仍写入自己的" "$GEO_CRON_EXISTS" "1"
assert_contains "T3e 有他人条目: 不误删他人" "$GEO_CRON" 'other-job'
assert_contains "T3e 有他人条目: 也加上自己的" "$GEO_CRON" "$GEODATA_PATH_ESC"

# ---------------------------------------------------------------------------
echo "== T4: handler_check_sni_ports =="
# ---------------------------------------------------------------------------
cat > "${SB}/stubs_sni.sh" <<'STUBS'
GREEN=''; YELLOW=''; NC=''
CUR_FILE='handler'
_i18n() { printf '%s' "${1:-}"; }
_error() { printf 'ERROR:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; printf 'ERROR:%s\n' "$*" >&2; exit 1; }
systemctl() { printf 'SYSTEMCTL:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; return 0; }
port_held_by_xray() { printf 'HELD:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; return "${STUB_HELD:-1}"; }
_ensure_xray_runtime_dirs() { printf 'ENSURE_DIRS\n' >> "${CALL_LOG:-/dev/null}"; return 0; }
exec_check() {
    local n
    n="$(( $(cat "${SB}/check.cnt" 2>/dev/null || echo 0) + 1 ))"
    printf '%s' "$n" > "${SB}/check.cnt"
    printf 'CHECK:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"
    local var="STUB_CHECK_${n}"
    return "${!var:-1}"
}
STUBS

run_sni() { # 依赖环境变量 STUB_CHECK_1 / STUB_CHECK_2 / STUB_HELD
    : > "$CALL_LOG"
    rm -f "${SB}/check.cnt"
    {
        cat "${SB}/stubs_sni.sh"
        printf '%s\n' "$sni_fn"
        printf 'handler_check_sni_ports\n'
    } > "${SB}/sni.sh"
    RC=0
    "$BASH_BIN" "${SB}/sni.sh" > "${SB}/o" 2> "${SB}/e" || RC=$?
    SNI_LOG="$(cat "$CALL_LOG")"
    SNI_ERR="$(cat "${SB}/e")"
    SNI_CHECKS="$(grep -c '^CHECK:' "$CALL_LOG" 2>/dev/null || true)"
    SNI_STOPS="$(grep -c '^SYSTEMCTL:-q stop' "$CALL_LOG" 2>/dev/null || true)"
    SNI_STARTS="$(grep -c '^SYSTEMCTL:-q start' "$CALL_LOG" 2>/dev/null || true)"
}

STUB_CHECK_1=0 STUB_HELD=0 run_sni
assert_eq "T4a 预检通过: rc=0" "$RC" "0"
assert_eq "T4a 预检通过: 只跑一次预检" "$SNI_CHECKS" "1"
assert_not_contains "T4a 预检通过: 不碰 systemctl" "$SNI_LOG" 'SYSTEMCTL'
assert_not_contains "T4a 预检通过: 不判端口归属" "$SNI_LOG" 'HELD'

STUB_CHECK_1=1 STUB_HELD=1 run_sni
assert_eq "T4b 预检失败+非自家: rc=1 (_error)" "$RC" "1"
assert_contains "T4b 非自家: 打印 ERROR" "$SNI_ERR" 'ERROR'
assert_contains "T4b 非自家: 报端口守卫失败" "$SNI_ERR" 'port_guard_fail'
assert_not_contains "T4b 非自家: 不停服务" "$SNI_LOG" 'SYSTEMCTL:-q stop'

# 注: port_held_by_xray 返回 **0 表示"自家占用"** (return 0 = 真), 返回 1 = 非自家。
STUB_CHECK_1=1 STUB_CHECK_2=0 STUB_HELD=0 run_sni
assert_eq "T4c 自家占用+复检通过: rc=0" "$RC" "0"
assert_eq "T4c 跑足两次预检" "$SNI_CHECKS" "2"
assert_eq "T4c 停了一次服务让位" "$SNI_STOPS" "1"
assert_eq "T4c 不再重启 (让 _restart 去拉起)" "$SNI_STARTS" "0"
assert_not_contains "T4c 不打印 ERROR" "$SNI_ERR" 'ERROR'

STUB_CHECK_1=1 STUB_CHECK_2=1 STUB_HELD=0 run_sni
assert_eq "T4d 复检仍失败: rc=1" "$RC" "1"
assert_eq "T4d 回了滚重启一次" "$SNI_STARTS" "1"
assert_contains "T4d 打印 ERROR (端口守卫失败)" "$SNI_ERR" 'ERROR'
assert_contains "T4d 回滚前补齐运行目录" "$SNI_LOG" 'ENSURE_DIRS'

# ---------------------------------------------------------------------------
echo "== T5: 负向校验 — 上述判据确实锚在真实代码行上 =="
# ---------------------------------------------------------------------------
# 每例都在**副本**上改坏 (绝不碰仓库工作区), 证明"改坏 -> 对应断言会红"。
HANDLER_SRC=core/handler.sh
SHA_BEFORE="$(sha256sum "$HANDLER_SRC" | cut -d' ' -f1)"

extract_fn_from() { # $1=file $2=fn
    awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' "$1"
}

neg_case() { # $1=名称 $2=sed 表达式; 命中并改动成功才继续
    cp "$HANDLER_SRC" "${SB}/neg.sh"
    sed -i "$2" "${SB}/neg.sh"
    if cmp -s "$HANDLER_SRC" "${SB}/neg.sh"; then
        bad "NEG $1: 改坏未生效 (sed 未命中), 本用例无意义"
        return 1
    fi
    ok
    return 0
}

# NEG-1 (护 T1c): 去掉大小写折叠 -> 大写 XRAY 不再归一
if neg_case 'reset 折叠' 's|case "${TARGET_CONFIG,,}" in|case "${TARGET_CONFIG}" in|'; then
    nfn="$(extract_fn_from "${SB}/neg.sh" handler_reset_script_config)"
    : > "$CALL_LOG"
    {
        cat "${SB}/stubs_reset.sh"
        printf '%s\n' "$nfn"
        printf 'handler_reset_script_config XRAY\n'
    } > "${SB}/neg_reset.sh"
    NEG_RC=0
    "$BASH_BIN" "${SB}/neg_reset.sh" >/dev/null 2>&1 || NEG_RC=$?
    n_lines="$(grep -c '^RESET:' "$CALL_LOG" 2>/dev/null || true)"
    assert_eq "NEG-1 去掉折叠后大写 XRAY 不再重置 (故 T1c 判据有效)" "$n_lines" "0"
fi

# NEG-2 (护 T1a): 保留字段裁成只剩 version -> 默认重置会丢 warp/rules
if neg_case 'reset 保留字段' "s|'version' 'warp' 'rules'|'version'|"; then
    nfn="$(extract_fn_from "${SB}/neg.sh" handler_reset_script_config)"
    : > "$CALL_LOG"
    {
        cat "${SB}/stubs_reset.sh"
        printf '%s\n' "$nfn"
        printf 'handler_reset_script_config\n'
    } > "${SB}/neg_reset2.sh"
    NEG_RC=0
    "$BASH_BIN" "${SB}/neg_reset2.sh" >/dev/null 2>&1 || NEG_RC=$?
    n_args="$(grep '^RESET:' "$CALL_LOG" 2>/dev/null | head -1 || true)"
    assert_not_contains "NEG-2 裁掉保留字段后 warp 丢失 (故 T1a 判据有效)" "$n_args" 'warp'
fi

# NEG-3 (护 T2d): 换掉子命令名 -> 确认后不再调用正确的停止续订
if neg_case 'cert 子命令' "s|'--stop-renew'|'--bogus-flag'|"; then
    nfn="$(extract_fn_from "${SB}/neg.sh" handler_remove_certificate)"
    : > "$CALL_LOG"
    {
        cat "${SB}/stubs_cert.sh"
        printf '%s\n' "$nfn"
        printf 'handler_remove_certificate\n'
    } > "${SB}/neg_cert.sh"
    NEG_RC=0
    printf 'y\n' | "$BASH_BIN" "${SB}/neg_cert.sh" >/dev/null 2>&1 || NEG_RC=$?
    n_ssl="$(grep '^SSL:' "$CALL_LOG" 2>/dev/null | head -1 || true)"
    assert_not_contains "NEG-3 换掉子命令后 --stop-renew 缺失 (故 T2d 判据有效)" "$n_ssl" '--stop-renew'
fi

# NEG-4 (护 T4d): 删掉回滚前的运行目录补齐
if neg_case 'sni 回滚补齐' 's|^        _ensure_xray_runtime_dirs$|        : removed-by-neg|'; then
    nfn="$(extract_fn_from "${SB}/neg.sh" handler_check_sni_ports)"
    : > "$CALL_LOG"
    rm -f "${SB}/check.cnt"
    {
        cat "${SB}/stubs_sni.sh"
        printf '%s\n' "$nfn"
        printf 'handler_check_sni_ports\n'
    } > "${SB}/neg_sni.sh"
    NEG_RC=0
    STUB_CHECK_1=1 STUB_CHECK_2=1 STUB_HELD=0 "$BASH_BIN" "${SB}/neg_sni.sh" >/dev/null 2>&1 || NEG_RC=$?
    # 剧本删掉了"非自家占用先补齐"的分支, 应当走到 _error 并以非 0 退出。若它静默跑完,
    # 下面那条"ENSURE_DIRS 不再出现"的断言会因"根本没跑到那段"而假绿 —— 故这里必须验一次。
    if [[ "${NEG_RC}" -ne 0 ]]; then ok; else bad "NEG-4 剧本应因 _error 以非 0 退出"; fi
    n_log="$(cat "$CALL_LOG" 2>/dev/null || true)"
    assert_not_contains "NEG-4 删掉补齐后 ENSURE_DIRS 不再出现 (故 T4d 判据有效)" "$n_log" 'ENSURE_DIRS'
fi

# 复核: 本段只在副本上动手, 仓库工作区必须与开工时逐字节一致
assert_eq "T5 结束时 core/handler.sh 未被改动" "$(sha256sum "$HANDLER_SRC" | cut -d' ' -f1)" "$SHA_BEFORE"

echo "---"
echo "==== handler_misc_arms_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
