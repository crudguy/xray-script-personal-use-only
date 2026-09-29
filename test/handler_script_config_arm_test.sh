#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_script_config_arm_test.sh
# 测试目标: 写脚本配置 (config.json) 的两条臂 —— handler_script_config 与
#           handler_x25519_config 的**决策层**回归。
#
# 为什么需要本测试 (审计背景):
#   这两条臂是全仓"写入面最宽"的地方: SCRIPT_CONFIG 是 Xray 配置、nginx 配置、
#   分享链接、订阅的共同上游快照, 写错字段 = 后面全错, 且**没有任何 GUI 可见的
#   中间产物** —— config.json 在 ~/.xray-script-personal-use-only/ 下, 用户不会去看。
#   此前二者全仓零覆盖。
#
#   handler_script_config 的复杂度集中在 4 段 `case "${CONFIG_TAG,,}"` —— 同一个
#   tag 会命中多段 (如 trojan 命中第 1/3/4 段, vision 命中第 1/4 段但不命中第 3 段),
#   改漏一段的表现是"少写一个字段", 用户要到装完才发现某个能力没生效。
#
#   handler_x25519_config 里有一条**安全不变量**: Reality 私钥是长期密钥, 默认**不
#   回显** (客户端只需要 Public Key + Short ID)。它一旦落到终端回滚 / screen / tmux
#   日志 / `2>log` 重定向 / 运维录屏里等同永久泄露。本测试把它钉死。
#
# 锁定不变量:
#   [A] 通用段
#     T1  reset 先行     -- 先调 handler_reset_script_config, 切 tag 后旧 tag 的字段不残留
#     T2  rules 三态     -- 空/y -> 1; n (含大写 N) -> 0; bt/cn/ad 同口径
#     T3  端口形态       -- 非 mkcp 用输入或回落 443, 且写的是 JSON **number**
#     T4  tag 大小写不敏感 (VISION == vision), 但 .xray.tag 保留输入原文
#   [B] tag 路由 —— 各 tag 命中哪些字段
#     T5  trojan   -> trojan / path / target / serverNames / shortIds (无 uuid)
#     T6  vision   -> uuid / target / serverNames / shortIds (无 trojan, **无 path**)
#     T7  mkcp     -> uuid / kcp seed, 且端口**强制**由 generate 现算 (忽略用户输入)
#     T8  sni      -> uuid / fallback / path / target / serverNames / shortIds
#                     + nginx.domain / nginx.cdn; nginx.ca 仅在邮箱非空时写
#   [C] x25519
#     T9  三段解析       -- "私钥,公钥,hash32" 分别落 .xray.privateKey/publicKey/hash32
#     T10 私钥默认不回显 (core), 公钥与 hash32 必回显
#     T11 SHOW_PRIVATE_KEY=1 时才回显明文
#
# 实现: 从 core/handler.sh 抽**真实函数体** eval 注入; 桩只替换外边界
#   (exec_generate / persist_script_config / handler_reset_script_config / _i18n /
#    is_enabled)。被测函数写回全局 SCRIPT_CONFIG —— 按项目教训**不得**用 `( )` 子
#   shell 包裹, 否则写回出不去父进程、断言会成片假绿。
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$REPO"

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available in this environment"
    exit 0
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1 (期望 [$3] 实际 [$2])"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1 (未包含 [$3]，实际 [$2])"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1 (不应包含 [$3]，实际 [$2])"; fi; }
count_lines() { # $1=正则 $2=文件
    if [[ -f "$2" ]]; then
        grep -c "$1" "$2" || true
    else
        printf '0'
    fi
}
# 抽真实函数体 (抽不到 -> 空串, 让静态断言失败得明明白白)
extract_fn() { awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' "$1"; }

echo "==== handler_script_config_arm_test ===="

SB=".workbuddy/tmp/sc_arm.$$"
mkdir -p "$SB"

# ---------------------------------------------------------------------------
# 真实函数体
# ---------------------------------------------------------------------------
sc_fn="$(extract_fn core/handler.sh handler_script_config)"
x_fn="$(extract_fn core/handler.sh handler_x25519_config)"
assert_contains "T0a handler_script_config 抽取成功" "$sc_fn" 'CONFIG_TAG'
assert_contains "T0b handler_x25519_config 抽取成功" "$x_fn" 'privateKey'

# 作为输入基准: 故意带上"上一个 tag"留下的陈值, 以及 reset 白名单字段
SC_BASE='{"version":"v-test","xray":{"version":"26.3.27","tag":"old-tag","uuid":"OLD-UUID","trojan":"OLD-PASSWORD","path":"/oldpath","target":"old.example.com","serverNames":["old.example.com"],"shortIds":["aa"],"port":443,"warp":1,"rules":{"reset":1,"bt":0,"cn":0,"ad":0},"sniffRouteOnly":1},"nginx":{"version":"v-test","domain":"old.example.com","cdn":"","ca":"old@example.com"}}'

declare -A CONFIG_DATA

# ---------------------------------------------------------------------------
# 驱动: 跑一次 handler_script_config, 返回 RC / 落盘后的 SCRIPT_CONFIG / 留痕日志
# 环境变量:
#   CFG_TAG    tag 入参    CD_*        CONFIG_DATA 键值 (cd_key 形式不便于传中文 key, 用 CD_VARS)
#   GEN_*      exec_generate 各选项的返回值
# ---------------------------------------------------------------------------
run_sc() {
    local plog="$1"
    local cfgout="$2"
    local genlog="$3"
    : >"$plog"
    : >"$genlog"
    rm -f "$cfgout"

    CONFIG_DATA=()
    # CD_VARS 形如 "tag=vision|port=8443"
    local pair
    for pair in ${CD_VARS:-}; do
        # shellcheck disable=SC2034
        CONFIG_DATA["${pair%%=*}"]="${pair#*=}"
    done

    # 颜色与 CUR_FILE 只被 eval 注入的被测函数体读取 —— shellcheck 数据流不跨 eval,
    # 故逐条前置 disable (文件头 disable 会掩盖真正的死变量)。
    # shellcheck disable=SC2034
    GREEN=$'\033[32m'
    # shellcheck disable=SC2034
    YELLOW=$'\033[33m'
    # shellcheck disable=SC2034
    NC=$'\033[0m'
    # shellcheck disable=SC2034
    CUR_FILE='handler'
    SCRIPT_CONFIG="$SC_BASE"

    _i18n() { printf '%s' "${1#.}"; }
    is_enabled() {
        case "${1:-}" in 1 | true | yes | y | on) return 0 ;; *) return 1 ;; esac
    }
    # 模拟真实 reset 语义: 清 .xray 陈值, 但保留白名单字段
    handler_reset_script_config() {
        printf 'RESET\n' >>"$plog"
        SCRIPT_CONFIG="$(printf '%s' "${SCRIPT_CONFIG}" | jq '.xray |= (to_entries | map(select(.key as $k | ["version", "warp", "rules", "sniffRouteOnly"] | index($k))) | from_entries)')"
    }
    exec_generate() {
        printf 'GEN:%s\n' "$*" >>"$genlog"
        if [[ "${GEN_FAIL:-0}" == '1' ]]; then
            return 0 # 返回空串 —— 模拟外部生成器拿不到值
        fi
        case "${1:-}" in
        '--uuid')
            # 对齐 generate_uuid 真实语义: 入参已是标准 UUID 则**复用它**, 否则才生成新的
            local _u="${2:-}"
            if [[ "${_u}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
                printf '%s' "${_u}"
            else
                printf '%s' "${GEN_UUID:-uuid-from-gen}"
            fi
            ;;
        '--password') printf '%s' "${GEN_PASSWORD:-pass-from-gen}" ;;
        '--path') printf '%s' "${GEN_PATH:-/genpath}" ;;
        '--target') printf '%s' "${GEN_TARGET:-gen.example.com}" ;;
        '--port') printf '%s' "${GEN_PORT:-55999}" ;;
        '--server-names') printf '%s' "${GEN_SERVERNAMES:-[\"gen.example.com\"]}" ;;
        '--short-ids') printf '%s' "${GEN_SHORTIDS:-[\"a1\",\"b2c3\"]}" ;;
        '--x25519') printf '%s' "${GEN_X25519:-PRIV_FROM_GEN,PUB_FROM_GEN,HASH_FROM_GEN}" ;;
        *) printf '%s' "gen-${1:-}" ;;
        esac
    }
    persist_script_config() {
        printf 'PERSIST\n' >>"$plog"
        printf '%s' "${SCRIPT_CONFIG}" >"$cfgout"
    }

    eval "$sc_fn"
    handler_script_config
    return 0
}

# ---------------------------------------------------------------------------
# T1: reset 先行 + 陈值不残留
# ---------------------------------------------------------------------------
echo "== T1 reset 先行与陈值清理 =="
CD_VARS='tag=vision' GEN_UUID='NEW-UUID' run_sc "$SB/t1.log" "$SB/t1.json" "$SB/t1.gen"
assert_eq "T1a reset 被调用一次" "$(count_lines '^RESET$' "$SB/t1.log")" '1'
assert_eq "T1b persist 恰好一次 (收尾落盘)" "$(count_lines '^PERSIST$' "$SB/t1.log")" '1'
assert_contains "T1c reset 在 persist 之前 (先清后写)" "$(cat "$SB/t1.log")" 'RESET
PERSIST'
assert_eq "T1d 旧 tag 的 trojan 陈值已清除" "$(jq -r '.xray.trojan // "GONE"' "$SB/t1.json")" 'GONE'
assert_eq "T1e uuid 被换成新值" "$(jq -r '.xray.uuid' "$SB/t1.json")" 'NEW-UUID'
assert_eq "T1f reset 白名单 version 保留" "$(jq -r '.xray.version' "$SB/t1.json")" '26.3.27'
assert_eq "T1g reset 白名单 warp 保留" "$(jq -r '.xray.warp' "$SB/t1.json")" '1'
assert_eq "T1h reset 白名单 rules 保留 (此切面 PCR)" "$(jq -r '.xray.rules.reset' "$SB/t1.json")" '1'
assert_eq "T1i 顶层 version 未被波及" "$(jq -r '.version' "$SB/t1.json")" 'v-test'

# ---------------------------------------------------------------------------
# T2: rules 三态 —— 空 / y / n(含大写) 三种口径
# ---------------------------------------------------------------------------
echo "== T2 rules 三态 =="
CD_VARS='tag=vision' run_sc "$SB/t2a.log" "$SB/t2a.json" "$SB/t2a.gen"
assert_eq "T2a1 rules 缺省 -> reset=1 (默认起黑洞路由)" "$(jq -r '.xray.rules.reset' "$SB/t2a.json")" '1'
assert_eq "T2a2 bt 缺省 -> 1" "$(jq -r '.xray.rules.bt' "$SB/t2a.json")" '1'
assert_eq "T2a3 cn 缺省 -> 1" "$(jq -r '.xray.rules.cn' "$SB/t2a.json")" '1'
assert_eq "T2a4 ad 缺省 -> 1" "$(jq -r '.xray.rules.ad' "$SB/t2a.json")" '1'

CD_VARS='tag=vision rules=n block-bt=N block-cn=no block-ad=N' run_sc "$SB/t2b.log" "$SB/t2b.json" "$SB/t2b.gen"
assert_eq "T2b1 rules=n -> reset=0" "$(jq -r '.xray.rules.reset' "$SB/t2b.json")" '0'
assert_eq "T2b2 bt=N (大写) -> 0 (判等前有小写化)" "$(jq -r '.xray.rules.bt' "$SB/t2b.json")" '0'
assert_eq "T2b3 cn=no -> 1 (只有 n 才关)" "$(jq -r '.xray.rules.cn' "$SB/t2b.json")" '1'
assert_eq "T2b4 ad=N -> 0" "$(jq -r '.xray.rules.ad' "$SB/t2b.json")" '0'

CD_VARS='tag=vision rules=Y block-bt=y' run_sc "$SB/t2c.log" "$SB/t2c.json" "$SB/t2c.gen"
assert_eq "T2c1 rules=Y -> 1" "$(jq -r '.xray.rules.reset' "$SB/t2c.json")" '1'
assert_eq "T2c2 bt=y -> 1" "$(jq -r '.xray.rules.bt' "$SB/t2c.json")" '1'

# ---------------------------------------------------------------------------
# T3: 端口形态
# ---------------------------------------------------------------------------
echo "== T3 端口策略与 JSON 类型 =="
CD_VARS='tag=vision' run_sc "$SB/t3a.log" "$SB/t3a.json" "$SB/t3a.gen"
assert_eq "T3a1 无输入回落 443" "$(jq -r '.xray.port' "$SB/t3a.json")" '443'
assert_eq "T3a2 写的是 JSON number (下游 jq 比较/模板插值类型敏感)" "$(jq -r '.xray.port|type' "$SB/t3a.json")" 'number'

CD_VARS='tag=vision port=8443' run_sc "$SB/t3b.log" "$SB/t3b.json" "$SB/t3b.gen"
assert_eq "T3b1 用用户输入" "$(jq -r '.xray.port' "$SB/t3b.json")" '8443'
assert_eq "T3b2 仍是 number" "$(jq -r '.xray.port|type' "$SB/t3b.json")" 'number'
assert_eq "T3b3 非 mkcp 不调 generate --port" "$(count_lines '^GEN:--port' "$SB/t3b.gen")" '0'

# ---------------------------------------------------------------------------
# T4: tag 大小写不敏感, 但落盘保留原文
# ---------------------------------------------------------------------------
echo "== T4 tag 大小写不敏感 =="
CD_VARS='tag=VISION' GEN_UUID='U1' run_sc "$SB/t4.log" "$SB/t4.json" "$SB/t4.gen"
assert_eq "T4a 大写 VISION 仍命中 vision 分支 (写 uuid)" "$(jq -r '.xray.uuid' "$SB/t4.json")" 'U1'
assert_eq "T4b .xray.tag 保留输入原文" "$(jq -r '.xray.tag' "$SB/t4.json")" 'VISION'

# ---------------------------------------------------------------------------
# T5-T8: tag 路由 —— 各 tag 命中哪些字段
# ---------------------------------------------------------------------------
has() { jq -e "$1" "$2" >/dev/null 2>&1; }

echo "== T5 trojan =="
CD_VARS='tag=trojan password=THE-PWD' run_sc "$SB/t5.log" "$SB/t5.json" "$SB/t5.gen"
assert_eq "T5a 写 trojan 密码" "$(jq -r '.xray.trojan' "$SB/t5.json")" 'THE-PWD'
assert_eq "T5b trojan 不写 uuid" "$(jq -r '.xray.uuid // "NONE"' "$SB/t5.json")" 'NONE'
assert_eq "T5c trojan 命中第 3 段 -> 有 path" "$(jq -r '.xray.path' "$SB/t5.json")" '/genpath'
assert_eq "T5d trojan 命中第 4 段 -> 有 target" "$(jq -r '.xray.target' "$SB/t5.json")" 'gen.example.com'
assert_eq "T5e trojan 不改 nginx.domain" "$(jq -r '.nginx.domain' "$SB/t5.json")" 'old.example.com'

echo "== T6 vision =="
CD_VARS='tag=vision uuid=11111111-2222-3333-4444-555555555555' run_sc "$SB/t6.log" "$SB/t6.json" "$SB/t6.gen"
assert_eq "T6a 写 uuid (标准 UUID 入参被复用)" "$(jq -r '.xray.uuid' "$SB/t6.json")" '11111111-2222-3333-4444-555555555555'
assert_eq "T6b vision 不写 trojan" "$(jq -r '.xray.trojan // "NONE"' "$SB/t6.json")" 'NONE'
assert_eq "T6c vision 不命中第 3 段 -> 无 path" "$(jq -r '.xray.path // "NONE"' "$SB/t6.json")" 'NONE'
assert_eq "T6d vision 命中第 4 段 -> 有 target" "$(jq -r '.xray.target' "$SB/t6.json")" 'gen.example.com'
assert_eq "T6e serverNames 是 JSON 数组" "$(jq -r '.xray.serverNames|type' "$SB/t6.json")" 'array'
assert_eq "T6f shortIds 是 JSON 数组" "$(jq -r '.xray.shortIds|type' "$SB/t6.json")" 'array'
assert_eq "T6g serverNames 内容来自 generate" "$(jq -r '.xray.serverNames[0]' "$SB/t6.json")" 'gen.example.com'
assert_eq "T6h uuid 透传给 generate (复用已有密钥)" "$(count_lines '^GEN:--uuid 11111111-2222-3333-4444-555555555555$' "$SB/t6.gen")" '1'

echo "== T7 mkcp =="
CD_VARS='tag=mkcp uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee seed=THE-SEED port=8443' GEN_PORT='57123' run_sc "$SB/t7.log" "$SB/t7.json" "$SB/t7.gen"
assert_eq "T7a 端口强制由 generate 现算 (忽略用户输入的 8443)" "$(jq -r '.xray.port' "$SB/t7.json")" '57123'
assert_eq "T7b 确实调了 generate --port" "$(count_lines '^GEN:--port' "$SB/t7.gen")" '1'
assert_eq "T7c 写 kcp seed" "$(jq -r '.xray.kcp' "$SB/t7.json")" 'THE-SEED'
assert_eq "T7d mkcp 也写 uuid (命中第 1 段)" "$(jq -r '.xray.uuid' "$SB/t7.json")" 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
assert_eq "T7e mkcp 不命中第 3 段 -> 无 path" "$(jq -r '.xray.path // "NONE"' "$SB/t7.json")" 'NONE'
assert_eq "T7f mkcp 不命中第 4 段 -> 无 target" "$(jq -r '.xray.target // "NONE"' "$SB/t7.json")" 'NONE'
assert_eq "T7g 随机端口仍是 number" "$(jq -r '.xray.port|type' "$SB/t7.json")" 'number'

echo "== T8 sni =="
CD_VARS='tag=sni target=sni.example.com cdn=cdn.example.com' run_sc "$SB/t8a.log" "$SB/t8a.json" "$SB/t8a.gen"
assert_eq "T8a1 sni 写 nginx.domain" "$(jq -r '.nginx.domain' "$SB/t8a.json")" 'sni.example.com'
assert_eq "T8a2 sni 写 nginx.cdn" "$(jq -r '.nginx.cdn' "$SB/t8a.json")" 'cdn.example.com'
assert_eq "T8a3 邮箱为空 -> **不**覆盖 nginx.ca (条件守卫)" "$(jq -r '.nginx.ca' "$SB/t8a.json")" 'old@example.com'
assert_eq "T8a4 sni 写 fallback uuid" "$(jq -r '.xray.fallback // "NONE"' "$SB/t8a.json")" 'uuid-from-gen'
assert_eq "T8a5 sni 写 xray.target" "$(jq -r '.xray.target' "$SB/t8a.json")" 'sni.example.com'

CD_VARS='tag=sni target=sni.example.com email=new@example.com' run_sc "$SB/t8b.log" "$SB/t8b.json" "$SB/t8b.gen"
assert_eq "T8b1 邮箱非空 -> 覆盖 nginx.ca" "$(jq -r '.nginx.ca' "$SB/t8b.json")" 'new@example.com'

echo "== T8c xhttp / fallback =="
CD_VARS='tag=fallback fallback=FB-UUID' run_sc "$SB/t8c.log" "$SB/t8c.json" "$SB/t8c.gen"
assert_eq "T8c1 fallback 写 uuid + fallback" "$(jq -r '[.xray.uuid,.xray.fallback]|join(",")' "$SB/t8c.json")" 'uuid-from-gen,FB-UUID'
assert_eq "T8c2 fallback 有 path" "$(jq -r '.xray.path' "$SB/t8c.json")" '/genpath'

# ---------------------------------------------------------------------------
# T9-T11: x25519 —— 三段解析 + 私钥不回显
# ---------------------------------------------------------------------------
run_x() {
    local plog="$1"
    local cfgout="$2"
    local outlog="$3"
    : >"$plog"
    rm -f "$cfgout"
    : >"$outlog"

    # shellcheck disable=SC2034
    GREEN=$'\033[32m'
    # shellcheck disable=SC2034
    YELLOW=$'\033[33m'
    # shellcheck disable=SC2034
    NC=$'\033[0m'
    # shellcheck disable=SC2034
    CUR_FILE='handler'
    SCRIPT_CONFIG="$SC_BASE"

    _i18n() { printf '%s' "${1#.}"; }
    is_enabled() {
        case "${1:-}" in 1 | true | yes | y | on) return 0 ;; *) return 1 ;; esac
    }
    exec_generate() {
        printf 'GEN:%s\n' "$*" >>"${plog}.gen"
        case "${1:-}" in
        '--x25519') printf '%s' "${GEN_X25519:-PRIV_FROM_GEN,PUB_FROM_GEN,HASH_FROM_GEN}" ;;
        *) printf '%s' "gen-${1:-}" ;;
        esac
    }
    persist_script_config() {
        printf 'PERSIST\n' >>"$plog"
        printf '%s' "${SCRIPT_CONFIG}" >"$cfgout"
    }

    eval "$x_fn"
    handler_x25519_config >"$outlog" 2>&1
    return 0
}

echo "== T9 三段解析 =="
GEN_X25519='SECRETPRIVKEY,PUBKEYVALUE,HASH32VALUE' run_x "$SB/t9.log" "$SB/t9.json" "$SB/t9.out"
assert_eq "T9a privateKey" "$(jq -r '.xray.privateKey' "$SB/t9.json")" 'SECRETPRIVKEY'
assert_eq "T9b publicKey" "$(jq -r '.xray.publicKey' "$SB/t9.json")" 'PUBKEYVALUE'
assert_eq "T9c hash32" "$(jq -r '.xray.hash32' "$SB/t9.json")" 'HASH32VALUE'
assert_eq "T9d persist 恰好一次" "$(count_lines '^PERSIST$' "$SB/t9.log")" '1'

echo "== T10 私钥默认不回显 (安全核心) =="
out="$(cat "$SB/t9.out")"
assert_not_contains "T10a 默认输出不得含明文私钥" "$out" 'SECRETPRIVKEY'
assert_contains "T10b 给出隐藏提示而非留白" "$out" 'private_key_hidden'
assert_contains "T10c 公钥必回显 (客户端需要)" "$out" 'PUBKEYVALUE'
assert_contains "T10d hash32 必回显" "$out" 'HASH32VALUE'
assert_contains "T10e Private Key 行仍在 (只是值被隐藏)" "$out" 'Private Key'

echo "== T11 SHOW_PRIVATE_KEY=1 才回显 =="
SHOW_PRIVATE_KEY=1 GEN_X25519='SECRETPRIVKEY,PUBKEYVALUE,HASH32VALUE' run_x "$SB/t11.log" "$SB/t11.json" "$SB/t11.out"
out="$(cat "$SB/t11.out")"
assert_contains "T11a 显式开启后回显明文私钥" "$out" 'SECRETPRIVKEY'
assert_not_contains "T11b 开启后不再打隐藏提示" "$out" 'private_key_hidden'
SHOW_PRIVATE_KEY=0 GEN_X25519='SECRETPRIVKEY,PUBKEYVALUE,HASH32VALUE' run_x "$SB/t11b.log" "$SB/t11b.json" "$SB/t11b.out"
assert_not_contains "T11c SHOW_PRIVATE_KEY=0 仍不回显" "$(cat "$SB/t11b.out")" 'SECRETPRIVKEY'

# ---------------------------------------------------------------------------
# 负向校验: 把源码副本改坏, 确认断言真的会变红 (不是恒绿)
# 改坏前先确认副本与原件确有差异 —— replace 打偏会让"被测一字未动"伪装成通过。
# ---------------------------------------------------------------------------
# 注: NEG 副本由 sed 自本文件生成, 它内部同样带着这段 NEG —— 若不设 SKIP_NEG,
#     副本跑到这段会再生成一份副本并执行, 无限套娃 (实测: 卡到进程被 KILL 都没有输出)。
#     因此由发起方用 SKIP_NEG=1 拉起副本, 只让它跑主体、不让它再发起负向校验。
if [[ "${SKIP_NEG:-0}" == '1' ]]; then
    echo "== NEG 段已跳过 (副本被拉起) =="
    rm -rf "$SB"
    echo "---"
    echo "==== handler_script_config_arm_test: PASS=$PASS FAIL=$FAIL ===="
    [[ "$FAIL" == '0' ]]
    exit
fi

echo "== NEG 负向校验 =="
neg_run() { # $1=说明 $2=期望<all-pass|has-fail>
    local label="$1"
    local want="$2"
    local out
    out="$(cd "$REPO" && SKIP_NEG=1 bash "test/neg_tmp_sc_arm_test.sh" 2>&1 || true)"
    local n
    n="$(printf '%s\n' "$out" | grep -c '\[FAIL\]' || true)"
    if [[ "$want" == 'all-pass' ]]; then
        [[ "$n" == '0' ]] && ok || bad "NEG $label 基线应全绿, 实际 $n 条 FAIL"
    else
        [[ "$n" != '0' ]] && ok || bad "NEG $label 应检出失败, 实际 0 条 (断言恒绿!)"
    fi
}

# 逐块改写核心/handler.sh 副本 + 生成测试副本
gen_neg() { # $1=python 改写表达式
    python3 - "$1" <<'PY'
import sys, pathlib
src = pathlib.Path('core/handler.sh').read_text()
mode = sys.argv[1]
s = src
if mode == 'no_reset':
    s = s.replace("    handler_reset_script_config\n    # 从 CONFIG_DATA 或生成器获取配置值",
                  "    # 从 CONFIG_DATA 或生成器获取配置值", 1)
elif mode == 'mkcp_port_from_input':
    s = s.replace("""        XRAY_PORT="$(exec_generate '--port')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg seed "${KCP_SEED}" '.xray.kcp = $seed')"
""", """        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg seed "${KCP_SEED}" '.xray.kcp = $seed')"
""", 1)
elif mode == 'port_as_string':
    s = s.replace("""jq --argjson port "${XRAY_PORT}" '.xray.port = $port'""",
                  """jq --arg port "${XRAY_PORT}" '.xray.port = $port'""", 1)
elif mode == 'no_lower_rules':
    # 只摘掉 block-bt 一行的 ${var,,} —— 对应 T2b2 (输入大写 N): 失去小写化后
    # "N" != "n" 成立, bt 会被写成 1, 断言应立刻变红。
    s = s.replace("""jq --arg bt "${XRAY_RULES_BT,,}" ' if $bt != "n" then .xray.rules.bt = 1 else .xray.rules.bt = 0 end '""",
                  """jq --arg bt "${XRAY_RULES_BT}" ' if $bt != "n" then .xray.rules.bt = 1 else .xray.rules.bt = 0 end '""", 1)
elif mode == 'ca_no_guard':
    s = s.replace("""[[ -n "${CA_EMAIL}" ]] && SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg ca "${CA_EMAIL}" '.nginx.ca = $ca')\"""",
                  """SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg ca "${CA_EMAIL}" '.nginx.ca = $ca')\"""", 1)
elif mode == 'echo_private_key':
    s = s.replace("""    if is_enabled "${SHOW_PRIVATE_KEY:-0}"; then
        echo -e "${GREEN}[Private Key]${NC} ${PRIVATE_KEY}" >&2
    else
        echo -e "${YELLOW}[Private Key]${NC} $(_i18n ".${CUR_FILE}.script.private_key_hidden")" >&2
    fi""", """    echo -e "${GREEN}[Private Key]${NC} ${PRIVATE_KEY}" >&2""", 1)
else:
    raise SystemExit('unknown mode: ' + mode)
if s == src:
    raise SystemExit('改写未生效 (原文未命中): ' + mode)
tmp = pathlib.Path('core/_neg_handler.sh')
tmp.write_text(s)
PY
    sed 's#core/handler.sh#core/_neg_handler.sh#g' test/handler_script_config_arm_test.sh >test/neg_tmp_sc_arm_test.sh
}

gen_neg_ok=1
gen_neg 'no_reset' || gen_neg_ok=0
if [[ "$gen_neg_ok" == '1' ]]; then neg_run "去掉 reset 调用" 'has-fail'; else bad "NEG 改写未生效: no_reset"; fi

gen_neg 'mkcp_port_from_input' && neg_run "mkcp 端口改用用户输入" 'has-fail' || bad "NEG 改写未生效: mkcp_port_from_input"
gen_neg 'port_as_string' && neg_run "端口写成 JSON string" 'has-fail' || bad "NEG 改写未生效: port_as_string"
gen_neg 'no_lower_rules' && neg_run "rules 判等去掉小写化" 'has-fail' || bad "NEG 改写未生效: no_lower_rules"
gen_neg 'ca_no_guard' && neg_run "nginx.ca 去掉非空守卫" 'has-fail' || bad "NEG 改写未生效: ca_no_guard"
gen_neg 'echo_private_key' && neg_run "私钥默认回显" 'has-fail' || bad "NEG 改写未生效: echo_private_key"

rm -f core/_neg_handler.sh test/neg_tmp_sc_arm_test.sh
rm -rf "$SB"

echo "---"
echo "==== handler_script_config_arm_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" == '0' ]]
