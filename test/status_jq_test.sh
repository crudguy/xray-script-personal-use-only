#!/usr/bin/env bash
# shellcheck disable=SC2034  # run_fn 内 SCRIPT_CONFIG_PATH 供随后 source 进来的 print_status 实现读取 (跨 source)。
# P2-1 收尾回归守卫: print_status 状态栏取数由 4 次 jq 合并为 1 次.
#   静态: print_status 内 jq 调用恰好 1 次; 旧形态 (`jq '.'` + `echo|jq -r`) 清零.
#   行为: 抽取 menu.sh 真实 print_status 函数体, 以桩件 jq / i18n 驱动三种配置场景.
#   等价: 以"旧 4 次 jq 实现"为参照, 逐场景对比新旧输出, 断言逐字一致 (低风险重构的硬约束).
# 纯 bash, 不依赖真实 jq (自带 jq 桩件), 可在无 jq 的沙箱与 CI 中运行.
set -u
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1" >&2; }

MENU='core/menu.sh'
# 兼顾"从仓库根运行"(CI/run_tests.sh)与"直接执行本文件"
if [[ ! -r "$MENU" && -r "${0%/*}/../$MENU" ]]; then
    cd "${0%/*}/.." || exit 1
fi
# 临时目录固定落在仓库 test/.tmp/ —— 不裸用 mktemp:
# Git-Bash 下 mktemp 会返回 C:\... 反斜杠路径, 既污染 PATH 又破坏 awk -v 转义.
TMPD="test/.tmp/status_jq_$$"
rm -rf "$TMPD"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT

echo "== P2-1 print_status 单次 jq 守卫 =="

# ---------------------------------------------------------------- 静态契约
if [[ ! -r "$MENU" ]]; then
    bad "找不到 $MENU"
    echo "PASS=$PASS FAIL=$FAIL"
    exit 1
fi

BODY="$(awk '/^function print_status\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$MENU")"
if [[ -z "$BODY" ]]; then
    bad "未能从 $MENU 抽取 print_status 函数体"
    echo "PASS=$PASS FAIL=$FAIL"
    exit 1
fi

N_JQ="$(printf '%s\n' "$BODY" | grep -v '^[[:space:]]*#' | grep -c 'jq ')"
if [[ "$N_JQ" -eq 1 ]]; then
    ok "print_status 内 jq 调用恰为 1 次 (实测 $N_JQ)"
else
    bad "print_status 内 jq 调用应为 1 次, 实测 $N_JQ"
fi

if printf '%s\n' "$BODY" | grep -qF "jq -r '[.xray.version, .xray.tag, .xray.warp] | .[]'"; then
    ok "采用单次 jq 数组取三字段 (version/tag/warp)"
else
    bad "未使用单次 jq 数组取数"
fi

if grep -qF "SCRIPT_CONFIG=\$(jq '.'" "$MENU"; then
    bad "menu.sh 仍存在 SCRIPT_CONFIG=\$(jq '.') 旧形态"
else
    ok "menu.sh 已清除 4 次 jq 的旧取数实现"
fi
if grep -qF 'echo "${SCRIPT_CONFIG}" | jq' "$MENU"; then
    bad "menu.sh 仍存在 echo|jq 管道取字段"
else
    ok "menu.sh 已无 echo|jq 管道取字段"
fi
if printf '%s\n' "$BODY" | grep -qE 'SCRIPT_CONFIG=|local SCRIPT_CONFIG'; then
    bad "print_status 仍引用中间变量 SCRIPT_CONFIG"
else
    ok "print_status 不再保留中间变量 SCRIPT_CONFIG"
fi

# ---------------------------------------------------------------- 桩件准备
mkdir -p "$TMPD/bin"

cat >"$TMPD/bin/jq" <<'JQSTUB'
#!/usr/bin/env bash
# 测试用 jq 桩件: 仅实现本用例涉及的表达式, 纯 bash 无外部依赖.
raw=0; expr=''; file=''
for a in "$@"; do
    case "$a" in
    -r) raw=1 ;;
    *) if [[ -z "$expr" ]]; then expr="$a"; else file="$a"; fi ;;
    esac
done
if [[ -n "$file" ]]; then
    [[ -r "$file" ]] || { echo "jq: error: could not open $file" >&2; exit 4; }
    body="$(tr -d '\n\r' <"$file")"
else
    body="$(tr -d '\n\r')"
    [[ -n "$body" ]] || { echo "jq: error: no input" >&2; exit 4; }
fi
# 最小 JSON 合法性校验: 真实 jq 遇到非法输入会非 0 退出, 桩件需同语义,
# 否则"配置损坏"场景会假性通过 (把整段垃圾当对象取字段).
_trim="${body#"${body%%[![:space:]]*}"}"
_trim="${_trim%"${_trim##*[![:space:]]}"}"
[[ "$_trim" == \{*\} ]] || { echo "jq: error: parse error" >&2; exit 4; }
pick() {
    local k="$1" v
    v="$(printf '%s' "$body" | grep -oE "\"$k\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9]+)" | head -1)"
    [[ -n "$v" ]] || { printf 'null\n'; return; }
    v="${v#*:}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%\"}"; v="${v#\"}"
    printf '%s\n' "$v"
}
case "$expr" in
'.') printf '%s\n' "$body" ;;
'[.xray.version, .xray.tag, .xray.warp] | .[]')
    pick version
    pick tag
    pick warp
    ;;
.*) pick "${expr##*.}" ;;
*)
    echo "jq: unsupported expr: $expr" >&2
    exit 3
    ;;
esac
JQSTUB
chmod +x "$TMPD/bin/jq"

cat >"$TMPD/prelude.sh" <<'PRELUDE'
CUR_FILE='menu'
NC='' GREEN='<G>' RED='<R>' YELLOW='' BLUE='' CYAN=''
_menu_rule() { printf -- '---\n'; }
_i18n() {
    case "$1" in
    *.status.not_installed) printf 'NOT_INSTALLED\n' ;;
    *.status.not_configured) printf 'NOT_CONFIGURED\n' ;;
    *.status.enabled) printf 'ENABLED\n' ;;
    *.status.disabled) printf 'DISABLED\n' ;;
    *.bbr.state_on) printf 'BBR_ON\n' ;;
    *.bbr.state_off) printf 'BBR_OFF\n' ;;
    *.bbr.state_unknown) printf 'BBR_UNKNOWN\n' ;;
    *) printf '\n' ;;
    esac
}
sysctl() { return 1; }
PRELUDE

# 真实的 print_status 函数体
awk '/^function print_status\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$MENU" >"$TMPD/new_fn.sh"

# 旧实现参照: 把新取数块整体替换为"1 次 jq '.' + 3 次 echo|jq -r"
cat >"$TMPD/old_block.txt" <<'OLDBLOCK'
    local SCRIPT_CONFIG
    SCRIPT_CONFIG=$(jq '.' "${SCRIPT_CONFIG_PATH}" || true)
    local XRAY_VERSION
    XRAY_VERSION=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.version' || true)
    local CONFIG_TAG
    CONFIG_TAG=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag' || true)
    local WARP_STATUS
    WARP_STATUS=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.warp' || true)
OLDBLOCK

awk -v blk="$TMPD/old_block.txt" '
    /^    # 一次性取出/ { while ((getline l < blk) > 0) print l; skip=1; next }
    skip && /^    \} < </ { skip=0; next }
    skip { next }
    { print }
' "$TMPD/new_fn.sh" >"$TMPD/old_fn.sh"

if grep -qF "jq '.'" "$TMPD/old_fn.sh" && ! grep -qF '一次性取出' "$TMPD/old_fn.sh"; then
    ok "旧实现参照函数构造成功 (用于等价对拍)"
else
    bad "旧实现参照函数构造失败"
fi

# ---------------------------------------------------------------- 场景夹具
printf '%s\n' '{"xray":{"version":"v1.2.3","tag":"Vision","warp":1}}' >"$TMPD/case_a.json"
printf '%s\n' '{"xray":{"version":"v9.9.9","tag":"","warp":0}}' >"$TMPD/case_c.json"
printf '%s\n' '{ this is not json' >"$TMPD/case_bad.json"

run_fn() { # $1=函数体文件 $2=config路径
    (
        set -u
        export PATH="$TMPD/bin:$PATH"
        # shellcheck disable=SC1091
        source "$TMPD/prelude.sh"
        SCRIPT_CONFIG_PATH="$2"
        # shellcheck disable=SC1090
        source "$1"
        print_status
    ) 2>/dev/null
}

# ---------------------------------------------------------------- 行为断言
OUT_A="$(run_fn "$TMPD/new_fn.sh" "$TMPD/case_a.json")"
if printf '%s' "$OUT_A" | grep -q 'v1.2.3' && printf '%s' "$OUT_A" | grep -q '<G>'; then
    ok "场景A 有版本/标签: 版本原样显示且着色 (GREEN)"
else
    bad "场景A 版本显示异常: $(printf '%s' "$OUT_A" | tr '\n' '|')"
fi
if printf '%s' "$OUT_A" | grep -q 'Vision' && printf '%s' "$OUT_A" | grep -q 'ENABLED'; then
    ok "场景A 标签 Vision + WARP enabled 正确"
else
    bad "场景A 标签/WARP 显示异常"
fi

OUT_MISS="$(run_fn "$TMPD/new_fn.sh" "$TMPD/nope.json")"
if printf '%s' "$OUT_MISS" | grep -q 'NOT_INSTALLED' &&
    printf '%s' "$OUT_MISS" | grep -q 'NOT_CONFIGURED' &&
    printf '%s' "$OUT_MISS" | grep -q 'DISABLED'; then
    ok "场景B 配置文件缺失: 三项均落未安装/未配置/关闭 (不崩)"
else
    bad "场景B 缺失文件处理异常: $(printf '%s' "$OUT_MISS" | tr '\n' '|')"
fi

OUT_BAD="$(run_fn "$TMPD/new_fn.sh" "$TMPD/case_bad.json")"
if printf '%s' "$OUT_BAD" | grep -q 'NOT_INSTALLED'; then
    ok "场景B2 配置非法 JSON: 优雅降级为未安装 (不崩)"
else
    bad "场景B2 非法 JSON 处理异常"
fi

OUT_C="$(run_fn "$TMPD/new_fn.sh" "$TMPD/case_c.json")"
if printf '%s' "$OUT_C" | grep -q 'v9.9.9' &&
    printf '%s' "$OUT_C" | grep -q 'NOT_CONFIGURED' &&
    printf '%s' "$OUT_C" | grep -q 'DISABLED'; then
    ok "场景C 空标签 + warp=0: 未配置 / 关闭"
else
    bad "场景C 显示异常: $(printf '%s' "$OUT_C" | tr '\n' '|')"
fi

# ---------------------------------------------------------------- 新旧等价对拍
for c in case_a.json case_c.json case_bad.json; do
    NEWOUT="$(run_fn "$TMPD/new_fn.sh" "$TMPD/$c")"
    OLDOUT="$(run_fn "$TMPD/old_fn.sh" "$TMPD/$c")"
    if [[ "$NEWOUT" == "$OLDOUT" ]]; then
        ok "等价对拍 [$c]: 新旧实现输出逐字一致"
    else
        bad "等价对拍 [$c] 不一致"
        diff <(printf '%s\n' "$OLDOUT") <(printf '%s\n' "$NEWOUT") >&2 || true
    fi
done
NEWOUT="$(run_fn "$TMPD/new_fn.sh" "$TMPD/nope.json")"
OLDOUT="$(run_fn "$TMPD/old_fn.sh" "$TMPD/nope.json")"
if [[ "$NEWOUT" == "$OLDOUT" ]]; then
    ok "等价对拍 [文件缺失]: 新旧实现输出逐字一致"
else
    bad "等价对拍 [文件缺失] 不一致"
    diff <(printf '%s\n' "$OLDOUT") <(printf '%s\n' "$NEWOUT") >&2 || true
fi

# ---------------------------------------------------------------- 子进程计数
CNT_NEW="$(printf '%s\n' "$BODY" | grep -v '^[[:space:]]*#' | grep -o 'jq ' | wc -l | tr -d ' ')"
if [[ "$CNT_NEW" -eq 1 ]]; then
    ok "重构后 jq 调用数 1 (原 4), 每轮主菜单少 3 次 fork"
else
    bad "jq 调用数应为 1, 实测 $CNT_NEW"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
