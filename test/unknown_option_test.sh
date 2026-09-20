#!/usr/bin/env bash
# =============================================================================
# 测试名称: unknown_option_test.sh
# 测试目标: P1-3 — 未知/不支持参数不再静默成功 (exit 0), 改为打印用法并 exit 2;
#           同时为 main.sh / handler.sh / install.sh 补 --help / -h。
#           用静态守卫锁定结构, 不依赖 jq / 真实菜单 (与 printf_format_test 同思路)。
# 注意: 本测试只断言"代码里存在对应分支与退出码", 行为级 exit-code 验证需在装了
#       jq 的环境由 CI 走真实链路 (load_i18n 需要 jq, 沙箱无 jq 故不做行为级)。
# =============================================================================
set -u

SB=".workbuddy/tmp/unknown_option_sb"
rm -rf "$SB"; mkdir -p "$SB"

# 抽取顶层函数体: 从 `function NAME()` 到第一个列 0 的 `}` 结束
extract() { # $1=file $2=funcname -> 输出到 stdout
    awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\)"){f=1} f{print} f&&/^\}/{exit}' "$1"
}

pass=0; fail=0
ok(){ if [[ $1 -eq 0 ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

# ---------------------------------------------------------------------------
# T1 [handler.sh] main() 的 case 必须有 `*)` 默认分支, 且打印 unknown_option 文案并 exit 2
# ---------------------------------------------------------------------------
extract core/handler.sh main > "$SB/h.sh"
grep -Eq '^[[:space:]]*\*\)' "$SB/h.sh"; ok $? && echo "[T1a] handler.sh main() 含 * 默认分支" || echo "[FAIL T1a] handler.sh main() 缺少 * 默认分支"
grep -q 'exit 2' "$SB/h.sh";            ok $? && echo "[T1b] handler.sh * 分支退出码为 2"      || echo "[FAIL T1b] handler.sh * 分支未 exit 2"
grep -q "handler.unknown_option" "$SB/h.sh"; ok $? && echo "[T1c] handler.sh 引用 i18n handler.unknown_option" || echo "[FAIL T1c] handler.sh 未引用 handler.unknown_option"

# ---------------------------------------------------------------------------
# T2 [generate.sh] main() 的 case 必须有 `*)` 默认分支, 打印 Supported 用法并 exit 2
# ---------------------------------------------------------------------------
extract core/generate.sh main > "$SB/g.sh"
grep -Eq '^[[:space:]]*\*\)' "$SB/g.sh"; ok $? && echo "[T2a] generate.sh main() 含 * 默认分支" || echo "[FAIL T2a] generate.sh main() 缺少 * 默认分支"
grep -q 'exit 2' "$SB/g.sh";            ok $? && echo "[T2b] generate.sh * 分支退出码为 2"    || echo "[FAIL T2b] generate.sh * 分支未 exit 2"
grep -q 'Unknown or unsupported option' "$SB/g.sh"; ok $? && echo "[T2c] generate.sh 打印 Unknown 用法" || echo "[FAIL T2c] generate.sh 未打印 Unknown 用法"

# ---------------------------------------------------------------------------
# T3 [main.sh] main() 的 case 必须有 `--help | -h`, 打印 main.usage 并 exit 0
# ---------------------------------------------------------------------------
extract core/main.sh main > "$SB/m.sh"
grep -q -- '--help | -h' "$SB/m.sh";     ok $? && echo "[T3a] main.sh 含 --help|-h 分支"       || echo "[FAIL T3a] main.sh 缺少 --help|-h 分支"
grep -q "_i18n '.main.usage'" "$SB/m.sh"; ok $? && echo "[T3b] main.sh --help 打印 main.usage" || echo "[FAIL T3b] main.sh --help 未引用 main.usage"
grep -q 'exit 0' "$SB/m.sh";            ok $? && echo "[T3c] main.sh --help 退出码为 0"       || echo "[FAIL T3c] main.sh --help 未 exit 0"

# ---------------------------------------------------------------------------
# T4 [install.sh] parse_args 必须有 `--help | -h` 并打印用法后 exit 0
# ---------------------------------------------------------------------------
extract install.sh parse_args > "$SB/i.sh"
grep -q -- '--help | -h' "$SB/i.sh";     ok $? && echo "[T4a] install.sh 含 --help|-h 分支"    || echo "[FAIL T4a] install.sh parse_args 缺少 --help|-h 分支"
grep -q 'exit 0' "$SB/i.sh";            ok $? && echo "[T4b] install.sh --help 退出码为 0"    || echo "[FAIL T4b] install.sh --help 未 exit 0"

# ---------------------------------------------------------------------------
# T5 [i18n] zh/en 双语都必须存在 handler.unknown_option 键 (防未来漂移/漏译)
#   注: "unknown_option": 带前导引号, 不会误匹配既有的扁平键 "err.unknown_option":
# ---------------------------------------------------------------------------
grep -q '"unknown_option":' i18n/zh.json; ok $? && echo "[T5a] zh.json 含 handler.unknown_option 键" || echo "[FAIL T5a] zh.json 缺 handler.unknown_option 键"
grep -q '"unknown_option":' i18n/en.json; ok $? && echo "[T5b] en.json 含 handler.unknown_option 键" || echo "[FAIL T5b] en.json 缺 handler.unknown_option 键"

# ---------------------------------------------------------------------------
# T6 [check.sh] main() 的 case 必须有 `*)` 默认分支, 引用 check.unknown_option 并 exit 2
#    背景: core/main.sh 的注释与 README 都推荐脚本化告警直接调 `core/check.sh --health`
#          (0=无失败项 / 1=有失败项), 但这条路径原本没有未知参数保护 —— cron 里把
#          `--health` 误写成 `--heath` 会什么都不做并返回 0, 监控永远假绿。
#          handler.sh 在 P1-3 已修 (的代码就在 handler.sh:3282 注释里), check.sh 是漏网的那个。
# ---------------------------------------------------------------------------
extract core/check.sh main > "$SB/c.sh"
grep -Eq '^[[:space:]]*\*\)' "$SB/c.sh"; ok $? && echo "[T6a] check.sh main() 含 *) 默认分支"  || echo "[FAIL T6a] check.sh main() 缺少 *) 默认分支"
grep -q 'exit 2' "$SB/c.sh";            ok $? && echo "[T6b] check.sh *) 分支退出码为 2"       || echo "[FAIL T6b] check.sh *) 分支未 exit 2"
grep -q 'unknown_option' "$SB/c.sh";    ok $? && echo "[T6c] check.sh 引用 unknown_option 文案" || echo "[FAIL T6c] check.sh 未引用 unknown_option 文案"

# ---------------------------------------------------------------------------
# T7 [i18n] check 段的 unknown_option 必须双语齐备 (不能只在 handler 段有)
#    注: 顶层的 `"unknown_option":` 可能来自 handler 段, 故先截出 check 块再判定。
# ---------------------------------------------------------------------------
check_block_has_key() { # $1=语言文件
    awk '/^  "check": \{/{f=1} f{print} f && /^  \},/{exit}' "$1" | grep -q '"unknown_option":'
}
check_block_has_key i18n/zh.json; ok $? && echo "[T7a] zh.json 的 check 段含 unknown_option" || echo "[FAIL T7a] zh.json 的 check 段缺 unknown_option"
check_block_has_key i18n/en.json; ok $? && echo "[T7b] en.json 的 check 段含 unknown_option" || echo "[FAIL T7b] en.json 的 check 段缺 unknown_option"

echo "==== unknown_option_test: PASS=$pass FAIL=$fail ===="
rm -rf "$SB"
[[ $fail -eq 0 ]]
