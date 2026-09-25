#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_purge_nofile_test.sh
# 测试目标: handler.sh 里**两条最不可逆的路径**的行为回归。
#
# 为什么需要本测试: 全仓审计发现 handler.sh 的分派臂中相当一部分在测试里从未出现
#   (2026-09-24 审计时约占 2/3; 此后臂数与覆盖数都在变, 故此处不再写死数字 ——
#    要查当前值用: awk 抽 handler.sh 的 main() 后 grep -c 看臂数)。
# 其中风险最高的两个恰恰零覆盖 ——
#   handler_purge        卸载 Xray (不可逆), 且会清本项目写进 cron / Nginx 的痕迹
#   handler_nofile_limit 改 /etc/security/limits.d + /etc/systemd/*.conf.d 三个文件,
#                        并 daemon-reexec、重启服务
# 静态检查 (bash -n / shellcheck) 只能保证语法与风格, 抓不到"先动配置再下载""取消却
# 已经写盘""上游卸载失败把整个流程拖垮"这类语义错误。
#
# 锁定不变量:
#   T2 取消 (回 N)        -> 三个文件一个都不落盘, 且不留审计条目 (没写盘比写对了更值钱)
#   T3 确认 (回 y)        -> 三个文件内容与预期逐字节一致
#   T4 目标 > fs.nr_open  -> 按 nr_open 钳制后落盘 (否则 pam_limits 静默忽略)
#   T5 写盘失败           -> 立即 _error 中止, **不继续**写后面两个 systemd 文件
#   T6 有服务 + 重启回 N  -> 文件已落盘但不重启 (重启是单独一次确认)
#   P1 卸载脚本下载失败   -> 先中止, cron/nginx 配置/persist 一个都不许动
#   P2 正常卸载顺序       -> cron -> nginx 回滚 -> 上游卸载 -> 重置配置 -> 落盘
#   P3 上游卸载脚本非 0   -> 只告警, 不阻断后续配置重置
#   T7/P4 (NEG) 把守卫改坏, 上述判据必须变红
#
# 实现: 从 core/handler.sh 抽**真实函数体** (不另写实现, 避免漂移), 用 sed 把 /etc
#   落点改写到沙箱, 桩件走 heredoc 生成后 source。管道里跑的桩件用**文件**计数/留痕,
#   不用变量 (右侧是子 shell, 变量改不回父进程)。
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$REPO"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1 (期望 [$3] 实际 [$2])"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1 (未包含 [$3])"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1 (不应包含 [$3])"; fi; }
assert_absent() { if [[ ! -e "$2" ]]; then ok; else bad "$1 (文件竟然存在: $2)"; fi; }
assert_present() { if [[ -e "$2" ]]; then ok; else bad "$1 (文件不存在: $2)"; fi; }

SB="$(pwd)/.workbuddy/tmp/purge_nofile_$$"
rm -rf "$SB"
mkdir -p "$SB"
# 落点沙箱根: 目录名刻意避开 "/etc/" 字样 —— 若叫 ".../etc", 改写后的路径仍含子串
# "/etc/security/limits.d", 下面"改写是否生效"的复核会永远命中, 变成一条恒真的假护栏。
ETC="${SB}/rootfs-etc"

# ---------------------------------------------------------------------------
# 抽取真实函数体
# ---------------------------------------------------------------------------
nofile_fn="$(awk '/^function handler_nofile_limit\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' core/handler.sh)"
purge_fn="$(awk '/^function handler_purge\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' core/handler.sh)"
atom_fn="$(awk '/^function _atomic_write\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' core/_common.sh)"
norm_fn="$(awk '/^function _net_norm\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' core/handler.sh)"

for v in nofile_fn purge_fn atom_fn norm_fn; do
    if [[ -z "${!v}" ]]; then bad "抽取 $v 失败"; fi
done
if [[ ${FAIL} -gt 0 ]]; then echo "==== handler_purge_nofile_test: PASS=$PASS FAIL=$FAIL ===="; exit 1; fi

# ---------------------------------------------------------------------------
# 静态契约
# ---------------------------------------------------------------------------
echo "== 静态契约 =="
assert_contains "S1 handler_purge 先下载校验再动配置" "${purge_fn}" '_download_verified'
assert_contains "S2 handler_purge 下载失败即 _error (不继续)" "${purge_fn}" '_error'
assert_contains "S3 handler_purge 重置 xray 字段" "${purge_fn}" "reset_json_fields"
assert_contains "S4 handler_purge 有审计留痕" "${purge_fn}" '_audit_log'
assert_contains "S5 nofile 三个落点都在" "${nofile_fn}" '/etc/security/limits.d'
assert_contains "S6 nofile 落点含 systemd system.conf.d" "${nofile_fn}" '/etc/systemd/system.conf.d'
assert_contains "S7 nofile 落点含 systemd user.conf.d" "${nofile_fn}" '/etc/systemd/user.conf.d'
assert_contains "S8 nofile 有 fs.nr_open 钳制" "${nofile_fn}" 'fs.nr_open'
assert_contains "S9 nofile 取消分支提示并返回" "${nofile_fn}" 'nofile.cancelled'

# ---------------------------------------------------------------------------
# 桩件
# ---------------------------------------------------------------------------
cat > "${SB}/stubs_nofile.sh" <<'STUBS'
GREEN=''; YELLOW=''; RED=''; NC=''
CUR_FILE='handler'
_i18n() { printf '%s' "${1:-}"; }
_audit_log() { printf 'AUDIT:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; }
_warn() { printf 'WARN:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; }
_info() { printf 'INFO:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; }
_pass() { printf 'PASS:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; }
# 真实 _error 是 exit; 桩必须同样 exit —— 否则"写盘失败后不再继续"这条不变量测不出来
_error() { printf 'ERROR:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; exit 1; }
# sysctl 视为存在 (读 nr_open 用); systemctl 视为不存在 -> 跳过 daemon-reexec
cmd_exists() {
    case "${1:-}" in
        sysctl) return 0 ;;
        systemctl) return "${STUB_HAS_SYSTEMCTL:-1}" ;;
        *) command -v -- "${1:-}" >/dev/null 2>&1 ;;
    esac
}
sysctl() { printf '%s\n' "${STUB_NR_OPEN:-1000000}"; }
_unit_exists() { return "${STUB_UNIT_RC:-1}"; }
_nofile_probe() { printf '%s' "${STUB_NOFILE_VAL:-}"; return 0; }
handler_restart() { printf 'RESTART:xray\n' >> "${CALL_LOG:-/dev/null}"; return 0; }
handler_nginx_restart() { printf 'RESTART:nginx\n' >> "${CALL_LOG:-/dev/null}"; return 0; }
# _atomic_write 由真实实现改名而来 (见 funcs 生成处), 这里只加"可控失败"外壳
_atomic_write() {
    if [[ "${STUB_AW_FAIL:-0}" == '1' && "${1:-}" == *limits.d* ]]; then
        cat >/dev/null
        return 1
    fi
    _atomic_write_real "$@"
}
STUBS

cat > "${SB}/stubs_purge.sh" <<'STUBS'
YELLOW=''; RED=''; NC=''; GREEN=''
CUR_FILE='handler'
_i18n() { printf '%s' "${1:-}"; }
_audit_log() { printf 'AUDIT:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; }
_info() { printf 'INFO:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; }
_error() { printf 'ERROR:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; exit 1; }
# 下载校验桩: STUB_DL_FAIL=1 时失败; 否则产出沙箱里的假卸载脚本 (rc 由 STUB_PURGE_RC 控制)
_download_verified() {
    printf 'DOWNLOAD:%s\n' "${1:-}" >> "${CALL_LOG:-/dev/null}"
    if [[ "${STUB_DL_FAIL:-0}" == '1' ]]; then return 1; fi
    local p="${FAKE_PURGE_SCRIPT:?}"
    printf '#!/usr/bin/env bash\nprintf "UPSTREAM:%%s\\n" "$*" >> "%s"\nexit %s\n' \
        "${CALL_LOG:-/dev/null}" "${STUB_PURGE_RC:-0}" > "$p"
    printf '%s' "$p"
}
_purge_crontab_entries() { printf 'CRON:purged\n' >> "${CALL_LOG:-/dev/null}"; return 0; }
reset_json_fields() {
    # 只记"被重置的字段名"($2), 不记整份 JSON —— 便于断言"重置的是 xray, 没动别的"
    printf 'RESET:%s\n' "${2:-}" >> "${CALL_LOG:-/dev/null}"
    printf '%s' '{"version":"vTEST"}'
}
persist_script_config() {
    printf 'PERSIST\n' >> "${CALL_LOG:-/dev/null}"
    printf '%s\n' "${SCRIPT_CONFIG:-}" > "${FAKE_SCRIPT_CONFIG_FILE:?}"
}
STUBS

# nofile 侧 funcs: 真 _atomic_write (改名) + 真 _net_norm + 真 handler_nofile_limit, /etc 改写进沙箱
{
    printf '%s\n' "${atom_fn}" | sed 's/^function _atomic_write() {/function _atomic_write_real() {/'
    printf '%s\n' "${norm_fn}"
    printf '%s\n' "${nofile_fn}"
} > "${SB}/funcs_nofile.sh"
sed -i "s|/etc/security/limits.d|${ETC}/security/limits.d|g" "${SB}/funcs_nofile.sh"
sed -i "s|/etc/systemd/system.conf.d|${ETC}/systemd/system.conf.d|g" "${SB}/funcs_nofile.sh"
sed -i "s|/etc/systemd/user.conf.d|${ETC}/systemd/user.conf.d|g" "${SB}/funcs_nofile.sh"
# 改写复核: 锚点没命中 -> 就地失败, 避免"改了但没生效"导致测试真写 /etc
if grep -q '/etc/security/limits.d' "${SB}/funcs_nofile.sh" || grep -q '/etc/systemd/system.conf.d' "${SB}/funcs_nofile.sh"; then
    bad "沙箱化改写未生效 (funcs 里仍有 /etc 绝对路径)"
    echo "==== handler_purge_nofile_test: PASS=$PASS FAIL=$FAIL ===="
    exit 1
fi

{
    printf '%s\n' "${purge_fn}"
} > "${SB}/funcs_purge.sh"

# ---------------------------------------------------------------------------
# 驱动脚本
# ---------------------------------------------------------------------------
cat > "${SB}/run_nofile.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source "${SB}/stubs_nofile.sh"
source "${SB}/funcs_nofile.sh"
handler_nofile_limit
EOF

cat > "${SB}/run_purge.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source "${SB}/stubs_purge.sh"
source "${SB}/funcs_purge.sh"
# handler_purge 会读取下列全局量 (set -u 下缺失即崩), 故显式补上:
#   NGINX_PATH            指向沙箱内的不存在的脚本 -> \`bash <missing>\` 返回非 0,
#                         正好驱动"回滚失败仅告警"这条分支
#   XRAY_INSTALL_URL/SHA  只在 _download_verified (桩) 的入参里被引用
SCRIPT_CONFIG='{"version":"vTEST","xray":{"tag":"Vision"}}'
NGINX_PATH="${SB}/nonexistent-nginx.sh"
XRAY_INSTALL_URL='https://example.invalid/install-release.sh'
XRAY_INSTALL_SHA256='deadbeef'
export SCRIPT_CONFIG NGINX_PATH XRAY_INSTALL_URL XRAY_INSTALL_SHA256
handler_purge
EOF

NOFILE_LOG="${SB}/call_nofile.log"
LIMITS_FILE="${ETC}/security/limits.d/99-xray-script-personal-use-only-nofile.conf"
SYSD_SYS_FILE="${ETC}/systemd/system.conf.d/99-xray-script-personal-use-only-nofile.conf"
SYSD_USR_FILE="${ETC}/systemd/user.conf.d/99-xray-script-personal-use-only-nofile.conf"
BANNER='# Managed by xray-script-personal-use-only (nofile limit). Safe to delete this file.'

reset_nofile() { rm -rf "${ETC}"; : > "${NOFILE_LOG}"; }

run_nofile() { # $1=stdin 文本; 其余 "$@" = env 变量
    local inp="$1"
    shift
    printf '%s' "${inp}" | env CALL_LOG="${NOFILE_LOG}" "$@" bash "${SB}/run_nofile.sh" \
        > "${SB}/out.txt" 2>&1
}

# ---------------------------------------------------------------------------
# T2 取消 -> 零写盘
# ---------------------------------------------------------------------------
echo "== T2 取消 (回 N) =="
reset_nofile
run_nofile 'n
' || true
assert_absent "T2a 取消时 limits.d 未落盘" "${LIMITS_FILE}"
assert_absent "T2b 取消时 systemd system.conf.d 未落盘" "${SYSD_SYS_FILE}"
assert_absent "T2c 取消时 systemd user.conf.d 未落盘" "${SYSD_USR_FILE}"
assert_not_contains "T2d 取消时未留审计条目" "$(cat "${NOFILE_LOG}")" 'AUDIT:'
assert_contains "T2e 取消时提示 cancelled" "$(cat "${NOFILE_LOG}")" 'nofile.cancelled'

# ---------------------------------------------------------------------------
# T3 确认且无服务 -> 三文件内容逐字节一致
# ---------------------------------------------------------------------------
echo "== T3 确认 (回 y, 无服务) =="
reset_nofile
run_nofile 'y
' || true
expect_limits="${BANNER}
root soft nofile 1000000
root hard nofile 1000000
* soft nofile 1000000
* hard nofile 1000000"
assert_eq "T3a limits.d 内容一致" "$(cat "${LIMITS_FILE}" 2>/dev/null || echo MISSING)" "${expect_limits}"
expect_sysd="${BANNER}
[Manager]
DefaultLimitNOFILE=1000000"
assert_eq "T3b system.conf.d 内容一致" "$(cat "${SYSD_SYS_FILE}" 2>/dev/null || echo MISSING)" "${expect_sysd}"
assert_eq "T3c user.conf.d 内容一致" "$(cat "${SYSD_USR_FILE}" 2>/dev/null || echo MISSING)" "${expect_sysd}"
assert_contains "T3d 留审计条目" "$(cat "${NOFILE_LOG}")" 'AUDIT:nofile-limit'
assert_contains "T3e 收尾提示 done" "$(cat "${NOFILE_LOG}")" 'nofile.done'

# ---------------------------------------------------------------------------
# T4 钳制: 目标值不得超过 fs.nr_open
# ---------------------------------------------------------------------------
echo "== T4 按 fs.nr_open 钳制 =="
reset_nofile
run_nofile 'y
' STUB_NR_OPEN=524288 || true
assert_contains "T4a 落盘值被钳制为 nr_open" "$(cat "${LIMITS_FILE}" 2>/dev/null)" 'root soft nofile 524288'
assert_contains "T4b 未落盘未经钳制的原值" "$(cat "${LIMITS_FILE}" 2>/dev/null | grep -c 1000000 || true)" '0'
assert_contains "T4c 有钳制告警" "$(cat "${NOFILE_LOG}")" 'nofile.clamped'

# ---------------------------------------------------------------------------
# T5 写盘失败 -> 立即中止, 不继续写后面两个文件
# ---------------------------------------------------------------------------
echo "== T5 写盘失败即中止 =="
reset_nofile
rc=0
run_nofile 'y
' STUB_AW_FAIL=1 || rc=$?
assert_eq "T5a 写盘失败时脚本以非 0 结束" "${rc}" "1"
assert_contains "T5b 报出 write_failed" "$(cat "${NOFILE_LOG}")" 'nofile.write_failed'
assert_absent "T5c 中止后 systemd system.conf.d 未被写" "${SYSD_SYS_FILE}"
assert_absent "T5d 中止后 systemd user.conf.d 未被写" "${SYSD_USR_FILE}"

# ---------------------------------------------------------------------------
# T6 有服务 + 重启回 N -> 文件写好但不重启
# ---------------------------------------------------------------------------
echo "== T6 有服务但重启回 N =="
reset_nofile
run_nofile 'y
n
' STUB_UNIT_RC=0 || true
assert_present "T6a 文件仍已落盘" "${LIMITS_FILE}"
assert_not_contains "T6b 未重启任何服务" "$(cat "${NOFILE_LOG}")" 'RESTART:'
assert_contains "T6c 提示 restart_skipped" "$(cat "${NOFILE_LOG}")" 'nofile.restart_skipped'

# ---------------------------------------------------------------------------
# T7 NEG: 把取消分支的 return 0 抹掉, T2 的"零写盘"必须变红
# ---------------------------------------------------------------------------
echo "== T7 NEG: 取消守卫失效必须变红 =="
neg_funcs="${SB}/funcs_nofile_neg.sh"
cp "${SB}/funcs_nofile.sh" "${neg_funcs}"
# 命中 cancelled 提示行后, 把紧随其后的 `return 0` 换成 `:` (等价于取消分支继续往下执行)
sed -i '/nofile\.cancelled/{n;s|return 0|:|;}' "${neg_funcs}"
if grep -qE '^[[:space:]]*return 0[[:space:]]*$' <(sed -n '/nofile\.cancelled/,+2p' "${neg_funcs}"); then
    bad "T7 副本改坏未生效 (cancelled 分支仍 return 0)"
else
    ok
    cat > "${SB}/run_nofile_neg.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source "${SB}/stubs_nofile.sh"
source "${neg_funcs}"
handler_nofile_limit
EOF
    reset_nofile
    printf 'n\n' | env CALL_LOG="${NOFILE_LOG}" bash "${SB}/run_nofile_neg.sh" >/dev/null 2>&1 || true
    if [[ -e "${LIMITS_FILE}" ]]; then
        ok
    else
        bad "T7 守卫已失效, 但副本仍未写盘 —— NEG 未生效"
    fi
fi

# ---------------------------------------------------------------------------
# P1 卸载脚本下载失败 -> 不许动任何配置
# ---------------------------------------------------------------------------
echo "== P1 下载校验失败即中止 =="
PURGE_LOG="${SB}/call_purge.log"
FAKE_SC="${SB}/script_config.json"
printf '%s\n' '{"version":"vTEST","xray":{"tag":"Vision"}}' > "${FAKE_SC}"
run_purge() { # $1..$n = env 变量
    : > "${PURGE_LOG}"
    env CALL_LOG="${PURGE_LOG}" FAKE_PURGE_SCRIPT="${SB}/fake_purge.sh" \
        FAKE_SCRIPT_CONFIG_FILE="${FAKE_SC}" "$@" bash "${SB}/run_purge.sh" \
        > "${SB}/purge_out.txt" 2>&1
}

rc=0
run_purge STUB_DL_FAIL=1 || rc=$?
assert_eq "P1a 下载失败时非 0 结束" "${rc}" "1"
assert_contains "P1b 报出下载失败" "$(cat "${PURGE_LOG}")" 'install.fail_download'
assert_not_contains "P1c 未清 cron" "$(cat "${PURGE_LOG}")" 'CRON:purged'
assert_not_contains "P1d 未重置脚本配置" "$(cat "${PURGE_LOG}")" 'RESET:'
assert_not_contains "P1e 未落盘脚本配置" "$(cat "${PURGE_LOG}")" 'PERSIST'
assert_eq "P1f 脚本配置内容未被改动" "$(cat "${FAKE_SC}")" '{"version":"vTEST","xray":{"tag":"Vision"}}'

# ---------------------------------------------------------------------------
# P2 正常卸载 -> 顺序与重置范围
# ---------------------------------------------------------------------------
echo "== P2 正常卸载顺序 =="
rc=0
run_purge || rc=$?
log="$(cat "${PURGE_LOG}")"
assert_eq "P2a 正常卸载以 0 结束" "${rc}" "0"
assert_contains "P2b 下载了上游卸载脚本" "${log}" 'DOWNLOAD:'
assert_contains "P2c 清了 cron" "${log}" 'CRON:purged'
assert_contains "P2d 调用了上游卸载脚本" "${log}" 'UPSTREAM:remove --purge'
assert_contains "P2e 重置了 xray 字段" "${log}" 'RESET:xray'
assert_contains "P2f 落盘了脚本配置" "${log}" 'PERSIST'
# 顺序: cron < 上游卸载 < reset < persist
n_cron="$(printf '%s\n' "${log}" | grep -n 'CRON:purged' | cut -d: -f1)"
n_up="$(printf '%s\n' "${log}" | grep -n 'UPSTREAM:remove' | cut -d: -f1)"
n_reset="$(printf '%s\n' "${log}" | grep -n 'RESET:xray' | cut -d: -f1)"
n_persist="$(printf '%s\n' "${log}" | grep -n 'PERSIST' | cut -d: -f1)"
if [[ -n "${n_cron}" && -n "${n_up}" && -n "${n_reset}" && -n "${n_persist}" ]] &&
    ((n_cron < n_up && n_up < n_reset && n_reset < n_persist)); then
    ok
else
    bad "P2g 步骤顺序异常 (cron=${n_cron} upstream=${n_up} reset=${n_reset} persist=${n_persist})"
fi
assert_eq "P2h 落盘内容为重置后的配置" "$(cat "${FAKE_SC}")" '{"version":"vTEST"}'

# ---------------------------------------------------------------------------
# P3 上游卸载脚本非 0 -> 只告警, 不阻断配置重置
# ---------------------------------------------------------------------------
echo "== P3 上游卸载失败不阻断 =="
rc=0
run_purge STUB_PURGE_RC=1 || rc=$?
log="$(cat "${PURGE_LOG}")"
assert_eq "P3a 仍以 0 结束" "${rc}" "0"
assert_contains "P3b 重置照常执行" "${log}" 'RESET:xray'
assert_contains "P3c 落盘照常执行" "${log}" 'PERSIST'

# ---------------------------------------------------------------------------
# P4 NEG: 把"先下载校验"提前到配置清理之后的假想实现必须被抓出来
# ---------------------------------------------------------------------------
echo "== P4 NEG: 下载失败仍动配置必须变红 =="
neg_purge="${SB}/funcs_purge_neg.sh"
cp "${SB}/funcs_purge.sh" "${neg_purge}"
# 把下载失败时的 `_error` 换成只打日志 (等价于"下载失败却继续往下清配置")
sed -i 's|_error "$(_i18n ".${CUR_FILE}.install.fail_download")"|printf "IGNORED_DL_FAIL\\n"|' "${neg_purge}"
if grep -q 'IGNORED_DL_FAIL' "${neg_purge}"; then
    ok
    cat > "${SB}/run_purge_neg.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source "${SB}/stubs_purge.sh"
source "${neg_purge}"
SCRIPT_CONFIG='{"version":"vTEST","xray":{"tag":"Vision"}}'
export SCRIPT_CONFIG
handler_purge
EOF
    : > "${PURGE_LOG}"
    printf '%s\n' '{"version":"vTEST","xray":{"tag":"Vision"}}' > "${FAKE_SC}"
    env CALL_LOG="${PURGE_LOG}" FAKE_PURGE_SCRIPT="${SB}/fake_purge.sh" \
        FAKE_SCRIPT_CONFIG_FILE="${FAKE_SC}" STUB_DL_FAIL=1 \
        bash "${SB}/run_purge_neg.sh" >/dev/null 2>&1 || true
    if grep -q 'CRON:purged' "${PURGE_LOG}"; then
        ok
    else
        bad "P4 守卫已失效, 但副本仍没清 cron —— NEG 未生效"
    fi
else
    bad "P4 副本改坏未生效 (未命中 _error 锚点)"
fi

rm -rf "${SB}"

echo "==== handler_purge_nofile_test: PASS=$PASS FAIL=$FAIL ===="
[[ ${FAIL} -eq 0 ]]
