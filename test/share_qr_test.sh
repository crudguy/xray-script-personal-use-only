#!/usr/bin/env bash
# =============================================================================
# P2-4 子项③ 回归守卫: qrencode 缺失时的降级处理
#
# 背景: core/share.sh 原写法 `echo -e "${SHARE_LINK}" | qrencode -t ansiutf8`
#       是裸命令。qrencode 未安装时返回 127, 经 set -Eeuo pipefail + ERR trap
#       会直接中止整个分享流程 —— 二维码只是附加信息, 不该让主流程失败。
#
# 本测试验证:
#   1. 静态守卫: share.sh 含 `command -v qrencode`; 裸 `| qrencode` 仅 1 处(在守卫内)。
#   2. 行为(抽取 share.sh 真实 if 块 + 桩件驱动):
#      - 无 qrencode -> 打印 i18n 提示, rc=0, 不打印空标题;
#      - 有 qrencode -> 正常显示标题并调用 qrencode。
#   3. 对照实验: 复刻旧写法, 证明缺 qrencode 时确实失败(修复确有必要)。
#
# 纯 bash, 不依赖 jq / qrencode。
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARE="$ROOT/core/share.sh"

PASS=0
FAIL=0

assert() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS + 1)); printf '  ok   %-30s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %-30s got=%q want=%q\n' "$name" "$got" "$want"
    fi
}

assert_contains() {
    local name="$1" hay="$2" needle="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        PASS=$((PASS + 1)); printf '  ok   %-30s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %-30s (missing %q)\n' "$name" "$needle"
    fi
}

assert_not_contains() {
    local name="$1" hay="$2" needle="$3"
    if [[ "$hay" != *"$needle"* ]]; then
        PASS=$((PASS + 1)); printf '  ok   %-30s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %-30s (unexpected %q)\n' "$name" "$needle"
    fi
}

echo "== 静态守卫: core/share.sh =="
SRC="$(cat "$SHARE")"
assert_contains "uses command -v qrencode" "$SRC" 'command -v qrencode'
assert_contains "references qr_missing key" "$SRC" 'qr_missing'
n_pipe="$(grep -c '| *qrencode' "$SHARE" || true)"
assert "single bare | qrencode" "$n_pipe" "1"

# 抽取真实 if 块 (从 4 空格缩进的 SHARE_SHOW_QR 判断, 到同缩进的 fi)
BLOCK="$(awk '/^    if \[\[ "\$\{SHARE_SHOW_QR\}" -eq 1 \]\]/{f=1} f{print} f&&/^    fi$/{exit}' "$SHARE")"
assert_contains "block extracted" "$BLOCK" 'SHARE_SHOW_QR'
assert_contains "block guards qrencode" "$BLOCK" 'command -v qrencode'
assert_contains "block has hint branch" "$BLOCK" 'qr_missing'

# 注: 不用 mktemp -d —— Windows/Git-Bash 下它可能返回 "C:/..." 风格路径, MSYS 工具
#     无法解析(尤其 chmod +x 与 PATH 查找), 会让"存在 qrencode"场景假失败。
#     改用项目约定的 test/.tmp/ 下固定目录, 路径可被 MSYS 正常解析。
TMPD="$ROOT/test/.tmp/share_qr_test.$$"
rm -rf "$TMPD" 2>/dev/null || true
mkdir -p "$TMPD/empty" "$TMPD/bin"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT
BASH_BIN="$(command -v bash)"
printf '%s\n' "$BLOCK" > "$TMPD/block.sh"

# 组装 runner: 桩件 i18n / _menu_title + 真实 if 块
{
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'trap "echo TRAP_HIT >&2" ERR'
    printf '%s\n' '_i18n() { case "$1" in'
    printf '%s\n' '  .title.warn) printf "%s" "WARN";;'
    printf '%s\n' '  .share.qr)   printf "%s" "QR";;'
    printf '%s\n' '  .share.qr_missing) printf "%s" "QRMISS";;'
    printf '%s\n' '  *) printf "%s" "";;'
    printf '%s\n' 'esac; }'
    printf '%s\n' '_menu_title() { printf "TITLE:%s\n" "$1"; }'
    printf '%s\n' 'YELLOW=""; NC=""'
    printf '%s\n' 'SHARE_SHOW_QR=1'
    printf '%s\n' 'SHARE_LINK="vless://example"'
    printf '%s\n' 'CUR_FILE="share"'
    cat "$TMPD/block.sh"
    printf '%s\n' 'echo "DONE_RC0"'
} > "$TMPD/runner.sh"

# --- 场景 A: 无 qrencode ---
echo "== 行为 A: 缺 qrencode (降级) =="
outA="$(PATH="$TMPD/empty" "$BASH_BIN" "$TMPD/runner.sh" 2>&1)"; rcA=$?
assert "A rc=0 (no abort)" "$rcA" "0"
assert_contains "A prints hint" "$outA" "QRMISS"
assert_contains "A completes" "$outA" "DONE_RC0"
assert_not_contains "A no empty title" "$outA" "TITLE:"
assert_not_contains "A no ERR trap" "$outA" "TRAP_HIT"

# --- 场景 B: 有 qrencode ---
echo "== 行为 B: 存在 qrencode (正常) =="
cat > "$TMPD/bin/qrencode" <<'EOQ'
#!/usr/bin/env bash
printf 'FAKEQR %s\n' "$*"
EOQ
chmod +x "$TMPD/bin/qrencode"
outB="$(PATH="$TMPD/bin:/usr/bin:/bin" "$BASH_BIN" "$TMPD/runner.sh" 2>&1)"; rcB=$?
assert "B rc=0" "$rcB" "0"
assert_contains "B prints title" "$outB" "TITLE:QR"
assert_contains "B invokes qrencode" "$outB" "FAKEQR"
assert_contains "B completes" "$outB" "DONE_RC0"

# --- 对照实验: 旧写法 (裸调) 在缺 qrencode 时确实失败 ---
echo "== 对照: 旧写法 (裸调) =="
{
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'trap "echo TRAP_HIT >&2" ERR'
    printf '%s\n' 'SHARE_LINK="vless://example"'
    printf '%s\n' 'echo -e "${SHARE_LINK}" | qrencode -t ansiutf8'
    printf '%s\n' 'echo "OLD_DONE_RC0"'
} > "$TMPD/old.sh"
outOld="$(PATH="$TMPD/empty" "$BASH_BIN" "$TMPD/old.sh" 2>&1)"; rcOld=$?
if [[ "$rcOld" -ne 0 || "$outOld" == *TRAP_HIT* ]]; then
    PASS=$((PASS + 1)); printf '  ok   %-30s (rc=%s)\n' "old-form fails w/o qrencode" "$rcOld"
else
    FAIL=$((FAIL + 1)); printf '  FAIL %-30s (expected failure, got rc=%s)\n' "old-form fails w/o qrencode" "$rcOld"
fi
assert_not_contains "old-form not completed" "$outOld" "OLD_DONE_RC0"

echo
echo "==== PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
