#!/usr/bin/env bash
#
# 测试名称: install_direct_args_test.sh
#
# 为什么需要本测试 (2026-09-25 全仓注释审计时发现):
#   install.sh 是单文件自包含入口, 它把"无交互直达参数"收集起来整体转发给 core/main.sh。
#   收集靠 main() 里那段 while-case 的**白名单穷举**, 而 core/main.sh 的 case 也是穷举
#   —— 两处列表天然会漂移。2026-09-25 新增 IPv6 功能时, main.sh 加了 4 个 --ipv6-* 参数,
#   install.sh 的白名单一个都没加, 而白名单上方的注释恰恰写着"与 core/main.sh 的 case
#   一一对应"。后果不是报错, 是**静默**: `install.sh --ipv6-enable` 落到 `*)`, 在未出现
#   直达参数时不收集, 于是 core/main.sh 收到空参数列表 -> 落回交互菜单。用户看到的是
#   "加了参数却像没加", 没有任何提示。
#
# 本测试锁的不变量:
#   1. core/main.sh 的每个"跑完就退出"的直达参数, install.sh 都必须能识别
#      (识别 = 被执行到 DIRECT_CALL 赋值分支)。
#   2. 一键安装类 (--vision/--xhttp/--fallback) **刻意不在**白名单 —— 它们要走到安装确认
#      流程, 不该被当成"跑完就退出"的直达项。这条反向断言防止后人为了"对齐"而误加。
#   3. 拼错的参数绝不能被识别 (否则 --heath 会被当成 --health 静默放过)。
#
# 为什么跑真实片段而不是 grep 文本:
#   grep 只能证明"字符串出现过", 证明不了"参数真的会被这个 case 分支接住"。这里把
#   install.sh main() 里那段 while-case **原样抽出**包成函数执行, 断言的是行为。
#
# 运行: bash test/install_direct_args_test.sh
#
# 依赖: bash, awk
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "${REPO}"

pass=0
fail=0
ok() {
    printf '  ok   %s\n' "$1"
    pass=$((pass + 1))
}
bad() {
    printf '  [FAIL] %s\n' "$1"
    fail=$((fail + 1))
}
assert_eq() { # $1 说明 $2 实测 $3 期望
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi
}

# ---------------------------------------------------------------------------
# 抽 install.sh main() 里收集直达参数的那段 while-case, 包成可执行探针
# ---------------------------------------------------------------------------
SB="${REPO}/.workbuddy/tmp/ida.$$"
mkdir -p "${SB}"

build_probe() { # $1 = install.sh 路径; 生成 ${SB}/probe.sh
    local snippet
    snippet="$(awk '/^    local -a DIRECT_ARGS=\(\)/{f=1} f{print} f&&/^    done/{exit}' "$1")"
    [[ -n "${snippet}" ]] || return 1
    {
        printf 'set -Eeuo pipefail\n_probe() {\n'
        printf '%s\n' "${snippet}"
        printf 'printf "%%s" "${DIRECT_CALL:-NONE}"\n}\n_probe "$@"\n'
    } >"${SB}/probe.sh"
}

# $1 = 参数; stdout = DIRECT_CALL 的值 (NONE 表示未被识别)
probe() {
    bash "${SB}/probe.sh" "$1"
}

echo "== T0 探针可用性 (抽真实片段, 不是复刻) =="
build_probe install.sh && ok "T0 抽到 install.sh 的 while-case 片段" ||
    bad "T0 抽取失败 —— 锚点 'local -a DIRECT_ARGS=()' 可能已改名, 本测试需同步"
[[ -s "${SB}/probe.sh" ]] && ok "T0b 探针非空" || bad "T0b 探针为空"

echo "== T1 基准: 老参数仍被识别 (防回归) =="
for a in --health --net-status --bbr --net-tune --nofile-limit --export-config --import-config --subscription --start --stop --restart --share; do
    assert_eq "T1 ${a} 被识别" "$(probe "${a}")" "${a}"
done

echo "== T2 IPv6 整组必须被识别 (本次审计发现漏登记) =="
for a in --ipv6-status --ipv6-enable --ipv6-disable --ipv6-disable-hard; do
    assert_eq "T2 ${a} 被识别" "$(probe "${a}")" "${a}"
done

echo "== T3 反向: 一键安装类刻意在白名单之外 =="
for a in --vision --xhttp --fallback; do
    assert_eq "T3 ${a} 不在白名单 (要走到安装确认流程)" "$(probe "${a}")" 'NONE'
done

echo "== T4 拼错的参数不得被识别 =="
for a in --healt --ipv6 --ipv6-statuss --bbrr; do
    assert_eq "T4 ${a} 不被识别" "$(probe "${a}")" 'NONE'
done

echo "== T5 main.sh 的直达参数与 install.sh 白名单对账 (防将来再次漂移) =="
# 抽 core/main.sh main() 的 case 里所有 `    --xxx)` 臂
# 只用 awk: run_tests.sh 声明的依赖是 bash/jq/awk/base64, 本测试不引入 python3。
main_arms="$(awk '/^function main\(\)/{f=1; next}
    f && /^    --[a-z0-9-]+\)/{ sub(/^ +/, ""); sub(/\).*$/, ""); print }' core/main.sh)"
# 一键安装类与安装器专用参数不在对账范围内
EXCLUDE=' --vision --xhttp --fallback --lang --check-deps --force-update '
missing=''
n=0
for a in ${main_arms}; do
    [[ "${EXCLUDE}" == *" ${a} "* ]] && continue
    n=$((n + 1))
    if [[ "$(probe "${a}")" != "${a}" ]]; then
        missing="${missing} ${a}"
    fi
done
[[ "${n}" -gt 0 ]] && ok "T5a 抽到 ${n} 个应被对账的直达参数" || bad "T5a 未抽到任何直达参数 (抽取逻辑失效)"
if [[ -z "${missing}" ]]; then
    ok "T5b 全部直达参数都在 install.sh 白名单里"
else
    bad "T5b install.sh 白名单漏登记:${missing} —— 这些参数会被 *) 吞掉、静默落回交互菜单"
fi

echo "== T6 注释与行为一致: 白名单上方仍写着'与 core/main.sh 的 case 一一对应' =="
# 这条是"注释诚实性"守卫: 若哪天改成前缀匹配或移除对账说明, 这里会红, 提醒同步改注释。
# 它守的是注释本身 —— 本次审计里这条注释正是错得最离谱的一条 (声称一一对应, 实际差 4 项)。
if grep -q '与 core/main.sh 的 case 一一对应' install.sh; then
    ok "T6 对账说明仍在 (本测试即它的守据)"
else
    bad "T6 对账说明已消失 —— 若白名单机制已改, 请同步更新本测试"
fi

# ---------------------------------------------------------------------------
# NEG 负向校验: 把 --ipv6-status 从白名单摘掉, 上面所有断言必须变红
# ---------------------------------------------------------------------------
if [[ -z "${SKIP_NEG:-}" ]]; then
    echo "== NEG 反向校验: 摘掉 --ipv6-status 后必须变红 =="
    python3 - <<'PY'
import pathlib
s = pathlib.Path('install.sh').read_text(encoding='utf-8')
old = " | --ipv6-status | --ipv6-enable"
assert s.count(old) == 1, '变异锚点未命中'
new = " | --ipv6-enable"
pathlib.Path('core/_neg_install.sh').write_text(s.replace(old, new, 1), encoding='utf-8')
PY
    cp test/install_direct_args_test.sh "${SB}/neg_test.sh"
    sed -i 's#^build_probe install.sh#build_probe core/_neg_install.sh#' "${SB}/neg_test.sh"
    sed -i "s#^REPO=.*#REPO=\"${REPO}\"#" "${SB}/neg_test.sh"
    neg_out="$(SKIP_NEG=1 bash "${SB}/neg_test.sh" 2>&1 || true)"
    rm -f core/_neg_install.sh
    if printf '%s' "${neg_out}" | grep -q 'FAIL'; then
        ok "NEG 摘掉 --ipv6-status 后判据变红 (证明不是恒绿)"
    else
        bad "NEG 摘掉 --ipv6-status 后判据未变红 —— T2 形同虚设"
    fi
    if printf '%s' "${neg_out}" | grep -q 'T2 --ipv6-status 被识别'; then
        ok "NEG 命中点正是 T2 --ipv6-status"
    else
        bad "NEG 未命中 T2 --ipv6-status (可能打在了别处)"
    fi
else
    echo "== NEG 已跳过 (SKIP_NEG=1) =="
fi

rm -rf "${SB}"

printf '\n==== install_direct_args_test: PASS=%d FAIL=%d ====\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
exit 0
