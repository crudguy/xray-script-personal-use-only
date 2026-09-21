#!/usr/bin/env bash
#
# 用例: core/share.sh 的订阅聚合 (菜单 11 / --subscription)
#
# 背景 (为什么固化成脚本): 上一批给订阅加"遍历全部入站"的能力时, 临时写的驱动抓到了两个
# 真 bug —— fallback/sni 的聚合函数末尾"只生成最后一条链接而不 show_config", 而订阅分支
# 提前 return 够不到 main 末尾的兜底 show_config, 于是 fallback 只收 1 条、SNI 只收 4 条。
# 那两个驱动跑完就删了, 下次重构无法复现。本用例把等价断言固化下来。
#
# 覆盖:
#   sni      / SNI.json      -> 5 条 (含末节点 sni_reality_down, 即当年漏收的那条)
#   fallback / Fallback.json -> 2 条 (含末节点 fallbak_xhttp_reality)
#   multi    / Fallback.json -> 2 条 (通用遍历: 3 个入站里的 api 被协议过滤跳过)
#   vision   / Vision.json   -> 1 条 (单入站基线)
#   mkcp     / mKCP.json     -> 1 条, 且 sing-box 跳过 1 条 (mKCP 不可表达)
#
# 做法: 在临时沙箱里做一份 core/ + i18n/ 的副本 (保持相对布局), 把 share.sh 末尾的自动
#       入口 `main "$@"` 替换成测试驱动, 于是 $0/CUR_DIR/PROJECT_ROOT 全部与真实运行一致,
#       且不污染工作区。分发 (main --subscription) / 聚合 / 写订阅全部跑真实代码, 只替换
#       "读盘"那一层 —— XRAY_CONFIG_PATH 是绝对路径 /usr/local/etc/xray/config.json,
#       测试环境不写它, 改用夹具。curl 也被替成固定 IP, 让用例完全不联网。
#
# 依赖: bash, jq, base64, awk。
set -Eeuo pipefail

# 依赖检查: jq 缺失则优雅跳过 (与 backup_test/ssl_test 对齐, rc=3)
if ! command -v jq >/dev/null 2>&1; then
    printf 'SKIP: 缺少依赖 jq\n'
    printf '  本机 (MSYS) 需把 jq 垫片带进 PATH, 正确调用方式:\n'
    printf '    PATH="$PWD/test/.tmp/jqshim:$PATH" \\\n'
    printf '    XRAY_TEST_SHIM="$PWD/test/.tmp/jqshim" bash %s\n' "$0"
    exit 3
fi

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"

SB="$(mktemp -d "${TMPDIR:-/tmp}/xray-sub-test.XXXXXX")"
cleanup() {
    # XRAY_TEST_KEEP=1 时保留沙箱, 便于排查失败 (会把路径打到 stderr)
    if [[ "${XRAY_TEST_KEEP:-0}" == '1' ]]; then
        printf '\n(已保留沙箱: %s)\n' "${SB}" >&2
        return 0
    fi
    rm -rf "${SB}"
}
trap cleanup EXIT

fail=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
    printf '  FAIL %s\n' "$1"
    fail=1
}

# ---------------------------------------------------------------------------
# 1. 沙箱: core/ + i18n/ 副本 (i18n 供真实 load_i18n 读取; 只影响提示文案)
# ---------------------------------------------------------------------------
mkdir -p "${SB}/home/.xray-script-personal-use-only" "${SB}/fixtures" "${SB}/out"
cp -r "${REPO}/core" "${SB}/core"
cp -r "${REPO}/i18n" "${SB}/i18n"
cp "${REPO}"/config/xray/*.json "${SB}/fixtures/"
cp "${REPO}/config.json" "${SB}/base-config.json"
export HOME="${SB}/home"

# ---------------------------------------------------------------------------
# 2. 场景表 (name / tag / xray 夹具)
# ---------------------------------------------------------------------------
printf 'sni\tSNI\tSNI.json\n' >"${SB}/scenarios.tsv"
printf 'fallback\tFallback\tFallback.json\n' >>"${SB}/scenarios.tsv"
printf 'multi\tVision\tFallback.json\n' >>"${SB}/scenarios.tsv"
printf 'vision\tVision\tVision.json\n' >>"${SB}/scenarios.tsv"
printf 'mkcp\tmKCP\tmKCP.json\n' >>"${SB}/scenarios.tsv"

# ---------------------------------------------------------------------------
# 3. 驱动: 替换 share.sh 的自动入口, 于是 $0 = 沙箱里的 share.sh (CUR_FILE=share, i18n 键前缀正确)
# ---------------------------------------------------------------------------
cat >"${SB}/driver.txt" <<'DRIVER'
# ---------------- 测试驱动 (由 test/subscription_test.sh 注入, 非生产代码) ----------------
# 可选: 被测代码的 _common.sh 会把 PATH 覆盖成固定白名单, 若本机 jq 不在白名单内
# (如 Windows/MSYS 下放在别处), 由调用方通过 _T_SHIM 指定目录, 在此补回。
if [[ -n "${_T_SHIM:-}" ]]; then
    export PATH="${_T_SHIM}:${PATH}"
fi

# 不联网: get_common_config 会 curl 取公网 IP, 这里给固定值
curl() { printf '203.0.113.10'; }

# 只替换"读盘"这一层: 真实 XRAY_CONFIG_PATH 是绝对路径, 测试环境不可写
cache_json_data() {
    XRAY_CONFIG="$(jq '.' "${_T_FIXTURE_XRAY}")"
    SCRIPT_CONFIG="$(jq '.' "${SCRIPT_CONFIG_PATH}")"
}

mkdir -p "${_T_OUT}"
: >"${_T_OUT}/counts.tsv"
while IFS=$'\t' read -r _t_name _t_tag _t_fixture; do
    [[ -n "${_t_name}" ]] || continue
    _T_FIXTURE_XRAY="${_T_FIXTURES}/${_t_fixture}"
    # language 必须给真实值: load_i18n 用它拼 i18n/<lang>.json, 空串会直接 exit 1
    jq --arg tag "${_t_tag}" '.xray.tag = $tag | .language = "zh"' "${_T_BASE_CONFIG}" >"${SCRIPT_CONFIG_PATH}"
    SHARE_LINKS=()
    SHARE_NODES_JSON=''
    SINGBOX_SKIP=0
    main --subscription >"${_T_OUT}/${_t_name}.stdout" 2>"${_T_OUT}/${_t_name}.stderr" || true
    mkdir -p "${_T_OUT}/${_t_name}"
    cp -f "${SCRIPT_CONFIG_DIR}"/subscription-* "${_T_OUT}/${_t_name}/" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "${_t_name}" "${#SHARE_LINKS[@]}" "${SINGBOX_SKIP}" >>"${_T_OUT}/counts.tsv"
done <"${_T_SCENARIOS}"
DRIVER

if [[ "$(grep -c '^main "\$@"$' "${SB}/core/share.sh")" -ne 1 ]]; then
    bad "core/share.sh 里未找到唯一的入口行 main \"\$@\" (测试无法注入驱动)"
    printf '\n结果: 失败\n'
    exit 1
fi
awk -v drvfile="${SB}/driver.txt" '
    $0 == "main \"$@\"" {
        while ((getline ln < drvfile) > 0) print ln
        close(drvfile)
        hits++
        next
    }
    { print }
    END { if (hits != 1) exit 1 }
' "${SB}/core/share.sh" >"${SB}/core/share.patched.sh" || {
    bad "注入驱动失败"
    printf '\n结果: 失败\n'
    exit 1
}
mv "${SB}/core/share.patched.sh" "${SB}/core/share.sh"

# ---------------------------------------------------------------------------
# 4. 跑驱动 (独立进程: 沙箱 share.sh 自己就是入口)
# ---------------------------------------------------------------------------
if ! _T_OUT="${SB}/out" _T_SCENARIOS="${SB}/scenarios.tsv" _T_FIXTURES="${SB}/fixtures" \
    _T_BASE_CONFIG="${SB}/base-config.json" _T_SHIM="${XRAY_TEST_SHIM:-}" \
    bash "${SB}/core/share.sh" >"${SB}/driver.log" 2>&1; then
    bad "驱动执行失败, 见下"
    sed 's/^/  | /' "${SB}/driver.log" | head -40
    printf '\n结果: 失败\n'
    exit 1
fi
ok "驱动执行完成 (5 个场景)"

OUT="${SB}/out"
counts_of() { awk -v n="$1" -F'\t' '$1 == n {print $2}' "${OUT}/counts.tsv"; }
skip_of() { awk -v n="$1" -F'\t' '$1 == n {print $3}' "${OUT}/counts.tsv"; }

# Clash 的节点名只存在于 proxies: 段内。不能直接 grep 全文的 "- name:" ——
# proxy-groups 段里也有同名格式的条目 (「自动选择」「节点选择」), 会被误计成节点。
clash_names() {
    awk '/^proxies:/{f=1;next} /^proxy-groups:/{f=0}
         f && /- name: "/{ if (match($0, /"[^"]+"/)) print substr($0, RSTART + 1, RLENGTH - 2) }' "$1"
}

# ---------------------------------------------------------------------------
# 5. 逐场景核对三种订阅产物
# ---------------------------------------------------------------------------
assert_scenario() {
    local name="$1" want_nodes="$2" want_skip="$3"
    local got_nodes got_skip dir b64_lines clash_n sb_n tags_uniq

    dir="${OUT}/${name}"
    got_nodes="$(counts_of "${name}")"
    got_skip="$(skip_of "${name}")"
    if [[ -z "${got_nodes}" ]]; then
        bad "${name}: 场景未产出结果 (查看 ${dir}.stderr)"
        sed 's/^/  | /' "${OUT}/${name}.stderr" 2>/dev/null | head -10
        return 0
    fi
    if [[ "${got_nodes}" != "${want_nodes}" ]]; then
        bad "${name}: 节点数 ${got_nodes}, 期望 ${want_nodes}"
    else
        ok "${name}: 节点数 ${got_nodes}"
    fi
    if [[ "${got_skip}" != "${want_skip}" ]]; then
        bad "${name}: sing-box 跳过数 ${got_skip}, 期望 ${want_skip}"
    else
        ok "${name}: sing-box 跳过 ${got_skip}"
    fi

    # base64: 解码后应恰有 want_nodes 条链接, 且都是 vless:// 或 trojan://
    b64_lines="$(base64 -d <"${dir}/subscription-base64.txt" | grep -c . || true)"
    if [[ "${b64_lines}" != "${want_nodes}" ]]; then
        bad "${name}: base64 解出 ${b64_lines} 条链接, 期望 ${want_nodes}"
    elif base64 -d <"${dir}/subscription-base64.txt" | grep -qvE '^(vless|trojan)://'; then
        bad "${name}: base64 里出现非 vless/trojan 链接"
    else
        ok "${name}: base64 ${b64_lines} 条 vless/trojan 链接"
    fi

    # Clash: 只数 proxies: 段内的条目 (proxy-groups 里也有 "- name:")
    clash_n="$(clash_names "${dir}/subscription-clash.yaml" | wc -l | tr -d ' ')"
    if [[ "${clash_n}" != "${want_nodes}" ]]; then
        bad "${name}: clash proxies ${clash_n} 条, 期望 ${want_nodes}"
    else
        ok "${name}: clash proxies ${clash_n} 条"
    fi

    # 节点名不得重名 (通用遍历用入站 tag, 重名会让客户端无法区分节点)
    tags_uniq="$(clash_names "${dir}/subscription-clash.yaml" | sort -u | wc -l | tr -d ' ')"
    if [[ "${tags_uniq}" != "${want_nodes}" ]]; then
        bad "${name}: clash 节点名去重后 ${tags_uniq} 个, 期望 ${want_nodes} (存在重名或空名)"
    else
        ok "${name}: 节点名唯一 (${tags_uniq})"
    fi

    # sing-box: 减掉模板固定的 direct/block
    sb_n="$(jq '[.outbounds[] | select(.tag != "direct" and .tag != "block")] | length' "${dir}/subscription-singbox.json")"
    if [[ "${sb_n}" != "$((want_nodes - want_skip))" ]]; then
        bad "${name}: sing-box 节点 ${sb_n} 条, 期望 $((want_nodes - want_skip))"
    else
        ok "${name}: sing-box 节点 ${sb_n} 条"
    fi

    # api 入站 (dokodemo-door) 绝不能变成节点
    if grep -qi 'dokodemo' "${dir}/subscription-base64.txt" "${dir}/subscription-clash.yaml" \
        "${dir}/subscription-singbox.json"; then
        bad "${name}: 产物里出现 dokodemo (api 入站未被过滤)"
    else
        ok "${name}: api 入站已过滤"
    fi
}

assert_scenario sni 5 0
assert_scenario fallback 2 0
assert_scenario multi 2 0
assert_scenario vision 1 0
assert_scenario mkcp 1 1

# ---------------------------------------------------------------------------
# 6. 针对性回归: 末节点必须收进来 (当年 fallback 丢第 2 条 / SNI 丢第 5 条)
# ---------------------------------------------------------------------------
sni_links="$(base64 -d <"${OUT}/sni/subscription-base64.txt")"
for t in sni_vision_reality sni_xhttp_reality sni_tls_down sni_xhttp_cdn sni_reality_down; do
    if grep -q "#${t}\$" <<<"${sni_links}"; then
        ok "sni: 含末节点 ${t}"
    else
        bad "sni: 缺少节点 ${t} (订阅分支漏收该节点)"
    fi
done

fb_links="$(base64 -d <"${OUT}/fallback/subscription-base64.txt")"
for t in fallbak_vision_reality fallbak_xhttp_reality; do
    if grep -q "#${t}\$" <<<"${fb_links}"; then
        ok "fallback: 含节点 ${t}"
    else
        bad "fallback: 缺少节点 ${t} (订阅分支漏收该节点)"
    fi
done

# ---------------------------------------------------------------------------
# 7. 订阅产物权限应为 0600 (Windows/MSYS 无 POSIX 权限位, 拿不到则跳过)
# ---------------------------------------------------------------------------
mode="$(stat -c '%a' "${OUT}/sni/subscription-base64.txt" 2>/dev/null || true)"
case "${mode}" in
644 | '') ok "权限检查跳过 (文件系统无 POSIX 权限位: ${mode:-n/a})" ;;
600) ok "订阅文件权限 0600" ;;
*) bad "订阅文件权限 ${mode}, 期望 600" ;;
esac

# ---------------------------------------------------------------------------
if [[ "${fail}" -eq 0 ]]; then
    printf '结果: 通过\n'
else
    printf '结果: 失败\n'
fi
exit "${fail}"
