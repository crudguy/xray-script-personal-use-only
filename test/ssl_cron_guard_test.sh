#!/usr/bin/env bash
# =============================================================================
# test/ssl_cron_guard_test.sh — acme.sh 自动续期定时任务自检的守卫
#
# 守护的事实:
#   acme.sh 安装时会自己写 crontab, 但它**吞掉失败** —— 3.1.6 里 install 主流程是
#       if [ -z "$_nocron" ]; then installcronjob "$_c_home"; fi      (acme.sh:8246)
#   没有 || return; 而 installcronjob 在无 crontab 时 `_err ...; return 1`
#   (acme.sh:7510-7513)。于是"装失败"和"装成功"对外同码, 上层无从分辨 —— 用户以为
#   配好了自动续期, 实际证书 90 天后过期且无人知晓。
#   本项目此前完全依赖它、从不校验。故 ssl.sh 补了 _ssl_renew_cron_present /
#   _ssl_ensure_renew_cron, 本文件守护"这套自检真的在、且真的会响"。
#
# 做法: 抽**真实函数体** + eval 注入, 桩件替代 _common.sh 注入的函数。
#   不 source core/_common.sh —— 它的 ERR trap 是 exit, 落在宿主脚本上会让被测的
#   失败路径把整个测试脚本带走 (与 test/ssl_test.sh 同源的选型)。
#   桩件先定义再 eval, 顺序反了会触发 SC2218。
#
# 覆盖:
#   T1  定时任务已就位 -> 静默 (不产生告警)
#   T2  缺失但补装成功 -> 自愈, 不告警, 且补装后判定为已就位
#   T3  缺失且补装失败 -> 明确告警 + 给出手动补救命令
#   T4  本机没有 crontab -> 告警, 且**不**尝试补装 (补了也没用)
#   T5  _ssl_renew_cron_present 三态单测 (就位 / 缺失 / 无 crontab)
#   T6  i18n: .ssl.cron.* 与 .ssl.check_cron.present 在 zh/en 均存在且非空
#   T7  静态: install_acme_sh 两个出口都调了 _ssl_ensure_renew_cron
#   T8  静态: check_cron_jobs 真的会查 crontab (不再只是跑一次 --cron)
#   NEG1 去掉 install_acme_sh 里的自检调用 -> T7 必须变红
#   NEG2 去掉 check_cron_jobs 里的查询 -> T8 必须变红
# =============================================================================

set -u

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
# 放 /tmp 而非 .workbuddy/tmp: 后者在本机受 safe-delete 钩子管辖, 清理时会打一串
# genie-trash 报错污染输出 (与被测行为无关)。ssl_test.sh 同选型。
SB="/tmp/ssl-cron-guard.$$"
rm -rf "${SB}"
mkdir -p "${SB}/home/.acme.sh"
trap 'rm -rf "${SB}"' EXIT

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
# 参数顺序沿用全仓约定: $1=msg $2=实际 $3=期望 (写反了值相等时不显形, 只在失败时
# 把排查方向带偏 —— 见 test/share_common_config_test.sh 的同名教训)
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (期望 [$3] 实际 [$2])"; fi; }
assert_has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (未包含 [$3]，实际 [$2])"; fi; }
assert_hasnt() { if [[ "$2" == *"$3"* ]]; then bad "$1 (不该包含 [$3]，实际 [$2])"; else ok "$1"; fi; }

SRC="${SSL_SRC:-${REPO}/service/ssl.sh}"

# ---------------------------------------------------------------------------
# 桩件: 替代 core/_common.sh 注入的函数 + 外部命令
# ---------------------------------------------------------------------------
CRON_LIST="${SB}/cron.list"      # 存在且含 'acme.sh --cron' => 定时任务已就位
ACME_CALLS="${SB}/acme.calls"    # acme.sh 桩件的调用留痕
HAS_CRONTAB=1                    # 0 = 模拟本机没有 crontab 命令
# acme.sh 桩件是**独立进程**, 控制开关必须 export 才看得见 (漏掉 export 时桩件走
# 默认的成功分支 —— 于是"补装失败"用例恒绿, 断言从未真正验证过告警路径)
export CRON_LIST ACME_CALLS ACME_CRONJOB_OK

# _common.sh 注入的常量, 由下面 eval 注入的真实函数体在 ".${CUR_FILE}.cron.*" 里展开。
# 写法注意: 下面那条 disable 必须**独自前置且紧贴**目标行 —— 写到行尾触发 SC1126,
# 隔一行也无效 (只作用到紧邻的下一行)。另外注释正文千万别以 "# shellcheck " 开头,
# 那会被当成指令解析并报 SC1073/SC1072。
# shellcheck disable=SC2034
readonly CUR_FILE='ssl'
_i18n() { printf 'I18N[%s]' "${1:-}"; }
print_warn() { printf 'WARN %s\n' "$*"; }
cmd_exists() {
    [[ "${1:-}" == 'crontab' ]] || return 1
    [[ "${HAS_CRONTAB}" == 1 ]]
}
# 模拟 `crontab -l`: 有条目文件时打印并返回 0; 否则返回 1 (真实 crontab 在无条目时
# 也是非 0 退出 —— 被测靠 if 条件接住, 不会把"还没有任何定时任务"当成脚本崩溃)
crontab() {
    [[ "${1:-}" == '-l' ]] || return 2
    if [[ -f "${CRON_LIST}" ]]; then
        cat "${CRON_LIST}"
        return 0
    fi
    return 1
}

cat >"${SB}/home/.acme.sh/acme.sh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${ACME_CALLS}"
if [ "${1:-}" = '--install-cronjob' ]; then
    if [ "${ACME_CRONJOB_OK:-1}" = '1' ]; then
        printf '%s\n' '17 3,9,15,21 * * * "/home/u/.acme.sh"/acme.sh --cron --home "/home/u/.acme.sh" > /dev/null' >"${CRON_LIST}"
        exit 0
    fi
    exit 1
fi
exit 0
STUB
chmod +x "${SB}/home/.acme.sh/acme.sh"
export HOME="${SB}/home"

# --- 注入真实函数体 (桩件必须在 eval 之前定义, 顺序反了 SC2218) ---
extract_fn() {
    awk -v fn="$1" 'index($0, "function " fn "() {") == 1 {f=1} f {print} f && /^}/ {exit}' "${SRC}"
}
eval "$(extract_fn _ssl_renew_cron_present)"
eval "$(extract_fn _ssl_ensure_renew_cron)"

# 返回值捕获: 直接 $? 在 set -u 下可用, 但写成 if 更不容易读错
present_rc() { if _ssl_renew_cron_present >/dev/null 2>&1; then printf '0'; else printf '1'; fi; }

echo "[T1] 定时任务已就位 -> 静默"
printf '%s\n' '17 3,9,15,21 * * * "/home/u/.acme.sh"/acme.sh --cron --home "/home/u/.acme.sh" > /dev/null' >"${CRON_LIST}"
out="$(_ssl_ensure_renew_cron 2>&1)"
assert_hasnt "T1: 已就位时不产生告警" "${out}" "WARN"

echo "[T2] 缺失但补装成功 -> 自愈"
rm -f "${CRON_LIST}" "${ACME_CALLS}"
ACME_CRONJOB_OK=1
out="$(_ssl_ensure_renew_cron 2>&1)"
assert_hasnt "T2: 补装成功后不告警" "${out}" "WARN"
assert_eq "T2b: 补装后判定为已就位" "$(present_rc)" "0"
assert_has "T2c: 确实调用了 --install-cronjob" "$(cat "${ACME_CALLS}" 2>/dev/null)" "--install-cronjob"

echo "[T3] 缺失且补装失败 -> 明确告警"
rm -f "${CRON_LIST}" "${ACME_CALLS}"
ACME_CRONJOB_OK=0
out="$(_ssl_ensure_renew_cron 2>&1)"
assert_has "T3: 补装失败后告警 (不静默)" "${out}" "I18N[.ssl.cron.missing]"
assert_has "T3b: 同时给出手动补救命令" "${out}" "I18N[.ssl.cron.hint]"

echo "[T4] 本机没有 crontab -> 告警且不尝试补装"
rm -f "${CRON_LIST}" "${ACME_CALLS}"
HAS_CRONTAB=0
out="$(_ssl_ensure_renew_cron 2>&1)"
assert_has "T4: 无 crontab 时告警" "${out}" "I18N[.ssl.cron.missing]"
assert_eq "T4b: 不尝试补装 (环境不支持, 补了也没用)" "$(cat "${ACME_CALLS}" 2>/dev/null)" ""
HAS_CRONTAB=1

echo "[T5] _ssl_renew_cron_present 三态"
printf '%s\n' '17 3 * * * "/home/u/.acme.sh"/acme.sh --cron --home "/home/u/.acme.sh" > /dev/null' >"${CRON_LIST}"
assert_eq "T5a: 有 acme.sh --cron 条目 -> 0" "$(present_rc)" "0"
printf '%s\n' '0 4 * * * /usr/local/bin/backup.sh' >"${CRON_LIST}"
assert_eq "T5b: 有 crontab 但无 acme 条目 -> 1" "$(present_rc)" "1"
# 注释行里出现同样的串不算就位: 否则手抄一条备忘就能让自检误判为"已装好" (静默)
printf '%s\n' '# 备忘: ~/.acme.sh/acme.sh --cron 每天跑一次' >"${CRON_LIST}"
assert_eq "T5b2: 仅注释行含 acme.sh --cron -> 1 (不算就位)" "$(present_rc)" "1"
rm -f "${CRON_LIST}"
assert_eq "T5c: 完全无 crontab 条目 -> 1" "$(present_rc)" "1"
HAS_CRONTAB=0
assert_eq "T5d: 无 crontab 命令 -> 1" "$(present_rc)" "1"
HAS_CRONTAB=1

echo "[T6] i18n: 新增键在 zh/en 均存在且非空"
for key in ssl.cron.missing ssl.cron.hint ssl.check_cron.present; do
    zh="$(jq -r "if has(\"ssl\") then .ssl else {} end | .${key#ssl.}" "${REPO}/i18n/zh.json" 2>/dev/null)"
    en="$(jq -r "if has(\"ssl\") then .ssl else {} end | .${key#ssl.}" "${REPO}/i18n/en.json" 2>/dev/null)"
    assert_eq "T6: zh 有 ${key} 且非空" "$([[ -n "${zh}" && "${zh}" != 'null' ]] && echo y || echo n)" "y"
    assert_eq "T6: en 有 ${key} 且非空" "$([[ -n "${en}" && "${en}" != 'null' ]] && echo y || echo n)" "y"
done

# ---------------------------------------------------------------------------
# 静态守卫: 抽真实函数体, 断言"自检真的被调用"
#   —— 只查"函数存在"是不够的: 定义了却不调用, 一样静默
# ---------------------------------------------------------------------------
fn_has_call() { # $1=函数名 $2=调用串 $3=源文件
    awk -v fn="$1" 'index($0, "function " fn "() {") == 1 {f=1} f {print} f && /^}/ {exit}' "${3}" |
        grep -qF -- "${2}"
}

echo "[T7] install_acme_sh 出口都挂了自检"
if fn_has_call install_acme_sh '_ssl_ensure_renew_cron' "${SRC}"; then
    ok "T7: install_acme_sh 调用 _ssl_ensure_renew_cron"
else
    bad "T7: install_acme_sh 未调用 _ssl_ensure_renew_cron (定时任务缺失将再次静默)"
fi

echo "[T8] check_cron_jobs 真的会查 crontab"
if fn_has_call check_cron_jobs '_ssl_renew_cron_present' "${SRC}"; then
    ok "T8: check_cron_jobs 调用 _ssl_renew_cron_present"
else
    bad "T8: check_cron_jobs 未查询 crontab (退化成只跑一次 --cron, 名不副实)"
fi

# ---------------------------------------------------------------------------
# NEG: 把改动改坏, 确认守卫真的会红 (否则上面的 ok 可能只是恒绿)
# ---------------------------------------------------------------------------
if [[ -z "${SKIP_NEG:-}" ]]; then
    echo "[NEG] 负向校验"
    neg="${SB}/broken.sh"
    # NEG1: 去掉 install_acme_sh 里的两处自检调用
    sed '/_ssl_ensure_renew_cron/d' "${SRC}" >"${neg}"
    if fn_has_call install_acme_sh '_ssl_ensure_renew_cron' "${neg}"; then
        bad "NEG1: 去掉自检调用后守卫仍说有 -> 守卫失效 (恒绿)"
    else
        ok "NEG1: 去掉自检调用后守卫判红"
    fi
    # NEG2: 去掉 check_cron_jobs 里的 crontab 查询
    sed '/_ssl_renew_cron_present/d' "${SRC}" >"${neg}"
    if fn_has_call check_cron_jobs '_ssl_renew_cron_present' "${neg}"; then
        bad "NEG2: 去掉查询后守卫仍说有 -> 守卫失效 (恒绿)"
    else
        ok "NEG2: 去掉查询后守卫判红"
    fi

    # NEG3: 把自检实现改成空 -> **行为**断言 (T3/T4) 必须红。
    #   只验证静态守卫不够: 函数被调用了却什么都不做, 一样静默。
    #   (写这条的动因: 早期版本漏了 export ACME_CRONJOB_OK, 桩件恒走成功分支,
    #    "补装失败"路径从未被真正跑到, 断言是绿的但没验证任何东西。)
    if command -v python3 >/dev/null 2>&1; then
        neg3="${SB}/noop.sh"
        python3 - "${SRC}" "${neg3}" <<'PY'
import sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
start = src.index('function _ssl_ensure_renew_cron() {')
end = src.index('\n}\n', start) + 3
pathlib.Path(sys.argv[2]).write_text(src[:start] + 'function _ssl_ensure_renew_cron() {\n    return 0\n}\n' + src[end:])
PY
        if SSL_SRC="${neg3}" SKIP_NEG=1 bash "$0" 2>&1 | grep -q '^  FAIL T3'; then
            ok "NEG3: 自检改成空实现后行为断言判红"
        else
            bad "NEG3: 自检改成空实现后 T3 仍绿 -> 行为断言失效 (恒绿)"
        fi
    else
        printf '  skip NEG3 (缺 python3, 无法构造改坏副本)\n'
    fi
fi

echo
if [[ ${fail} -eq 0 ]]; then
    echo "==== ssl_cron_guard_test: 全部通过 ===="
else
    echo "==== ssl_cron_guard_test: 存在失败 ===="
fi
exit "${fail}"
