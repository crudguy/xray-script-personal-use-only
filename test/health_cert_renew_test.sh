#!/usr/bin/env bash
# =============================================================================
# test/health_cert_renew_test.sh — 体检"TLS 证书"分区里 acme.sh 续期链路两项的守卫
#
# 守护的事实 (为什么体检要看这两件事):
#   acme.sh 装好之后, "证书会不会自动续"这件事**不在本项目手里** —— 定时任务由
#   acme.sh 自己写进 crontab, 而它把安装失败吞成了同一个退出码 (详见
#   test/ssl_cron_guard_test.sh 头部的上游行号)。更麻烦的是 cron 里那次
#   `acme.sh --cron` 的输出被上游丢进 /dev/null, **跑挂了不会留下任何痕迹**:
#   没有日志、没有告警、没有退出码可查, 唯一能反推它的只有证书自身的剩余天数 ——
#   acme.sh 默认在剩余 30 天内续期, 所以只要续期链路是通的, 剩余天数永远不会跌破
#   30; 一旦跌进 21 天以内, 只可能是"该续没续上"。
#
#   体检此前只看"证书文件在不在 / 还剩几天", 于是下面两类故障都是静默的:
#     ① 定时任务压根没装 (证书还剩 80 天, 体检全绿, 90 天后一次性全红);
#     ② 定时任务在、但每次跑都失败 (剩余天数一路往下掉, 没人知道)。
#   本文件守护的就是补上来的那两项结论。
#
# 做法: 抽**真实函数体** + eval 注入, 桩件替代 _common.sh / 外部命令。
#   不 source core/check.sh —— 它的 ERR trap 是 exit, 落在宿主脚本上会让被测的
#   失败路径把整个测试脚本带走 (与 test/ssl_cron_guard_test.sh 同源的选型)。
#   桩件必须先定义再 eval, 顺序反了会触发 SC2218。
#
# 覆盖:
#   [A] 自动续期定时任务项
#     T1  未装 acme.sh -> skip (不适用), 且**不**计入结论
#     T2  已装 + 定时任务就位 -> pass
#     T3  已装 + 完全没有定时任务 -> warn
#     T3b 已装 + 有别的定时任务但没有 acme 那条 -> warn (有 crontab ≠ 续期已安排)
#     T4  已装 + 只有一条手抄的注释含 'acme.sh --cron' -> warn (注释不算就位)
#     T5  本机没有 crontab 命令 -> skip
#   [B] 剩余天数分级
#     T6  剩余 30 天 -> pass, 且不报 stalled
#     T7  剩余 10 天 -> warn stalled (跌进续期窗口 = 自动续期疑似未生效)
#     T8  剩余 3 天  -> warn expiring, 且**不**重复报 stalled (两档互斥)
#     T9  已过期     -> fail
#     T10 证书文件缺失 -> fail
#   [C] 文案
#     T11 新增键在 zh/en 均存在且非空
#   NEG1 阈值常量改成 0 -> T7 必须变红
#   NEG2 去掉"滤注释行" -> T4 必须变红
#   NEG3 判据退化成"有 crontab 就算就位" -> T3b 必须变红
# =============================================================================

set -u

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
# 放 /tmp 而非 .workbuddy/tmp: 后者在本机受 safe-delete 钩子管辖, 清理时会打一串
# 与被测行为无关的报错污染输出 (与 ssl_cron_guard_test.sh 同选型)。
SB="/tmp/health-cert-renew.$$"
rm -rf "${SB}"
mkdir -p "${SB}/home" "${SB}/certs"
trap 'rm -rf "${SB}"' EXIT

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
# 参数顺序沿用全仓约定: $1=msg $2=实际 $3=期望 (写反了值相等时不显形, 只在失败时
# 把排查方向带偏 —— 见 test/share_common_config_test.sh 的同名教训)
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (期望 [$3] 实际 [$2])"; fi; }
assert_has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (未包含 [$3]，实际 [$2])"; fi; }
assert_hasnt() { if [[ "$2" == *"$3"* ]]; then bad "$1 (不该包含 [$3]，实际 [$2])"; else ok "$1"; fi; }

SRC="${CHECK_SRC:-${REPO}/core/check.sh}"
ITEMS="${SB}/items"          # 桩件 _health_item 的落点 (skip 不落盘, 只打印)
CRON_LIST="${SB}/cron.list"  # 存在即模拟 `crontab -l` 有输出
NOW_TS='1000000'             # 桩件 date 给出的"当前时间"
CERT_TS=''                   # 桩件 date -d 给出的证书到期时间
HAS_CRONTAB=1                # 0 = 模拟本机没有 crontab 命令
HAS_JQ=0                     # 1 = 走读配置分支 (本用例不需要, 保持 0 走 else)

# ---------------------------------------------------------------------------
# 桩件 (必须在 eval 之前定义)
#   CUR_FILE 由下方 eval 注入的真实函数体在 ".${CUR_FILE}.health.*" 里展开, shellcheck
#   的数据流分析不跨 eval, 故需独自前置的 disable (与 ssl_cron_guard_test.sh 同)。
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
readonly CUR_FILE='check'
_i18n() { printf 'I18N[%s]' "${1:-}"; }
_health_section() { :; }
# 与真实实现同语义: skip 只打印、不计数 —— 否则"不适用"会污染结论统计,
# 也就测不出 T1/T5 的 skip 是不是真 skip。
_health_item() {
    if [[ "${1:-}" == 'skip' ]]; then
        printf 'SKIP %s\n' "${2:-}"
        return 0
    fi
    printf '%s|%s\n' "${1:-}" "${2:-}" >>"${ITEMS}"
}
cmd_exists() {
    case "${1:-}" in
    crontab)  [[ "${HAS_CRONTAB}" == 1 ]] ;;
    jq)       [[ "${HAS_JQ}" == 1 ]] ;;
    openssl)  return 0 ;;
    *)        return 1 ;;
    esac
}
crontab() {
    [[ "${1:-}" == '-l' ]] || return 2
    if [[ -f "${CRON_LIST}" ]]; then
        cat "${CRON_LIST}"
        return 0
    fi
    return 1     # 真实 crontab 在无条目时也是非 0 退出
}
openssl() { printf 'notAfter=stub\n'; }
date() {
    if [[ "${1:-}" == '-d' ]]; then
        printf '%s\n' "${CERT_TS}"    # 证书到期时间
    else
        printf '%s\n' "${NOW_TS}"     # 当前时间
    fi
}

# 被测函数体用到的父函数采集变量
# 注: cfg_cdn / custom_doms 不在此预置 —— 被测函数体自己会给它们赋值 (两个分支都赋),
# 这里预置反而会掩盖"set -u 下少赋一个"的问题。
# 下面这条 disable 必须**独自前置且紧贴**目标行: 写到行尾触发 SC1126, 隔一行也无效
# (只作用到紧邻的下一行)。另: 注释正文千万别以 "# shellcheck " 开头, 会被当指令解析。
# shellcheck disable=SC2034
SCRIPT_CONFIG_PATH="${SB}/nope.json"   # 不存在 -> 走 else 分支, 不读 jq
cert_dir="${SB}/certs"
cfg_domain='a.example.com'
export HOME="${SB}/home"

# 两个阈值**从被测源抽取**, 不在本文件另写一份: 否则源码把阈值改没了 (比如改成 0),
# 测试仍拿自己的 21 去算, "跌进续期窗口"这一档整个消失也照样全绿 —— 这正是 NEG1
# 要防的恒绿。抽不到就显式失败, 不要让测试带着默认值蒙混过去。
thr_warn="$(grep -m1 -E '^[[:space:]]*local cert_warn_days=' "${SRC}" || true)"
thr_win="$(grep -m1 -E '^[[:space:]]*local cert_renew_window_days=' "${SRC}" || true)"
if [[ -z "${thr_warn}" || -z "${thr_win}" ]]; then
    printf '  [FAIL] 未能从 %s 抽取证书阈值常量 (cert_warn_days / cert_renew_window_days)\n' "${SRC}"
    exit 1
fi
eval "$(printf '%s\n%s\n' "${thr_warn}" "${thr_win}" | sed 's/^[[:space:]]*//; s/^local //')"

extract_fn() {
    awk -v fn="$1" 'index($0, "function " fn "() {") == 1 {f=1} f {print} f && /^}/ {exit}' "${SRC}"
}
eval "$(extract_fn _health_certs)"

# ---------------------------------------------------------------------------
# 辅助
# ---------------------------------------------------------------------------
run_certs() { : >"${ITEMS}"; _health_certs 2>&1; }
items() { cat "${ITEMS}" 2>/dev/null; }
# $1=剩余天数 (可为负); 顺便把证书文件造出来
set_days() {
    CERT_TS="$((NOW_TS + $1 * 86400))"
    mkdir -p "${cert_dir}/${cfg_domain}"
    : >"${cert_dir}/${cfg_domain}/fullchain.pem"
}
install_acme() {
    mkdir -p "${HOME}/.acme.sh"
    : >"${HOME}/.acme.sh/acme.sh"
    chmod +x "${HOME}/.acme.sh/acme.sh"
}

# ---------------------------------------------------------------------------
echo "[A] 自动续期定时任务项"
# ---------------------------------------------------------------------------
echo "[T1] 未装 acme.sh -> skip 且不计入结论"
rm -rf "${HOME}/.acme.sh"
set_days 60
out="$(run_certs)"
assert_has "T1: 不适用时打 skip" "${out}" "SKIP I18N[.check.health.cert_cron_label]I18N[.check.health.cert_cron_na]"
assert_hasnt "T1b: skip 不进结论统计" "$(items)" "cert_cron"

echo "[T2] 已装 + 定时任务就位 -> pass"
install_acme
printf '%s\n' '17 3 * * * "/root/.acme.sh"/acme.sh --cron --home "/root/.acme.sh" > /dev/null' >"${CRON_LIST}"
run_certs >/dev/null
assert_has "T2: 就位记 pass" "$(items)" "pass|I18N[.check.health.cert_cron_label]I18N[.check.health.present]"

echo "[T3] 已装 + 完全没有定时任务 -> warn"
rm -f "${CRON_LIST}"
run_certs >/dev/null
assert_has "T3: 缺失时告警 (不静默)" "$(items)" "warn|I18N[.check.health.cert_cron_label]I18N[.check.health.cert_cron_missing]"

echo "[T3b] 有别的定时任务但没有 acme 那条 -> warn"
printf '%s\n' '0 4 * * * /usr/local/bin/backup.sh' >"${CRON_LIST}"
run_certs >/dev/null
assert_has "T3b: 有 crontab 不等于续期已安排" "$(items)" "I18N[.check.health.cert_cron_missing]"

echo "[T4] 只有注释行含 acme.sh --cron -> warn (注释不算就位)"
printf '%s\n' '# 备忘: ~/.acme.sh/acme.sh --cron 每天跑一次' >"${CRON_LIST}"
run_certs >/dev/null
assert_has "T4: 注释行不被当成定时任务" "$(items)" "I18N[.check.health.cert_cron_missing]"
assert_hasnt "T4b: 也确实没记 pass" "$(items)" "pass|I18N[.check.health.cert_cron_label]"

echo "[T5] 本机没有 crontab -> skip"
HAS_CRONTAB=0
out="$(run_certs)"
assert_has "T5: 环境不支持定时 -> 不适用" "${out}" "SKIP I18N[.check.health.cert_cron_label]I18N[.check.health.cert_cron_nocrontab]"
HAS_CRONTAB=1
rm -f "${CRON_LIST}"

# ---------------------------------------------------------------------------
echo "[B] 剩余天数分级"
# ---------------------------------------------------------------------------
echo "[T6] 剩余 30 天 -> pass"
set_days 30
run_certs >/dev/null
assert_has "T6: 正常天数记 pass" "$(items)" "pass|I18N[.check.health.cert_label]a.example.com"
assert_hasnt "T6b: 不报 stalled" "$(items)" "cert_renew_stalled"

echo "[T7] 剩余 10 天 -> warn stalled"
set_days 10
run_certs >/dev/null
assert_has "T7: 跌进续期窗口 -> 自动续期疑似未生效" "$(items)" "warn|I18N[.check.health.cert_label]a.example.com —— I18N[.check.health.cert_days]10 —— I18N[.check.health.cert_renew_stalled]"

echo "[T8] 剩余 3 天 -> warn expiring, 不重复报 stalled"
set_days 3
run_certs >/dev/null
assert_has "T8: 即将到期档位" "$(items)" "I18N[.check.health.cert_expiring]"
assert_hasnt "T8b: 两档互斥, 一个域名只出一条" "$(items)" "cert_renew_stalled"

echo "[T9] 已过期 -> fail"
set_days -1
run_certs >/dev/null
assert_has "T9: 过期记 fail" "$(items)" "fail|I18N[.check.health.cert_label]a.example.com —— I18N[.check.health.cert_expired]"

echo "[T10] 证书文件缺失 -> fail"
rm -rf "${cert_dir:?}/${cfg_domain}"
run_certs >/dev/null
assert_has "T10: 缺文件记 fail" "$(items)" "fail|I18N[.check.health.cert_label]a.example.com —— I18N[.check.health.cert_missing]"

# ---------------------------------------------------------------------------
echo "[C] i18n: 新增键在 zh/en 均存在且非空"
# ---------------------------------------------------------------------------
for key in cert_cron_label cert_cron_na cert_cron_nocrontab cert_cron_missing cert_renew_stalled; do
    zh="$(jq -r ".check.health.\"${key}\" // empty" "${REPO}/i18n/zh.json" 2>/dev/null)"
    en="$(jq -r ".check.health.\"${key}\" // empty" "${REPO}/i18n/en.json" 2>/dev/null)"
    assert_eq "T11: zh 有 ${key} 且非空" "$([[ -n "${zh}" ]] && echo y || echo n)" "y"
    assert_eq "T11: en 有 ${key} 且非空" "$([[ -n "${en}" ]] && echo y || echo n)" "y"
done

# ---------------------------------------------------------------------------
# NEG: 把改动改坏, 确认上面的 ok 不是恒绿
# ---------------------------------------------------------------------------
if [[ -z "${SKIP_NEG:-}" ]]; then
    echo "[NEG] 负向校验"
    # NEG1: 阈值改成 0 —— "跌进续期窗口"这一档直接消失, T7 必须红
    neg="${SB}/broken1.sh"
    sed 's/cert_renew_window_days=21/cert_renew_window_days=0/' "${SRC}" >"${neg}"
    if cmp -s "${SRC}" "${neg}"; then
        bad "NEG1: 变异未落地 (阈值常量没匹配上), 校验无意义"
    elif CHECK_SRC="${neg}" SKIP_NEG=1 bash "$0" 2>&1 | grep -q '^  FAIL T7'; then
        ok "NEG1: 阈值改坏后 T7 判红"
    else
        bad "NEG1: 阈值改坏后 T7 仍绿 -> 守卫失效 (恒绿)"
    fi

    # NEG2: 去掉滤注释那一步 —— 手抄的注释会被当成"已就位", T4 必须红
    neg="${SB}/broken2.sh"
    sed "s#| grep -v '\^\[\[:space:\]\]\*\#' ##" "${SRC}" >"${neg}"
    if cmp -s "${SRC}" "${neg}"; then
        bad "NEG2: 变异未落地 (滤注释的 grep 没匹配上), 校验无意义"
    elif CHECK_SRC="${neg}" SKIP_NEG=1 bash "$0" 2>&1 | grep -q '^  FAIL T4'; then
        ok "NEG2: 去掉滤注释后 T4 判红"
    else
        bad "NEG2: 去掉滤注释后 T4 仍绿 -> 守卫失效 (恒绿)"
    fi

    # NEG3: 判据退化成"crontab 里有任何内容就算就位" —— T3b 必须红
    if command -v python3 >/dev/null 2>&1; then
        neg="${SB}/broken3.sh"
        python3 - "${SRC}" "${neg}" <<'PY'
import sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
old = """        if [[ "${cron_txt}" == *'acme.sh --cron'* ]]; then"""
new = """        if [[ -n "${cron_txt}" ]]; then"""
assert old in src, 'anchor not found'
pathlib.Path(sys.argv[2]).write_text(src.replace(old, new, 1))
PY
        if [[ $? -ne 0 ]]; then
            bad "NEG3: 变异未落地 (判据行没匹配上), 校验无意义"
        elif CHECK_SRC="${neg}" SKIP_NEG=1 bash "$0" 2>&1 | grep -q '^  FAIL T3b'; then
            ok "NEG3: 判据退化后 T3b 判红"
        else
            bad "NEG3: 判据退化后 T3b 仍绿 -> 守卫失效 (恒绿)"
        fi
    else
        printf '  skip NEG3 (缺 python3, 无法构造改坏副本)\n'
    fi
fi

echo
if [[ ${fail} -eq 0 ]]; then
    echo "==== health_cert_renew_test: 全部通过 ===="
else
    echo "==== health_cert_renew_test: 存在失败 ===="
fi
exit "${fail}"
