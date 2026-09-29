#!/usr/bin/env bash
# =============================================================================
# 测试名称: core_entry_conflict_test.sh
# 测试目标: 守住"两个入口不得被加载进同一个 shell 进程"这条边界。
#
# 为什么需要本测试: 2026-09-26 复审发现 core/main.sh 与 core/handler.sh **各自定义了
#   一个同名 exec_read, 且语义恰恰相反**:
#     - main.sh    `bash read.sh "$@" || true`   —— 取到什么算什么, 空串交给调用方处理;
#     - handler.sh  循环重试 + **EOF 立即失败**, 函数内注释甚至明写"不能用 || true 兜住"。
#   当前**不是 bug**, 仅因 main.sh 用 `bash "${HANDLER_PATH}"` 以**子进程**方式拉起
#   handler.sh —— 两个定义从不在同一进程里共存, 谁也覆盖不了谁。
#
#   但这个安全性是脆弱的: 它不靠任何机制保证, 只靠"目前没人写 source"。一旦有人为了
#   (比如说) 省一次进程启动而改成 source 加载, 后加载者会**静默覆盖**先加载者, 调用方
#   以为自己在跑这一份、实际跑的是另一份 —— 故障形态是"输入校验被悄悄跳过"或"在无 TTY
#   的场景里卡住", 而且完全没有报错、现有用例一条也不会变红。
#
#   本用例把这条边界变成机器判据: 全仓**禁止 source 形式加载这两个入口**。真需要合并时,
#   请先统一函数名再删掉本用例的对应断言, 别直接放宽扫描范围。
#
# 扫描口径:
#   - 只看 source / 点号 这两种加载形式; `bash xxx.sh` 是子进程调用, 合法, 不算;
#   - 目标命中两种写法: 字面路径 (以 handler.sh / main.sh 结尾) 与**指向入口的变量**
#     (${HANDLER_PATH} 等) —— 后者是必要的, 因为 main.sh 里正是经由变量引用 handler.sh;
#   - 无 jq / shellcheck 等外部依赖, 故无 SKIP 分支。
# =============================================================================
set -u

SB=".workbuddy/tmp/core_entry_conflict_sb"
rm -rf "$SB"; mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

pass=0; fail=0
ok() { if [[ $1 -eq 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }

SRC_FILES=()
for f in core/*.sh service/*.sh tool/*.sh install.sh; do [[ -f "$f" ]] && SRC_FILES+=("$f"); done

# ---------------------------------------------------------------------------
# T1 抽取器: 找出所有以 source / 点号 形式加载两个入口的行
# ---------------------------------------------------------------------------
# 写成函数是为 T2 的负向自检复用 —— 自检要证明"它真会报", 不能只验证**没有命中**那一侧
# (这条守卫在正常态下永远为空, 只看为空是典型的恒绿陷阱)。
scan_source_entry() {
    local f='' line='' lineno=0 tok=''
    for f in "${SRC_FILES[@]}"; do
        lineno=0
        while IFS= read -r line; do
            lineno=$((lineno + 1))
            [[ "${line}" =~ ^[[:space:]]*# ]] && continue
            # 取出 source / . 之后的第一个 token 作为加载目标 (支持引号包裹)
            tok="$(printf '%s' "${line}" \
                | sed -nE 's/.*(^|[[:space:]])(source|\.)[[:space:]]+([^[:space:]#]+).*/\3/p')"
            [[ -n "${tok}" ]] || continue
            case "${tok}" in
            *handler.sh* | *main.sh* | *HANDLER_PATH* | *MAIN_PATH*)
                printf '%s:%s: %s\n' "$f" "${lineno}" "$(printf '%s' "${line}" | sed 's/^[[:space:]]*//')"
                ;;
            esac
        done <"$f"
    done
}

conflict="$(scan_source_entry)"

if [[ -z "${conflict}" ]]; then
    ok 0 && echo "[T1] 无脚本以 source / 点号形式加载 core 的两个入口 (扫描 ${#SRC_FILES[@]} 个文件)"
else
    ok 1 && echo "[FAIL T1] 存在 source 形式加载 core 入口 —— 同名 exec_read 会被静默覆盖:"
    printf '%s' "${conflict}" | sed 's/^/        - /' | head -n 20
    echo "        正确做法: 保持子进程调用 (bash xxx.sh), 或先统一两边的函数名。"
fi

# ---------------------------------------------------------------------------
# T2 负向自检: 把 main.sh 的子进程调用改成 source, 抽取器必须把它抓出来
# ---------------------------------------------------------------------------
# 为什么必须自检: 见 T1 抽取器处的说明。这里用**真变异**自证它咬得动, 而不只是跑了一次
#   空扫描。变异后立刻在 T3 还原核对, 不留副作用。
ori="${SB}/main.sh.ori"
cp -f core/main.sh "${ori}"

if ! sed -i 's|bash "\${HANDLER_PATH}" "\$@"|source "${HANDLER_PATH}" "$@"|' core/main.sh; then
    echo "[FAIL T2] sed 变异失败, 自检无法执行"
    ok 1
elif diff -q "${ori}" core/main.sh >/dev/null; then
    echo "[FAIL T2] 变异未落地 (调用写法可能与本用例预期不符) —— 自检无效, 请更新本段"
    ok 1
else
    conflict2="$(scan_source_entry)"
    if printf '%s' "${conflict2}" | grep -q 'core/main.sh:'; then
        ok 0 && echo "[T2] 负向自检通过 (改成 source 形式后能被抽出)"
    else
        ok 1 && echo "[FAIL T2] 负向自检失败 —— 变异已落地却没被报出, T1 可能是恒绿"
    fi
fi
cp -f "${ori}" core/main.sh

# ---------------------------------------------------------------------------
# T3 还原校验: 本用例改过业务文件, 必须自证已经原样放回
# ---------------------------------------------------------------------------
if diff -q "${ori}" core/main.sh >/dev/null; then
    ok 0 && echo "[T3] core/main.sh 已还原 (与改动前逐字节一致)"
else
    ok 1 && echo "[FAIL T3] core/main.sh 未还原 —— 手工恢复或 git checkout 它"
fi

echo "==== core_entry_conflict_test: PASS=$pass FAIL=$fail ===="
rm -rf "$SB"
[[ $fail -eq 0 ]]
