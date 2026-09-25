#!/usr/bin/env bash
#
# 共享测试工具库 (test/_harness.sh) —— 供 test/*_test.sh 复用, 不直接执行。
#
# 为什么需要它:
#   本目录已有 80 个用例, 而 ok/bad 被重复定义了 37 次、assert_eq 被重复定义了 36 次 ——
#   每个文件各抄一份, 于是"失败信息里期望/实际标反"这类问题只能逐个文件发现
#   (历史上一处标反排查方向被带偏过一次)。新增用例统一从这里 source, 不再各自抄。
#
# 存量用例**不强制迁移**: 它们已各自稳定且带自己的负向校验, 批量改动风险大于收益;
#   harness 只保证**新增**用例有一致的行为与输出格式。
#
# 约定 (与全仓一致, 不要改):
#   h_assert_eq <标签> <实际值> <期望值>   —— 第 2 参是实际, 第 3 参是期望。
#   反着写也能跑通 (值相等时不显形), 但跨文件复制会静默反接, 失败时才暴露,
#   而那时失败的"期望/实际"标注也是反的, 排查方向直接被带偏。
#
# 用法:
#   source "$(dirname "$0")/_harness.sh"
#   h_init 'my_test'
#   h_case 'T1 正常流程'
#   h_assert_eq 'T1 端口' "$(got)" '443'
#   h_finish
#
# 输出: 每条断言一行; 末尾打印通过率与耗时; 有失败则退出 1 (供 run_tests.sh 汇总)。
set -Eeuo pipefail

# --- 集中配置 ---------------------------------------------------------------
# 所有路径/地址/账号/超时统一在 test/config.env 里改, 不散落到各用例。
_harness_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly _harness_dir
# shellcheck source=config.env
if [[ -f "${_harness_dir}/config.env" ]]; then
    # shellcheck disable=SC1091  # 运行期按 TEST_PROFILE 组装, 静态检查看不到
    source "${_harness_dir}/config.env"
fi

# --- 计数器与计时 -----------------------------------------------------------
H_PASS=0
H_FAIL=0
H_SKIP=0
H_START=0
H_NAME=''
readonly H_START_EPOCH="${EPOCHREALTIME:-0}"

# 初始化: 记录用例名与起始时刻
h_init() {
    H_NAME="${1:-$(basename -- "$0")}"
    H_PASS=0
    H_FAIL=0
    H_SKIP=0
    H_START="${EPOCHREALTIME:-0}"
    printf '### %s\n' "${H_NAME}"
}

# 场景分组标题 —— 让输出能按"模块/场景"读, 而不是一长串断言
h_case() { printf '\n--- %s ---\n' "$1"; }

# --- 断言 -------------------------------------------------------------------
# 所有失败信息统一格式: [FAIL] 用例名 | 标签 | 期望: X | 实际: Y
# (用例名必须带上: run_tests.sh 汇总时只看退出码, 定位靠这一行)

# 相等: $2=实际 $3=期望
h_assert_eq() {
    if [[ "$2" == "$3" ]]; then
        H_PASS=$((H_PASS + 1)); printf '  ok   %s\n' "$1"
    else
        H_FAIL=$((H_FAIL + 1))
        printf '  FAIL %s\n       [FAIL] %s | %s | 期望: [%s] | 实际: [%s]\n' \
            "$1" "${H_NAME}" "$1" "$3" "$2"
    fi
}

# 不等: 用于"改坏后必须变化"的负向校验
h_assert_ne() {
    if [[ "$2" != "$3" ]]; then
        H_PASS=$((H_PASS + 1)); printf '  ok   %s\n' "$1"
    else
        H_FAIL=$((H_FAIL + 1))
        printf '  FAIL %s\n       [FAIL] %s | %s | 不应等于: [%s]\n' \
            "$1" "${H_NAME}" "$1" "$3"
    fi
}

# 包含子串
h_assert_contains() {
    if [[ "$2" == *"$3"* ]]; then
        H_PASS=$((H_PASS + 1)); printf '  ok   %s\n' "$1"
    else
        H_FAIL=$((H_FAIL + 1))
        printf '  FAIL %s\n       [FAIL] %s | %s | 未包含: [%s] | 实际: [%s]\n' \
            "$1" "${H_NAME}" "$1" "$3" "$2"
    fi
}

# 不含子串
h_assert_not_contains() {
    if [[ "$2" != *"$3"* ]]; then
        H_PASS=$((H_PASS + 1)); printf '  ok   %s\n' "$1"
    else
        H_FAIL=$((H_FAIL + 1))
        printf '  FAIL %s\n       [FAIL] %s | %s | 不应包含: [%s] | 实际: [%s]\n' \
            "$1" "${H_NAME}" "$1" "$3" "$2"
    fi
}

# 退出码: $2=实际 rc, $3=期望 rc
h_assert_rc() {
    if [[ "$2" == "$3" ]]; then
        H_PASS=$((H_PASS + 1)); printf '  ok   %s (rc=%s)\n' "$1" "$2"
    else
        H_FAIL=$((H_FAIL + 1))
        printf '  FAIL %s\n       [FAIL] %s | %s | 期望 rc: [%s] | 实际 rc: [%s]\n' \
            "$1" "${H_NAME}" "$1" "$3" "$2"
    fi
}

# 布尔条件: $2 为 0 视为真。用于"文件存在 / 命令成功"这类判断
h_assert_ok() {
    if [[ "$2" -eq 0 ]]; then
        H_PASS=$((H_PASS + 1)); printf '  ok   %s\n' "$1"
    else
        H_FAIL=$((H_FAIL + 1))
        printf '  FAIL %s\n       [FAIL] %s | %s | 期望成立, 实际不成立\n' \
            "$1" "${H_NAME}" "$1"
    fi
}

# 跳过: 环境不具备时**必须显式登记**, 否则"没跑"和"跑了通过"看起来一样
h_skip() {
    H_SKIP=$((H_SKIP + 1))
    printf '  SKIP %s (%s)\n' "$1" "${2:-原因未给出}"
}

# --- 沙箱 -------------------------------------------------------------------
# 每个用例一个独立目录, 退出时自动清理。用固定 $$ 后缀而非 mktemp:
# 本仓库约定临时产物一律落在 .workbuddy/tmp/, 且 $$ 便于失败后按 PID 找回现场。
h_sandbox() {
    H_SANDBOX="${TEST_TMP_DIR:-${_harness_dir}/../.workbuddy/tmp}/h.$(basename -- "$0" .sh).$$"
    rm -rf "${H_SANDBOX}"
    mkdir -p "${H_SANDBOX}"
    # shellcheck disable=SC2064  # 必须现在展开: $$ 与路径在 trap 时已不可靠
    trap "rm -rf '${H_SANDBOX}'" EXIT
    printf '%s' "${H_SANDBOX}"
}

# 造一个 PATH shim: h_stub <名字> <<'SH' ... SH
# 被 stub 的命令会记录调用到 ${H_SANDBOX}/<名字>.calls, 便于断言"真的被调用了"
h_stub() {
    local name="$1" body
    body="$(cat)"
    mkdir -p "${H_SANDBOX}/bin"
    {
        printf '#!/usr/bin/env bash\n'
        printf "printf '%%s\\n' \"\$*\" >>'${H_SANDBOX}/${name}.calls'\n"
        printf '%s\n' "${body}"
    } >"${H_SANDBOX}/bin/${name}"
    chmod +x "${H_SANDBOX}/bin/${name}"
    export PATH="${H_SANDBOX}/bin:${PATH}"
}

# --- 汇总 -------------------------------------------------------------------
# 打印通过率与耗时, 并按"有失败则非 0"退出 —— run_tests.sh 依赖这个退出码
h_finish() {
    local total elapsed
    total=$((H_PASS + H_FAIL + H_SKIP))
    elapsed="$(h_elapsed "${H_START}")"
    printf '\n---- %s 汇总 ----\n' "${H_NAME}"
    printf '断言: %d, 通过: %d, 失败: %d, 跳过: %d\n' \
        "${total}" "${H_PASS}" "${H_FAIL}" "${H_SKIP}"
    # 通过率按"已判定"的算, 跳过的不计入分母 —— 否则环境缺依赖会把通过率拉低,
    # 掩盖真实回归
    if [[ $((H_PASS + H_FAIL)) -gt 0 ]]; then
        printf '通过率: %.1f%%\n' "$(awk -v p="${H_PASS}" -v f="${H_FAIL}" \
            'BEGIN{printf "%.1f", (p*100)/(p+f)}')"
    fi
    printf '耗时: %ss\n' "${elapsed}"
    [[ "${H_FAIL}" -eq 0 ]] || return 1
    return 0
}

# 耗时(秒, 三位小数)。EPOCHREALTIME 在 bash 5.0+ 才有, 老版本退化为 0
h_elapsed() {
    local from="${1:-${H_START_EPOCH}}"
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        awk -v a="${from}" -v b="${EPOCHREALTIME}" 'BEGIN{printf "%.3f", b-a}'
    else
        printf '0.000'
    fi
}
