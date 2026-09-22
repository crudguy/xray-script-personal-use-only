#!/usr/bin/env bash
# valid_domain 功能回归测试 (纯 bash, 不依赖 jq / 框架)
# 锁定域名格式校验单一来源 (DOMAIN_REGEX 在 core/_common.sh) 与 valid_domain() 的判定语义,
# 防止校验规则被意外改松/改紧。
set -Eeuo pipefail

PASS=0
FAIL=0

# 抽取 DOMAIN_REGEX (唯一来源) 与 valid_domain 函数体
REGEX_SRC="$(awk '/^readonly DOMAIN_REGEX=/{print; exit}' core/_common.sh)"
FUNC_SRC="$(awk '/^function valid_domain\(\) \{/,/^}/' core/check.sh)"
if [[ -z "$REGEX_SRC" || -z "$FUNC_SRC" ]]; then
    echo "FATAL: 未能从 core/_common.sh / core/check.sh 抽取 DOMAIN_REGEX / valid_domain"; exit 1
fi
eval "$REGEX_SRC"
eval "$FUNC_SRC"

assert() {
    local desc="$1" domain="$2" exp="$3"
    local got
    if valid_domain "$domain"; then got=0; else got=1; fi
    if [[ "$got" -eq "$exp" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (domain=[$domain] expected rc=$exp got rc=$got)"
    fi
}

# ---- 有效域名 (期望 rc=0) ----
assert "simple"          "example.com"      0
assert "subdomain"       "sub.example.com"  0
assert "short-tld-invalid" "a.b.c.d"        1
assert "hyphen-label"    "exa-mple.com"     0
assert "punycode"        "xn--fiqs8s.com"   0
assert "co-uk"           "example.co.uk"    0

# ---- 无效域名 (期望 rc=1) ----
assert "empty"           ""                 1
assert "single-label"    "localhost"        1
assert "trailing-dot"    "example.com."     1
assert "double-dot"      "example..com"     1
assert "wildcard"        "*.example.com"    1
assert "leading-hyphen"  "-x.com"           1
assert "ipv4"            "1.2.3.4"          1
assert "with-space"      "a b.com"          1
assert "with-underscore" "a_b.com"          1

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
