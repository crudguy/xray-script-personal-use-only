#!/usr/bin/env bash
# =============================================================================
# 测试名称: warp_wireguard_test.sh
# 测试目标: 锁定 WARP 出站从「Docker 容器 + socks 转发」改为「原生 wireguard 出站」
#           之后的凭据链路与开关语义。
#
# 背景:
#   原实现要装 Docker、拉 cloudflare-warp 容器, Xray 再用 socks 出站指向容器的 40001。
#   现改为一次性注册拿 WireGuard 凭据 -> 落 warp.json 复用 -> 出站直接写 wireguard。
#   链路里有两个"外部世界说了算"的点, 必须在本测试里用桩钉死:
#     1) 密钥的 base64 编码变体 (标准/raw/url-safe) —— Xray 认哪一种不写死, 靠本机实测;
#     2) WARP 注册端点 —— 部分机房 IP 段会被直接回 500, 此时绝不能让状态位变成"已启用"
#        (否则路由规则指向不存在的出站, xray 拒绝加载整份配置)。
#
# 锁定:
#   T1  reserved 从 client_id 解出 3 字节 (含缺 padding / 非法输入的回退);
#   T2  _warp_outbound_json 的字段形状 (tag/protocol/peers/reserved/mtu);
#   T3  密钥生成优先走 xray wg (自产自销, 不做编码试错);
#   T4  无 xray wg 时退回 openssl, 并按本机实测选中能被 xray 接受的编码变体;
#   T5  三种变体全被拒 -> 失败 (不返回半截密钥);
#   T6  xray 缺失 -> 失败且给出提示;
#   T7  注册成功 -> 落一份完整凭据 (地址带 /32、/128 前缀, reserved 已解出);
#   T8  注册被端点拒绝 (500) / 响应缺字段 -> 失败, 不产出凭据;
#   T9  已有合法 warp.json -> 复用, **不再联网**;
#   T10 半截 warp.json -> 不复用, 重新走注册;
#   T11 _xray_apply_warp: 未启用零操作 / 启用追加 / 重复应用幂等;
#   T12 handler_warp 关闭: 出站与规则的**两处副本**一起清 (Xray 配置 + SCRIPT_CONFIG.rules);
#   T13 handler_warp 开启: 写出 wireguard 出站且状态位置 1;
#   T14 handler_warp 注册失败: 返回非 0, 且**一个字节都不落盘** (断言"没写盘"比"写对了"更值钱);
#   T15 handler_warp 落盘顺序: 先 Xray 配置、后脚本状态位 (失败时状态位不能先翻);
#   T16 (NEG) 去掉 .rules 的同步清理后, 关闭 WARP 会残留指向 warp 的规则 -> 证明该清理非虚设。
#
# 运行: bash test/warp_wireguard_test.sh
# =============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available in this environment"
    exit 0
fi

PASS=0; FAIL=0
assert_eq() { # $1=msg $2=got $3=expected
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $1 (got '$2' want '$3')"; fi
}
assert_ne() { # $1=msg $2=got $3=unexpected
    if [[ "$2" != "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $1 (got '$2' should not be '$3')"; fi
}
assert_contains() { # $1=msg $2=haystack $3=needle
    if [[ "$2" == *"$3"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $1 (missing '$3')"; fi
}

HANDLER="${WARP_HANDLER:-core/handler.sh}"
COMMON="core/_common.sh"

SB=".workbuddy/tmp/warp_wg_$$"
rm -rf "$SB"; mkdir -p "$SB/bin" "$SB/cfg"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

export PATH="$SB/bin:$PATH"
export SCRIPT_NAME='xray-script-personal-use-only'
export SCRIPT_CONFIG_DIR="$SB/cfg"
export TMPFILE_DIR="$SB"

# ---- 桩 xray: wg 子命令 + run -test 的编码判定 ----
# run -test 的判定锚在注入配置里的 secretKey 上:
# 桩 openssl 产出的私钥是 32 个 0xFF, base64 后全为 '/', 三种变体因此可区分:
#   std     -> 含 '='          raw -> 不含 '=' 也不含 '_'      urlsafe -> 含 '_'
cat > "$SB/bin/xray" <<'STUB_XRAY'
#!/usr/bin/env bash
if [[ "${1:-}" == 'wg' ]]; then
    if [[ "${STUB_WG_OK:-0}" == '1' ]]; then
        printf 'PrivateKey: %s\n' "${STUB_WG_PRIV:-}"
        printf 'PublicKey: %s\n' "${STUB_WG_PUB:-}"
        exit 0
    fi
    exit 1
fi
if [[ "${1:-}" == 'run' ]]; then
    cfg=''; prev=''
    for a in "$@"; do
        [[ "$prev" == '-config' ]] && cfg="$a"
        prev="$a"
    done
    [[ -n "$cfg" && -f "$cfg" ]] || exit 0
    if [[ "${STUB_REJECT_ALL:-0}" == '1' ]]; then
        echo 'invalid wireguard key' >&2
        exit 23
    fi
    sk="$(jq -r '.outbounds[0].settings.secretKey // empty' "$cfg" 2>/dev/null)"
    case "${STUB_ACCEPT_VARIANT:-std}" in
        std)     [[ "$sk" == *'='* ]] && exit 0 ;;
        raw)     [[ "$sk" != *'='* && "$sk" != *'_'* ]] && exit 0 ;;
        urlsafe) [[ "$sk" == *'_'* ]] && exit 0 ;;
    esac
    echo 'invalid wireguard key' >&2
    exit 23
fi
exit 0
STUB_XRAY

# ---- 桩 openssl: X25519 导出, 尾部 32 字节固定为 0xFF ----
cat > "$SB/bin/openssl" <<'STUB_OPENSSL'
#!/usr/bin/env bash
case "$*" in
    *genpkey*)
        out=''; prev=''
        for a in "$@"; do
            [[ "$prev" == '-out' ]] && out="$a"
            prev="$a"
        done
        [[ -n "$out" ]] || exit 1
        printf 'STUB-PEM\n' > "$out"
        ;;
    *-pubout*)
        printf '\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff'
        ;;
    *)
        printf '\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff'
        ;;
esac
exit 0
STUB_OPENSSL
chmod +x "$SB/bin/xray" "$SB/bin/openssl"

# ---- 桩 curl: 从 STUB_API_BODY 读响应体, 从 STUB_API_CODE 读状态码 ----
CURL_LOG="$SB/curl.log"
: > "$CURL_LOG"
curl() {
    printf '%s\n' "$*" >> "$CURL_LOG"
    [[ -n "${STUB_API_BODY:-}" ]] && printf '%s' "$STUB_API_BODY"
    printf '\n%s' "${STUB_API_CODE:-200}"
    return 0
}

# ---- 从产品代码抽真实实现 (不另写一份, 避免与产品漂移) ----
extract() { # $1=函数名 $2=文件
    awk -v fn="$1" '$0 ~ "^function " fn "\\(\\) \\{" {f=1} f{print} f && /^}$/ {exit}' "$2"
}
for fn in _xray_bin_path _warp_key_probe _warp_gen_keypair _warp_reserved_from_client_id \
          _warp_register _warp_ensure_credentials _warp_forget_credentials _warp_outbound_json \
          _xray_apply_warp handler_warp \
          _xray_config_probe _xray_observatory_mode _warp_outbound_tag _xray_apply_warp_balancer; do
    body="$(extract "$fn" "$HANDLER")"
    if [[ -z "$body" ]]; then
        echo "  [FAIL] 抽取产品函数失败: $fn"
        FAIL=$((FAIL+1))
    fi
    eval "$body"
done
eval "$(extract is_enabled "$COMMON")"
eval "$(extract cmd_exists "$COMMON")"
eval "$(extract _atomic_write "$COMMON")"
# 常量与产品同源 (只取 WARP_ 前缀那几个)。经临时文件中转而不用进程替换: 沙箱/CI
# 未必有 /dev/fd, 进程替换会静默失效 (表现为常量全空 -> 断言"假绿")
grep -E '^readonly WARP_' "$HANDLER" > "$SB/consts.sh"
while IFS= read -r line; do eval "$line"; done < "$SB/consts.sh"
# 健康探测/均衡的降级形态 (出站 tag 保持 warp) 在本测试里一律生效 —— 让 T11/T13 这些
# "出站 tag 是 warp" 的断言继续锚在降级语义上。"开探测"的 full 形态由
# test/xray_router_extras_test.sh 覆盖。两个变量在产品里由 handler.sh 顶层赋值,
# 这里只抽了函数体, 所以必须显式声明 (set -u 下不声明会 nounset)。
_XRAY_OBS_MODE='plain'
_WARP_OB_TAG=''
# WARP_STATUS 由被测产品函数经 bash 动态作用域读取 (shellcheck 静态看不到), 先 export
# 声明, 否则下面 T11 的裸赋值会被报 SC2034 (未使用变量)。
export WARP_STATUS=''
# 注: 不再对 WARP_CREDENTIALS_PATH 重复赋值 —— 产品里它是 readonly, 且取值就是
#     ${SCRIPT_CONFIG_DIR}/warp.json, 而 SCRIPT_CONFIG_DIR 已指向本测试沙箱

# ---- 其余桩件 ----
_i18n() { printf '%s' "${1//\"/}"; }
_i18n_sub() { printf '%s|%s=%s' "${1//\"/}" "$2" "$3"; }
print_info() { :; }
print_warn() { printf '%s\n' "$*" >&2; }
print_error() { printf '%s\n' "$*" >&2; exit 1; }
PERSIST_LOG="$SB/persist.log"
XRAY_WRITTEN="$SB/cfg/xray-written.json"
SCRIPT_WRITTEN="$SB/cfg/script-written.json"
: > "$PERSIST_LOG"
persist_xray_config() {
    printf 'xray\n' >> "$PERSIST_LOG"
    printf '%s\n' "${XRAY_CONFIG}" > "$XRAY_WRITTEN"
    return "${STUB_PERSIST_XRAY_RC:-0}"
}
persist_script_config() {
    printf 'script\n' >> "$PERSIST_LOG"
    printf '%s\n' "${SCRIPT_CONFIG}" > "$SCRIPT_WRITTEN"
    return 0
}

# 期望的密钥取值 (与桩 openssl 的 32 字节 0xFF 对应)
RAW_KEY="$(printf '\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff' | base64 -w0)"

echo "== T1  reserved 解析 =="
got="$(_warp_reserved_from_client_id "$(printf '\x01\x02\x03' | base64 -w0)")"
assert_eq "T1a 前三字节" "$got" "1 2 3"
got="$(_warp_reserved_from_client_id '')"
assert_eq "T1b 空输入回退 0 0 0" "$got" "0 0 0"
got="$(_warp_reserved_from_client_id '!!!not-base64!!!')"
assert_eq "T1c 非法输入回退 0 0 0" "$got" "0 0 0"
# 缺 padding: 24 字节 client_id 的 base64 无 '=' 结尾
cid_raw="$(printf '\x0a\x14\x1e\x28\x32\x3c\x46\x50\x5a\x64\x6e\x78\x82\x8c\x96\xa0\xaa\xb4\xbe\xc8\xd2\xdc\xe6\xf0' | base64 -w0)"
cid_nopad="${cid_raw%=*}"
got="$(_warp_reserved_from_client_id "$cid_nopad")"
assert_eq "T1d 缺 padding 仍能解出" "$got" "10 20 30"

echo "== T2  出站字段形状 =="
CREDS='{"private_key":"PRIV","public_key":"PUB","address":["172.16.0.2/32","2606:4700:110::1/128"],"peer_public_key":"PEER","endpoint":"162.159.192.1:2408","reserved":[1,2,3]}'
ob="$(_warp_outbound_json "$CREDS")"
assert_eq "T2a tag" "$(printf '%s' "$ob" | jq -r '.tag')" "warp"
assert_eq "T2b protocol" "$(printf '%s' "$ob" | jq -r '.protocol')" "wireguard"
assert_eq "T2c secretKey" "$(printf '%s' "$ob" | jq -r '.settings.secretKey')" "PRIV"
assert_eq "T2d address 条数" "$(printf '%s' "$ob" | jq -r '.settings.address | length')" "2"
assert_eq "T2e peer publicKey" "$(printf '%s' "$ob" | jq -r '.settings.peers[0].publicKey')" "PEER"
assert_eq "T2f endpoint" "$(printf '%s' "$ob" | jq -r '.settings.peers[0].endpoint')" "162.159.192.1:2408"
assert_eq "T2g reserved" "$(printf '%s' "$ob" | jq -c '.settings.reserved')" "[1,2,3]"
assert_eq "T2h mtu" "$(printf '%s' "$ob" | jq -r '.settings.mtu')" "1280"
assert_eq "T2i allowedIPs" "$(printf '%s' "$ob" | jq -c '.settings.peers[0].allowedIPs')" '["0.0.0.0/0","::/0"]'
assert_eq "T2j keepAlive" "$(printf '%s' "$ob" | jq -r '.settings.peers[0].keepAlive')" "25"
_warp_outbound_json '' >/dev/null 2>&1
assert_ne "T2k 空凭据失败" "$?" "0"

echo "== T3  密钥生成: 优先 xray wg =="
# 注: 桩件开关一律 export —— "VAR=x got=$(...)" 的前缀赋值只对**当前 shell** 生效,
#     传不进命令替换里 fork 出来的外部进程 (桩 xray 是脚本, 不是 shell 函数)。
#     本测试首版即栽在这里: 桩读不到开关就静默走错分支, 且失败表现是"结果不对",
#     不是"报错", 极易误判成产品逻辑有 bug。
export STUB_WG_OK=1 STUB_WG_PRIV='WGPRIV' STUB_WG_PUB='WGPUB'
got="$(_warp_gen_keypair)"
assert_eq "T3a 原样采用 xray wg 输出" "$got" "WGPRIV WGPUB"

echo "== T4  密钥生成: 退回 openssl + 实测编码 =="
export STUB_WG_OK=0
RAW_NOPAD="${RAW_KEY%=*}"
RAW_URLSAFE="$(printf '%s' "$RAW_NOPAD" | tr '/' '_')"
export STUB_ACCEPT_VARIANT='raw'
got="$(_warp_gen_keypair)"
assert_eq "T4a 选中 raw 变体" "$got" "${RAW_NOPAD} ${RAW_NOPAD}"
export STUB_ACCEPT_VARIANT='urlsafe'
got="$(_warp_gen_keypair)"
assert_eq "T4b 选中 urlsafe 变体" "$got" "${RAW_URLSAFE} ${RAW_URLSAFE}"
export STUB_ACCEPT_VARIANT='std'
got="$(_warp_gen_keypair)"
assert_eq "T4c 选中标准变体" "$got" "${RAW_KEY} ${RAW_KEY}"

echo "== T5/T6  密钥生成失败路径 =="
export STUB_REJECT_ALL=1
got="$(_warp_gen_keypair 2>"$SB/keyerr")" && rc=0 || rc=$?
assert_ne "T5a 三种变体全被拒则失败" "${rc:-0}" "0"
assert_contains "T5b 说明最后试过的编码" "$(cat "$SB/keyerr")" "handler.warp.key_probe_failed"
STUB_REJECT_ALL=0
# xray 缺失: 把 PATH 收窄到不含桩目录
old_path="$PATH"
PATH="/usr/bin:/bin"
export PATH
got_rc=0
got="$(_warp_gen_keypair 2>"$SB/noxray" || echo "__FAILED__")"
[[ "$got" == '__FAILED__' ]] || got_rc=1
PATH="$old_path"
export PATH
assert_eq "T6a xray 缺失即失败" "$got_rc" "0"
assert_contains "T6b 提示找不到 xray" "$(cat "$SB/noxray")" "handler.warp.no_xray"

echo "== T7  T8  注册 =="
STUB_API_BODY='{"config":{"client_id":"AQIDBA==","interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700:110::1"}},"peers":[{"public_key":"PEERKEY","endpoint":{"host":"engage.cloudflareclient.com:2408"}}]}}'
STUB_API_CODE=200 creds="$(_warp_register 'PUB' 'PRIV')"
assert_eq "T7a 私钥用本机生成的" "$(printf '%s' "$creds" | jq -r '.private_key')" "PRIV"
assert_eq "T7b v4 带 /32" "$(printf '%s' "$creds" | jq -r '.address[0]')" "172.16.0.2/32"
assert_eq "T7c v6 带 /128" "$(printf '%s' "$creds" | jq -r '.address[1]')" "2606:4700:110::1/128"
assert_eq "T7d peer 公钥" "$(printf '%s' "$creds" | jq -r '.peer_public_key')" "PEERKEY"
assert_eq "T7e endpoint" "$(printf '%s' "$creds" | jq -r '.endpoint')" "engage.cloudflareclient.com:2408"
assert_eq "T7f reserved 由 client_id 解出" "$(printf '%s' "$creds" | jq -c '.reserved')" "[1,2,3]"
STUB_API_CODE=500 creds="$(STUB_API_BODY='{}' _warp_register 'PUB' 'PRIV' 2>"$SB/reg500")" && rc=0 || rc=$?
assert_ne "T8a 500 视为失败" "${rc:-0}" "0"
assert_eq "T8b 失败不产出凭据" "${creds}" ""
assert_contains "T8c 报错带上状态码" "$(cat "$SB/reg500")" "500"
STUB_API_CODE=200 STUB_API_BODY='{"config":{"interface":{"addresses":{"v4":"172.16.0.2"}}}}' creds="$(_warp_register 'PUB' 'PRIV' 2>/dev/null)" && rc=0 || rc=$?
assert_ne "T8d 响应缺 peer 则失败" "${rc:-0}" "0"
STUB_API_CODE=200

echo "== T9  T10  凭据复用 =="
: > "$CURL_LOG"
printf '%s\n' "$CREDS" > "$WARP_CREDENTIALS_PATH"
got="$(_warp_ensure_credentials)"
assert_eq "T9a 复用已落盘凭据" "$(printf '%s' "$got" | jq -r '.private_key')" "PRIV"
assert_eq "T9b 复用路径不联网" "$(wc -l < "$CURL_LOG")" "0"
printf '%s\n' '{"private_key":"OLD"}' > "$WARP_CREDENTIALS_PATH"
STUB_API_BODY='{"config":{"client_id":"AQIDBA==","interface":{"addresses":{"v4":"172.16.0.2"}},"peers":[{"public_key":"PEERKEY","endpoint":{"host":"h:2408"}}]}}'
STUB_API_CODE=200 got="$(_warp_ensure_credentials)"
assert_eq "T10a 半截凭据不复用" "$(printf '%s' "$got" | jq -r '.peer_public_key')" "PEERKEY"
assert_eq "T10b 半截凭据触发重新注册" "$(wc -l < "$CURL_LOG")" "1"
assert_eq "T10c 新凭据已落盘" "$(jq -r '.peer_public_key' "$WARP_CREDENTIALS_PATH")" "PEERKEY"

echo "== T11 _xray_apply_warp =="
XRAY_CONFIG='{"outbounds":[{"tag":"direct","protocol":"freedom"}]}'
WARP_STATUS=0 _xray_apply_warp
assert_eq "T11a 未启用零操作" "$(printf '%s' "$XRAY_CONFIG" | jq -r '.outbounds | length')" "1"
WARP_STATUS=1
_xray_apply_warp
assert_eq "T11b 启用后追加出站" "$(printf '%s' "$XRAY_CONFIG" | jq -r '[.outbounds[] | select(.tag == "warp")] | length')" "1"
assert_eq "T11c 出站是 wireguard" "$(printf '%s' "$XRAY_CONFIG" | jq -r '.outbounds[] | select(.tag == "warp") | .protocol')" "wireguard"
_xray_apply_warp
assert_eq "T11d 重复应用幂等" "$(printf '%s' "$XRAY_CONFIG" | jq -r '[.outbounds[] | select(.tag == "warp")] | length')" "1"

echo "== T12 关闭: 出站与规则两处副本一起清 =="
XRAY_CONFIG_PATH="$SB/cfg/live.json"
cat > "$XRAY_CONFIG_PATH" <<'JSON'
{
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "warp", "protocol": "wireguard", "settings": {"secretKey": "x"}}
  ],
  "routing": {"rules": [
    {"ruleTag": "private-ip", "ip": ["geoip:private"], "outboundTag": "block"},
    {"ruleTag": "warp-ip", "ip": ["1.2.3.4"], "outboundTag": "warp"}
  ]}
}
JSON
SCRIPT_CONFIG='{"xray":{"warp":1},"rules":[{"ruleTag":"private-ip","outboundTag":"block"},{"ruleTag":"warp-ip","outboundTag":"warp"}]}'
: > "$PERSIST_LOG"
handler_warp
assert_eq "T12a 出站已摘" "$(jq -r '[.outbounds[] | select(.tag == "warp")] | length' "$XRAY_WRITTEN")" "0"
assert_eq "T12b 配置里规则已摘" "$(jq -r '[.routing.rules[] | select(.outboundTag == "warp")] | length' "$XRAY_WRITTEN")" "0"
assert_eq "T12c 其它规则保留" "$(jq -r '[.routing.rules[] | select(.outboundTag == "block")] | length' "$XRAY_WRITTEN")" "1"
assert_eq "T12d rules 副本里的 warp 规则也清了" "$(jq -r '[.rules[] | select(.outboundTag == "warp")] | length' "$SCRIPT_WRITTEN")" "0"
assert_eq "T12e 状态位置 0" "$(jq -r '.xray.warp' "$SCRIPT_WRITTEN")" "0"

echo "== T13 开启: 写出 wireguard 出站 =="
printf '%s\n' "$CREDS" > "$WARP_CREDENTIALS_PATH"
printf '%s\n' '{"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}' > "$XRAY_CONFIG_PATH"
SCRIPT_CONFIG='{"xray":{"warp":0},"rules":[]}'
: > "$PERSIST_LOG"
handler_warp
assert_eq "T13a 出站协议" "$(jq -r '.outbounds[] | select(.tag == "warp") | .protocol' "$XRAY_WRITTEN")" "wireguard"
assert_eq "T13b 状态位置 1" "$(jq -r '.xray.warp' "$SCRIPT_WRITTEN")" "1"

echo "== T14/T15 注册失败: 一字节都不落盘, 且状态位不先翻 =="
rm -f "$WARP_CREDENTIALS_PATH"
printf '%s\n' '{"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}' > "$XRAY_CONFIG_PATH"
SCRIPT_CONFIG='{"xray":{"warp":0},"rules":[]}'
: > "$PERSIST_LOG"
rm -f "$XRAY_WRITTEN" "$SCRIPT_WRITTEN"
STUB_API_CODE=500 handler_warp >/dev/null 2>&1 && rc=0 || rc=$?
assert_ne "T14a 启用失败返回非 0" "${rc:-0}" "0"
assert_eq "T14b 未调用 persist (没写盘)" "$(wc -l < "$PERSIST_LOG")" "0"
# 成功路径的落盘顺序: 先 xray 后 script
STUB_API_CODE=200
STUB_API_BODY='{"config":{"client_id":"AQIDBA==","interface":{"addresses":{"v4":"172.16.0.2"}},"peers":[{"public_key":"PEERKEY","endpoint":{"host":"h:2408"}}]}}'
: > "$PERSIST_LOG"
handler_warp >/dev/null 2>&1
assert_eq "T15a 先落 Xray 配置再落状态位" "$(tr '\n' ' ' < "$PERSIST_LOG")" "xray script "

echo "== T16 (NEG) 不清理 .rules 副本则规则会残留 =="
XRAY_CONFIG_PATH="$SB/cfg/live2.json"
cat > "$XRAY_CONFIG_PATH" <<'JSON'
{"outbounds": [{"tag": "warp", "protocol": "wireguard", "settings": {}}], "routing": {"rules": [{"ruleTag": "warp-ip", "outboundTag": "warp"}]}}
JSON
SCRIPT_CONFIG='{"xray":{"warp":1},"rules":[{"ruleTag":"warp-ip","outboundTag":"warp"}]}'
: > "$PERSIST_LOG"
# 模拟"只删 Xray 配置里那份、忘了同步 .rules"的写法
XRAY_CONFIG="$(jq '.' "$XRAY_CONFIG_PATH")"
XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq 'del(.outbounds[] | select(.tag == "warp")) | del(.routing.rules[] | select(.outboundTag == "warp"))')"
SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.xray.warp = 0')"
persist_xray_config
persist_script_config
assert_eq "T16a NEG: 配置里的规则删掉了" "$(jq -r '.routing.rules | length' "$XRAY_WRITTEN")" "0"
assert_ne "T16b NEG: .rules 副本仍残留 warp 规则 (证明 T12d 的清理非虚设)" \
    "$(jq -r '[.rules[] | select(.outboundTag == "warp")] | length' "$SCRIPT_WRITTEN")" "0"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
