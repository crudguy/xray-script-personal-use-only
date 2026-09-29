#!/usr/bin/env bash
# handler_bbr 幂等补齐持久化文件 回归测试 (纯 bash; 只写 .workbuddy/tmp, 不碰真实 /etc)
#
# 背景: 体检「内核网络」分区会检查两份 BBR 持久化文件 ——
#   /etc/modules-load.d/xray-script-personal-use-only-bbr.conf
#   /etc/sysctl.d/99-xray-script-personal-use-only-bbr.conf
# 而 handler_bbr 原先在"当前已是 bbr/fq"时直接 return 0 且**不落盘**。于是
# 云镜像/面板预设过 BBR 的机器会得到自相矛盾的结果: 体检报"持久化文件缺失,
# 重启后会失效", 而安装时却说"BBR 已启用, 无需操作" —— 且重启真的会丢。
#
# 本测试锁定修复后的三条不变量:
#   T1 已生效 + 文件缺失 -> 补齐两份 (内容即当前生效值), 并提示 persist_repair;
#   T2 已生效 + 文件齐全 -> 真正零写盘 (预置内容原封不动), 不出现 persist_repair;
#   T3 未生效            -> 仍走完整启用流程并落盘;
#   T4 (NEG) 把"齐全才短路"改回恒短路 -> T1 场景必须一个文件都不写,
#      证明 T1 的判据确实由这段守卫决定, 不是别的路径恒绿。
#
# 实现: 抽取 handler.sh 的 _bbr_persist_files / handler_bbr 与 _common.sh 的
#   _atomic_write **真实函数体**, 再用 sed 把 /etc 落点改写到沙箱临时目录后驱动。
#   不另写一份实现, 避免与产品代码漂移。
#
# 运行: bash test/bbr_persist_test.sh
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1 (期望 [$3] 实际 [$2])"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1 (未包含 [$3])"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1 (不应包含 [$3])"; fi; }
assert_file_eq() { # $1=desc $2=file $3=expected
    local got=''
    got="$(cat "$2" 2>/dev/null || true)"
    if [[ "$got" == "$3" ]]; then ok; else bad "$1 (文件内容不符, 实际 [$got])"; fi
}

SB="$(pwd)/.workbuddy/tmp/bbr_persist_$$"
rm -rf "$SB"
mkdir -p "$SB"

# ---------------------------------------------------------------------------
# 抽取真实函数体 (不 source 整个 handler.sh, 避免顶层副作用)
# ---------------------------------------------------------------------------
persist_fn="$(awk '/^function _bbr_persist_files\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' core/handler.sh)"
bbr_fn="$(awk '/^function handler_bbr\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' core/handler.sh)"
atom_fn="$(awk '/^function _atomic_write\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' core/_common.sh)"

if [[ -z "$persist_fn" || -z "$bbr_fn" || -z "$atom_fn" ]]; then
    echo "  [FAIL] 无法抽取 _bbr_persist_files / handler_bbr / _atomic_write 函数体"
    exit 1
fi

# ---------------------------------------------------------------------------
# T0 静态契约: 两条路径共用同一落盘实现 + 短路分支须看文件是否存在
# ---------------------------------------------------------------------------
assert_contains "T0a: handler_bbr 复用 _bbr_persist_files (落盘同源)" "$bbr_fn" '_bbr_persist_files'
assert_contains "T0b: 短路分支含 persist_repair 提示" "$bbr_fn" 'bbr.persist_repair'
assert_contains "T0c: 短路判据含 modules-load.d 文件存在性" "$bbr_fn" '-e "${modules_load_file}"'
assert_contains "T0d: 短路判据含 sysctl.d 文件存在性" "$bbr_fn" '-e "${sysctl_conf_file}"'
assert_contains "T0e: 落盘实现仍写两份文件 (modules-load.d)" "$persist_fn" '/etc/modules-load.d'
assert_contains "T0f: 落盘实现仍写两份文件 (sysctl.d)" "$persist_fn" '/etc/sysctl.d'
# 落盘内容必须成对 (缺 fq 时 BBR 失去 pacing)
assert_contains "T0g: modules-load.d 内容含 tcp_bbr" "$persist_fn" 'tcp_bbr'
assert_contains "T0h: sysctl.d 内容含 default_qdisc = fq" "$persist_fn" 'net.core.default_qdisc = fq'

# ---------------------------------------------------------------------------
# 桩件 (quoted heredoc: 原样落地, 变量留到运行时取)
# ---------------------------------------------------------------------------
cat > "$SB/stubs.sh" <<'STUBS'
GREEN=''; YELLOW=''; RED=''; NC=''
# handler.sh 里的 i18n key 由 ${CUR_FILE} 拼出 (如 .handler.bbr.already);
# set -u 下未定义会让命令替换静默失败 —— 文案缺失, 断言随之假绿。
CUR_FILE='handler'
_i18n() { printf '%s' "$1"; }
_audit_log() { printf '%s\n' "$*" >> "${AUDIT_LOG:-/dev/null}"; }
cmd_exists() { command -v -- "$1" >/dev/null 2>&1; }
# modprobe 桩: 加载 tcp_bbr 成功后把拥塞控制"变成" bbr (模拟内核支持并已生效)
modprobe() {
    printf 'modprobe %s\n' "$1" >> "${CALL_LOG:-/dev/null}"
    if [[ "$1" == 'tcp_bbr' ]]; then printf 'bbr\n' > "${CC_FILE:-/dev/null}"; fi
    return 0
}
# sysctl 桩: -n 读值 (拥塞控制取自 CC_FILE, 队列取 STUB_QDISC); -p 视为成功
sysctl() {
    printf 'sysctl %s\n' "$*" >> "${CALL_LOG:-/dev/null}"
    case "${1:-}" in
        -n)
            case "${2:-}" in
                net.ipv4.tcp_congestion_control) cat "${CC_FILE:-/dev/null}" 2>/dev/null || true ;;
                net.core.default_qdisc)          printf '%s\n' "${STUB_QDISC:-fq}" ;;
                *) return 1 ;;
            esac
            ;;
        -p) return 0 ;;
        *) return 0 ;;
    esac
}
STUBS

# 拼装函数文件: 抽出的真实函数体 + 把 /etc 落点改写到场景专属目录
write_funcs() { # $1=out $2=persist_fn $3=bbr_fn $4=etc_root [$5=额外 sed 表达式]
    {
        printf '%s\n' "$atom_fn"
        printf '%s\n' "$2"
        printf '%s\n' "$3"
    } > "$1"
    sed -i "s|/etc/modules-load.d|$4/modules-load.d|g; s|/etc/sysctl.d|$4/sysctl.d|g" "$1"
    if [[ -n "${5:-}" ]]; then
        sed -i "$5" "$1"
    fi
}

make_run() { # $1=funcs文件 $2=run文件
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -Eeuo pipefail\n'
        printf 'source "%s/stubs.sh"\n' "$SB"
        printf 'source "%s"\n' "$1"
        printf 'rc=0\n'
        printf 'handler_bbr || rc=$?\n'
        printf 'printf "RC=%%s\\n" "$rc"\n'
    } > "$2"
}

MOD_NAME='xray-script-personal-use-only-bbr.conf'
SYS_NAME='99-xray-script-personal-use-only-bbr.conf'
MOD_BODY='tcp_bbr
sch_fq'
SYS_BODY='net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr'

# ===========================================================================
# T1: 已生效 + 持久化文件缺失 -> 必须补齐两份
# ===========================================================================
A="$SB/caseA"
mkdir -p "$A"
write_funcs "$A/funcs.sh" "$persist_fn" "$bbr_fn" "$A/etc"
make_run "$A/funcs.sh" "$A/run.sh"
printf 'bbr\n' > "$A/cc.txt"
outA="$(CC_FILE="$A/cc.txt" STUB_QDISC='fq' AUDIT_LOG="$A/audit.log" CALL_LOG="$A/call.log" bash "$A/run.sh" 2>&1 || true)"

assert_contains "T1a: 已生效但缺文件时应报告已补齐" "$outA" 'bbr.persist_repair'
assert_contains "T1b: 应提示 BBR 已启用" "$outA" 'bbr.already'
assert_contains "T1c: 返回码应为 0" "$outA" 'RC=0'
assert_file_eq "T1d: modules-load.d 文件已补齐且内容正确" "$A/etc/modules-load.d/$MOD_NAME" "$MOD_BODY"
assert_file_eq "T1e: sysctl.d 文件已补齐且内容正确" "$A/etc/sysctl.d/$SYS_NAME" "$SYS_BODY"
if [[ -s "$A/audit.log" ]]; then ok; else bad "T1f: 补齐文件属写操作, 应留审计记录"; fi
# 补齐路径**不应**做模块加载 (已生效本身说明模块/内建可用; 免得内建内核被 modprobe 误判为不支持)
assert_not_contains "T1g: 已生效时不该再调 modprobe (内建内核会误报不支持)" "$(cat "$A/call.log" 2>/dev/null || true)" 'modprobe'

# ===========================================================================
# T2: 已生效 + 文件齐全 -> 真正零写盘
# ===========================================================================
B="$SB/caseB"
mkdir -p "$B/etc/modules-load.d" "$B/etc/sysctl.d"
write_funcs "$B/funcs.sh" "$persist_fn" "$bbr_fn" "$B/etc"
make_run "$B/funcs.sh" "$B/run.sh"
printf 'bbr\n' > "$B/cc.txt"
printf 'SENTINEL_KEEP_ME\n' > "$B/etc/modules-load.d/$MOD_NAME"
printf 'SENTINEL_KEEP_ME\n' > "$B/etc/sysctl.d/$SYS_NAME"
outB="$(CC_FILE="$B/cc.txt" STUB_QDISC='fq' AUDIT_LOG="$B/audit.log" CALL_LOG="$B/call.log" bash "$B/run.sh" 2>&1 || true)"

assert_contains "T2a: 文件齐全时应提示已启用" "$outB" 'bbr.already'
assert_contains "T2b: 返回码应为 0" "$outB" 'RC=0'
assert_not_contains "T2c: 文件齐全时不得出现补齐提示" "$outB" 'bbr.persist_repair'
assert_file_eq "T2d: 齐全时 modules-load.d 内容应原封不动" "$B/etc/modules-load.d/$MOD_NAME" 'SENTINEL_KEEP_ME'
assert_file_eq "T2e: 齐全时 sysctl.d 内容应原封不动" "$B/etc/sysctl.d/$SYS_NAME" 'SENTINEL_KEEP_ME'
assert_eq "T2f: 齐全时不应残留临时文件" "$(ls -1 "$B/etc/sysctl.d" | wc -l | tr -d ' ')" '1'

# ===========================================================================
# T3: 未生效 -> 仍走完整启用流程并落盘
# ===========================================================================
C="$SB/caseC"
mkdir -p "$C"
write_funcs "$C/funcs.sh" "$persist_fn" "$bbr_fn" "$C/etc"
make_run "$C/funcs.sh" "$C/run.sh"
printf 'cubic\n' > "$C/cc.txt"
outC="$(CC_FILE="$C/cc.txt" STUB_QDISC='fq' AUDIT_LOG="$C/audit.log" CALL_LOG="$C/call.log" bash "$C/run.sh" 2>&1 || true)"

assert_contains "T3a: 未生效时应进入启用流程" "$outC" 'bbr.enabling'
assert_contains "T3b: 启用成功应报告已生效" "$outC" 'bbr.verified'
assert_contains "T3c: 返回码应为 0" "$outC" 'RC=0'
assert_file_eq "T3d: 启用路径 modules-load.d 内容正确" "$C/etc/modules-load.d/$MOD_NAME" "$MOD_BODY"
assert_file_eq "T3e: 启用路径 sysctl.d 内容正确" "$C/etc/sysctl.d/$SYS_NAME" "$SYS_BODY"
assert_not_contains "T3f: 未生效时不应出现补齐提示" "$outC" 'bbr.persist_repair'

# ===========================================================================
# T4 (NEG): 把"齐全才短路"改回恒短路 -> T1 场景必须一个文件都不写
#   目的: 证明 T1d/T1e 的判据确实由这段守卫决定, 而不是别的路径恒绿。
# ===========================================================================
N="$SB/neg"
mkdir -p "$N"
write_funcs "$N/funcs.sh" "$persist_fn" "$bbr_fn" "$N/etc" \
    's|if \[\[ -e "\${modules_load_file}" && -e "\${sysctl_conf_file}" \]\]; then|if true; then|'
if grep -qF 'if true; then' "$N/funcs.sh"; then
    ok
else
    bad "T4a: NEG 的 sed 未生效 (测试自身失效, 后续断言无意义)"
fi
make_run "$N/funcs.sh" "$N/run.sh"
printf 'bbr\n' > "$N/cc.txt"
outN="$(CC_FILE="$N/cc.txt" STUB_QDISC='fq' AUDIT_LOG="$N/audit.log" CALL_LOG="$N/call.log" bash "$N/run.sh" 2>&1 || true)"

assert_not_contains "T4b: 恒短路版不应出现补齐提示" "$outN" 'bbr.persist_repair'
if [[ ! -e "$N/etc/modules-load.d/$MOD_NAME" ]]; then ok; else bad "T4c: 恒短路版竟然仍写了 modules 文件 (判据可疑)"; fi
if [[ ! -e "$N/etc/sysctl.d/$SYS_NAME" ]]; then ok; else bad "T4d: 恒短路版竟然仍写了 sysctl 文件 (判据可疑)"; fi

# ===========================================================================
# T5 语义归属: "开机自启"与"BBR 持久化"是两件事, 别再把 label 放错分区。
#   本次混淆的根因 = 内核网络分区用「开机自启: 」指代 BBR 持久化文件, 用户
#   自然理解成 xray 服务自启。故连同"哪个分区用哪个 label"一起锁死。
# ===========================================================================
kernel_fn="$(awk '/^function _health_kernel\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' core/check.sh)"
health_xray_fn="$(awk '/^function _health_xray\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' core/check.sh)"
if [[ -n "$kernel_fn" && -n "$health_xray_fn" ]]; then ok; else bad "T5a: 无法抽取 _health_kernel / _health_xray"; fi
assert_contains "T5b: 内核网络分区用 net_persist_label (BBR 持久化)" "$kernel_fn" 'net_persist_label'
assert_not_contains "T5c: 内核网络分区不得用 svc_enabled_label (那是服务自启)" "$kernel_fn" 'svc_enabled_label'
assert_contains "T5d: Xray 分区已补 svc_enabled_label (真·开机自启)" "$health_xray_fn" 'svc_enabled_label'
assert_contains "T5e: Xray 自启项判据须为 systemctl is-enabled" "$health_xray_fn" "systemctl -q is-enabled 'xray'"

zh_persist="$(jq -r '.check.health.net_persist_label' i18n/zh.json)"
zh_svc="$(jq -r '.check.health.svc_enabled_label' i18n/zh.json)"
assert_not_contains "T5f: net_persist_label 不应再自称开机自启 (避免与 xray 自启混淆)" "$zh_persist" '开机自启'
assert_contains "T5g: svc_enabled_label 才是开机自启" "$zh_svc" '开机自启'
for f in zh en; do
    for k in svc_enabled_label svc_disabled; do
        v="$(jq -r ".check.health.${k} // \"\"" "i18n/${f}.json")"
        if [[ -n "$v" ]]; then ok; else bad "T5h(${f}): .check.health.${k} 缺失"; fi
    done
    v="$(jq -r '.handler.bbr.persist_repair // ""' "i18n/${f}.json")"
    if [[ -n "$v" ]]; then ok; else bad "T5i(${f}): .handler.bbr.persist_repair 缺失"; fi
done

rm -rf "$SB"
echo "==== bbr_persist_test: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]]
