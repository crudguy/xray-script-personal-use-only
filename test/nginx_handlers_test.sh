#!/usr/bin/env bash
# =============================================================================
# 测试名称: nginx_handlers_test.sh
# 测试目标: Nginx「三件套」(install / update / purge) 的行为回归。
#
# 为什么需要本测试: 全仓审计显示 core/handler.sh 的 35 个分派臂里 22 个在测试中从未
# 出现, Nginx 三件套是其中**唯一会写系统目录**的一组 —— 编译安装落 /usr/local/nginx,
# 卸载会 rm -rf 安装目录并删 /usr/sbin/nginx 与 systemd 单元。误删发行版 Nginx 会让
# 机器上其它站点一起失去 Web 服务, 而静态检查 (bash -n / shellcheck) 对此完全无感。
#
# 两层覆盖:
#   H 层 core/handler.sh  —— 编排层: 什么时候才许调 nginx.sh、拒绝分支到底动没动配置
#   N 层 service/nginx.sh —— 归属判定: 发行版一律拒卸; /usr/sbin 软链与 unit 只在确认
#                            属于本项目时才删 (这两条正是"误删别人东西"的防线)
#
# 锁定不变量:
#   H1 install  段一 系统已有 nginx 命令 -> 不重装 (不调 nginx.sh --install)
#               段二 无论是否新装        -> handler_ssl_install 必被调用 (三段拆分的初衷)
#               段三 发行版二进制      -> 只告警, **不写站点配置、不记版本号**, return 0
#                    (记了版本号会让 nginx 自动更新 cron 误判"已安装")
#               段三 版本探测为空      -> _error 中止, **不许把空版本写进 config**
#   H2 update   nginx.sh rc=1 (无需更新, 最常见的分支) -> 提示而非假报错, 恒返回 0
#               nginx.sh rc=0 / rc>=2 -> 同样不许叠 ERR trap 噪音
#   H3 purge    拒绝卸载 -> 告警 + 审计 purge.skip, **config.json 一个字节都不许动**
#               正常卸载 -> 审计 purge + 重置 nginx 字段 + 落盘
#   N1 purge_nginx 发行版 -> return 1 且 **不进入卸载流程**
#   N2 purge_nginx 未安装 -> return 0
#   N3 purge_nginx 本项目编译版 -> 删安装目录; 软链/unit 仅在"确属本项目"时才删
#   N4 purge_nginx 软链指向别处 / unit 无本项目的 tcmalloc 标记 -> 一律保留
#   NEG (H2/H3/N1) 把守卫改坏, 上述判据必须变红
#
# 做法: awk 抽**真实函数体** (不另写实现, 避免漂移); N 层把 /usr 与 /etc 落点 sed 改写
#   进沙箱并复核改写生效 (否则会真删系统目录); ERR trap 从 core/_common.sh 原文抽取,
#   保证测的是"真实陷阱会不会响", 而不是测试自己编的一个。
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
assert_present() { if [[ -e "$2" ]]; then ok; else bad "$1 (不存在: $2)"; fi; }
assert_absent() { if [[ ! -e "$2" ]]; then ok; else bad "$1 (竟然存在: $2)"; fi; }

SB="$(pwd)/.workbuddy/tmp/nginx_handlers_$$"
rm -rf "$SB"
mkdir -p "${SB}/bin" "${SB}/rootfs"

# ---------------------------------------------------------------------------
# 抽取真实函数体
# ---------------------------------------------------------------------------
fn_of() { awk -v n="$2" '$0 ~ "^function " n "\\(\\) \\{"{f=1} f{print} f&&/^\}$/{exit}' "$1"; }

install_fn="$(fn_of core/handler.sh handler_nginx_install)"
update_fn="$(fn_of core/handler.sh handler_nginx_update)"
h_purge_fn="$(fn_of core/handler.sh handler_nginx_purge)"
n_purge_fn="$(fn_of service/nginx.sh purge_nginx)"
bin_fn="$(fn_of core/_common.sh _nginx_binary)"
local_inst_fn="$(fn_of core/_common.sh is_local_nginx_installed)"
dispatch_fn="$(fn_of core/handler.sh main)"

for v in install_fn update_fn h_purge_fn n_purge_fn bin_fn local_inst_fn dispatch_fn; do
    if [[ -z "${!v}" ]]; then bad "抽取 ${v} 失败"; fi
done
if [[ ${FAIL} -gt 0 ]]; then echo "==== nginx_handlers_test: PASS=$PASS FAIL=$FAIL ===="; exit 1; fi

# 真实 ERR trap (与 core/_common.sh 同一行) —— 用它才能证明"陷阱没响", 而非测试自造
grep -m1 "^trap '" core/_common.sh > "${SB}/errtrap.sh" || bad "未能抽取真实 ERR trap"
ERRSIG='意外失败'

# ---------------------------------------------------------------------------
# 静态契约
# ---------------------------------------------------------------------------
echo "== 静态契约 =="
assert_contains "S1 分派臂 --nginx-install 存在" "${dispatch_fn}" '--nginx-install) handler_nginx_install'
assert_contains "S2 分派臂 --nginx-update 存在" "${dispatch_fn}" '--nginx-update) handler_nginx_update'
assert_contains "S3 分派臂 --nginx-purge 存在" "${dispatch_fn}" '--nginx-purge) handler_nginx_purge'
assert_contains "S4 install 先判 nginx 命令是否存在" "${install_fn}" "cmd_exists 'nginx'"
assert_contains "S5 install 用 is_local_nginx_installed 区分发行版" "${install_fn}" 'is_local_nginx_installed'
assert_contains "S6 install 拒绝分支不记版本号 (PERSIST 在其后)" "${install_fn}" 'failed to detect nginx version'
assert_contains "S7 update 用 || rc 接住退出码 (进入条件上下文)" "${update_fn}" 'bash "${NGINX_PATH}" --update --brotli || rc=$?'
assert_contains "S8 update 区分 rc=1 (无需更新)" "${update_fn}" 'no_update'
assert_contains "S9 h_purge 拒绝分支不动配置" "${h_purge_fn}" 'purge.skip'
assert_contains "S10 n_purge 归属判定在最前" "${n_purge_fn}" 'is_local_nginx_installed'
assert_contains "S11 n_purge unit 归属按 tcmalloc 标记" "${n_purge_fn}" '/dev/shm/nginx/tcmalloc'
assert_contains "S12 n_purge 日志目录保留 (只提示不删)" "${n_purge_fn}" 'keep_logs'

# ---------------------------------------------------------------------------
# 桩件
# ---------------------------------------------------------------------------
cat > "${SB}/stubs_h.sh" <<'STUBS'
YELLOW=''; RED=''; NC=''; GREEN=''
CUR_FILE='handler'
_i18n() { printf '%s' "${1:-}"; }
_i18n_sub() { printf '%s' "${1:-}"; }
_audit_log() { printf 'AUDIT:%s|%s\n' "$1" "${2:-}" >> "${CALL_LOG:-/dev/null}"; }
print_info() { printf 'INFO:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; }
print_warn() { printf 'WARN:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; }
# 真实 _error 是显式 exit; 桩必须同样 exit, 否则"失败即中止"这条测不出来
_error() { printf 'ERROR:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; exit 1; }
# 三件套的编排桩: 全部只留痕, 由断言判定"该不该被调用"
handler_ssl_install() { printf 'SSL_INSTALL\n' >> "${CALL_LOG:-/dev/null}"; return "${STUB_SSL_RC:-0}"; }
handler_nginx_config() { printf 'NGINX_CONFIG\n' >> "${CALL_LOG:-/dev/null}"; return "${STUB_CFG_RC:-0}"; }
persist_script_config() {
    printf 'PERSIST\n' >> "${CALL_LOG:-/dev/null}"
    printf '%s\n' "${SCRIPT_CONFIG:-}" > "${FAKE_SC:?}"
}
reset_json_fields() {
    printf 'RESET:%s\n' "${2:-}" >> "${CALL_LOG:-/dev/null}"
    printf '%s' '{"version":"vTEST"}'
}
systemctl() { printf 'SYSTEMCTL:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; return 0; }
# STUB_HAS_NGINX=1 表示"系统里存在 nginx 命令" (发行版场景)
cmd_exists() {
    case "${1:-}" in
        nginx) [[ "${STUB_HAS_NGINX:-0}" == '1' ]] ;;
        *) command -v -- "${1:-}" >/dev/null 2>&1 ;;
    esac
}
# install 段三的守卫: STUB_LOCAL=1 表示"本项目编译版", 0 表示"发行版预装"
is_local_nginx_installed() { [[ "${STUB_LOCAL:-0}" == '1' ]]; }
STUBS

# N 层桩: 只补 nginx.sh 用到的输出函数与 systemctl; 归属判定用**真实实现**
cat > "${SB}/stubs_n.sh" <<'STUBS'
_i18n() { printf '%s' "${1:-}"; }
_i18n_sub() { printf '%s' "${1:-}"; }
print_info() { printf 'INFO:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; }
print_warn() { printf 'WARN:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; }
print_error() { printf 'ERROR:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; }
_nginx_package_owner() { printf 'OWNER:lookup\n' >> "${CALL_LOG:-/dev/null}"; return 0; }
systemctl() { printf 'SYSTEMCTL:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"; return 0; }
cmd_exists() {
    case "${1:-}" in
        nginx) [[ "${STUB_HAS_NGINX:-0}" == '1' ]] ;;
        *) command -v -- "${1:-}" >/dev/null 2>&1 ;;
    esac
}
STUBS

# ---------------------------------------------------------------------------
# H 层: 驱动脚本 + 假 nginx 二进制
# ---------------------------------------------------------------------------
cat > "${SB}/bin/nginx" <<'FAKE'
#!/usr/bin/env bash
# 桩 nginx: 只回应 -V, 版本号由 STUB_NGINX_V 控制 (留空即模拟"探测不到版本")
printf 'nginx version: nginx/%s\n' "${STUB_NGINX_V-1.29.0}"
printf 'built with OpenSSL %s\n' "${STUB_OPENSSL_V-3.5.4}"
FAKE
chmod +x "${SB}/bin/nginx"

cat > "${SB}/fake_nginx_svc.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'NGINX_SH:%s\n' "$*" >> "${CALL_LOG:-/dev/null}"
exit "${STUB_NGINX_SH_RC:-0}"
FAKE
chmod +x "${SB}/fake_nginx_svc.sh"

{
    printf '%s\n' "${install_fn}"
    printf '%s\n' "${update_fn}"
    printf '%s\n' "${h_purge_fn}"
} > "${SB}/fn_h.sh"

h_runner() { # $1=函数名 -> 生成 runner (单独文件, 便于 NEG 换源)
    cat > "${SB}/run_h_$1.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source "${SB}/errtrap.sh"
source "${SB}/stubs_h.sh"
source "${SB}/fn_h.sh"
declare NGINX_PATH="${SB}/fake_nginx_svc.sh"
SCRIPT_CONFIG='{"version":"vTEST","nginx":{"version":"1.29.0"}}'
export SCRIPT_CONFIG
$1
EOF
}

H_LOG="${SB}/call_h.log"
FAKE_SC="${SB}/script_config.json"

reset_h() { : > "${H_LOG}"; }

run_h() { # $1=函数名; 其余 = "KEY=VALUE" 形式的 env 变量
    local fn="$1"
    shift
    reset_h
    env CALL_LOG="${H_LOG}" FAKE_SC="${FAKE_SC}" \
        PATH="${SB}/bin:${PATH}" "$@" \
        bash "${SB}/run_h_${fn}.sh" > "${SB}/h_out.txt" 2>&1
}

h_out() { cat "${SB}/h_out.txt"; }
h_log() { cat "${H_LOG}"; }

# ---------------------------------------------------------------------------
# H1 install
# ---------------------------------------------------------------------------
echo "== H1 handler_nginx_install =="
h_runner handler_nginx_install

# H1a 系统已有 nginx 命令 -> 段一跳过, 但段二(acme.sh)照跑; 本项目编译版 -> 段三照跑
printf '%s\n' '{"version":"vTEST"}' > "${FAKE_SC}"
run_h handler_nginx_install STUB_HAS_NGINX=1 STUB_LOCAL=1 || true
assert_not_contains "H1a 已有 nginx 命令时不重装" "$(h_log)" 'NGINX_SH:--install'
assert_contains "H1b 已有 nginx 时仍装 acme.sh (三段拆分初衷)" "$(h_log)" 'SSL_INSTALL'
assert_contains "H1c 本项目编译版走配置写入" "$(h_log)" 'NGINX_CONFIG'
assert_contains "H1d 记录了版本号" "$(cat "${FAKE_SC}")" '1.29.0'
assert_contains "H1e 兜底 enable (防证书失败留半装状态)" "$(h_log)" 'SYSTEMCTL:-q is-enabled nginx'
assert_contains "H1f 有审计留痕" "$(h_log)" 'AUDIT:install|nginx version=1.29.0'
assert_not_contains "H1g 无假报错" "$(h_out)" "${ERRSIG}"

# H1h 系统没有 nginx 命令 -> 段一必须真装
printf '%s\n' '{"version":"vTEST"}' > "${FAKE_SC}"
run_h handler_nginx_install STUB_HAS_NGINX=0 STUB_LOCAL=1 || true
assert_contains "H1h 缺 nginx 时调 nginx.sh --install --brotli" "$(h_log)" 'NGINX_SH:--install --brotli'

# H1i 段一失败 -> _error 中止, 不继续段二
run_h handler_nginx_install STUB_HAS_NGINX=0 STUB_NGINX_SH_RC=1 || true
assert_contains "H1i 装 Nginx 失败即中止" "$(h_log)" 'ERROR:nginx install failed'
assert_not_contains "H1j 中止后不再装 acme.sh" "$(h_log)" 'SSL_INSTALL'

# H1k 发行版二进制 -> 只告警, 不写配置, 不记版本号, 且不中断
printf '%s\n' '{"version":"vTEST"}' > "${FAKE_SC}"
run_h handler_nginx_install STUB_HAS_NGINX=1 STUB_LOCAL=0 || true
assert_not_contains "H1k 发行版二进制不写站点配置" "$(h_log)" 'NGINX_CONFIG'
assert_not_contains "H1l 发行版二进制不记版本号" "$(h_log)" 'PERSIST'
assert_contains "H1m 发行版二进制告警 foreign_binary" "$(h_out)" 'nginx.foreign_binary'
assert_eq "H1n 发行版二进制时 config.json 未被改写" "$(cat "${FAKE_SC}")" '{"version":"vTEST"}'
assert_not_contains "H1o 发行版二进制无假报错" "$(h_out)" "${ERRSIG}"

# H1p 版本探测为空 -> 不许把空版本写进去
printf '%s\n' '{"version":"vTEST"}' > "${FAKE_SC}"
run_h handler_nginx_install STUB_HAS_NGINX=1 STUB_LOCAL=1 STUB_NGINX_V= || true
assert_not_contains "H1p 探测不到版本时不落盘" "$(h_log)" 'PERSIST'
assert_eq "H1q 探测不到版本时 config.json 保持原样" "$(cat "${FAKE_SC}")" '{"version":"vTEST"}'

# ---------------------------------------------------------------------------
# H2 update
# ---------------------------------------------------------------------------
echo "== H2 handler_nginx_update =="
h_runner handler_nginx_update

run_h handler_nginx_update STUB_NGINX_SH_RC=0 || true
assert_not_contains "H2a rc=0 时无假报错" "$(h_out)" "${ERRSIG}"
assert_not_contains "H2b rc=0 时不误报无需更新" "$(h_log)" 'no_update'
assert_contains "H2c 传参是 --update --brotli" "$(h_log)" 'NGINX_SH:--update --brotli'
assert_not_contains "H2d 不擅自带 --force (不覆盖运行中的二进制)" "$(h_log)" '--force'

# rc=1 = 已是最新版本 —— 最常见分支, 修复前必叠假报错
run_h handler_nginx_update STUB_NGINX_SH_RC=1 || true
assert_not_contains "H2e rc=1 时无假报错 (本 bug 的回归锁)" "$(h_out)" "${ERRSIG}"
assert_contains "H2f rc=1 时提示 no_update" "$(h_log)" 'no_update'

run_h handler_nginx_update STUB_NGINX_SH_RC=2 || true
assert_not_contains "H2g rc=2 时无假报错" "$(h_out)" "${ERRSIG}"
assert_contains "H2h rc=2 时报 update_failed" "$(h_log)" 'update_failed'

# ---------------------------------------------------------------------------
# H3 purge
# ---------------------------------------------------------------------------
echo "== H3 handler_nginx_purge =="
h_runner handler_nginx_purge

# H3a 拒绝卸载 (nginx.sh rc=1) -> 只告警, config.json 一个字节都不许动
ORIG_SC='{"version":"vTEST","nginx":{"version":"1.29.0","domain":"a.example.com"}}'
printf '%s\n' "${ORIG_SC}" > "${FAKE_SC}"
run_h handler_nginx_purge STUB_NGINX_SH_RC=1 || true
assert_contains "H3a 拒绝卸载时告警" "$(h_out)" 'nginx.purge_refused'
assert_contains "H3b 审计记为 purge.skip" "$(h_log)" 'AUDIT:purge.skip'
assert_not_contains "H3c 拒绝时不重置配置" "$(h_log)" 'RESET:'
assert_not_contains "H3d 拒绝时不落盘" "$(h_log)" 'PERSIST'
assert_eq "H3e 拒绝时 config.json 逐字节未变" "$(cat "${FAKE_SC}")" "${ORIG_SC}"
assert_not_contains "H3f 拒绝时无假报错" "$(h_out)" "${ERRSIG}"

# H3g 正常卸载 -> 审计 purge + 重置 nginx 字段 + 落盘
run_h handler_nginx_purge STUB_NGINX_SH_RC=0 || true
assert_contains "H3g 正常卸载留审计 purge" "$(h_log)" 'AUDIT:purge|nginx'
assert_contains "H3h 重置的是 nginx 字段" "$(h_log)" 'RESET:nginx'
assert_contains "H3i 落盘" "$(h_log)" 'PERSIST'
assert_not_contains "H3j 正常卸载无假报错" "$(h_out)" "${ERRSIG}"

# ---------------------------------------------------------------------------
# N 层: purge_nginx 归属判定 (落点改写进沙箱)
# ---------------------------------------------------------------------------
echo "== N purge_nginx 归属判定 =="
NX="${SB}/rootfs"
sed "s|/usr/sbin/nginx|${NX}/usr-sbin-nginx|g" <<<"${n_purge_fn}" > "${SB}/fn_n.sh"
sed -i "s|/etc/systemd/system/nginx.service|${NX}/etc-systemd-nginx.service|g" "${SB}/fn_n.sh"
{
    printf '%s\n' "${bin_fn}"
    printf '%s\n' "${local_inst_fn}"
} >> "${SB}/fn_n.sh"
# 改写复核: 锚点没命中 -> 就地失败, 绝不带着真实 /usr 与 /etc 路径往下跑
if grep -q '/usr/sbin/nginx' "${SB}/fn_n.sh" || grep -q '/etc/systemd/system/nginx.service' "${SB}/fn_n.sh"; then
    bad "沙箱化改写未生效 (fn_n.sh 仍有 /usr 或 /etc 绝对路径)"
    echo "==== nginx_handlers_test: PASS=$PASS FAIL=$FAIL ===="
    exit 1
fi

cat > "${SB}/run_n.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source "${SB}/stubs_n.sh"
source "${SB}/fn_n.sh"
declare NGINX_PATH="${NX}/usr-local-nginx"
declare NGINX_PREFIX_DIR="${NX}/usr-local-nginx"
declare NGINX_LOG_PATH="${NX}/var-log-nginx"
purge_nginx
EOF

N_LOG="${SB}/call_n.log"
NX_SBIN="${NX}/usr-sbin-nginx"
NX_UNIT="${NX}/etc-systemd-nginx.service"
NX_INSTALL="${NX}/usr-local-nginx"
NX_BIN="${NX_INSTALL}/sbin/nginx"
NX_LOG_DIR="${NX}/var-log-nginx"

setup_n() { # $1 = local | foreign | none
    rm -rf "${NX}"
    mkdir -p "${NX_INSTALL}/sbin" "${NX_LOG_DIR}"
    case "$1" in
        local)
            printf '#!/bin/sh\n' > "${NX_BIN}"
            chmod +x "${NX_BIN}"
            ln -s "${NX_BIN}" "${NX_SBIN}"
            printf '[Service]\nExecStartPre=/bin/chown nginx:nginx /dev/shm/nginx/tcmalloc\n' > "${NX_UNIT}"
            ;;
        foreign)
            printf '#!/bin/sh\n' > "${NX_SBIN}"
            chmod +x "${NX_SBIN}"
            ;;
        none) rm -rf "${NX_INSTALL}" ;;
    esac
    : > "${N_LOG}"
}

run_n() { # 其余 = "KEY=VALUE" 形式的 env 变量
    env CALL_LOG="${N_LOG}" "$@" bash "${SB}/run_n.sh" > "${SB}/n_out.txt" 2>&1
}

n_log() { cat "${N_LOG}"; }

# N1 发行版 nginx 在场 + 本项目未安装 -> 拒绝
setup_n foreign
rc=0
run_n STUB_HAS_NGINX=1 || rc=$?
assert_eq "N1a 发行版时 return 1" "${rc}" "1"
assert_contains "N1b 报 refuse_foreign" "$(n_log)" 'nginx.purge.refuse_foreign'
assert_contains "N1c 打印了包归属线索" "$(n_log)" 'OWNER:lookup'
assert_present "N1d 发行版二进制未被删" "${NX_SBIN}"
assert_not_contains "N1e 发行版时未进入卸载流程" "$(n_log)" 'start_purge'

# N2 完全没有 nginx -> return 0
setup_n none
rc=0
run_n STUB_HAS_NGINX=0 || rc=$?
assert_eq "N2a 未安装时 return 0" "${rc}" "0"
assert_contains "N2b 提示 not_installed" "$(n_log)" 'nginx.purge.not_installed'

# N3 本项目编译版 -> 清安装目录 + 属于本项目的软链与 unit
setup_n local
rc=0
run_n STUB_HAS_NGINX=0 || rc=$?
assert_eq "N3a 正常卸载 return 0" "${rc}" "0"
assert_absent "N3b 安装目录已删" "${NX_INSTALL}"
assert_absent "N3c 指向本项目的 /usr/sbin 软链已删" "${NX_SBIN}"
assert_absent "N3d 带 tcmalloc 标记的 unit 已删" "${NX_UNIT}"
assert_present "N3e 日志目录一律保留" "${NX_LOG_DIR}"
assert_contains "N3f 提示日志位置" "$(n_log)" 'nginx.purge.keep_logs'
assert_contains "N3g 收尾 daemon-reload" "$(n_log)" 'SYSTEMCTL:daemon-reload'

# N4 软链指向别处 + unit 无本项目标记 -> 都必须保留 (防误删别人的)
setup_n local
rm -f "${NX_SBIN}"; printf '#!/bin/sh\n' > "${NX}/other-nginx"; ln -s "${NX}/other-nginx" "${NX_SBIN}"
printf '[Service]\nExecStart=/usr/sbin/nginx\n' > "${NX_UNIT}"
rc=0
run_n STUB_HAS_NGINX=0 || rc=$?
assert_present "N4a 非本项目软链被保留" "${NX_SBIN}"
assert_present "N4b 非本项目 unit 被保留" "${NX_UNIT}"
assert_contains "N4c 提示跳过软链" "$(n_log)" 'nginx.purge.skip_sbin'
assert_contains "N4d 提示跳过 unit" "$(n_log)" 'nginx.purge.skip_unit'

# ---------------------------------------------------------------------------
# NEG: 守卫改坏, 对应判据必须变红
# ---------------------------------------------------------------------------
echo "== NEG =="

# NEG-U: 摘掉 update 的 `|| rc=$?` -> rc=1 时真实 ERR trap 必须响 (H2e 的判据变红)
sed 's, --update --brotli || rc=$?, --update --brotli,' "${SB}/fn_h.sh" > "${SB}/fn_h_neg_u.sh"
if cmp -s "${SB}/fn_h.sh" "${SB}/fn_h_neg_u.sh"; then
    bad "NEG-U 副本改坏未生效 (未命中 update 的接码锚点)"
else
    sed -i "s|${SB}/fn_h.sh|${SB}/fn_h_neg_u.sh|g" "${SB}/run_h_handler_nginx_update.sh"
    run_h handler_nginx_update STUB_NGINX_SH_RC=1 || true
    if [[ "$(h_out)" == *"${ERRSIG}"* ]]; then
        ok
    else
        bad "NEG-U 守卫已失效, 但副本仍未叠假报错 —— NEG 未生效"
    fi
    sed -i "s|${SB}/fn_h_neg_u.sh|${SB}/fn_h.sh|g" "${SB}/run_h_handler_nginx_update.sh"
fi

# NEG-P: 抹掉拒绝分支的 return 0 -> "拒绝时不重置/不落盘" 必须变红
sed '/purge\.skip/{n;s|return 0|:|;}' "${SB}/fn_h.sh" > "${SB}/fn_h_neg_p.sh"
if cmp -s "${SB}/fn_h.sh" "${SB}/fn_h_neg_p.sh"; then
    bad "NEG-P 副本改坏未生效 (未命中拒绝分支的 return 0)"
else
    sed -i "s|${SB}/fn_h.sh|${SB}/fn_h_neg_p.sh|g" "${SB}/run_h_handler_nginx_purge.sh"
    printf '%s\n' "${ORIG_SC}" > "${FAKE_SC}"
    run_h handler_nginx_purge STUB_NGINX_SH_RC=1 || true
    if [[ "$(h_log)" == *'RESET:'* ]]; then
        ok
    else
        bad "NEG-P 守卫已失效, 但副本仍未重置配置 —— NEG 未生效"
    fi
    sed -i "s|${SB}/fn_h_neg_p.sh|${SB}/fn_h.sh|g" "${SB}/run_h_handler_nginx_purge.sh"
fi

# NEG-N: 去掉归属判定 -> 发行版场景必须被当成"可卸载"往下走 (N1e 的判据变红)
sed 's|if ! is_local_nginx_installed; then|if false; then|' "${SB}/fn_n.sh" > "${SB}/fn_n_neg.sh"
if cmp -s "${SB}/fn_n.sh" "${SB}/fn_n_neg.sh"; then
    bad "NEG-N 副本改坏未生效 (未命中归属判定锚点)"
else
    sed -i "s|${SB}/fn_n.sh|${SB}/fn_n_neg.sh|g" "${SB}/run_n.sh"
    setup_n foreign
    run_n STUB_HAS_NGINX=1 || true
    if [[ "$(n_log)" == *'start_purge'* ]]; then
        ok
    else
        bad "NEG-N 守卫已失效, 但副本仍未进入卸载流程 —— NEG 未生效"
    fi
    sed -i "s|${SB}/fn_n_neg.sh|${SB}/fn_n.sh|g" "${SB}/run_n.sh"
fi

rm -rf "${SB}"

echo "==== nginx_handlers_test: PASS=$PASS FAIL=$FAIL ===="
[[ ${FAIL} -eq 0 ]]
