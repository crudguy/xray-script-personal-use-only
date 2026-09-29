#!/usr/bin/env bash
# =============================================================================
# 测试名称: ci_local_ratchet_test.sh
# 测试目标: ci-local.sh 的 [5/5] 存量债务棘轮 (SC2155/SC2034/SC2154 只许下降)。
#
# 为什么需要本测试: ci-local.sh 第 3 阶段的判据是"当前 .shellcheckrc 下是否干净",
# 若有人往 .shellcheckrc 里加一行 disable=, 第 3 阶段照样全绿 —— 棘轮是唯一会因此
# 变红的门禁, 也是本地与 CI 对齐的最后一环。它此前**根本不存在**(文件头注释写着 5 个
# step, 实际只实现了 4 个), 属"本地绿 / CI 红"的长期隐患, 故加静态 + 行为双层守卫。
#
# 断言分四组:
#   T1 静态: 阶段存在、取数方式(--rcfile=/dev/null)正确、判定器与调用形态就位
#   T2 行为: 抽 _ratchet_check 真实函数体驱动三场景 (全 0 / 两处回潮 / 仅有未登记规则)
#   T3 对齐: ci-local 登记的三条规则 == CI shellcheck.yml 的 BASE 基线键
#   T4 NEG : 副本里把回潮判据改"永不触发", 上述行为断言必须变红 (区分真守卫与装饰)
# =============================================================================
set -u

SB="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
CI="${SB}/ci-local.sh"
WF="${SB}/.github/workflows/shellcheck.yml"
WORK="${SB}/.workbuddy/tmp/ci_ratchet_$$"
mkdir -p "$WORK"

pass=0; fail=0
ok(){ if [[ $1 -eq 0 ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
assert_eq(){ # $1=实际 $2=期望 $3=描述
    if [[ "$1" == "$2" ]]; then ok 0; echo "  [PASS] $3"; else ok 1; echo "  [FAIL] $3 (实际='$1' 期望='$2')"; fi
}
assert_contains(){ # $1=文本 $2=子串 $3=描述
    if [[ "$1" == *"$2"* ]]; then ok 0; echo "  [PASS] $3"; else ok 1; echo "  [FAIL] $3 (未包含 '$2')"; fi
}

echo "== ci_local_ratchet_test: ci-local 存量债务棘轮守卫 =="

# ---------------------------------------------------------------------------
# T1 静态守卫
# ---------------------------------------------------------------------------
echo "-- T1 静态: 阶段与判定器就位 --"
t1=0
grep -qF '[5/5] 存量债务棘轮' "$CI" || { t1=1; echo "    缺 [5/5] 棘轮阶段标题"; }
grep -qF -- '--rcfile=/dev/null' "$CI" || { t1=1; echo "    缺 --rcfile=/dev/null (会用 .shellcheckrc 过滤, 计数失真)"; }
grep -qE '^_ratchet_check\(\) \{' "$CI" || { t1=1; echo "    缺 _ratchet_check 判定器定义"; }
grep -qF '_ratchet_check < "${ratchet_tmp}"' "$CI" || { t1=1; echo "    判定器调用形态不匹配 (需走文件重定向, 管道/进程替换会丢退出码)"; }
grep -qE 'for rule in SC2155 SC2034 SC2154' "$CI" || { t1=1; echo "    三条登记规则未在同一循环内声明"; }
grep -qF 'unable to read --rcfile' "$CI" || { t1=1; echo "    缺 --rcfile 未生效的护栏"; }
ok "$t1"
[[ $t1 -eq 0 ]] && echo "  [PASS] T1 棘轮阶段静态结构完整" || echo "  [FAIL] T1 棘轮阶段静态结构不完整(见上)"

# ---------------------------------------------------------------------------
# 驱动判定器: 从脚本里抽**真实函数体**再注入, 不另写一份实现 (避免漂移)
# ---------------------------------------------------------------------------
run_ratchet(){ # $1=脚本 $2= dump 文件 -> stdout=判定输出; 返回判定器退出码
    local fn=''
    local rc=0
    fn="${WORK}/fn_$(basename "$1").sh"
    awk '/^_ratchet_check\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$1" > "$fn"
    if [[ ! -s "$fn" ]]; then
        echo "    判定器抽取为空 (脚本里找不到 _ratchet_check)"
        return 2
    fi
    # shellcheck disable=SC1090  # $fn 是从被测脚本里运行时抽出的函数体, shellcheck 无法静态跟随
    ( . "$fn"; _ratchet_check < "$2" )
    rc=$?
    return "$rc"
}

# 场景 dump
: > "${WORK}/empty.txt"
cat > "${WORK}/hit.txt" <<'EOF'
core/x.sh:10:5: warning: a local assignment masks return value [SC2155]
core/y.sh:20:7: warning: b is unused [SC2034]
core/y.sh:31:9: warning: c is unused [SC2034]
core/z.sh:40:3: warning: d quote this to prevent word splitting [SC2086]
EOF
cat > "${WORK}/other.txt" <<'EOF'
core/z.sh:40:3: warning: d quote this to prevent word splitting [SC2086]
core/z.sh:41:3: warning: e quote this [SC2086]
EOF

echo "-- T2 行为: 三场景驱动 --"
t2=0

out_empty="$(run_ratchet "$CI" "${WORK}/empty.txt")"; rc_empty=$?
assert_eq "$rc_empty" 0 "T2a 全 0 dump -> 判定器返回 0"
assert_contains "$out_empty" "SC2155 维持 0 处" "T2a SC2155 结论行渲染"
assert_contains "$out_empty" "SC2034 维持 0 处" "T2a SC2034 结论行渲染"
assert_contains "$out_empty" "SC2154 维持 0 处" "T2a SC2154 结论行渲染"
[[ $rc_empty -eq 0 ]] || t2=1

out_hit="$(run_ratchet "$CI" "${WORK}/hit.txt")"; rc_hit=$?
assert_eq "$rc_hit" 1 "T2b 含回潮 dump -> 判定器返回 1"
assert_contains "$out_hit" "SC2155 回潮 1 处" "T2b SC2155 计数精确 (1 处)"
assert_contains "$out_hit" "SC2034 回潮 2 处" "T2b SC2034 计数精确 (2 处)"
assert_contains "$out_hit" "SC2154 维持 0 处" "T2b 未回潮的规则仍报 ok (逐条独立)"
[[ $rc_hit -eq 1 ]] || t2=1

out_other="$(run_ratchet "$CI" "${WORK}/other.txt")"; rc_other=$?
assert_eq "$rc_other" 0 "T2c 只有未登记规则(SC2086) -> 不误伤, 返回 0"
assert_contains "$out_other" "SC2155 维持 0 处" "T2c 未登记规则不污染登记规则的计数"
[[ $rc_other -eq 0 ]] || t2=1

ok "$t2"

# ---------------------------------------------------------------------------
# T3 与 CI workflow 对齐: 两边登记的规则集合必须一致
# ---------------------------------------------------------------------------
echo "-- T3 对齐: ci-local 规则集 == CI 基线键 --"
loc_rules="$(grep -oE 'for rule in (SC[0-9]+ )+SC[0-9]+' "$CI" | head -1 | sed 's/for rule in //' | tr -s ' ' '\n' | sort | tr '\n' ' ')"
wf_rules="$(grep -oE '\[SC[0-9]+\]=[0-9]+' "$WF" | sed 's/^\[//; s/\]=.*//' | sort -u | tr '\n' ' ')"
assert_eq "$loc_rules" "$wf_rules" "T3 ci-local 与 CI 的棘轮规则集一致 (本地='$loc_rules'  CI='$wf_rules')"

# ---------------------------------------------------------------------------
# T4 NEG: 把副本里的回潮判据改成"永不触发", 行为断言必须捕获
# ---------------------------------------------------------------------------
echo "-- T4 NEG: 判据失效必须变红 --"
neg="${WORK}/ci-local-neg.sh"
cp "$CI" "$neg"
# 把 `[ "${cur}" -gt 0 ]` 抬到 999: 等价于"永远认为没回潮"
sed -i 's/\[ "${cur}" -gt 0 \]/[ "${cur}" -gt 999 ]/' "$neg"
if grep -qF '[ "${cur}" -gt 999 ]' "$neg"; then
    ok 0; echo "  [PASS] T4 副本已改坏 (回潮判据抬到 999)"
    out_neg="$(run_ratchet "$neg" "${WORK}/hit.txt")"; rc_neg=$?
    t4=0
    [[ $rc_neg -eq 0 ]] || { t4=1; echo "    判据已失效但副本仍返回 1 —— NEG 未生效"; }
    # 反面校验: 副本必须"看起来正常"(三条都打印 ok), 才说明是判据失效而非整体崩掉
    assert_contains "$out_neg" "SC2155 维持 0 处" "T4 副本呈'假绿': SC2155 被误判为 0"
    assert_contains "$out_neg" "SC2034 维持 0 处" "T4 副本呈'假绿': SC2034 被误判为 0"
    [[ $rc_neg -eq 0 ]] || t4=1
    ok "$t4"
else
    ok 1; echo "  [FAIL] T4 无法改坏副本 (sed 未命中判据, NEG 无效)"
fi

rm -rf "$WORK"

echo "==== ci_local_ratchet_test: PASS=$pass FAIL=$fail ===="
[[ $fail -eq 0 ]]
