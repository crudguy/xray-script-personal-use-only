#!/usr/bin/env bash
# =============================================================================
# 测试名称: rule_value_check_test.sh
# 测试目标: 锁定"分流值写前校验"的判定语义与接线。
#
# 背景: 分流菜单 (9 -> 2 -> 3/4/5/6) 输入为空/非法时, add_rule 曾把空串写成
#   ip:[""] 非法规则, 触发 xray 校验失败 -> 回滚 + 退出码 1。
#   除 add_rule 的空值守卫外, 现新增"写前校验" (check.sh 的 _rule_is_valid_ip /
#   _rule_is_valid_domain), 由 core/handler.sh 的 exec_read 在**写盘前**调用,
#   非法值当场提示重输, 不再进回滚流程。
#
# 本测试防三件事:
#   (1) 校验被改松 —— 放过明显非法值, 又走回滚;
#   (2) 校验被改紧 —— 误拒 xray 实际支持的合法值 (geoip:xxx / CIDR / 通配域名...);
#   (3) 接线被摘掉 —— 函数还在, 但 exec_read / check.sh 分派 / i18n 文案断了。
#
# 依赖: bash, awk, jq (jq 缺失时按本项目约定以 rc=3 SKIP)。
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

# 行为级/集成断言的工作区: 隔离 HOME (check.sh 经 load_i18n 读 config.json 的 language)
TMPH=".workbuddy/tmp/rule_value_check_home_$$"
SB=".workbuddy/tmp/rule_value_check.$$"
trap 'rm -rf "${TMPH}" "${SB}" 2>/dev/null || true' EXIT
mkdir -p "${SB}"

# --- 抽取待测函数体 (纯 bash, 不 source 整个 check.sh 以免拉起 set -Eeuo 与 i18n) ---
SRC="$(
    awk '/^function _rule_split_values\(\) \{/,/^}/' core/check.sh
    awk '/^function _rule_is_valid_ip\(\) \{/,/^}/' core/check.sh
    awk '/^function _rule_is_valid_domain\(\) \{/,/^}/' core/check.sh
    awk '/^function _rule_first_invalid\(\) \{/,/^}/' core/check.sh
)"
if [[ -z "${SRC}" ]]; then
    echo "FATAL: 未能从 core/check.sh 抽取 _rule_* 函数"
    exit 1
fi
eval "${SRC}"

# ---------------------------------------------------------------------------
# T1 ip 分流值: 判定语义
# ---------------------------------------------------------------------------
assert_ip() {
    local desc="$1" val="$2" exp="$3"
    local got=1
    _rule_is_valid_ip "${val}" && got=0
    if [[ "${got}" -eq "${exp}" ]]; then ok; else bad "T1 ip [${desc}] val=[${val}] 期望 rc=${exp} 实测 rc=${got}"; fi
}

# 合法 (期望放行)
assert_ip "ipv4"              "1.2.3.4"        0
assert_ip "ipv4-cidr"         "1.2.3.0/24"     0
assert_ip "ipv4-cidr-32"      "1.2.3.4/32"     0
assert_ip "geoip"             "geoip:cn"       0
assert_ip "geoip-private"     "geoip:private"  0
assert_ip "ext"               "ext:ip.dat:cn"  0
assert_ip "ipv6-full"         "2001:db8:0:0:0:0:0:1" 0
assert_ip "ipv6-compressed"   "2001:db8::1"    0
assert_ip "ipv6-loopback"     "::1"            0
assert_ip "ipv6-cidr"         "2001:db8::/32"  0
# 非法 (期望拦下)
assert_ip "empty"             ""               1
assert_ip "octet-overflow"    "999.1.1.1"      1
assert_ip "cidr-overflow"     "1.2.3.4/33"     1
assert_ip "not-ip"            "abc"            1
assert_ip "domain-in-ip"      "example.com"    1
assert_ip "short-ipv4"        "1.2.3"          1
assert_ip "single-colon"      "abc:def"        1
assert_ip "inner-space"       "1.2.3.4 5.6.7.8" 1

# ---------------------------------------------------------------------------
# T2 domain 分流值: 判定语义
# ---------------------------------------------------------------------------
assert_domain() {
    local desc="$1" val="$2" exp="$3"
    local got=1
    _rule_is_valid_domain "${val}" && got=0
    if [[ "${got}" -eq "${exp}" ]]; then ok; else bad "T2 domain [${desc}] val=[${val}] 期望 rc=${exp} 实测 rc=${got}"; fi
}

# 合法 (期望放行)
assert_domain "plain"         "example.com"              0
assert_domain "sub"           "sub.example.com"          0
assert_domain "wildcard"      "*.example.com"            0
assert_domain "geosite"       "geosite:category-ads-all" 0
assert_domain "domain-prefix" "domain:foo.com"           0
assert_domain "full-prefix"   "full:bar.com"             0
assert_domain "keyword"       "keyword:ads"              0
assert_domain "regexp"        "regexp:^ad[sx]\.com$"     0
assert_domain "ext"           "ext:geosite.dat:cn"       0
# 非法 (期望拦下)
assert_domain "empty"         ""                         1
assert_domain "double-dot"    "a..com"                   1
assert_domain "leading-dot"   ".com"                     1
assert_domain "trailing-dot"  "com."                     1
assert_domain "with-space"    "a b.com"                  1
assert_domain "prefix-only"   "domain:"                  1

# ---------------------------------------------------------------------------
# T3 _rule_first_invalid: 找出的"第一个非法值"必须精确 (含去空格/丢空项)
# ---------------------------------------------------------------------------
assert_first() {
    local desc="$1" kind="$2" raw="$3" exp="$4"
    local got
    got="$(_rule_first_invalid "${kind}" "${raw}")"
    if [[ "${got}" == "${exp}" ]]; then ok; else bad "T3 [${desc}] 期望=[${exp}] 实测=[${got}]"; fi
}

assert_first "ip 跳过空项与空格, 命中 xyz"  ip     ' , 1.2.3.4,,xyz '  'xyz'
assert_first "ip 全合法 -> 空"              ip     '1.2.3.4, 5.6.7.8 ' ''
assert_first "ip 只有逗号空格 -> 空"        ip     ' , , '             ''
assert_first "ip 空串 -> 空"                ip     ''                  ''
assert_first "domain 命中含空格项"          domain 'a.com, bad domain ' 'bad domain'
assert_first "domain 全合法 -> 空"          domain 'a.com,*.b.com'      ''

# ---------------------------------------------------------------------------
# T4 接线守卫: 函数必须真的被调用 (否则等于加了没生效)
# ---------------------------------------------------------------------------
grep -qE '^[[:space:]]*--rule-ip\)[[:space:]]*check_rule_ip' core/check.sh \
    && ok || bad "T4: check.sh 分派缺 --rule-ip -> check_rule_ip"
grep -qE '^[[:space:]]*--rule-domain\)[[:space:]]*check_rule_domain' core/check.sh \
    && ok || bad "T4: check.sh 分派缺 --rule-domain -> check_rule_domain"
# 退出码透传守卫: 分派必须是 `... || exit $?` —— 否则 set -e 的 ERR trap 会把
# "校验不通过"误报成"[错误] 脚本在第 N 行意外失败 ... return 1" (见 check.sh 内注释)
grep -qE '^[[:space:]]*--rule-ip\)[[:space:]]*check_rule_ip .*\|\|[[:space:]]*exit[[:space:]]+\$\?' core/check.sh \
    && ok || bad "T4: --rule-ip 分派缺 '|| exit \$?' (校验不通过会被 ERR trap 误报)"
grep -qE '^[[:space:]]*--rule-domain\)[[:space:]]*check_rule_domain .*\|\|[[:space:]]*exit[[:space:]]+\$\?' core/check.sh \
    && ok || bad "T4: --rule-domain 分派缺 '|| exit \$?' (校验不通过会被 ERR trap 误报)"
grep -qE 'check_rule_ip\(\)[[:space:]]*\{' core/check.sh \
    && ok || bad "T4: check.sh 缺 check_rule_ip 定义"
grep -qE 'check_rule_domain\(\)[[:space:]]*\{' core/check.sh \
    && ok || bad "T4: check.sh 缺 check_rule_domain 定义"
grep -qE '^[[:space:]]*block-ip \| warp-ip\)' core/handler.sh \
    && ok || bad "T4: exec_read 缺 block-ip|warp-ip 分支"
grep -qE '^[[:space:]]*block-domain \| warp-domain\)' core/handler.sh \
    && ok || bad "T4: exec_read 缺 block-domain|warp-domain 分支"
grep -qF "exec_check '--rule-ip'" core/handler.sh \
    && ok || bad "T4: exec_read 未调用 --rule-ip"
grep -qF "exec_check '--rule-domain'" core/handler.sh \
    && ok || bad "T4: exec_read 未调用 --rule-domain"
# 空输入放行 (交由 add_rule 的 value_empty 守卫): 分支内须有"剥离空格/逗号后非空才校验"的守卫
grep -qF 'result//[[:space:],]/' core/handler.sh \
    && ok || bad "T4: exec_read 分支缺空输入放行守卫 (result//[[:space:],]/)"

# ---------------------------------------------------------------------------
# T5 i18n 文案: zh/en 双侧齐备且非空 (缺 jq 则 SKIP)
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    for lang in zh en; do
        for key in 'check.rule.invalid_ip' 'check.rule.invalid_domain'; do
            v="$(jq -r ".${key} // empty" "i18n/${lang}.json" 2>/dev/null || true)"
            if [[ -n "${v}" ]]; then ok; else bad "T5: i18n/${lang}.json 缺空键 ${key}"; fi
        done
    done
else
    echo "SKIP: 缺少依赖 jq, 跳过 T5 文案断言"
fi

# ---------------------------------------------------------------------------
# T6 行为级: 真跑 check.sh, 校验不通过须 rc=1 且**不出现** ERR trap 的"意外失败"噪音
#    (否则用户会看到一条假的"[错误] 脚本在第 N 行意外失败 ... return 1", 与
#     "当场提示重输"的体验冲突)。缺 jq 时 check.sh 的 i18n 加载不完整, 跳过。
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    mkdir -p "${TMPH}/.xray-script-personal-use-only"
    printf '{"version":"vT","language":"zh"}\n' >"${TMPH}/.xray-script-personal-use-only/config.json"

    out_bad="$(HOME="${TMPH}" bash core/check.sh --rule-ip 'abc' 2>&1)"
    rc_bad=$?
    [[ "${rc_bad}" -eq 1 ]] && ok || bad "T6: 非法 ip 应 rc=1, 实测 rc=${rc_bad}"
    case "${out_bad}" in
    *意外失败*) bad "T6: 非法 ip 输出含 ERR trap 噪音: $(printf '%s' "${out_bad}" | tr '\n' '|')" ;;
    *) ok ;;
    esac
    case "${out_bad}" in
    *分流值不合法*) ok ;;
    *) bad "T6: 非法 ip 未渲染出 [失败] 文案: $(printf '%s' "${out_bad}" | tr '\n' '|')" ;;
    esac

    out_ok="$(HOME="${TMPH}" bash core/check.sh --rule-ip '1.2.3.4,geoip:cn' 2>&1)"
    rc_ok=$?
    [[ "${rc_ok}" -eq 0 ]] && ok || bad "T6: 合法 ip 应 rc=0, 实测 rc=${rc_ok}"
    [[ -z "${out_ok}" ]] && ok || bad "T6: 合法 ip 不应有任何输出, 实测: $(printf '%s' "${out_ok}" | tr '\n' '|')"

    out_dm="$(HOME="${TMPH}" bash core/check.sh --rule-domain 'bad domain' 2>&1)"
    rc_dm=$?
    [[ "${rc_dm}" -eq 1 ]] && ok || bad "T6: 非法 domain 应 rc=1, 实测 rc=${rc_dm}"
    case "${out_dm}" in
    *意外失败*) bad "T6: 非法 domain 输出含 ERR trap 噪音" ;;
    *) ok ;;
    esac

    HOME="${TMPH}" bash core/check.sh --rule-ip '' >/dev/null 2>&1
    rc_empty=$?
    [[ "${rc_empty}" -eq 0 ]] && ok || bad "T6: 空输入应放行 (rc=0), 实测 rc=${rc_empty}"
else
    echo "SKIP: 缺少依赖 jq, 跳过 T6 行为级断言"
fi

# ---------------------------------------------------------------------------
# NEG 负向校验: 把"合法 IPv6 至少两个冒号"的守卫放宽, 确认 T1 的 single-colon
#     断言真能捕获该回归 (证明不是"加了等于没加")。
# ---------------------------------------------------------------------------
BROKEN="${SRC//'*:*:*'/'*:*'}"
if [[ "${BROKEN}" == "${SRC}" ]]; then
    bad "NEG: 未能构造成破损版 (未匹配到 *:*:* 守卫)"
else
    NEG_GOT="$(
        eval "${BROKEN}"
        if _rule_is_valid_ip 'abc:def'; then echo yes; else echo no; fi
    )"
    if [[ "${NEG_GOT}" == "yes" ]]; then
        ok
    else
        bad "NEG: 放宽冒号守卫后 abc:def 仍被拒 -> T1 无法捕获该回归"
    fi
fi

# ---------------------------------------------------------------------------
# T7 集成: 抽出真实 exec_read, 校验走**真实** core/check.sh, 用"假 read.sh"按序喂值。
#   证明两件事:
#     (a) 非法值会被 exec_read 的重试循环消费 (不写盘), 喂到合法值才通过;
#     (b) 空输入不烧重试 (一次即放行, 交由 add_rule 的 value_empty 守卫 no-op)。
#   缺 jq 时 check.sh 的 i18n 加载不完整, 跳过。
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    awk '/^function exec_read\(\) \{/{c=1} c{print} c&&/^\}$/{exit}' core/handler.sh >"${SB}/exec_read.sh"
    if [[ ! -s "${SB}/exec_read.sh" ]]; then
        bad "T7: 无法从 core/handler.sh 抽取 exec_read"
    else
        # 假 read.sh: 每次调用计数, 并按计数从 QUEUE 里取第 N 行作为"用户输入"
        cat >"${SB}/fake_read.sh" <<'EOF'
#!/usr/bin/env bash
printf 'x\n' >>"${CALLS}"
n="$(wc -l <"${CALLS}" | tr -d ' ')"
sed -n "${n}p" "${QUEUE}"
exit 0
EOF
        # 驱动: exec_check 接到**真实** check.sh 上 (CHECK_PATH 由 $3 传入)
        cat >"${SB}/drv.sh" <<'DRV'
READ_PATH="$1"; CUR_FILE='handler'; CHECK_PATH="$3"; export HOME="$4"
declare -A CONFIG_DATA
_i18n() { printf '%s' "$1"; }
_error() { printf 'ERROR %s\n' "$1" >&2; exit 1; }
exec_check() { bash "${CHECK_PATH}" "$@" || return $?; }
source "$2"
exec_read 'block-ip'
printf 'GOT=%s' "${CONFIG_DATA[block-ip]}"
DRV

        # (a) 先非法后合法 -> 重试一次后通过
        printf 'abc\n1.2.3.4\n' >"${SB}/queue_a"
        : >"${SB}/calls_a"
        out_a="$(CALLS="${SB}/calls_a" QUEUE="${SB}/queue_a" \
            bash "${SB}/drv.sh" "${SB}/fake_read.sh" "${SB}/exec_read.sh" "$REPO/core/check.sh" "${TMPH}" 2>/dev/null)"
        rc_a=$?
        n_a="$(wc -l <"${SB}/calls_a" | tr -d ' ')"
        [[ "${rc_a}" -eq 0 ]] && ok || bad "T7: 非法后合法应成功 (rc=${rc_a})"
        [[ "${n_a}" == "2" ]] && ok || bad "T7: 非法值应触发 1 次重读 (read 调用数=${n_a}, 期望 2)"
        [[ "${out_a}" == "GOT=1.2.3.4" ]] && ok || bad "T7: 通过后应存入合法值, 实测 [${out_a}]"

        # (b) 空输入 -> 一次即放行 (不烧重试), 值留空交由 add_rule 守卫 no-op
        printf '\n' >"${SB}/queue_b"
        : >"${SB}/calls_b"
        out_b="$(CALLS="${SB}/calls_b" QUEUE="${SB}/queue_b" \
            bash "${SB}/drv.sh" "${SB}/fake_read.sh" "${SB}/exec_read.sh" "$REPO/core/check.sh" "${TMPH}" 2>/dev/null)"
        rc_b=$?
        n_b="$(wc -l <"${SB}/calls_b" | tr -d ' ')"
        [[ "${rc_b}" -eq 0 ]] && ok || bad "T7: 空输入应放行 (rc=${rc_b})"
        [[ "${n_b}" == "1" ]] && ok || bad "T7: 空输入应只读 1 次 (read 调用数=${n_b}, 期望 1)"
        [[ "${out_b}" == "GOT=" ]] && ok || bad "T7: 空输入应存空值交由 add_rule 守卫, 实测 [${out_b}]"
    fi
else
    echo "SKIP: 缺少依赖 jq, 跳过 T7 集成断言"
fi

echo "==== rule_value_check_test: PASS=${PASS} FAIL=${FAIL} ===="
[[ "${FAIL}" -eq 0 ]]
