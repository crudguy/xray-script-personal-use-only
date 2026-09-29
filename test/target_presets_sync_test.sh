#!/usr/bin/env bash
# shellcheck disable=SC2034  # 本用例把 install.sh 的真实函数体 awk 抽取后 eval 注入, 下列常量与桩件变量 (I18N_DATA/GREEN/NC/PROJECT_ROOT/SCRIPT_CONFIG_PATH/JQ_AVAILABLE/AW_FAIL) 由被注入的函数体读取; shellcheck 的数据流不跨 eval。
# =============================================================================
# 测试名称: target_presets_sync_test.sh
# 测试目标: 锁定 install.sh 的 _sync_target_presets —— 启动期把上游模板的 Reality
#   target 预设同步进运行时配置 (补新增 / 删上游点名失效), 且绝不误伤用户数据。
#
# 背景: 运行时 config.json 只在**首次安装**时下载一次, 此后永远不再从模板取 ——
#   上游修掉一个不可用预设, 早已装好的机器也拿不到 (本轮清理 .target 里的
#   fandom 家族 / leercapitulo 即因此需在升级说明里附一条手工 jq 命令)。
#   自愈逻辑因此必须同时守好两个方向: 只补该补的, 只删上游显式点名失效的。
#
# 锁定:
#   1. 合并: 模板有而运行时没有的键被补入; **已存在的键其值不被覆盖** (用户可能改过
#      serverNames); 运行时独有的键一律保留 (只增不删); 其它顶层键毫发无伤;
#   2. 删除: 仅删模板 .target_removed 点名的键, 且删除前留 .bak 备份 (可回滚);
#      模板没有该字段时什么都不删;
#   3. 幂等: 无差异时不写盘、不打印;
#   4. 边界: 前置条件不满足 (文件缺失 / .target 形态不符 / jq 不可用) 一律静默 return 0;
#   5. 安全: jq 失败时绝不把空内容写回 (配置不被清空); 写盘失败也 return 0 不阻断启动;
#      提示只走 stderr (stdout 会被 --share / --export-config 等直达参数消费);
#   6. 契约: main() 在"项目目录就位"之后才调用它; install.sh 双份 I18N_DATA (zh/en)
#      的 3 个提示键齐备且 en 那份是纯 ASCII; config.json 的 target_removed 合法、
#      不与预设池 .target 的键重叠;
#   7. (NEG) 逐条把守卫改坏, 同一套判据必须报警 —— 证明守卫不是恒绿摆设。
#
# 依赖网络吗: 不。
# 运行: bash test/target_presets_sync_test.sh
# =============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available in this environment"
    exit 0
fi

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1" >&2; }
assert_eq() { local d="$1" g="$2" e="$3"; if [[ "$g" == "$e" ]]; then ok "$d"; else bad "$d (got[$g] exp[$e])"; fi; }
assert_ne() { local d="$1" g="$2" u="$3"; if [[ "$g" != "$u" ]]; then ok "$d"; else bad "$d (got[$g] should not be [$u])"; fi; }
assert_contains() { local d="$1" h="$2" n="$3"; if [[ "$h" == *"$n"* ]]; then ok "$d"; else bad "$d (missing [$n])"; fi; }
assert_not_contains() { local d="$1" h="$2" n="$3"; if [[ "$h" != *"$n"* ]]; then ok "$d"; else bad "$d (unexpectedly has [$n])"; fi; }

SRC='install.sh'
SB=".workbuddy/tmp/target_sync_$$"; rm -rf "$SB"; mkdir -p "$SB/repo" "$SB/neg"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# 抽取 install.sh 的真实函数体 (不另写一份实现, 避免测试与实现漂移)
# 注: 全程用临时文件承载多行内容, 不用进程替换 —— 沙箱缺 /dev/fd 时 < <(...) 会失效
# ---------------------------------------------------------------------------
extract_fn() { # $1=函数名 $2=源文件
    awk -v fn="$1" '$0 ~ "^function " fn "\\(\\) \\{" {f=1} f{print} f && /^\}$/ {exit}' "$2"
}

SYNC="$(extract_fn _sync_target_presets "$SRC")"
AT_RAW="$(extract_fn _atomic_write "$SRC")"
assert_ne "T0: 抽到 _sync_target_presets 函数体" "${SYNC}" ""
assert_ne "T0: 抽到 _atomic_write 函数体" "${AT_RAW}" ""
if [[ $FAIL -ne 0 ]]; then echo "PASS=$PASS FAIL=$FAIL"; exit 1; fi
printf '%s\n' "${SYNC}" > "$SB/sync_body.txt"

# 真实原子写改名为 _aw_real 保留 (桩件转交它落盘, 使"落盘内容"仍是真的)
AT_REAL="${AT_RAW/function _atomic_write/function _aw_real}"
eval "${AT_REAL}"

# ---- 被注入函数体读取的全局常量 / 桩件基础 ----
declare -A I18N_DATA=()
I18N_DATA['tip']='tip'
I18N_DATA['presets_added']='ADDED'
I18N_DATA['presets_removed']='REMOVED'
I18N_DATA['presets_sync_failed']='SYNCFAIL'
GREEN=''; YELLOW=''; NC=''
JQ_AVAILABLE=1
cmd_exists() { [[ "$1" == 'jq' && "${JQ_AVAILABLE}" == '1' ]]; }
ATOMIC_LOG="$SB/atomic_log"; : > "$ATOMIC_LOG"
AW_FAIL=''
# 桩件用 eval 注入 (与 install_update_test.sh 同款): shellcheck 的数据流不跨 eval,
# 且规避"定义前调用"类的静态误报。桩件既记录调用次数 (它被 | 管道调用, 变量不回传,
# 故用文件承载), 又转交真实原子写。
eval '_atomic_write() { printf "%s\n" "${1:-}" >> "$ATOMIC_LOG"; if [[ -n "$AW_FAIL" ]]; then return 1; fi; _aw_real "${1:-}"; }'

eval "${SYNC}"

# ---------------------------------------------------------------------------
# 夹具
# ---------------------------------------------------------------------------
# 模板 = 仓库真实 config.json (保证与生产同源)
cp config.json "$SB/repo/config.json"
TEMPLATE="$SB/repo/config.json"
RUNTIME="$SB/runtime.json"

# 模拟一台"老机器": 只认得 2 个预设, 其中 tidal 的 serverNames 被用户改过;
# 另有 1 个自加域名, 以及 1 个上游已判定失效 (在 target_removed 名单里) 的域名。
setup_legacy() {
    jq -n '{
      version: "v-old",
      language: "zh",
      path: "/usr/local/x",
      my_own_key: "keepme",
      target: {
        "tidal.com": ["tidal.com", "user.custom.example"],
        "www.fandom.com": ["www.fandom.com"],
        "my.own.example": ["my.own.example"]
      }
    }' > "$RUNTIME"
}

run_sync() {
    : > "$ATOMIC_LOG"
    local rc=0
    _sync_target_presets >"$SB/out.txt" 2>"$SB/err.txt" || rc=$?
    printf '%s' "$rc" > "$SB/rc.txt"
    return 0
}
calls() { wc -l < "$ATOMIC_LOG" | tr -d ' \n'; }

PROJECT_ROOT="$SB/repo"
SCRIPT_CONFIG_PATH="$RUNTIME"

# ============================================================ T1 合并语义
echo "== T1 合并语义 (只补缺失键, 不覆盖已有值) =="
setup_legacy
assert_eq "T1 前置: 老配置只有 3 个预设" "$(jq -r '.target | length' "$RUNTIME")" "3"
pre="$(cat "$RUNTIME")"
run_sync
assert_eq "T1a: 返回 0" "$(cat "$SB/rc.txt")" "0"
assert_eq "T1b: 恰好写盘一次" "$(calls)" "1"
assert_eq "T1c: 模板里的新预设已补入 (www.sony.com)" \
    "$(jq -r '.target | has("www.sony.com")' "$RUNTIME")" "true"
# 期望值 = 模板键数 + 运行时独有的键数 (my.own.example 这 1 个, 只增不删)
# 注意 www.fandom.com 被删、但它本就不在模板里, 故不影响模板那一项
expect_n=$(( $(jq -r '.target | length' "$TEMPLATE") + 1 ))
assert_eq "T1d: 补入后数量 = 模板键数 + 运行时独有键数" \
    "$(jq -r '.target | length' "$RUNTIME")" "${expect_n}"
assert_eq "T1e: 已存在的键其 serverNames 不被覆盖 (用户改过)" \
    "$(jq -c '.target["tidal.com"]' "$RUNTIME")" '["tidal.com","user.custom.example"]'
assert_eq "T1f: 运行时独有的键保留 (只增不删)" \
    "$(jq -r '.target | has("my.own.example")' "$RUNTIME")" "true"
assert_eq "T1g: 其它顶层键不受影响 (version)" "$(jq -r '.version' "$RUNTIME")" "v-old"
assert_eq "T1h: 其它顶层键不受影响 (language)" "$(jq -r '.language' "$RUNTIME")" "zh"
assert_eq "T1i: 未知的自定义顶层键也保留" "$(jq -r '.my_own_key' "$RUNTIME")" "keepme"
assert_ne "T1j: 配置确实发生了变化" "$(cat "$RUNTIME")" "$pre"
assert_eq "T1k: 同步后 JSON 合法且 .target 仍是对象" \
    "$(jq -r '.target | type == "object"' "$RUNTIME")" "true"
assert_contains "T1l: 提示走 stderr (补入明细)" "$(cat "$SB/err.txt")" 'ADDED'
assert_eq "T1m: stdout 保持干净 (不被提示污染)" "$(cat "$SB/out.txt")" ""

# ============================================================ T2 删除语义
echo "== T2 删除语义 (只删上游点名失效的键) =="
assert_eq "T2a: target_removed 点名的键已删除" \
    "$(jq -r '.target | has("www.fandom.com")' "$RUNTIME")" "false"
assert_contains "T2b: 提示走 stderr (移除明细)" "$(cat "$SB/err.txt")" 'REMOVED'
assert_contains "T2c: 提示里点名了被删域名" "$(cat "$SB/err.txt")" 'www.fandom.com'
assert_eq "T2d: 删除前留下 .bak 备份" \
    "$([[ -f "${RUNTIME}.bak" ]] && echo yes || echo no)" "yes"
assert_eq "T2e: .bak 内容是同步前的原样" "$(cat "${RUNTIME}.bak")" "$pre"
assert_eq "T2f: 未点名的键不被删 (模板也有的 tidal)" \
    "$(jq -r '.target | has("tidal.com")' "$RUNTIME")" "true"
assert_eq "T2g: 未点名的键不被删 (用户自加的)" \
    "$(jq -r '.target | has("my.own.example")' "$RUNTIME")" "true"

# 模板没有 target_removed 字段时: 无名单即不删, 且不报错
PROJECT_ROOT="$SB/t_no_removed"; mkdir -p "$PROJECT_ROOT"
jq 'del(.target_removed)' "$TEMPLATE" > "$PROJECT_ROOT/config.json"
SCRIPT_CONFIG_PATH="$RUNTIME"
jq -n '{target: {"www.fandom.com": ["www.fandom.com"]}}' > "$RUNTIME"
run_sync
assert_eq "T2h: 模板无 target_removed 时命中的域名不被删 (无名单即不删)" \
    "$(jq -r '.target | has("www.fandom.com")' "$RUNTIME")" "true"
assert_eq "T2i: 模板无 target_removed 时仍正常返回 0" "$(cat "$SB/rc.txt")" "0"

# ============================================================ T3 幂等
echo "== T3 幂等 (无差异不写盘、不打印) =="
PROJECT_ROOT="$SB/repo"; SCRIPT_CONFIG_PATH="$RUNTIME"
setup_legacy
run_sync   # 第一次: 产生差异
run_sync   # 第二次: 应完全空转
assert_eq "T3a: 第二次不再写盘" "$(calls)" "0"
assert_eq "T3b: 第二次不打印任何提示" "$(cat "$SB/err.txt")" ""
assert_eq "T3c: 第二次仍返回 0" "$(cat "$SB/rc.txt")" "0"

# ============================================================ T4 前置条件静默跳过
echo "== T4 前置条件不满足时静默跳过 =="
skip_case() { # $1=说明 (调用方负责布置夹具)
    : > "$ATOMIC_LOG"
    local rc=0
    _sync_target_presets >"$SB/out.txt" 2>"$SB/err.txt" || rc=$?
    assert_eq "T4($1): 返回 0 不阻断" "$rc" "0"
    assert_eq "T4($1): 未写盘" "$(calls)" "0"
}

# a) 模板文件不存在
setup_legacy
PROJECT_ROOT="$SB/empty_repo"; mkdir -p "$PROJECT_ROOT"; rm -f "$PROJECT_ROOT/config.json"
SCRIPT_CONFIG_PATH="$RUNTIME"; skip_case "模板缺失"

# b) 运行时配置不存在
setup_legacy
PROJECT_ROOT="$SB/repo"; SCRIPT_CONFIG_PATH="$SB/nonexistent.json"; skip_case "运行时缺失"

# c) 模板 .target 缺失
setup_legacy
SCRIPT_CONFIG_PATH="$RUNTIME"
PROJECT_ROOT="$SB/t_no_target"; mkdir -p "$PROJECT_ROOT"
jq 'del(.target)' "$TEMPLATE" > "$PROJECT_ROOT/config.json"; skip_case "模板无 .target"

# d) 模板 .target 是空对象
PROJECT_ROOT="$SB/t_empty_target"; mkdir -p "$PROJECT_ROOT"
jq '.target = {}' "$TEMPLATE" > "$PROJECT_ROOT/config.json"; skip_case "模板 .target 为空"

# e) 模板 .target 非对象 (字符串)
PROJECT_ROOT="$SB/t_str_target"; mkdir -p "$PROJECT_ROOT"
jq '.target = "not-an-object"' "$TEMPLATE" > "$PROJECT_ROOT/config.json"; skip_case "模板 .target 非对象"

# f) 运行时 .target 缺失
PROJECT_ROOT="$SB/repo"; printf '{"version":"v"}\n' > "$RUNTIME"
SCRIPT_CONFIG_PATH="$RUNTIME"; skip_case "运行时无 .target"

# g) 运行时 .target 非对象
printf '{"target":"nope"}\n' > "$RUNTIME"; skip_case "运行时 .target 非对象"

# h) jq 不可用
setup_legacy; JQ_AVAILABLE=0; skip_case "jq 不可用"; JQ_AVAILABLE=1

# ============================================================ T5 安全防护
echo "== T5 安全防护 =="
PROJECT_ROOT="$SB/repo"; SCRIPT_CONFIG_PATH="$RUNTIME"

# a) 运行时配置是非法 JSON -> 不得清空它
printf 'THIS IS NOT JSON{{{\n' > "$RUNTIME"
broken_pre="$(cat "$RUNTIME")"
: > "$ATOMIC_LOG"
rc=0; _sync_target_presets >"$SB/out.txt" 2>"$SB/err.txt" || rc=$?
assert_eq "T5a: 非法 JSON 时返回 0 (不阻断启动)" "$rc" "0"
assert_eq "T5a: 非法 JSON 时未写盘" "$(calls)" "0"
assert_eq "T5a: 非法 JSON 的内容未被清空" "$(cat "$RUNTIME")" "$broken_pre"

# b) 写盘失败 -> 仍返回 0, 并给出提示 (不阻断启动)
setup_legacy
AW_FAIL=1
run_sync
assert_eq "T5b: 写盘失败时仍返回 0" "$(cat "$SB/rc.txt")" "0"
assert_contains "T5b: 写盘失败有提示" "$(cat "$SB/err.txt")" 'SYNCFAIL'
assert_eq "T5b: 写盘失败时配置未被破坏 (仍是合法 JSON)" \
    "$(jq -r '.target | length' "$RUNTIME")" "3"
AW_FAIL=''

# c) 提示只走 stderr
setup_legacy
run_sync
assert_eq "T5c: 提示不污染 stdout" "$(cat "$SB/out.txt")" ""

# ============================================================ T6 静态契约
echo "== T6 静态契约 =="
assert_contains "T6a: 两侧文件缺失即 return 0" "${SYNC}" '[[ -f "${repo_config}" && -f "${SCRIPT_CONFIG_PATH}" ]] || return 0'
assert_contains "T6b: jq 不可用即 return 0" "${SYNC}" "cmd_exists 'jq' || return 0"
assert_contains "T6c: 先用变量接住 jq 结果 (非同文件管道直写)" "${SYNC}" 'new_config="$(jq'
assert_contains "T6d: 取空即放弃 (绝不把空内容写回)" "${SYNC}" '[[ -n "${new_config}" ]] || return 0'
assert_contains "T6e: 用 _atomic_write 原子落盘" "${SYNC}" '_atomic_write "${SCRIPT_CONFIG_PATH}"'
assert_contains "T6f: 无差异时不写盘 (差异判据早退)" "${SYNC}" '[[ -n "${to_add}${to_del}" ]] || return 0'
assert_contains "T6g: 删除前先备份" "${SYNC}" '.bak'
assert_contains "T6h: 删除只认上游显式名单" "${SYNC}" 'target_removed'

# 三条提示必须全部重定向到 stderr (stdout 会被 --share/--export-config 消费)
hints=0; hints_all_stderr=1
while IFS= read -r line; do
    [[ "$line" == *'echo -e'* ]] || continue
    hints=$((hints + 1))
    [[ "$line" == *'>&2'* ]] || hints_all_stderr=0
done < "$SB/sync_body.txt"
assert_eq "T6i: 函数内共 3 条提示" "$hints" "3"
assert_eq "T6i: 三条提示都走 stderr" "$hints_all_stderr" "1"

call_line="$(grep -n '^    _sync_target_presets$' "$SRC" | head -1 | cut -d: -f1)"
anchor_line="$(grep -n 'if \[\[ -d "${PROJECT_ROOT}" \]\]' "$SRC" | head -1 | cut -d: -f1)"
assert_ne "T6j: main() 中调用了 _sync_target_presets" "${call_line}" ""
assert_ne "T6j: 找到项目目录就位的判断行" "${anchor_line}" ""
if [[ -n "${call_line}" && -n "${anchor_line}" && "${call_line}" -gt "${anchor_line}" ]]; then
    ok "T6k: 调用发生在项目目录就位之后 (模板才是最新的)"
else
    bad "T6k: 调用位置不在项目目录就位之后 (call=${call_line} anchor=${anchor_line})"
fi

# ============================================================ T7 i18n (install.sh 双份)
echo "== T7 install.sh 双份 I18N_DATA =="
zh_block="$(sed -n '/^declare -A I18N_DATA=(/,/^)/p' "$SRC")"
en_block="$(sed -n '/^        I18N_DATA=(/,/^        )/p' "$SRC")"
assert_ne "T7: 抽到中文默认块" "${zh_block}" ""
assert_ne "T7: 抽到英文块" "${en_block}" ""
for k in presets_added presets_removed presets_sync_failed; do
    assert_contains "T7(zh): 含 ${k} 且非空" "${zh_block}" "['${k}']='"
    assert_contains "T7(en): 含 ${k} 且非空" "${en_block}" "['${k}']='"
done
assert_not_contains "T7: 中文块里没有混入英文文案" "${zh_block}" 'Reality target presets'
printf '%s\n' "${en_block}" > "$SB/en_block.txt"
nonascii=0
LC_ALL=C grep -q '[^ -~]' "$SB/en_block.txt" && nonascii=1
assert_eq "T7: 英文块是纯 ASCII (确实是英文那一份)" "${nonascii}" "0"

# ============================================================ T8 config.json 的名单不变量
echo "== T8 config.json 的 target_removed 不变量 =="
DOMAIN_REGEX="$(sed -n 's/^readonly DOMAIN_REGEX="\(.*\)"$/\1/p' core/_common.sh)"
assert_ne "T8: 从 core/_common.sh 取到 DOMAIN_REGEX" "${DOMAIN_REGEX}" ""
assert_eq "T8a: target_removed 存在且是非空数组" \
    "$(jq -r '.target_removed | type == "array" and length > 0' config.json)" "true"
jq -r '.target_removed[]' config.json > "$SB/removed_list.txt"
bad_elem=''
while IFS= read -r d; do
    [[ -n "${d}" ]] || continue
    if ! [[ "${d}" =~ ${DOMAIN_REGEX} ]]; then bad_elem="${bad_elem}${d} "; fi
done < "$SB/removed_list.txt"
assert_eq "T8b: 名单里每项都是合法域名" "${bad_elem}" ""
assert_eq "T8c: 名单里的域名不得同时留在预设池 (否则删了又补)" \
    "$(jq -c '[.target_removed[] as $k | select(.target | has($k))]' config.json)" "[]"
assert_eq "T8d: 预设池里的域名不得出现在名单中" \
    "$(jq -c '[.target | keys[] as $k | select(.target_removed | index($k))]' config.json)" "[]"

# ============================================================ T9 (NEG) 守卫自证
echo "== T9 (NEG) 把守卫改坏, 同一套判据必须报警 =="
SRC_TEXT="$(cat "$SRC")"

# NEG-A: 把"不覆盖已存在键"改成无条件覆盖 -> T1e 的判据必须翻转
ORIG_KEEP='if (.target | has($e.key)) then . else .target[$e.key] = $e.value end'
NEW_OVERWRITE='.target[$e.key] = $e.value'
assert_contains "T9a: 定位到 keep-if-exists 守卫" "${SRC_TEXT}" "${ORIG_KEEP}"
sed 's/if (\.target | has(\$e\.key)) then \. else \.target\[\$e\.key\] = \$e\.value end/.target[$e.key] = $e.value/' \
    "$SRC" > "$SB/neg/overwrite.sh"
neg_a="$(extract_fn _sync_target_presets "$SB/neg/overwrite.sh")"
assert_not_contains "T9a(NEG): 破损副本已无 keep 守卫" "${neg_a}" "${ORIG_KEEP}"
eval "${neg_a}"
setup_legacy
run_sync
assert_eq "T9a(NEG): 去掉守卫后用户改过的 serverNames 被覆盖 = T1e 判据真会红" \
    "$(jq -c '.target["tidal.com"]' "$RUNTIME")" '["tidal.com"]'
eval "${SYNC}"   # 复原真实实现

# NEG-B: 删掉删除段所在行 (jq 表达式因此语法错误 -> 整体放弃) -> T2a 的判据必须翻转
grep -vF '| reduce ($removed[]) as $k (.;' "$SRC" > "$SB/neg/nodel.sh"
neg_b="$(extract_fn _sync_target_presets "$SB/neg/nodel.sh")"
assert_ne "T9b(NEG): 破损副本抽到了函数体" "${neg_b}" ""
assert_not_contains "T9b(NEG): 破损副本已无删除段" "${neg_b}" 'reduce ($removed[]) as $k'
eval "${neg_b}"
setup_legacy
run_sync
assert_eq "T9b(NEG): 去掉删除段后失效域名仍在 = T2a 判据真会红" \
    "$(jq -r '.target | has("www.fandom.com")' "$RUNTIME")" "true"
eval "${SYNC}"   # 复原真实实现

# NEG-C: 去掉 main() 里的调用 -> T6j 的静态判据必须报缺失
grep -v '^    _sync_target_presets$' "$SRC" > "$SB/neg/nocall.sh"
nocall_line="$(grep -n '^    _sync_target_presets$' "$SB/neg/nocall.sh" | head -1 | cut -d: -f1)"
assert_eq "T9c(NEG): 删掉调用后静态判据报缺失 = 守卫不是摆设" "${nocall_line}" ""

# ---------------------------------------------------------------------------
echo "==== target_presets_sync_test: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]]
