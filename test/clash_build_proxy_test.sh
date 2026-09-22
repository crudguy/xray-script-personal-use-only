#!/usr/bin/env bash
# clash_build_proxy 功能回归测试 (依赖 jq)
# 锁定订阅 Clash 配置块生成: vless/reality、trojan/reality、vless/tls、vless/none(kcp)
# 四个分支的输出形态 (trojan 不显式加 tls 行、trojan 用 password 而非 uuid、kcp 加 kcp-opts)。
set -Eeuo pipefail

PASS=0
FAIL=0

FUNC_SRC="$(awk '/^function clash_build_proxy\(\) \{/,/^}/' core/share.sh)"
if [[ -z "$FUNC_SRC" ]]; then
    echo "FATAL: 未能从 core/share.sh 抽取 clash_build_proxy"; exit 1
fi
eval "$FUNC_SRC"

CLASH_PROXIES=''
CLASH_NAMES=()

contains() {
    local desc="$1" needle="$2"
    if [[ "$CLASH_PROXIES" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (missing [$needle])"
    fi
}
excludes() {
    local desc="$1" needle="$2"
    if [[ "$CLASH_PROXIES" != *"$needle"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (unexpected [$needle])"
    fi
}

# 1. vless + reality (非 trojan -> 加 tls 行 + reality-opts + flow)
node='{"tag":"n1","scheme":"vless","user":"uuid-111","host":"h.com","port":"443","type":"tcp","security":"reality","sni":"h.com","pbk":"pbk1","sid":"sid1","fp":"chrome","flow":"xtls-rprx-vision"}'
CLASH_PROXIES=''; CLASH_NAMES=(); clash_build_proxy "$node"
contains "vless-reality-type"   "    type: vless"
contains "vless-reality-server" "    server: h.com"
contains "vless-reality-port"   "    port: 443"
contains "vless-reality-uuid"   "    uuid: \"uuid-111\""
contains "vless-reality-tls"    "    tls: true"
contains "vless-reality-sni"    "    servername: h.com"
contains "vless-reality-fp"     "    client-fingerprint: chrome"
contains "vless-reality-opts"   "    reality-opts:"
contains "vless-reality-pbk"    "      public-key: \"pbk1\""
contains "vless-reality-sid"    "      short-id: \"sid1\""
contains "vless-reality-flow"   "    flow: xtls-rprx-vision"
excludes "vless-reality-no-kcp" "kcp-opts:"
excludes "vless-reality-no-alpn" "alpn:"

# 2. trojan + reality (trojan -> 不加 tls 行, 用 password 而非 uuid, 仍有 reality-opts)
node='{"tag":"n2","scheme":"trojan","user":"pwd-222","host":"h2.com","port":"8443","type":"tcp","security":"reality","sni":"h2.com","pbk":"pbk2","sid":"sid2","fp":"firefox"}'
CLASH_PROXIES=''; CLASH_NAMES=(); clash_build_proxy "$node"
contains "trojan-reality-type"     "    type: trojan"
contains "trojan-reality-password" "    password: \"pwd-222\""
contains "trojan-reality-opts"     "    reality-opts:"
contains "trojan-reality-pbk"      "      public-key: \"pbk2\""
excludes "trojan-reality-no-tls"   "    tls: true"
excludes "trojan-reality-no-uuid"  "    uuid:"

# 3. vless + tls (tls 分支 -> tls 行 + alpn h2, 无 reality-opts)
node='{"tag":"n3","scheme":"vless","user":"uuid-333","host":"h3.com","port":"443","type":"tcp","security":"tls","sni":"h3.com","fp":"safari"}'
CLASH_PROXIES=''; CLASH_NAMES=(); clash_build_proxy "$node"
contains "vless-tls-type"   "    type: vless"
contains "vless-tls-tls"    "    tls: true"
contains "vless-tls-alpn"   "    alpn:"
contains "vless-tls-uuid"   "    uuid: \"uuid-333\""
excludes "vless-tls-no-reality" "reality-opts:"

# 4. vless + none + kcp (无 tls, kcp-opts + seed)
node='{"tag":"n4","scheme":"vless","user":"uuid-444","host":"h4.com","port":"443","type":"kcp","security":"none","seed":"myseed","sni":"h4.com"}'
CLASH_PROXIES=''; CLASH_NAMES=(); clash_build_proxy "$node"
contains "none-kcp-type"     "    type: vless"
contains "none-kcp-network"  "    network: kcp"
contains "none-kcp-opts"     "    kcp-opts:"
contains "none-kcp-seed"     "      seed: myseed"
excludes "none-kcp-no-tls"   "    tls: true"

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
