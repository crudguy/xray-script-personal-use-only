#!/usr/bin/env bash
# =============================================================================
# 测试名称: share_common_config_test.sh
# 测试目标: core/share.sh 的 get_common_config —— 入站字段抽取的正确性与 fork 成本。
#
# 为什么需要本测试:
#   "生成分享链接/订阅很慢"的本地部分, 大头是 fork: 原实现为取 13 个字段各跑一次
#   `echo "$JSON" | jq` (外加两次 `bash generate.sh --random` 取随机数), 而订阅按入站
#   逐个调本函数 —— 5 节点的 SNI 配置就是 200+ 次 jq。合并成"一次 jq 取完"之后,
#   正确性完全押在**分隔符**上, 这是本次重构唯一可能出错的地方:
#
#   [1] 分隔符不能用 tab。tab 属于 IFS 的空白字符, `read` 会把连续 tab 合并 ——
#       一旦中间某个字段为空 (缺 realitySettings、缺 clients 都是常态), 后面的字段
#       会整体左移串位: seed 跑到 type 上、path 跑到 server_name 上。这类错不会报错,
#       只会生成一条**看起来正常但实际连不上**的分享链接, 属于最难排查的那类故障。
#       故用 \x1f (Unit Separator, 非 IFS 空白), 空字段原样保留。
#   [2] 合并不能改变取值语义: 原 jq 用 `if . == null then empty` 取空串, 合并后用
#       `// ""`; 端口等数字字段走 `tostring` 后才 join (jq 的 join 不接受非字符串)。
#   [3] Reality 的两个数组原本写 `.[$random % length]`: 数组为空时 length 为 0,
#       jq 里 % 0 是错误, 整条 jq 以非 0 退出 —— 在 set -e 下会打断整次订阅生成。
#       合并后加了长度守卫, 本用例专门盯这条 (empty 数组 -> 空串且不崩)。
#
# 锁定不变量:
#   T1  完整配置: 各字段取到正确值
#   T2  缺 realitySettings: server_name/short_id 为空, 且**后续字段不串位**
#   T3  缺 clients: uuid/password/flow 为空, 其余字段仍各就各位
#   T4  mKCP seed 三种历史写法都能取到 (finalmask-aes128gcm / legacy / 旧 kcpSettings.seed)
#   T5  端口为数字时取值正确 (tostring 后不被截断)
#   T6  Reality 数组为空 -> 空串且不崩 (原写法在此处除零)
#   T7  fork 成本: 一次调用只 fork 2 次 jq (原为 15 次)
#   T8  (NEG) 分隔符换回 tab -> 空字段串位, 上面的断言必须变红
#
# 依赖: bash, jq, awk
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
# 调用约定与全仓一致: assert_eq <标签> <实际> <期望> ($2=got $3=expected)。
#   反着写也能跑, 但与其余 18 个用例的约定相反, 跨文件复制断言时必踩;
#   且失败信息的"期望/实际"标注必须与之对应, 标反了排查方向会被带偏 (此处踩过)。
assert_eq() { # $1=msg $2=got $3=expected
    if [[ "$2" == "$3" ]]; then ok; else bad "$1 (期望 [$3] 实际 [$2])"; fi
}
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1 (未包含 [$3]，实际 [$2])"; fi; }
# stderr 必须干净: jq 的 parse error 不写 stdout、也不改退出码, 只看断言会漏掉
# (见 DEFAULT_SCRIPT_CONFIG 处的踩坑记录)。
assert_err_clean() {
    local e=''
    [[ -f "$SB/err" ]] && e="$(cat "$SB/err")"
    if [[ -z "${e}" ]]; then ok; else bad "$1 被测 stderr 应为空 (实际 [${e}])"; fi
}

SB=".workbuddy/tmp/scc.$$"
rm -rf "$SB"
mkdir -p "$SB/bin"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

# jq 计数桩: 转发给真 jq, 同时记一笔 (用于 T7 的 fork 成本断言)
cat >"$SB/bin/jq" <<SHIM
#!/usr/bin/env bash
printf 'jq\n' >>"$PWD/$SB/jq.log"
exec /usr/bin/jq "\$@"
SHIM
chmod +x "$SB/bin/jq"

extract_fn() { awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' "$1"; }

FN_SRC="${SHARE_GCC_SRC:-core/share.sh}"
fn="$(extract_fn "${FN_SRC}" get_common_config)"
if [[ -z "${fn}" ]]; then
    echo "SKIP: 未抽到 get_common_config (源码结构变了?)"
    exit 0
fi

# 默认脚本配置: 刻意用单引号整串常量, 不内联进 `${var:-...}`。
#   实测踩坑: 写成 `${GCC_SCRIPT_CONFIG:-{\"xray\":{...}}}` 时, bash 扫参数展开的
#   结束 `}` 会停在默认值内部的第一个 `}` 上 —— 变量**未设置**时恰好正确 (剩下的 `}`
#   当字面量补回来), 变量**已设置**时却变成 "<值>}}" (多出两个 `}`)。
#   更阴的是 jq 对尾部多余字符宽容: 打印 parse error 但仍输出第一个合法值且退出 0,
#   于是断言照样全绿、只在 stderr 留一行噪声 —— 换个严格的 jq 就会直接翻车。
#   故: 默认值外提; 且每条用例都断言 stderr 干净 (见 assert_err_clean)。
DEFAULT_SCRIPT_CONFIG='{"xray":{"port":443,"publicKey":"pk","tag":"vision"}}'

# 驱动: 装配桩件后跑目标函数, 打印全部字段便于断言
#   stdin: XRAY_CONFIG  JSON; $1: inbound 索引; stderr 落在 $SB/err 供后置断言
run_gcc() {
    local xray_cfg script_cfg idx
    xray_cfg="$(cat)"
    script_cfg="${GCC_SCRIPT_CONFIG:-${DEFAULT_SCRIPT_CONFIG}}"
    idx="${1:-0}"
    (
        declare -A CLIENT_CONFIG
        # 这两个是喂给下面 eval 注入的真实函数的状态变量, shellcheck 看不到那层引用
        # shellcheck disable=SC2034
        XRAY_CONFIG="${xray_cfg}"
        # shellcheck disable=SC2034
        SCRIPT_CONFIG="${script_cfg}"
        # 公网探测不在本用例范围内 (由 ip_resolve_test 覆盖), 桩掉以求确定与快速
        _resolve_public_ips() { :; }
        _preferred_remote_host() { printf '203.0.113.9'; }
        eval "$fn"
        get_common_config "${idx}"
        local k
        for k in protocol uuid password seed type flow security path server_name short_id inbound_tag port public_key tag remote_host; do
            printf '%s=[%s]\n' "${k}" "${CLIENT_CONFIG[${k}]:-}"
        done
    )
}

field() { # field <输出> <字段名> -> 值 (去掉首尾方括号; 纯 bash, 不依赖 sed)
    local line v
    while IFS= read -r line; do
        case "${line}" in
        "$2="*)
            v="${line#"$2"=}"
            v="${v#\[}"
            printf '%s' "${v%\]}"
            return 0
            ;;
        esac
    done <<<"$1"
}

echo "=== share.sh get_common_config 字段抽取测试 ==="

# --- T1 完整配置 ---
full='{"inbounds":[{"tag":"in-0","protocol":"vless","settings":{"clients":[{"id":"uuid-1","flow":"xtls-rprx-vision"}]},"streamSettings":{"network":"tcp","security":"reality","xhttpSettings":{"path":"/vp"},"realitySettings":{"serverNames":["www.microsoft.com"],"shortIds":["0a"]}}}]}'
out="$(printf '%s' "$full" | run_gcc 0 2>"$SB/err")"
assert_err_clean "T1"
assert_eq "T1 protocol" "$(field "$out" protocol)" "vless"
assert_eq "T1 uuid" "$(field "$out" uuid)" "uuid-1"
assert_eq "T1 flow" "$(field "$out" flow)" "xtls-rprx-vision"
assert_eq "T1 type" "$(field "$out" type)" "tcp"
assert_eq "T1 security" "$(field "$out" security)" "reality"
assert_eq "T1 path" "$(field "$out" path)" "/vp"
assert_eq "T1 server_name" "$(field "$out" server_name)" "www.microsoft.com"
assert_eq "T1 short_id" "$(field "$out" short_id)" "0a"
assert_eq "T1 inbound_tag" "$(field "$out" inbound_tag)" "in-0"
assert_eq "T1 port (数字字段经 tostring)" "$(field "$out" port)" "443"
assert_eq "T1 public_key" "$(field "$out" public_key)" "pk"

# --- T2 缺 realitySettings: 空字段不得让后面的字段串位 ---
noreality='{"inbounds":[{"tag":"in-1","protocol":"vless","settings":{"clients":[{"id":"uuid-2","flow":"xtls-rprx-vision"}]},"streamSettings":{"network":"tcp","security":"tls","xhttpSettings":{"path":"/vp2"}}}]}'
out="$(printf '%s' "$noreality" | run_gcc 0 2>"$SB/err")"
assert_err_clean "T2"
assert_eq "T2 server_name 为空" "$(field "$out" server_name)" ""
assert_eq "T2 short_id 为空" "$(field "$out" short_id)" ""
assert_eq "T2 path 未串位" "$(field "$out" path)" "/vp2"
assert_eq "T2 inbound_tag 未串位" "$(field "$out" inbound_tag)" "in-1"
assert_eq "T2 uuid 未串位" "$(field "$out" uuid)" "uuid-2"

# --- T3 缺 clients: 中间三个字段为空, 其余不动 ---
noclient='{"inbounds":[{"tag":"in-2","protocol":"trojan","streamSettings":{"network":"tcp","security":"tls","xhttpSettings":{"path":"/tj"}}}]}'
out="$(printf '%s' "$noclient" | run_gcc 0 2>"$SB/err")"
assert_err_clean "T3"
assert_eq "T3 uuid 为空" "$(field "$out" uuid)" ""
assert_eq "T3 password 为空" "$(field "$out" password)" ""
assert_eq "T3 flow 为空" "$(field "$out" flow)" ""
assert_eq "T3 protocol 未串位" "$(field "$out" protocol)" "trojan"
assert_eq "T3 path 未串位" "$(field "$out" path)" "/tj"
assert_eq "T3 inbound_tag 未串位" "$(field "$out" inbound_tag)" "in-2"

# --- T4 mKCP seed 的三种历史写法 ---
# 三段配置直接写全 (不再用嵌套 jq 拼): 拼装一旦出问题, 报的是 jq 解析错而非断言失败,
# 排查方向会被带偏 (实测踩到: 拼错时错误出现在别处, 用例却仍"全绿")。
# 用关联数组而非三个标量 + ${!var} 间接展开: 后者 shellcheck 看不到引用, 每个变量都
#   得挂一条 disable, 三条注释比数据本身还长 (且 disable 只管紧跟的那一行, 漏一个就红)。
declare -A T4_CFG=(
    [aes]='{"inbounds":[{"tag":"mk","protocol":"vless","streamSettings":{"network":"kcp","security":"none","finalmask":{"udp":[{"type":"mkcp-aes128gcm","settings":{"password":"pw-aes"}}]}}}]}'
    [legacy]='{"inbounds":[{"tag":"mk","protocol":"vless","streamSettings":{"network":"kcp","security":"none","finalmask":{"udp":[{"type":"mkcp-legacy","settings":{"value":"val-legacy"}}]}}}]}'
    [old]='{"inbounds":[{"tag":"mk","protocol":"vless","streamSettings":{"network":"kcp","security":"none","kcpSettings":{"seed":"seed-old"}}}]}'
)
for spec in 'aes:pw-aes' 'legacy:val-legacy' 'old:seed-old'; do
    var="${spec%%:*}"
    want="${spec#*:}"
    out="$(printf '%s' "${T4_CFG[${var}]}" | run_gcc 0 2>"$SB/err")"
    assert_err_clean "T4(${var})"
    assert_eq "T4 mKCP seed (${var})" "$(field "$out" seed)" "${want}"
done

# --- T5 port 为其它数字 / 脚本配置缺字段 ---
cfg5='{"xray":{"port":8443,"publicKey":"","tag":"sni"}}'
out="$(printf '%s' "$full" | GCC_SCRIPT_CONFIG="$cfg5" run_gcc 0 2>"$SB/err")"
assert_err_clean "T5"
assert_eq "T5 port 8443" "$(field "$out" port)" "8443"
assert_eq "T5 public_key 空" "$(field "$out" public_key)" ""
assert_eq "T5 tag 仍取到" "$(field "$out" tag)" "sni"

# --- T6 Reality 数组为空: 不得崩 (原写法 % 0 会让 jq 非 0 退出) ---
emptyrv='{"inbounds":[{"tag":"in-3","protocol":"vless","settings":{"clients":[{"id":"uuid-3"}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverNames":[],"shortIds":[]}}}]}'
out="$(printf '%s' "$emptyrv" | run_gcc 0 2>"$SB/err")"
assert_err_clean "T6"
assert_eq "T6 空数组 -> server_name 空串且不崩" "$(field "$out" server_name)" ""
assert_eq "T6 空数组 -> short_id 空串且不崩" "$(field "$out" short_id)" ""
assert_eq "T6 后续字段仍正确" "$(field "$out" inbound_tag)" "in-3"

# --- T7 fork 成本: 一次调用只 fork 2 次 jq ---
: >"$SB/jq.log"
PATH="$PWD/$SB/bin:$PATH" run_gcc 0 >/dev/null <<<"$full"
assert_eq "T7 单次调用 jq fork 数 (原为 15)" "$(grep -c 'jq' "$SB/jq.log" || true)" "2"

# --- T8 (NEG) 分隔符换回 tab: 空字段串位, 上面断言必须变红 ---
if [[ -z "${SKIP_NEG:-}" ]]; then
    python3 - <<'PY'
import pathlib

src = pathlib.Path('core/share.sh').read_text()
start = src.index('function get_common_config() {')
end = src.index('\n}\n', start) + 3
body = src[start:end]
if '\\u001f' not in body:
    raise SystemExit('未找到 \\u001f 分隔符 (源码结构变了?)')
neg_body = body.replace('\\u001f', '\\t').replace("IFS=$'\\x1f'", "IFS=$'\\t'")
if neg_body == body:
    raise SystemExit('NEG 改写未生效')
if '\\u001f' in neg_body:
    raise SystemExit('NEG 改写不彻底')
pathlib.Path('.workbuddy/tmp/scc_neg.sh').write_text(src[:start] + neg_body + src[end:])
PY
    neg_out="$(SHARE_GCC_SRC=".workbuddy/tmp/scc_neg.sh" SKIP_NEG=1 bash test/share_common_config_test.sh 2>&1 || true)"
    n_bad="$(printf '%s\n' "${neg_out}" | grep -c '\[FAIL\]' || true)"
    if [[ "${n_bad}" != '0' ]]; then
        ok "T8(NEG) 分隔符换成 tab 后断言变红 (${n_bad} 条)"
    else
        bad "T8(NEG) 换成 tab 后仍全绿 —— 断言对空字段串位无感!"
    fi
    rm -f .workbuddy/tmp/scc_neg.sh
fi

echo "---"
echo "==== share_common_config_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" == '0' ]]
