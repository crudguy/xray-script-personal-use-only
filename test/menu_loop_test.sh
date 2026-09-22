#!/usr/bin/env bash
# =============================================================================
# 测试名称: menu_loop_test.sh
# 测试目标: P1-2 主循环 — processes_index 选完一项操作后回到主菜单(支持连续配置),
#           而非退出脚本; 同时验证顶层 EOF / `*` 不会空转 (立即 exit 0)。
# 设计: 桩件化 exec_menu (按队列文件返回预设选择序列) / exec_handler (no-op) /
#       processes_config (记录调用并 return 0), 抽取真实 processes_index 函数体运行。
# 注意: ①exec_menu 经命令替换 `$(...)` 调用, 其内部变量修改无法回写外层循环, 故用
#         文件 ($QUEUE) 持久化"待消费选择序列" —— 这是测试桩件约束, 非产品逻辑。
#       ②产品侧已把主菜单读取由 banner/status/index 三次 fork 合并为单次
#         `exec_menu --index-full` (见 core/main.sh 内注释); 桩件必须跟随该接口,
#         否则队列永不消费、断言全挂 —— 本用例曾长期"打印 FAIL 却不 exit 非零",
#         导致这种接口失配在 CI 上静默通过。故结尾按 $ok 决定退出码, 让失败真正被拦住。
# =============================================================================
set -u

SB="test/.tmp/menu_loop_sb"
rm -rf "$SB"; mkdir -p "$SB"
# EXIT trap: 断言失败提前退出时也要收掉沙箱, 否则多次运行会不断累积残留目录
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT
CALLS="$SB/calls"; : > "$CALLS"
QUEUE="$SB/queue"
MAIN=core/main.sh

# 抽取 processes_index 函数体 (从 main.sh: 顶层 `function processes_index()` 到顶层 `}`)
awk '/^function processes_index\(\)/{f=1} f{print} f&&/^\}/{exit}' "$MAIN" > "$SB/pi.sh"

# --- 桩件 ---
exec_handler() { :; }
# 子菜单桩件: 记录"被调用"并 return 0 (模拟 `*` 分支回到父菜单, 而非退出脚本)
processes_config() { echo "config_called" >> "$CALLS"; return 0; }

# exec_menu 桩件: 仅 `--index-full` 从队列文件头部弹出一个值并回显 (主菜单读取入口);
#   其他子命令 (banner/status) 返回空。接口名与 core/main.sh 的实际调用保持一致 ——
#   详见文件头注意事项②。队列状态持久化到文件, 以跨越命令替换 subshell 的变量隔离。
exec_menu() {
    case "$1" in
        --index-full)
            echo "index_full_call" >> "$CALLS"
            local first rest
            first="$(head -1 "$QUEUE" 2>/dev/null)"
            rest="$(tail -n +2 "$QUEUE" 2>/dev/null)"
            printf '%s\n' "$rest" > "$QUEUE"
            printf '%s' "${first:-0}"
            ;;
        *) : ;;   # banner / status: 不消费选择
    esac
}

# 加载抽取的 processes_index (其调用的 exec_menu/exec_handler/processes_config 用上方桩件)
# shellcheck source=/dev/null
source "$SB/pi.sh"

ok=1

# ---------------------------------------------------------------------------
# 场景 A: 选 9(进配置) -> processes_config 被调用 -> return 0 回到主菜单 ->
#         再选 0(`*`/EOF) -> exit 0。证明"选完一项后回到主菜单" (主循环生效)。
# ---------------------------------------------------------------------------
printf '9\n0\n' > "$QUEUE"; : > "$CALLS"
( processes_index ); rcA=$?
idxA=$(grep -c index_full_call "$CALLS" 2>/dev/null || true)
cfgA=$(grep -c config_called "$CALLS" 2>/dev/null || true)
[[ $rcA -eq 0 ]] || { echo "[FAIL A] 退出码应为 0, 实际 $rcA"; ok=0; }
# 2 次 index_full_call = 迭代1(选9) + 迭代2(选0), 证明选 9 后回到主菜单重读了一次选择
[[ $idxA -eq 2 ]] || { echo "[FAIL A] exec_menu --index-full 应被调用 2 次 (主循环回到主菜单), 实际 $idxA"; ok=0; }
[[ $cfgA -eq 1 ]] || { echo "[FAIL A] processes_config 应被调用 1 次 (选 9), 实际 $cfgA"; ok=0; }

# ---------------------------------------------------------------------------
# 场景 B: 直接选 0 (等价于 EOF/无输入 -> get_choose 归一为 0) -> 立即 exit 0,
#         不进入第二次迭代 (防止无 TTY / cron 场景下的空转)。
# ---------------------------------------------------------------------------
printf '0\n' > "$QUEUE"; : > "$CALLS"
( processes_index ); rcB=$?
idxB=$(grep -c index_full_call "$CALLS" 2>/dev/null || true)
[[ $rcB -eq 0 ]] || { echo "[FAIL B] 退出码应为 0, 实际 $rcB"; ok=0; }
[[ $idxB -eq 1 ]] || { echo "[FAIL B] exec_menu --index-full 应仅调用 1 次 (EOF/* 不空转), 实际 $idxB"; ok=0; }

# 失败必须传导为退出码 —— run_tests.sh 与 CI 只按退出码计成败, 只打印 FAIL 不算数。
# (沙箱收尾交给上方 EXIT trap, 不在此处 rm, 以免掩盖退出码。)
if [[ $ok -eq 1 ]]; then
    echo "==== menu_loop_test: PASS=5 FAIL=0 ===="
    exit 0
fi
echo "==== menu_loop_test: FAIL ===="
exit 1
