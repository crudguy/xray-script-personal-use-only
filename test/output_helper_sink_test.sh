#!/usr/bin/env bash
# =============================================================================
# 测试名称: output_helper_sink_test.sh
# 测试目标: 输出助手 (print_* 与短名 _error/_warn/_info/_pass, 及 check.sh 的 _check_*) 的
#           「单一真源 + 刻意差异 + 无同名遮蔽」契约, 以及由下沉顺带修复的 share.sh 崩溃回归。
#
# 为什么需要本测试 (审计结论):
#   1) 短名助手曾有三套同源副本: main.sh / handler.sh 各一份 _error (逐字相同),
#      handler.sh / backup.sh 各一份 _info/_warn。改一处忘一处即漂移 —— handler.sh 的
#      注释就写着"与 check.sh / backup.sh 里的同名函数格式完全一致", 而实际 check.sh
#      的 _info 是**黄色** (体检语境用它把"信息"与"通过"分开), 与事实不符。
#   2) 更要命的是一处**真实缺陷**: core/share.sh 由 `bash "${CUR_DIR}/share.sh"` 子进程
#      执行 (main.sh:156/245), 不继承父进程函数; 其 cache_json_data 在"Xray 未安装"分支
#      调用 _error —— 而全仓无定义, 用户实际看到的是
#          bash: _error: 未找到命令
#          [错误] 脚本在第 N 行意外失败 (退出码 127): _error "..."
#      恰恰就是该分支注释里说要避免的"看不懂的报错"。
#   修法 = 把短名统一下沉到 core/_common.sh (print_* 的别名), 各脚本删副本。
#   后续: check.sh 的三个本地助手 (_info/_pass/_fail) 虽为刻意实现, 却与 _common.sh 的
#      同名别名重名 —— 构成"同名不同行为"的遮蔽陷阱 (且 check.sh 的 _fail 还与 backup.sh
#      的同名函数语义相反)。本次加 _check_ 前缀消歧义, 行为与视觉零变化。
#
# 锁定不变量:
#   T1 单一真源   —— main.sh / handler.sh / backup.sh 不得再有短名副本; _common.sh 提供四个别名
#   T2 别名等价   —— _error≡print_error / _info≡print_info / _warn≡print_warn / _pass≡print_pass
#                    (同输入下 stdout、stderr、退出码三项全等)
#   T3 share 回归 —— 仅抽 _common.sh 的实现 + share.sh 的 cache_json_data, 未安装分支
#                    必须 rc=1 并打出错误行, 且**不得**出现"未找到命令"/"command not found"/127
#   T4 刻意差异   —— check 的 _check_info 用黄且只取首参; _check_fail 不退出; backup._fail exit 1
#   T5 负向校验   —— 把别名改成指向不存在的函数, T3 的判据必须变红 (证明断言非恒绿)
#   T6 消歧义     —— check.sh 用 _check_ 前缀后不得再有裸 _info/_pass/_fail; _test 保持原名
#
# 实现: 用 awk/grep 抽**真实函数体** (不另写实现, 避免漂移), 桩件走 heredoc。
#   别名型函数 (`function _error() { print_error "$@"; }`) 是单行, 抽取器需先试单行形态,
#   否则 awk 找不到行首 `}` 会一路吞到文件尾。
#   NEG 只在**副本**上改坏, 绝不碰仓库工作区。
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$REPO"
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1 (期望 [$3] 实际 [$2])"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1 (未包含 [$3])"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1 (不应包含 [$3])"; fi; }

SB="$REPO/.workbuddy/tmp/outhelper_sink.$$"
rm -rf "$SB" 2>/dev/null || true
mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

COMMON=core/_common.sh

# 抽取真实函数体: 先试单行形态 (别名), 再退回 awk 多行 (以行首 `}` 收尾)
extract_fn() { # $1=file $2=fn
    local one
    one="$(grep -m1 -E "^function ${2}\\(\\) \\{.*\\}$" "$1" 2>/dev/null || true)"
    if [[ -n "$one" ]]; then
        printf '%s\n' "$one"
        return 0
    fi
    awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' "$1"
}

# ---------------------------------------------------------------------------
echo "== T1: 单一真源 — 短名不再散落各脚本 =="
# ---------------------------------------------------------------------------
for spec in "core/main.sh:_error" "core/main.sh:_warn" \
    "core/handler.sh:_error" "core/handler.sh:_warn" \
    "core/handler.sh:_info" "core/handler.sh:_pass" \
    "tool/backup.sh:_info" "tool/backup.sh:_warn"; do
    f="${spec%%:*}"
    fn="${spec##*:}"
    if [[ -z "$(extract_fn "$f" "$fn")" ]]; then ok; else bad "$f 仍留有本地 $fn 副本 (应已下沉)"; fi
done
for fn in _error _warn _info _pass; do
    assert_contains "_common.sh 提供 $fn (指向 print_*)" "$(extract_fn "$COMMON" "$fn")" "print_"
done
assert_contains "_common.sh 新增 print_pass" "$(extract_fn "$COMMON" print_pass)" ".title.pass"

# ---------------------------------------------------------------------------
echo "== T2: 别名与目标行为等价 =="
# ---------------------------------------------------------------------------
cat > "${SB}/stub.sh" <<'STUB'
RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; NC=$'\033[0m'
_i18n() {
    case "${1:-}" in
        '.title.error') printf 'ERR' ;;
        '.title.hint') printf 'HINT' ;;
        '.title.info') printf 'INFO' ;;
        '.title.warn') printf 'WARN' ;;
        '.title.pass') printf 'PASS' ;;
        *) printf '' ;;
    esac
}
STUB

craft() { # $1=输出脚本 $2=目标函数 $3=别名 (空则只装目标)
    local out="$1" t="$2" a="${3:-}"
    {
        printf 'source %q\n' "${SB}/stub.sh"
        extract_fn "$COMMON" "$t"
        if [[ -n "$a" ]]; then extract_fn "$COMMON" "$a"; fi
        printf '%s "$@"\n' "${a:-$t}"
    } > "$out"
}

for pair in "_error:print_error" "_warn:print_warn" "_info:print_info" "_pass:print_pass"; do
    a="${pair%%:*}"
    t="${pair##*:}"
    craft "${SB}/via_alias.sh" "$t" "$a"
    craft "${SB}/via_real.sh" "$t"
    rc_a=0
    "$BASH_BIN" "${SB}/via_alias.sh" 'msg' 'hint' > "${SB}/ao" 2> "${SB}/ae" || rc_a=$?
    rc_b=0
    "$BASH_BIN" "${SB}/via_real.sh" 'msg' 'hint' > "${SB}/bo" 2> "${SB}/be" || rc_b=$?
    assert_eq "$a 与 $t 退出码一致" "$rc_a" "$rc_b"
    assert_eq "$a 与 $t stdout 一致" "$(cat "${SB}/ao")" "$(cat "${SB}/bo")"
    assert_eq "$a 与 $t stderr 一致" "$(cat "${SB}/ae")" "$(cat "${SB}/be")"
done

# ---------------------------------------------------------------------------
echo "== T3: share.sh 未安装分支不再 command not found (本次修复的回归) =="
# ---------------------------------------------------------------------------
share_fn="$(extract_fn core/share.sh cache_json_data)"
assert_contains "可抽取 share.cache_json_data" "$share_fn" 'cache_json_data'
assert_contains "该分支确实调用 _error" "$share_fn" '_error'

# 组装真实链路: 桩 i18n + _common.sh 的 print_error/_error + share.sh 的 cache_json_data
build_share_probe() { # $1=common 源文件 $2=输出脚本
    {
        printf 'source %q\n' "${SB}/stub.sh"
        extract_fn "$1" print_error
        extract_fn "$1" _error
        printf 'XRAY_CONFIG_PATH=%q\n' "${SB}/no-such-xray-config.json"
        printf 'SCRIPT_CONFIG_PATH=%q\n' "${SB}/no-such-script-config.json"
        printf 'CUR_FILE=share\n'
        printf '%s\n' "$share_fn"
        printf 'cache_json_data\n'
    } > "$2"
}

build_share_probe "$COMMON" "${SB}/share_ok.sh"
rc_s=0
"$BASH_BIN" "${SB}/share_ok.sh" > "${SB}/so" 2> "${SB}/se" || rc_s=$?
assert_eq "未安装分支 rc=1 (友好退出而非 127)" "1" "$rc_s"
assert_contains "打出错误行 (title.error 桩 = ERR)" "$(cat "${SB}/se")" 'ERR'
assert_not_contains "不再出现中文 未找到命令" "$(cat "${SB}/se")" '未找到命令'
assert_not_contains "不再出现 command not found" "$(cat "${SB}/se")" 'command not found'
assert_not_contains "不再出现退出码 127" "$(cat "${SB}/se")" '127'
assert_eq "stdout 保持干净 (错误只走 stderr)" "" "$(cat "${SB}/so")"

# ---------------------------------------------------------------------------
echo "== T4: 刻意差异被保留 (非疏漏, 不得被'顺手统一') =="
# ---------------------------------------------------------------------------
ci="$(extract_fn core/check.sh _check_info)"
assert_contains "check._check_info 用黄色" "$ci" 'YELLOW'
assert_not_contains "check._check_info 不是绿色 (故与 handler/backup 不同)" "$ci" 'GREEN'
assert_contains "check._check_info 只取首参" "$ci" '"${1:-}"'

cf="$(extract_fn core/check.sh _check_fail)"
assert_not_contains "check._check_fail 不退出 (体检要跑完全部检查项)" "$cf" 'exit 1'
bf="$(extract_fn tool/backup.sh _fail)"
assert_contains "backup._fail 退出 (备份失败即终止)" "$bf" 'exit 1'
assert_contains "common._info 走 print_info" "$(extract_fn "$COMMON" _info)" 'print_info'

# ---------------------------------------------------------------------------
echo "== T5: 负向校验 — 别名坏掉后 T3 的判据必须变红 =="
# ---------------------------------------------------------------------------
cp "$COMMON" "${SB}/common_neg.sh"
sed -i 's|^function _error() { print_error "\$@"; }|function _error() { __missing_sink_fn "$@"; }|' "${SB}/common_neg.sh"
if [[ "$(extract_fn "${SB}/common_neg.sh" _error)" != *'__missing_sink_fn'* ]]; then
    bad "NEG: 改坏未生效 (sed 未命中), 本用例无意义"
else
    ok
    build_share_probe "${SB}/common_neg.sh" "${SB}/share_neg.sh"
    rc_n=0
    "$BASH_BIN" "${SB}/share_neg.sh" > "${SB}/no" 2> "${SB}/ne" || rc_n=$?
    # 注: 判据是"别名坏了就该真的炸", 不是"炸出哪个语种的文案" —— bash 的报错文案随
    #     locale 变化 (中文环境给 "未找到命令", CI 的 C.UTF-8 给 "command not found"),
    #     只锚中文会让本用例在 CI 上恒红 (本地中文环境看不到)。故两种形态都接受。
    neg_err="$(cat "${SB}/ne")"
    if [[ "${neg_err}" == *'未找到命令'* || "${neg_err}" == *'command not found'* ]]; then
        ok
    else
        bad "NEG: 坏掉后确实 command not found (故 T3 判据有效) (实际 [${neg_err}])"
    fi
    assert_not_contains "NEG: 坏掉后不再有友好错误行 (故 T3 的 ERR 断言会红)" "$(cat "${SB}/ne")" 'ERR'
    # 注: 这里**不断言** 127 —— 子脚本不带 set -e, `command not found` 之后会继续往下跑,
    #     最终函数返回 0, 错误被静默吞掉。比"报 127"更隐蔽, 也正是本用例要防的形态。
    if [[ "$rc_n" == '1' ]]; then
        bad "NEG: 坏掉后退出码仍是 1 (T3 的 rc 判据恒绿?)"
    else
        ok
    fi
fi

# ---------------------------------------------------------------------------
echo "== T6: check.sh 助手加 _check_ 前缀 (消同名遮蔽歧义) =="
# ---------------------------------------------------------------------------
# 三个 _check_* 定义须齐全; 且**不得**再有裸 _info/_pass/_fail 的定义或调用 ——
# 有则说明漏改 (又回到遮蔽), 或像 _fail 那样"未定义即崩"。
for fn in _check_info _check_pass _check_fail; do
    if [[ -n "$(extract_fn core/check.sh "$fn")" ]]; then ok; else bad "core/check.sh 缺 $fn 定义"; fi
done
for fn in _info _pass _fail; do
    # 注: grep -c 无匹配时退出码为 1, 在 set -e 下会直接杀掉脚本 (命令替换里的退出码
    #     同样是赋值语句的退出码) -> 必须 `|| true` 接住, 否则本用例在"零匹配"(=期望结果)
    #     时反而崩溃。
    n="$(grep -cE "(^function ${fn}\(\) \{)|(^[[:space:]]*${fn} )" core/check.sh || true)"
    assert_eq "check.sh 无裸 ${fn} 定义/调用" "0" "$n"
done
# _test 全仓独此一份、无重名 -> 本次刻意不扩大改动面
assert_contains "check._test 保持原名 (无歧义, 未一并改名)" "$(extract_fn core/check.sh _test)" 'title.test'

# NEG: 副本里把 _check_info 全量改回裸 _info, 上面的检测必须变红 (否则判据恒绿)
cp core/check.sh "${SB}/check_neg.sh"
sed -i -e 's/^function _check_info() {/function _info() {/' \
    -e 's/^\([[:space:]]*\)_check_info /\1_info /' "${SB}/check_neg.sh"
if [[ -z "$(extract_fn "${SB}/check_neg.sh" _check_info)" ]]; then
    ok
    neg_n="$(grep -cE "(^function _info\(\) \{)|(^[[:space:]]*_info )" "${SB}/check_neg.sh" || true)"
    if [[ "${neg_n}" -ge 1 ]]; then ok; else bad "NEG: 裸 _info 未被 T6 检测命中 (判据恒绿?)"; fi
else
    bad "NEG: 改坏未生效 (sed 未命中 _check_info 定义), 本用例无意义"
fi

echo "---"
echo "==== output_helper_sink_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
