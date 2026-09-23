#!/usr/bin/env bash
# =============================================================================
# 测试名称: menu_guard_soft_fail_test.sh
# 测试目标: 菜单项的"预期内不可用"必须优雅降级 —— 提示 + 返回菜单,
#           不得用 _error 中断整个脚本。
#
# 背景: 非 SNI 模式下选 "9 管理配置 -> 3 SNI 配置管理", 旧实现直接
#       `[[ tag == sni ]] || _error ...`。_error 会 exit 1, 一路冒泡成 install.sh
#       trampoline 的 "[错误] 脚本在第 984 行意外失败 (退出码 1)"; 用户只看到
#       一串错误、被迫重进脚本, 连"换个菜单项"都做不到。
#       backup 导入未填归档路径同理 —— 文案本身就是"已取消导入"(属取消, 非故障)。
#       注: 与同级 processes_* 的 `*) return 0` 惯例一致; 真正的操作失败仍由
#           exec_handler 的 _error 兜底退出 (那条路径保持原样, 本测试不管)。
#
# 覆盖:
#   T1 静态契约 —— 两处守卫不得出现 _error, 必须 print_warn + return 0;
#   T2 行为 —— 抽真实 processes_sni_config: tag 非 sni 时 RC=0、有警告、
#      不进 SNI 菜单、不执行任何动作; tag=sni(含大写) 仍正常进菜单 (守卫不误伤);
#   T3 行为 —— 抽真实 processes_backup: 空路径 RC=0、有警告、不调用 handler;
#      给出路径时正常转发 handler (守卫不误伤);
#   NEG 负向校验 —— 把守卫改回 _error 版, 确认 T1/T2 真能捕获回归 (否则加了等于没加)。
#
# 依赖: bash + jq (config 由真实 jq 读取)。无 jq 时跳过行为段并明确标注。
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/core/main.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s%s\n' "$1" "${2:+ ($2)}"; }
assert_contains() {
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing $(printf '%q' "$3")"; fi
}
assert_not_contains() {
    if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "unexpected $(printf '%q' "$3")"; fi
}

# 注: 不用裸 mktemp -d —— Windows/Git-Bash 下可能返回 "C:/..." 风格路径, MSYS 无法解析。
#     改用项目内固定目录 (约定 .workbuddy/tmp/, 见项目记忆)。
TMPD="$ROOT/.workbuddy/tmp/menu_guard_soft_fail.$$"
rm -rf "$TMPD" 2>/dev/null || true
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT
BASH_BIN="$(command -v bash)"

# 取 core/main.sh 中某 processes_* 的真实函数体
extract() { awk -v fn="$1" '$0 == "function " fn "() {" {f=1} f {print} f && /^}$/ {exit}' "$MAIN"; }

# 先剥掉整行注释再判定 —— 保护性注释里必然出现 "_error" 字样 (解释"为何不用它"),
# 不剥离会把注释误判成调用, 断言恒红 (本测试初版即踩此坑)。
strip_comments() { sed -E 's/^[[:space:]]*#.*$//' <<<"$1"; }

# 静态谓词: "这段函数体是优雅降级的吗" —— 代码里无 _error 且含 print_warn。
# 抽成函数是为了让 NEG 段能拿它去检验破损副本 (证明谓词真能区分)。
guard_is_graceful() { local s; s="$(strip_comments "$1")"; [[ "$s" != *'_error'* && "$s" == *'print_warn'* ]]; }

FN_SNI="$(extract processes_sni_config)"
FN_BAK="$(extract processes_backup)"
printf '%s\n' "$FN_SNI" > "$TMPD/fn_sni.sh"
printf '%s\n' "$FN_BAK" > "$TMPD/fn_bak.sh"

# ---------------------------------------------------------------------------
echo "[T1] 静态契约: 守卫不得 _error 退出, 必须 print_warn"
# ---------------------------------------------------------------------------
[[ -n "$FN_SNI" ]] && ok "T1: 抽取到 processes_sni_config" || bad "T1: 抽取 processes_sni_config"
[[ -n "$FN_BAK" ]] && ok "T1: 抽取到 processes_backup" || bad "T1: 抽取 processes_backup"
guard_is_graceful "$FN_SNI" && ok "T1: SNI 守卫优雅 (无 _error + 有 print_warn)" \
    || bad "T1: SNI 守卫仍是硬退出" "$FN_SNI"
guard_is_graceful "$FN_BAK" && ok "T1: 备份导入守卫优雅 (无 _error + 有 print_warn)" \
    || bad "T1: 备份导入守卫仍是硬退出" "$FN_BAK"
# 守卫必须发生在读菜单之前 —— 否则用户先看到一串菜单再被告知"不适用"
sni_code="$(strip_comments "$FN_SNI")"
sni_guard_line="$(grep -n 'print_warn' <<<"$sni_code" | head -1 | cut -d: -f1)"
sni_menu_line="$(grep -n "exec_menu '--sni'" <<<"$sni_code" | head -1 | cut -d: -f1)"
if [[ -n "$sni_guard_line" && -n "$sni_menu_line" && "$sni_guard_line" -lt "$sni_menu_line" ]]; then
    ok "T1: 守卫在 exec_menu 之前 (不会先渲染菜单再拒绝)"
else
    bad "T1: 守卫位置应在 exec_menu 之前" "guard=$sni_guard_line menu=$sni_menu_line"
fi

# ---------------------------------------------------------------------------
# 行为段: 需要真实 jq (函数内 `jq -r '.xray.tag'`)
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
    echo "[T2/T3] SKIP: 缺少 jq, 跳过行为断言"
else
    # 桩件说明:
    #   exec_menu 的 MARK 走 stderr —— 函数经 $(...) 捕获其 stdout (选择编号),
    #   stderr 会逃出捕获进入结果文本, 用于断言"是否渲染了菜单"。
    build_runner() { # $1=输出文件 $2=函数体文件
        {
            printf '%s\n' 'set -Eeuo pipefail'
            printf '%s\n' 'CUR_FILE="main"'
            # 颜色变量来自 _common.sh; runner 里 set -u, 缺失会直接崩 (备份分支的
            # printf "${GREEN}[%s]${NC}" 即踩此坑), 故显式置空。
            printf '%s\n' 'GREEN=""; NC=""; RED=""; YELLOW=""'
            printf '%s\n' '_i18n() { printf "%s" "$1"; }'
            printf '%s\n' 'print_warn() { printf "WARN %s\n" "$*" >&2; }'
            printf '%s\n' '_error() { printf "ERROR %s\n" "$*" >&2; exit 1; }'
            printf '%s\n' 'exec_menu() { printf "MENUCALL %s\n" "$*" >&2; cat "${CHFILE:-/dev/null}" 2>/dev/null || true; }'
            printf '%s\n' 'exec_handler() { printf "HANDLER %s\n" "$*" >&2; }'
            printf '%s\n' 'processes_web_config() { :; }'
            printf '%s\n' 'processes_ca_vendor() { :; }'
            printf '%s\n' 'processes_custom_sites() { :; }'
            cat "$2"
            printf '%s\n' "$3"
            printf '%s\n' 'printf "RC=%s\n" "$?"'
        } > "$1"
    }
    build_runner "$TMPD/runner_sni.sh" "$TMPD/fn_sni.sh" 'processes_sni_config'
    build_runner "$TMPD/runner_bak.sh" "$TMPD/fn_bak.sh" 'processes_backup'
    printf '0\n' > "$TMPD/ch"

    run_sni() { # $1=tag 值
        printf '{"xray":{"tag":"%s"}}\n' "$1" > "$TMPD/cfg.json"
        CHFILE="$TMPD/ch" SCRIPT_CONFIG_PATH="$TMPD/cfg.json" \
            "$BASH_BIN" "$TMPD/runner_sni.sh" 2>&1
    }

    echo "[T2] 行为: 非 SNI 模式应提示 + 返回, 不退出/不进菜单"
    out_vision="$(run_sni vision)"
    assert_contains     "T2: 非 SNI -> 正常返回 (RC=0)"    "$out_vision" 'RC=0'
    assert_not_contains "T2: 非 SNI -> 未硬退出 (无 ERROR)" "$out_vision" 'ERROR'
    assert_contains     "T2: 非 SNI -> 输出警告提示"        "$out_vision" 'WARN'
    assert_contains     "T2: 非 SNI -> 用 not_support 文案" "$out_vision" '.main.not_support'
    assert_not_contains "T2: 非 SNI -> 不渲染 SNI 菜单"     "$out_vision" 'MENUCALL'
    assert_not_contains "T2: 非 SNI -> 不执行任何动作"      "$out_vision" 'HANDLER'

    echo "[T2b] 行为: SNI 模式 (含大小写) 守卫不误伤"
    for t in sni SNI Sni; do
        out_sni="$(run_sni "$t")"
        assert_contains     "T2b: tag=$t -> 进入 SNI 菜单" "$out_sni" 'MENUCALL --sni'
        assert_contains     "T2b: tag=$t -> 正常返回"       "$out_sni" 'RC=0'
        assert_not_contains "T2b: tag=$t -> 不误报警告"     "$out_sni" 'WARN'
    done

    echo "[T3] 行为: 备份导入未填路径应提示 + 返回, 不调用 handler"
    run_bak() { # $1=喂给 read 的输入行 (用 %b 解析 \n, %s 会原样输出反斜杠+n)
        printf '%b' "$1" | CHFILE="$TMPD/ch2" SCRIPT_CONFIG_PATH="$TMPD/cfg.json" \
            "$BASH_BIN" "$TMPD/runner_bak.sh" 2>&1
    }
    printf '2\n' > "$TMPD/ch2"
    out_bak_empty="$(run_bak '\n')"
    assert_contains     "T3: 空路径 -> 正常返回 (RC=0)"       "$out_bak_empty" 'RC=0'
    assert_not_contains "T3: 空路径 -> 未硬退出 (无 ERROR)"    "$out_bak_empty" 'ERROR'
    assert_contains     "T3: 空路径 -> 输出警告提示"           "$out_bak_empty" 'WARN'
    assert_contains     "T3: 空路径 -> 用 backup_ipath 文案"   "$out_bak_empty" '.main.backup_ipath_required'
    assert_not_contains "T3: 空路径 -> 不调用 handler"         "$out_bak_empty" 'HANDLER'

    out_bak_path="$(run_bak '/root/bk/a.tar.gz\n')"
    assert_contains "T3: 给出路径 -> 转发给 handler" "$out_bak_path" 'HANDLER --import-config /root/bk/a.tar.gz'
    assert_contains "T3: 给出路径 -> 正常返回"       "$out_bak_path" 'RC=0'
fi

# ---------------------------------------------------------------------------
echo "[NEG] 负向校验: 改回 _error 版, 确认本用例真能捕获回归"
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
    python3 - "$TMPD/fn_sni.sh" "$TMPD/fn_sni_broken.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding='utf-8').read()
old = """    if [[ "${tag,,}" != 'sni' ]]; then
        print_warn "$(_i18n ".${CUR_FILE}.not_support")"
        return 0
    fi"""
new = """    [[ "${tag,,}" == 'sni' ]] || _error "$(_i18n ".${CUR_FILE}.not_support")" """
assert old in src, 'NEG: 未在真实函数体中找到守卫块 (测试需跟随实现更新)'
open(sys.argv[2], 'w', encoding='utf-8').write(src.replace(old, new))
PY
    if [[ -s "$TMPD/fn_sni_broken.sh" ]]; then
        neg_fn="$(cat "$TMPD/fn_sni_broken.sh")"
        if guard_is_graceful "$neg_fn"; then
            bad "NEG: 静态谓词未能识别破损版 (断言形同虚设)"
        else
            ok "NEG: 静态谓词能识别破损版 (T1 有效)"
        fi
        if command -v jq >/dev/null 2>&1; then
            # 复用同一套桩件渲染破损版 runner, 断言"优雅契约"不再成立
            {
                printf '%s\n' 'set -Eeuo pipefail'
                printf '%s\n' 'CUR_FILE="main"'
                printf '%s\n' '_i18n() { printf "%s" "$1"; }'
                printf '%s\n' 'print_warn() { printf "WARN %s\n" "$*" >&2; }'
                printf '%s\n' '_error() { printf "ERROR %s\n" "$*" >&2; exit 1; }'
                printf '%s\n' 'exec_menu() { printf "MENUCALL %s\n" "$*" >&2; cat "${CHFILE:-/dev/null}" 2>/dev/null || true; }'
                cat "$TMPD/fn_sni_broken.sh"
                printf '%s\n' 'processes_sni_config'
                printf '%s\n' 'printf "RC=%s\n" "$?"'
            } > "$TMPD/runner_neg.sh"
            # 必须显式回到 tag=vision —— 上一段 T2b 循环把 cfg.json 留成了 tag=Sni,
            # 直接复用会让破损版恰好走"合法分支"而不触发 _error, NEG 假绿。
            printf '{"xray":{"tag":"vision"}}\n' > "$TMPD/cfg.json"
            neg_out="$(CHFILE="$TMPD/ch" SCRIPT_CONFIG_PATH="$TMPD/cfg.json" "$BASH_BIN" "$TMPD/runner_neg.sh" 2>&1)"
            assert_contains     "NEG: 破损版会硬退出 (有 ERROR)" "$neg_out" 'ERROR'
            assert_not_contains "NEG: 破损版拿不到 RC=0"          "$neg_out" 'RC=0'
        fi
    else
        bad "NEG: 破损版生成失败"
    fi
else
    echo "  SKIP: 缺少 python3, 跳过 NEG 负向校验"
fi

echo
echo "==== menu_guard_soft_fail_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
