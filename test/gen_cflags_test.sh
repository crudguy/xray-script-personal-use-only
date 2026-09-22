#!/usr/bin/env bash
# gen_cflags 行为回归测试 (纯 bash, mock gcc, 不依赖真实编译环境)
#
# 锁定 service/nginx.sh 的 gen_cflags 依据 `gcc -v --help` 能力探测拼装 CFLAGS 的语义:
#   1. 基础项恒为 `-g0 -O3`;
#   2. 各 -f* 能力项"探测到才追加", 且追加的是预期的反向开关 (如 -fstack-reuse -> -fstack-reuse=all);
#   3. -fexceptions 优先于 -fhandle-exceptions (elif 语义): 前者命中时不再追加后者;
#   4. -fsanitize 走 `gcc -E -fno-sanitize=all` 实测, 编译失败则不追加;
#   5. 追加顺序与函数内 if 顺序一致 (下游把 cflags 拼进编译命令, 顺序错误会得到不同产物)。
#
# 防回归: 误改 grep 模式 / 增删能力项 / 颠倒 elif 优先级 / 破坏 sanitizer 实测分支。
# 运行: bash test/gen_cflags_test.sh
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

PASS=0
FAIL=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  [FAIL] $3 (got '$1' want '$2')"; fi; }

# --- 抽取 gen_cflags 函数体 (不加载整个 nginx.sh, 避免其顶层副作用) ---
FUNC_SRC="$(awk '/^function gen_cflags\(\) \{/{f=1} f{print} f&&/^}/{exit}' service/nginx.sh)"
if [[ -z "$FUNC_SRC" ]]; then
    echo "  [FAIL] 无法从 service/nginx.sh 抽取 gen_cflags 函数体"
    exit 1
fi

# --- 桩件目录: 放一个假 gcc 供 PATH 前置 ---
# 注: 用项目内约定目录 test/.tmp/ (裸 mktemp 在 Git-Bash 下可能返回 MSYS 无法解析的路径)。
mkdir -p test/.tmp
MOCK_BIN="$REPO/test/.tmp/gen_cflags_mockbin.$$"
mkdir -p "$MOCK_BIN"
cat >"$MOCK_BIN/gcc" <<'EOF'
#!/usr/bin/env bash
# 假 gcc: `-v --help` 时吐出 $MOCK_GCC_HELP 指向的文本; `-E ...` 时按 $MOCK_GCC_E_RC 返回;
# 其余调用一律成功。让 gen_cflags 的能力探测结果完全可控。
case "$*" in
    *"--help"*) cat "${MOCK_GCC_HELP:-/dev/null}" ;;
    *"-E"*)     exit "${MOCK_GCC_E_RC:-0}" ;;
    *)          exit 0 ;;
esac
EOF
chmod +x "$MOCK_BIN/gcc"

# --- 隔离工作目录: sanitizer 分支会在 CWD 建/删 temp.c ---
WORKDIR="$REPO/test/.tmp/gen_cflags_work.$$"
mkdir -p "$WORKDIR"
HELP_DIR="$REPO/test/.tmp/gen_cflags_help.$$"
mkdir -p "$HELP_DIR"

# 生成一份 help 文本; 参数为要写入的 flag 行
write_help() {
    local out="$1"
    shift
    : >"$out"
    local line
    for line in "$@"; do
        printf '%s\n' "$line" >>"$out"
    done
}

# 在隔离目录里跑一次 gen_cflags 并回显拼装结果
run_cflags() {
    local helpfile="$1" e_rc="${2:-0}"
    (
        cd "$WORKDIR" || exit 1
        export PATH="$MOCK_BIN:$PATH"
        export MOCK_GCC_HELP="$helpfile"
        export MOCK_GCC_E_RC="$e_rc"
        eval "$FUNC_SRC"
        # 显式置空: gen_cflags 自身会重置该数组, 这里预置是为了让"从干净状态出发"成立,
        # 同时消除 shellcheck 的 SC2154 (赋值发生在 eval 注入的函数体里, 数据流不跨 eval)。
        cflags=()
        gen_cflags
        printf '%s' "${cflags[*]}"
    )
}

# ---- T1 空能力: 仅基础项 ----
EMPTY="$HELP_DIR/empty.txt"
write_help "$EMPTY"
assert_eq "$(run_cflags "$EMPTY")" "-g0 -O3" "T1: 无任何能力项时应只剩 -g0 -O3"

# ---- T2 单个能力项 (值改写: -fstack-reuse -> =all) ----
H2="$HELP_DIR/t2.txt"
write_help "$H2" "-fstack-reuse"
assert_eq "$(run_cflags "$H2")" "-g0 -O3 -fstack-reuse=all" "T2: 探测到 -fstack-reuse 应追加 -fstack-reuse=all"

# ---- T3 反向开关 (探测 -fplt/-ftrapv -> 追加 -fplt/-fno-trapv) ----
H3="$HELP_DIR/t3.txt"
write_help "$H3" "-fplt" "-ftrapv"
assert_eq "$(run_cflags "$H3")" "-g0 -O3 -fplt -fno-trapv" "T3: -fplt 原样, -ftrapv 反向为 -fno-trapv"

# ---- T4 elif 优先级: 同时具备时只走 -fexceptions 分支 ----
H4="$HELP_DIR/t4.txt"
write_help "$H4" "-fexceptions" "-fhandle-exceptions"
assert_eq "$(run_cflags "$H4")" "-g0 -O3 -fno-exceptions" "T4: -fexceptions 命中时不应再追加 -fno-handle-exceptions"

# ---- T5 elif 回退: 仅有 -fhandle-exceptions ----
H5="$HELP_DIR/t5.txt"
write_help "$H5" "-fhandle-exceptions"
assert_eq "$(run_cflags "$H5")" "-g0 -O3 -fno-handle-exceptions" "T5: 仅 -fhandle-exceptions 时应追加 -fno-handle-exceptions"

# ---- T6 sanitizer 实测通过: 追加 -fno-sanitize=all ----
H6="$HELP_DIR/t6.txt"
write_help "$H6" "-fsanitize"
assert_eq "$(run_cflags "$H6" 0)" "-g0 -O3 -fno-sanitize=all" "T6: -fsanitize 且 gcc -E 成功应追加 -fno-sanitize=all"

# ---- T7 sanitizer 实测失败: 不追加 ----
assert_eq "$(run_cflags "$H6" 1)" "-g0 -O3" "T7: -fsanitize 但 gcc -E 失败时不应追加"

# ---- T8 不相关 help 文本不应误命中 ----
H8="$HELP_DIR/t8.txt"
write_help "$H8" "-funrelated" "-fstack" "not-a-flag"
assert_eq "$(run_cflags "$H8")" "-g0 -O3" "T8: 相似但不相干的 token 不应触发追加"

# ---- T9 全量能力: 顺序与函数内 if 完全一致 ----
H9="$HELP_DIR/t9.txt"
write_help "$H9" \
    "-fstack-reuse" "-fdwarf2-cfi-asm" "-fplt" "-ftrapv" \
    "-fexceptions" "-fhandle-exceptions" "-funwind-tables" \
    "-fasynchronous-unwind-tables" "-fstack-check" "-fstack-clash-protection" \
    "-fstack-protector" "-fcf-protection=" "-fsplit-stack" "-fsanitize" "-finstrument-functions"
EXPECT9="-g0 -O3 -fstack-reuse=all -fdwarf2-cfi-asm -fplt -fno-trapv -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-check -fno-stack-clash-protection -fno-stack-protector -fcf-protection=none -fno-split-stack -fno-sanitize=all -fno-instrument-functions"
assert_eq "$(run_cflags "$H9" 0)" "$EXPECT9" "T9: 全量能力项的拼装顺序应与源码逐一对应"

# ---- T10 副作用清理: sanitizer 分支不应把 temp.c 留在 CWD ----
tmp_leftover="no"
[[ -e "$WORKDIR/temp.c" ]] && tmp_leftover="yes"
assert_eq "$tmp_leftover" "no" "T10: sanitizer 分支应清理临时 temp.c (CWD 无残留)"

rm -rf "$MOCK_BIN" "$WORKDIR" "$HELP_DIR" 2>/dev/null || true

echo
echo "==== gen_cflags_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
