#!/usr/bin/env bash
# =============================================================================
# 测试名称: os_detect_sync_test.sh
# 测试目标: install.sh 与 core/_common.sh 各自保有一份 _os / _os_full / _os_ver /
#           _gh_url / _atomic_write / cmd_exists 的完整副本 (install.sh 必须单文件
#           自包含, 运行时仓库尚不存在, 无法 source _common.sh)。这种不可避免的复制
#           最大的风险是"功能漂移" —— 一侧修了逻辑、另一侧忘了同步。本测试把这两份
#           实现的"代码体"静态锁定为一致, 任一侧改动函数逻辑而未同步另一侧时立刻报错。
# 注: 仅比对去掉注释/空行后的代码体, 容忍两侧注释措辞差异 —— 包括**行尾注释**
#     (如 _atomic_write 的 `local tmp_path=''      # 临时文件路径` 只存在于 _common.sh,
#      若不剥行尾注释会误报漂移); 一旦代码逻辑本身出现分叉, 本测试即失败, 强制同步。
# 注2: load_i18n **刻意不同源**, 不在本测试范围内: install.sh 版自带 I18N_DATA 数组
#      (运行当时尚无 i18n JSON 可读), _common.sh 版从 i18n/<lang>.json 构建 I18N_MAP,
#      两者本就是两套实现, 把它纳入会永久常红。
# =============================================================================
set -u

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
INSTALL="$ROOT/install.sh"
COMMON="$ROOT/core/_common.sh"

pass=0; fail=0
ok(){ if [[ $1 -eq 0 ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

# 抽取函数体并归一化: 去注释行 + 去行尾注释 + 去空行 (保留代码结构)
# 行尾注释必须用"至少一个空白"再接 #, 不能写成 [[:space:]]*# —— 后者允许零个空白,
# 会误伤 ${#arr[@]} 这类取长度语法 (# 前是 '{' 而非空白);
# 且用 POSIX BRE 的 [[:space:]][[:space:]]* 而非 GNU 的 \+, 兼容 BSD/Git-Bash sed。
extract_norm() { # $1=funcname $2=file -> stdout
    awk "/^function ${1}\\(\) \\{/{f=1} f{print} f&&/^\\}/{exit}" "$2" \
        | grep -v '^[[:space:]]*#' \
        | sed 's/[[:space:]][[:space:]]*#.*$//' \
        | grep -v '^[[:space:]]*$'
}

for fn in _os _os_full _os_ver _gh_url _atomic_write cmd_exists; do
    ia="$(extract_norm "$fn" "$INSTALL")"
    ca="$(extract_norm "$fn" "$COMMON")"
    if [[ -z "$ia" || -z "$ca" ]]; then
        fail=$((fail+1))
        echo "[FAIL] $fn 在 install.sh 或 _common.sh 中未找到 (抽取为空)"
        continue
    fi
    if diff -w <(printf '%s\n' "$ia") <(printf '%s\n' "$ca") >/dev/null; then
        ok 0; echo "[T] $fn: install.sh 与 _common.sh 代码体一致"
    else
        ok 1
        echo "[FAIL] $fn: install.sh 与 _common.sh 实现已漂移, 请同步两侧 (仅注释差异不会触发本失败)"
        diff -w <(printf '%s\n' "$ia") <(printf '%s\n' "$ca") | sed 's/^/    /'
    fi
done

echo "==== os_detect_sync_test: PASS=$pass FAIL=$fail ===="
[[ $fail -eq 0 ]]
