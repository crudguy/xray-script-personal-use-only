#!/usr/bin/env bash
#
# 测试入口: 依次执行 test/*_test.sh 并汇总。
#
# 为什么需要它: CI 的门禁原先只有"语法 + ShellCheck"这类静态检查, 没有任何行为验证。
# 上一批给订阅加"遍历全部入站"时, 两个真 bug (fallback/sni 漏收末节点、误删首节点预填)
# 全靠临时驱动才抓到, 而临时驱动跑完就删了, 下次重构无法复现。本目录把这些断言固化下来,
# 由 .github/workflows/shellcheck.yml 的 "行为测试" 步骤执行。
#
# 用法:
#   bash test/run_tests.sh            # 全量
#   bash test/run_tests.sh <关键字>   # 只跑文件名含关键字的用例
#
# 依赖: bash, jq, awk, base64 (Linux CI 均自带)。Windows/MSYS 下若 jq 不在
#       /usr/bin 内, 用 XRAY_TEST_SHIM=<jq所在目录> 指路。
set -Eeuo pipefail

TEST_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
FILTER="${1:-}"

ran=0
failed=0
failed_names=''

for t in "${TEST_DIR}"/*_test.sh; do
    [[ -f "${t}" ]] || continue
    name="$(basename "${t}")"
    if [[ -n "${FILTER}" && "${name}" != *"${FILTER}"* ]]; then
        continue
    fi
    ran=$((ran + 1))
    printf '\n=== %s ===\n' "${name}"
    rc=0
    # 用例自行判定成败并 return 退出码; 这里必须接住, 不能让 set -e 提前结束汇总
    bash "${t}" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        printf '>>> %s 失败 (rc=%d)\n' "${name}" "${rc}"
        failed=$((failed + 1))
        failed_names="${failed_names} ${name}"
    fi
done

printf '\n================ 汇总 ================\n'
if [[ "${ran}" -eq 0 ]]; then
    printf '未找到匹配的用例 (过滤: %s)\n' "${FILTER:-无}"
    exit 1
fi
printf '用例: %d, 失败: %d\n' "${ran}" "${failed}"
if [[ "${failed}" -ne 0 ]]; then
    printf '失败用例:%s\n' "${failed_names}"
    exit 1
fi
printf '全部通过\n'
