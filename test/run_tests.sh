#!/usr/bin/env bash
#
# 测试入口: 依次执行 test/*_test.sh 并汇总, 生成可读报告。
#
# 为什么需要它: CI 的门禁原先只有"语法 + ShellCheck"这类静态检查, 没有任何行为验证。
# 上一批给订阅加"遍历全部入站"时, 两个真 bug (fallback/sni 漏收末节点、误删首节点预填)
# 全靠临时驱动才抓到, 而临时驱动跑完就删了, 下次重构无法复现。本目录把这些断言固化下来,
# 由 .github/workflows/shellcheck.yml 的 "行为测试" 步骤执行。
#
# 用法:
#   bash test/run_tests.sh            # 全量
#   bash test/run_tests.sh <关键字>   # 只跑文件名含关键字的用例
#   TEST_REPORT=/tmp/r.txt bash test/run_tests.sh   # 指定报告落点
#
# 退出码: 0=全部通过, 1=有用例失败(或没匹配到用例)。ci-local.sh 与 CI 均只依赖此语义。
#
# 报告: 默认落在 .workbuddy/tmp/test-report.txt (仓库约定: 临时产物不进项目根)。
#   含每个用例的耗时、汇总通过率与总耗时、失败明细(用例名 + 期望/实际)。
#   用例级通过率口径说明见 test/README.md —— 断言级通过率由各用例自行汇总打印。
#
# 依赖: bash(5.0+, 取 EPOCHREALTIME 计时), jq, awk, base64 (Linux CI 均自带)。
#       Windows/MSYS 下若 jq 不在 /usr/bin 内, 用 XRAY_TEST_SHIM=<jq所在目录> 指路。
set -Eeuo pipefail

TEST_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
FILTER="${1:-}"

# 报告落点: 默认 .workbuddy/tmp/ (不污染项目根), 可用 TEST_REPORT 覆盖
REPORT="${TEST_REPORT:-${TEST_DIR}/../.workbuddy/tmp/test-report.txt}"
mkdir -p "$(dirname -- "${REPORT}")"
: >"${REPORT}"

ran=0
failed=0
failed_names=''
durations=''

# 计时: EPOCHREALTIME 是 bash 5.0+ 特性; 老 bash 退化为 0, 报告里会显示 0.000s
now() { printf '%s' "${EPOCHREALTIME:-0}"; }
elapsed() { # $1=起点 $2=终点
    awk -v a="${1}" -v b="${2}" 'BEGIN{printf "%.3f", (b-a)}'
}

total_start="$(now)"
tmp_dir="$(dirname -- "${REPORT}")"
cur_log="${tmp_dir}/.run_tests.cur.$$"
fail_log="${tmp_dir}/.run_tests.fail.$$"
: >"${fail_log}"
trap 'rm -f "${cur_log}" "${fail_log}"' EXIT

{
    printf '================ 测试报告 ================\n'
    printf '开始时间: %s\n' "$(date '+%F %T %Z')"
    printf '过滤条件: %s\n' "${FILTER:-无(全量)}"
    printf '运行环境: TEST_PROFILE=%s\n' "${TEST_PROFILE:-local}"
} >>"${REPORT}"

for t in "${TEST_DIR}"/*_test.sh; do
    [[ -f "${t}" ]] || continue
    name="$(basename -- "${t}")"
    if [[ -n "${FILTER}" && "${name}" != *"${FILTER}"* ]]; then
        continue
    fi
    ran=$((ran + 1))
    printf '\n=== %s ===\n' "${name}"

    t0="$(now)"
    : >"${cur_log}"
    rc=0
    # 必须接住退出码且不中断汇总: 用 || 兜住, 并从 PIPESTATUS[0] 取**被测用例**的 rc
    # (直接 $? 取到的是 tee 的, 恒为 0, 会把失败全部漏掉)
    bash "${t}" 2>&1 | tee -a "${REPORT}" "${cur_log}" || rc="${PIPESTATUS[0]}"
    t1="$(now)"
    d="$(elapsed "${t0}" "${t1}")"
    durations="${durations}${d} ${name}"$'\n'

    printf '耗时: %ss\n' "${d}" >>"${REPORT}"
    if [[ "${rc}" -ne 0 ]]; then
        printf '>>> %s 失败 (rc=%d)\n' "${name}" "${rc}"
        failed=$((failed + 1))
        failed_names="${failed_names} ${name}"
        # 收集该用例内部的 [FAIL] 明细行 (用例名/期望/实际), 便于在汇总里直接看到原因
        {
            printf -- '--- 失败明细: %s ---\n' "${name}"
            if grep -q 'FAIL' "${cur_log}" 2>/dev/null; then
                grep -E 'FAIL' "${cur_log}"
            else
                printf '(用例未输出含 FAIL 的明细行, 仅以退出码 %d 失败)\n' "${rc}"
            fi
        } >>"${fail_log}"
    fi
done

total_end="$(now)"
total_d="$(elapsed "${total_start}" "${total_end}")"
passed=$((ran - failed))

sum=$(cat <<EOF

================ 汇总 ================
用例: ${ran}, 通过: ${passed}, 失败: ${failed}
用例通过率: $(awk -v p="${passed}" -v t="${ran}" 'BEGIN{printf "%.1f", (p*100)/t}')%
总耗时: ${total_d}s
耗时最长 Top5:
$(printf '%s' "${durations}" | sort -rn | head -5 | awk 'NF>=2{printf "  %8ss  %s\n", $1, $2}')
EOF
)
if [[ "${ran}" -eq 0 ]]; then
    printf '\n================ 汇总 ================\n'
    printf '未找到匹配的用例 (过滤: %s)\n' "${FILTER:-无}"
    printf '报告: %s\n' "${REPORT}"
    exit 1
fi
printf '%s\n' "${sum}"
printf '%s\n' "${sum}" >>"${REPORT}"

if [[ -s "${fail_log}" ]]; then
    printf '\n---- 失败明细 ----\n'
    cat "${fail_log}"
    printf '\n---- 失败明细 ----\n' >>"${REPORT}"
    cat "${fail_log}" >>"${REPORT}"
fi
printf '报告文件: %s\n' "${REPORT}"

[[ "${failed}" -eq 0 ]] || exit 1
printf '全部通过\n'
