#!/usr/bin/env bash
# =============================================================================
# 测试名称: check_dispatch_exit_test.sh
# 测试目标: 锁定 "check.sh 的退出码是检查结论, 不是脚本崩溃" 这条语义。
#
# 背景: core/check.sh 的每个选项都是只读检查器, 用退出码表达结论 (0=通过 / 非 0=未通过),
#   这是**正常业务语义** (cron 靠 `--health` 的 1 判"有失败项")。但 main() 的 case 分派臂
#   把检查函数当普通命令调用 —— 不在条件上下文里, 于是 `return 1` 被 set -e 的 ERR trap
#   当成"意外失败", 在一次正常的检查末尾多打一条:
#     [错误] 脚本在第 2219 行意外失败 (退出码 1): return "${rc}"
#   行号是**分派臂那一行**, 不是 `return` 那一行 —— ERR trap 里的 LINENO 指向调用点
#   (2026-09-24 实测确认: --net-status 报 2219, 而 return 在 1259, 一度被误判成"VPS 上是
#    另一个版本的文件")。触发点: BBR 体检发现"持久化未配置", 属正常结论, 用户却看到崩溃。
#   修法沿用本项目已有构造 (--rule-ip / --rule-domain 早就这么写): 每个臂末尾 `|| exit $?`,
#   进入条件上下文后 errexit 与 ERR trap 都不触发, 退出码照常透传。
#
# 本测试防三件事:
#   T1 静态契约 —— 新增/改动的分派臂漏写 `|| exit $?` (当时 15 个臂里 9 个在冒假报错);
#   T2 行为级   —— "检查不通过"必须 rc=1 且**无** ERR trap 噪音, 且仍渲染自己的结论文案;
#   T3 转发路径 —— 菜单/CLI 那条 `main.sh --net-status` 也不许把假报错漏出去;
#   T4 NEG      —— 摘掉一个臂的守卫, T1/T2 的判据必须变红 (证明不是"加了等于没加")。
#
# 依赖: bash, awk, jq (缺 jq 时跳过 T2/T3/T4 行为级, 静态断言照跑)。
# =============================================================================
set -u

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    echo "FAIL: $*"
}

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

SB=".workbuddy/tmp/check_dispatch_exit.$$"
trap 'rm -rf "${SB}" 2>/dev/null || true' EXIT
mkdir -p "${SB}"

# 隔离 HOME: check.sh 的 load_i18n 读 ${HOME}/.xray-script-personal-use-only/config.json
TMPH="${SB}/home"
mkdir -p "${TMPH}/.xray-script-personal-use-only"
printf '{"version":"vT","language":"zh"}\n' >"${TMPH}/.xray-script-personal-use-only/config.json"

# ERR trap 的固定文案片段 —— 判据统一走它, 避免各处硬编码措辞
NOISE_TAG='意外失败'

# ---------------------------------------------------------------------------
# 共用: 从任意一份 check.sh 里抽出 main() 的 case 分派块, 再列出**缺守卫**的臂。
#   用 awk 抽真实函数体 / 真实 case 块, 不另写一份"期望的分派表"(否则改实现就漂移)。
# ---------------------------------------------------------------------------
dispatch_block() {
    awk '/^function main\(\) \{/,/^}/' "$1" |
        awk '/^    case "\$\{option\}" in/,/^    esac/'
}
# $1 = check.sh 路径; 输出: 每个缺 `|| exit $?` 的分派臂 (一行一条)
missing_guard_arms() {
    dispatch_block "$1" | grep -E '^    --[a-z-]+\)' | grep -vF '|| exit $? ;;' || true
}

# ---------------------------------------------------------------------------
# T1 静态契约: main() 分派表里**每个**臂都以 `|| exit $?` 收尾
# ---------------------------------------------------------------------------
DISPATCH="$(dispatch_block core/check.sh)"
if [[ -n "${DISPATCH}" ]]; then
    ok
else
    bad "T1: 未能从 core/check.sh 的 main() 抽出 case 分派块 (结构变了? 本用例需同步)"
fi

ARM_TOTAL="$(printf '%s\n' "${DISPATCH}" | grep -cE '^    --[a-z-]+\)' || true)"
MISSING="$(missing_guard_arms core/check.sh)"
if [[ -z "${MISSING}" ]]; then
    ok
else
    bad "T1: 分派臂缺 '|| exit \$?' (检查不通过会被 ERR trap 报成脚本崩溃): $(printf '%s' "${MISSING}" | tr '\n' '|')"
fi
# 下限而非精确值: 将来新增臂(带守卫)不该让本用例无辜变红, 但"抽取逻辑失效导致扫到 0 条"必须暴露
[[ "${ARM_TOTAL}" -ge 20 ]] && ok ||
    bad "T1: 只扫到 ${ARM_TOTAL} 个分派臂 (少于 20), 抽取逻辑或分派块结构可能已变"

# 未知选项分支: 必须仍以 EXIT_USAGE 退出 (cron 里把 --health 写成 --heath 时监控不能假绿)
case "${DISPATCH}" in
*'exit "${EXIT_USAGE}"'*) ok ;;
*) bad "T1: 未知选项分支不再以 EXIT_USAGE 退出 (监控会假绿)" ;;
esac

# ---------------------------------------------------------------------------
# T2 行为级: 真跑 check.sh —— "检查不通过"须 rc=1, 无 ERR trap 噪音, 且渲染自己的结论
#   全部选**离线可判定**的臂 (纯格式校验, 不做 DNS / 探活), 避免 CI 无网时抖动。
# ---------------------------------------------------------------------------
assert_arm() {
    local opt="$1" arg="$2" desc="$3"
    local out='' rc=0
    out="$(env HOME="${TMPH}" bash core/check.sh "${opt}" "${arg}" 2>&1)" || rc=$?
    case "${out}" in
    *"${NOISE_TAG}"*) bad "T2 [${desc}] 出现 ERR trap 假报错: $(printf '%s' "${out}" | tr '\n' '|')" ;;
    *) ok ;;
    esac
    [[ "${rc}" -eq 1 ]] && ok ||
        bad "T2 [${desc}] 期望 rc=1 (结论必须照旧透传给 cron/exec_read), 实测 rc=${rc}"
    case "${out}" in
    *'[失败]'*) ok ;;
    *) bad "T2 [${desc}] 未渲染出自己的结论文案 (消音不该靠吞输出): $(printf '%s' "${out}" | tr '\n' '|')" ;;
    esac
}

if command -v jq >/dev/null 2>&1; then
    assert_arm '--ip' 'bad' 'ip 格式非法'
    assert_arm '--port' '70000' '端口越界'
    assert_arm '--password' '1' '密码过短'
    assert_arm '--short' 'zz' 'Short ID 非法'
    assert_arm '--domain-format' 'bad_domain' '域名格式非法'
    assert_arm '--email' 'nope' '邮箱非法'
    assert_arm '--list-index' 'abc' '列表序号非法'
    assert_arm '--rule-ip' 'abc' '分流值非法'

    # -----------------------------------------------------------------------
    # T3 转发路径: 用户报的那条命令 (`main.sh --net-status`)。
    #   体检的"持久化不完整"是正常结论 —— 报告照出、不许有假报错。
    #   rc 不强求 1 (体检是否达标取决于本机 /etc 下有没有留持久化文件), 只要求
    #   它是"结论" (0/1) 而不是崩溃码。
    # -----------------------------------------------------------------------
    t3_out='' t3_rc=0
    t3_out="$(env HOME="${TMPH}" bash core/main.sh --net-status 2>&1)" || t3_rc=$?
    case "${t3_out}" in
    *"${NOISE_TAG}"*) bad "T3: main.sh --net-status 漏出 ERR trap 假报错: $(printf '%s' "${t3_out}" | tr '\n' '|')" ;;
    *) ok ;;
    esac
    [[ "${t3_rc}" -ge 0 && "${t3_rc}" -le 1 ]] && ok ||
        bad "T3: main.sh --net-status 应 rc ∈ {0,1}, 实测 ${t3_rc}"
    # 报告本体必须还在 (排掉"为了消音直接不跑体检"这条路); 标题取自 i18n, 不硬编码中文
    t3_title="$(jq -r '.check.net_status.title // empty' i18n/zh.json 2>/dev/null || true)"
    case "${t3_out}" in
    *"${t3_title}"*) ok ;;
    *) bad "T3: main.sh --net-status 未渲染体检报告标题 [${t3_title}]" ;;
    esac
else
    echo "SKIP: 缺少依赖 jq, 跳过 T2/T3 行为级断言"
fi

# ---------------------------------------------------------------------------
# T4 NEG 负向校验: 在副本里摘掉 **一个** 臂的 `|| exit $?`, T1/T2 的判据必须变红。
#   若这里不红, 说明上面两条断言其实是"加了等于没加"。
#   副本需自带 core/ + i18n/ (check.sh 经 $0 推 PROJECT_ROOT, 再找 ../i18n)。
# ---------------------------------------------------------------------------
NEG="${SB}/neg"
mkdir -p "${NEG}/core" "${NEG}/i18n" "${NEG}/home/.xray-script-personal-use-only"
cp core/check.sh core/_common.sh "${NEG}/core/"
cp i18n/*.json "${NEG}/i18n/"
printf '{"version":"vT","language":"zh"}\n' >"${NEG}/home/.xray-script-personal-use-only/config.json"
# 只改 --ip 那一个臂: 去掉 `|| exit $?`
sed -i 's/^\(    --ip) check_ip "\$@" >&2\) || exit \$? ;;/\1 ;;/' "${NEG}/core/check.sh"

if grep -qF -- '--ip) check_ip "$@" >&2 ;;' "${NEG}/core/check.sh"; then
    ok
else
    bad "T4: NEG 副本没能改坏 (sed 未命中) —— 负向校验无效"
fi

NEG_MISSING="$(missing_guard_arms "${NEG}/core/check.sh")"
case "${NEG_MISSING}" in
*'--ip)'*) ok ;;
*) bad "T4: 摘掉守卫后静态判据未变红 —— T1 形同虚设 (missing=[${NEG_MISSING}])" ;;
esac
# 只该红这一个臂: 其余 19 个守卫仍在 (证明判据是逐臂的, 不是"整体有就行")
NEG_MISSING_N="$(printf '%s\n' "${NEG_MISSING}" | grep -c . || true)"
[[ "${NEG_MISSING_N}" -eq 1 ]] && ok ||
    bad "T4: 期望恰好 1 个臂缺守卫, 实测 ${NEG_MISSING_N} 个"

if command -v jq >/dev/null 2>&1; then
    neg_out='' neg_rc=0
    neg_out="$(env HOME="${NEG}/home" bash "${NEG}/core/check.sh" '--ip' 'bad' 2>&1)" || neg_rc=$?
    case "${neg_out}" in
    *"${NOISE_TAG}"*) ok ;;
    *) bad "T4: 摘掉守卫后行为级未复现假报错 —— T2 形同虚设: $(printf '%s' "${neg_out}" | tr '\n' '|')" ;;
    esac
    # 退出码仍应是 1 (假报错是"多打印", 不是"改了结论")
    [[ "${neg_rc}" -eq 1 ]] && ok || bad "T4: NEG 副本 rc 应为 1, 实测 ${neg_rc}"
fi

echo "==== check_dispatch_exit_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
