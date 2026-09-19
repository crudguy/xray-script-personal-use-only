#!/usr/bin/env bash
# =============================================================================
# P1-1 回归测试: 菜单选择经 stdout 传递 (而非退出码)。
#
# 验证 exec_menu 改造后的契约:
#   1. 选择编号经 stdout 返回 (含 0 与非 0)
#   2. exec_menu 自身恒 return 0 -> 退出码恢复标准语义, 裸调用不触发 set -e
#   3. 旧的 `|| choose=$?` 写法已失效 (拿不到非 0 选择) —— 反向守卫, 防止回退
#   4. 源码静态守卫: exec_menu 用 printf 输出且不再 return "${OPTION}",
#      全仓 `|| choose=$?` 调用点已清零
#
# 用桩件模拟 menu.sh (exit N 返回选择, UI 走 stderr), 不依赖真实菜单 / jq。
# 运行: bash test/menu_dispatch_test.sh
# =============================================================================
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

PASS=0; FAIL=0
assert_ok() { if eval "$1"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $2"; fi; }
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $3 (got '$1' want '$2')"; fi; }

# --- 桩件 menu.sh: UI 走 stderr, 选择编号经 exit 返回 ---
# 注: 不用裸 mktemp —— Windows/Git-Bash 下它可能返回 "C:/..." 风格路径, MSYS 无法
#     解析, 且 set -e + 收尾 rm 失败会中止脚本。改用项目内固定目录(约定 .workbuddy/tmp/)。
mkdir -p .workbuddy/tmp
FAKE_MENU=".workbuddy/tmp/menu_dispatch_fake_menu.$$"
cat > "$FAKE_MENU" <<'EOF'
#!/usr/bin/env bash
# 模拟 menu.sh: 渲染 UI 到 stderr, 选择编号经退出码返回
printf '[fake menu UI] option selected\n' >&2
exit "${FAKE_CHOICE:-0}"
EOF
chmod +x "$FAKE_MENU"

# --- 从 main.sh 抽取 exec_menu 函数体并加载 (不加载整个 main.sh, 避免其依赖) ---
EXEC_MENU_SRC="$(awk '/^function exec_menu\(\) \{/{f=1} f{print} f&&/^}/{exit}' core/main.sh)"
if [[ -z "$EXEC_MENU_SRC" ]]; then
    echo "  [FAIL] 无法从 main.sh 抽取 exec_menu 函数体"
    exit 1
fi
# 让桩件成为 MENU_PATH, 然后定义函数
MENU_PATH="$FAKE_MENU"
export FAKE_CHOICE=0   # 桩经此环境变量接收"选择编号"; 后续各 T 重赋值即被子进程继承
eval "$EXEC_MENU_SRC"

echo "[T1] 非 0 选择经 stdout 返回"
FAKE_CHOICE=5
choose="$(exec_menu --x)"
assert_eq "$choose" "5" "T1: 选 5 应得到 '5'"

echo "[T2] 选 0 也能正确返回 '0' (0 不再与'成功'混淆)"
FAKE_CHOICE=0
choose="$(exec_menu --x)"
assert_eq "$choose" "0" "T2: 选 0 应得到 '0'"

echo "[T3] exec_menu 裸调用退出码恒为 0 (不触发 set -e / ERR trap)"
FAKE_CHOICE=9
rc=0
exec_menu --x >/dev/null || rc=$?
assert_eq "$rc" "0" "T3: 裸调用退出码应为 0 (实际 $rc)"

echo "[T4] 反向守卫: 旧写法 '|| choose=\$?' 已失效 (拿不到非 0 选择)"
FAKE_CHOICE=5
legacy_choose=0
exec_menu --x || legacy_choose=$?
assert_eq "$legacy_choose" "0" "T4: 旧写法应保持初始 0 (证明 stdout 是唯一传值通道)"

echo "[T5] 静态守卫: 源码契约"
# 5a: exec_menu 用 printf 输出选择
if printf '%s' "$EXEC_MENU_SRC" | grep -q 'printf'; then
    assert_ok true "T5a: exec_menu 含 printf 输出"
else
    assert_ok false "T5a: exec_menu 未用 printf 输出选择"
fi
# 5b: exec_menu 不再 return "${OPTION}"
if printf '%s' "$EXEC_MENU_SRC" | grep -q 'return "${OPTION}"'; then
    assert_ok false "T5b: exec_menu 仍 return 选择编号 (应改为 printf)"
else
    assert_ok true "T5b: exec_menu 不再 return 选择编号"
fi
# 5c: 全仓 exec_menu 调用点不再用 '|| choose=$?'
if grep -rq '|| choose=$' core/main.sh; then
    assert_ok false "T5c: main.sh 仍存在 '|| choose=\$?' 调用点"
else
    assert_ok true "T5c: 全仓 '|| choose=\$?' 调用点已清零"
fi

rm -f "$FAKE_MENU" 2>/dev/null || true

echo
echo "==== menu_dispatch_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
