#!/usr/bin/env bash
# =============================================================================
# 测试名称: target_presets_test.sh
# 测试目标: 锁定 .target 预设清单的可用性不变量, 以及"留空 = 随机选"的提示行为。
#
# 背景: .target 是"回车即随机"的候选池 (core/generate.sh 的 generate_target 直接
#   从它的键里随机取), 池子里混进一个不可用域名, 用户随机到它就会配置失败; 而原
#   提示只有一句"请输入目标域名 target (默认随机选择)", 极易被读成"随便填个域名",
#   实际它是 Reality 的伪装目标 (写进 realitySettings.target), 有 TLS 1.3 + X25519
#   等硬条件。本测试把"清单干净"与"提示说清楚"两件事固定下来。
#
# 锁定:
#   1. config.json 的 .target 非空 (>= 10), 每个键符合域名格式, 每个值是非空数组
#      且包含键自身 (serverNames 必须含 target, 见 handler.sh 的 REALITY 守卫);
#   2. 已实测不可用的域名不得回流 —— 并做 NEG 反向校验证明守卫真会报警;
#   3. read.sh --target 会打印"它是什么"的说明与**完整**预设清单, 且提示只走 stderr,
#      stdout 仍然只返回用户输入 (调用方靠它取值); 其它参数不得打印该清单;
#   4. core/check.sh 的 get_tls_info 必须带 -servername (SNI) —— 不带会把按 SNI
#      分流的正常站点误拒 (实测 www.samsung.com / www.docker.com), NEG 同第 2 条;
#   5. i18n zh / en 的 .read.target / target_hint / target_presets 齐备非空。
#
# 依赖网络吗: 不。真实可达性由 test/target_probe.sh 手工校验 (结论随出网环境变化,
#   不适合放进 CI); 本测试只锁定"不会退化"的静态不变量与交互行为。
#
# 运行: bash test/target_presets_test.sh
# =============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available in this environment"
    exit 0
fi

PASS=0; FAIL=0
# 传值/包含断言 (不依赖 $?, 规避 SC2319)
assert_eq() { # $1=msg $2=got $3=expected
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $1 (got '$2' want '$3')"; fi
}
assert_ne() { # $1=msg $2=got $3=unexpected
    if [[ "$2" != "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $1 (got '$2' should not be '$3')"; fi
}
assert_contains() { # $1=msg $2=haystack $3=needle
    if [[ "$2" == *"$3"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $1 (missing '$3')"; fi
}
assert_not_contains() { # $1=msg $2=haystack $3=needle
    if [[ "$2" != *"$3"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $1 (unexpectedly has '$3')"; fi
}

SB=".workbuddy/tmp/target_presets_$$"
rm -rf "$SB"; mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

CONFIG='config.json'

# 已实测不可用的域名 (2026-09-23, 大陆移动网络实测):
#   fandom 家族: DNS 被投毒 (www.fandom.com -> 108.160.162.31), 443/80 均不可达
#   www.leercapitulo.co: TCP 可达, 但 TLS 1.3 / X25519 探测均失败
#   www.lenovo.com:      两种形态下都取不到 TLS 1.3
BAD_DOMAINS='fandom.com toarumajutsunoindex.fandom.com dragonball.fandom.com pokemon.fandom.com nichijou.fandom.com bleach.fandom.com naruto.fandom.com onepiece.fandom.com www.fandom.com www.leercapitulo.co www.lenovo.com'

# 从 _common.sh 取域名正则 (单一来源, 不在测试里另抄一份)
DOMAIN_REGEX="$(sed -n 's/^readonly DOMAIN_REGEX="\(.*\)"$/\1/p' core/_common.sh)"
assert_ne "T0: 从 core/_common.sh 取到 DOMAIN_REGEX" "${DOMAIN_REGEX}" ""

# ---------------------------------------------------------------------------
# 预设清单体检: 输出每行一个问题, 全部干净则无输出
# 注: 全部用重定向到临时文件, 不用进程替换 —— 本沙箱缺 /dev/fd 时 < <(...) 会失效
# ---------------------------------------------------------------------------
preset_issues() { # $1=config 文件路径
    local cfg="$1" k='' v='' bad='' sn=''

    jq -r '.target | keys[]' "$cfg" > "$SB/keys.txt" 2>/dev/null || : > "$SB/keys.txt"
    if [[ ! -s "$SB/keys.txt" ]]; then
        printf 'no_presets\n'
        return 0
    fi

    local n=''
    n="$(jq -r '.target | length' "$cfg" 2>/dev/null || echo 0)"
    if ((n < 10)); then
        printf 'too_few=%s\n' "$n"
    fi

    while IFS= read -r k; do
        [[ -n "${k}" ]] || continue
        # 键必须是合法域名 (IP / 带端口 / 带路径都会被 valid_domain 拒绝)
        if ! [[ "${k}" =~ ${DOMAIN_REGEX} ]]; then
            printf 'bad_key=%s\n' "${k}"
        fi
        # 值必须是非空数组, 且包含键自身 (REALITY serverNames 必须含 target)
        v="$(jq -r --arg k "${k}" '.target[$k] | length' "$cfg" 2>/dev/null || echo 0)"
        if ((v == 0)); then
            printf 'empty_names=%s\n' "${k}"
        fi
        jq -e --arg k "${k}" '.target[$k] | index($k) != null' "$cfg" >/dev/null 2>&1 ||
            printf 'self_missing=%s\n' "${k}"
        # 键本身不得是已实测不可用的域名
        for bad in ${BAD_DOMAINS}; do
            if [[ "${k}" == "${bad}" ]]; then
                printf 'known_bad=%s\n' "${k}"
            fi
        done
        # serverNames 里的每一项同样要是合法域名, 且不得是已实测不可用的域名
        jq -r --arg k "${k}" '.target[$k][]' "$cfg" > "$SB/names.txt" 2>/dev/null || : > "$SB/names.txt"
        while IFS= read -r sn; do
            [[ -n "${sn}" ]] || continue
            if ! [[ "${sn}" =~ ${DOMAIN_REGEX} ]]; then
                printf 'bad_names=%s:%s\n' "${k}" "${sn}"
            fi
            for bad in ${BAD_DOMAINS}; do
                if [[ "${sn}" == "${bad}" ]]; then
                    printf 'known_bad_names=%s:%s\n' "${k}" "${sn}"
                fi
            done
        done < "$SB/names.txt"
    done < "$SB/keys.txt"
    return 0
}

# ---------------------------------------------------------------------------
# T1 正式清单必须无任何问题
# ---------------------------------------------------------------------------
issues="$(preset_issues "${CONFIG}")"
assert_eq "T1: config.json 预设清单无任何问题" "${issues}" ""

n="$(jq -r '.target | length' "${CONFIG}" 2>/dev/null || echo 0)"
if ((n >= 10)); then cnt='yes'; else cnt='no'; fi
assert_eq "T1a: 预设数量 >= 10 (当前 ${n})" "${cnt}" "yes"

found=''
for bad in ${BAD_DOMAINS}; do
    if jq -e --arg b "${bad}" '.target | has($b)' "${CONFIG}" >/dev/null 2>&1; then
        found="${found}${bad} "
    fi
done
assert_eq "T1b: 已实测不可用的域名不在预设清单中" "${found}" ""

# 键自身必须在自己的 serverNames 里 (REALITY 守卫 handler.sh 要求)
jq -r '.target | keys[]' "${CONFIG}" > "$SB/self_keys.txt" 2>/dev/null || : > "$SB/self_keys.txt"
self_ok='yes'
while IFS= read -r k; do
    [[ -n "${k}" ]] || continue
    jq -e --arg k "${k}" '.target[$k] | index($k) != null' "${CONFIG}" >/dev/null 2>&1 || self_ok='no'
done < "$SB/self_keys.txt"
assert_eq "T1c: 每个预设的 serverNames 都包含自身" "${self_ok}" "yes"

# ---------------------------------------------------------------------------
# T2 (NEG) 守卫自证: 分别注入"已知坏域名 / 非法键 / 空数组", 判据必须逐个报出
# ---------------------------------------------------------------------------
jq '.target["www.fandom.com"] = ["www.fandom.com"]' "${CONFIG}" > "$SB/bad_fandom.json"
assert_contains "T2a(NEG): 塞回 fandom -> known_bad" "$(preset_issues "$SB/bad_fandom.json")" 'known_bad=www.fandom.com'

jq '.target["not_a_domain"] = ["not_a_domain"]' "${CONFIG}" > "$SB/bad_key.json"
assert_contains "T2b(NEG): 塞入非法键 -> bad_key" "$(preset_issues "$SB/bad_key.json")" 'bad_key=not_a_domain'

jq '.target["www.sky.com"] = []' "${CONFIG}" > "$SB/empty_names.json"
assert_contains "T2c(NEG): 清空某个 serverNames -> empty_names" "$(preset_issues "$SB/empty_names.json")" 'empty_names=www.sky.com'

jq '.target["www.sky.com"] = ["www.fandom.com"]' "${CONFIG}" > "$SB/bad_names.json"
assert_contains "T2d(NEG): serverNames 里混入坏域名 -> known_bad_names" \
    "$(preset_issues "$SB/bad_names.json")" 'known_bad_names=www.sky.com:www.fandom.com'

# ---------------------------------------------------------------------------
# T3 read.sh --target 的提示行为 (用临时 HOME 指向临时 config.json)
# ---------------------------------------------------------------------------
mkdir -p "$SB/home_zh/.xray-script-personal-use-only" "$SB/home_en/.xray-script-personal-use-only"
jq '.language="zh"' "${CONFIG}" > "$SB/home_zh/.xray-script-personal-use-only/config.json"
jq '.language="en"' "${CONFIG}" > "$SB/home_en/.xray-script-personal-use-only/config.json"

hint_zh="$(jq -r '.read.target_hint' i18n/zh.json)"
hint_en="$(jq -r '.read.target_hint' i18n/en.json)"
first_key="$(jq -r '.target | keys | .[0]' "${CONFIG}")"
last_key="$(jq -r '.target | keys | .[-1]' "${CONFIG}")"

rc=0
printf 'tidal.com\n' | HOME="$PWD/$SB/home_zh" bash core/read.sh --target >"$SB/out_zh.txt" 2>"$SB/err_zh.txt" || rc=$?
assert_eq "T3a: read.sh --target 正常退出" "${rc}" "0"
assert_eq "T3b: stdout 只返回用户输入 (提示不污染取值)" "$(cat "$SB/out_zh.txt")" "tidal.com"
assert_contains "T3c: 打印了 target_hint 说明" "$(cat "$SB/err_zh.txt")" "${hint_zh}"
assert_contains "T3d: 清单含首项 ${first_key}" "$(cat "$SB/err_zh.txt")" "${first_key}"
assert_contains "T3e: 清单含末项 ${last_key}" "$(cat "$SB/err_zh.txt")" "${last_key}"
assert_contains "T3f: 清单前缀文案出现" "$(cat "$SB/err_zh.txt")" "$(jq -r '.read.target_presets' i18n/zh.json)"

rc=0
printf '\n' | HOME="$PWD/$SB/home_en" bash core/read.sh --target >"$SB/out_en.txt" 2>"$SB/err_en.txt" || rc=$?
assert_eq "T3g: en 语言下同样正常退出" "${rc}" "0"
assert_contains "T3h: en 语言下打印英文说明" "$(cat "$SB/err_en.txt")" "${hint_en}"

# 负向: 其它参数不得打印预设清单 (避免提示逻辑挂错分支)
printf '443\n' | HOME="$PWD/$SB/home_zh" bash core/read.sh --port >/dev/null 2>"$SB/err_port.txt" || true
assert_not_contains "T3i: --port 不打印预设清单" "$(cat "$SB/err_port.txt")" "${first_key}"
assert_not_contains "T3j: --port 不打印 target 说明" "$(cat "$SB/err_port.txt")" "${hint_zh}"

# ---------------------------------------------------------------------------
# T4 check.sh 的 TLS 探测必须带 SNI
# ---------------------------------------------------------------------------
tls_fn="$(awk '/^function get_tls_info\(\) \{/,/^\}/' core/check.sh)"
assert_ne "T4: 抽到 get_tls_info 函数体" "${tls_fn}" ""
assert_contains "T4a: TLS 探测带 -servername (SNI)" "${tls_fn}" '-servername "${1:-}"'

# NEG: 去掉 SNI 后同一判据必须报缺失 (注释里的说明文字不算数, 故断言整条参数)
sed 's/ -servername "${1:-}"//g' core/check.sh > "$SB/check_nosni.sh"
tls_fn_neg="$(awk '/^function get_tls_info\(\) \{/,/^\}/' "$SB/check_nosni.sh")"
assert_ne "T4b(NEG): 破损副本抽到了函数体" "${tls_fn_neg}" ""
assert_not_contains "T4c(NEG): 去掉 SNI 后判据报缺失" "${tls_fn_neg}" '-servername "${1:-}"'

# ---------------------------------------------------------------------------
# T5 i18n: 三处文案 zh / en 双侧齐备且非空
# ---------------------------------------------------------------------------
for f in zh en; do
    for key in target target_hint target_presets; do
        v="$(jq -r --arg k "${key}" '.read[$k] // ""' "i18n/${f}.json" 2>/dev/null || true)"
        assert_ne "T5(${f}): .read.${key} 非空" "${v}" ""
    done
done

# ---------------------------------------------------------------------------
# T6 提示与随机池同源: generate_target 仍从 .target 的键取值
# ---------------------------------------------------------------------------
gen_fn="$(awk '/^function generate_target\(\) \{/,/^\}/' core/generate.sh)"
assert_contains "T6: generate_target 从 .target 的键随机取值 (与提示同源)" "${gen_fn}" '.target | keys'

# ---------------------------------------------------------------------------
echo "==== target_presets_test: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]]
