#!/usr/bin/env bash
# generate.sh 纯逻辑回归测试 (纯 bash, 不依赖 jq / xray / openssl 真实二进制)
#   锁定: generate_random 范围映射 (stub od 定死 32 位输入) / generate_short_id 长度分支
#        (stub openssl) / main 未知参数 exit 2 (P1-3) 与合法派发.
set -u
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1" >&2; }
assert_eq() { local d="$1" g="$2" e="$3"; if [[ "$g" == "$e" ]]; then ok "$d"; else bad "$d (got[$g] exp[$e])"; fi; }

SRC='core/generate.sh'
if [[ ! -r "$SRC" && -r "${0%/*}/../$SRC" ]]; then cd "${0%/*}/.." || exit 1; fi
TMPD=".workbuddy/tmp/generate_$$"; rm -rf "$TMPD"; mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT
[[ -r "$SRC" ]] || { bad "找不到 $SRC"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# ---- 抽取真实函数体 ----
RAND="$(awk '/^function generate_random\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
SHID="$(awk '/^function generate_short_id\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
MAIN="$(awk '/^function main\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
[[ -n "$RAND" && -n "$SHID" && -n "$MAIN" ]] || { bad "函数抽取失败"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }
eval "$RAND"; eval "$SHID"

# ---- od / openssl 桩件 (定死输入, 保证确定性) ----
od()      { printf '4294967295\n'; }   # 最大 uint32
openssl() { printf '%s' "${@: -1}"; }  # 回显长度参数, 验证长度透传

echo "== generate_random 范围映射 =="
assert_eq "random 10..20 取模映射 (=3+10)" "$(generate_random 10 20)" "13"
assert_eq "random 无参 原样输出原始随机"     "$(generate_random)" "4294967295"
assert_eq "random min>=max 走 else 原样"     "$(generate_random 20 10)" "4294967295"
assert_eq "random 非数字 走 else"           "$(generate_random a b)" "4294967295"

echo "== generate_short_id 长度分支 =="
assert_eq "short_id '5'   -> openssl 长度 5" "$(generate_short_id 5)" "5"
assert_eq "short_id '0'   -> 空串"           "$(generate_short_id 0)" ""
assert_eq "short_id 'abc' -> 随机长度(桩=>3)" "$(generate_short_id abc)" "3"
assert_eq "short_id '  7  ' 去空格->7"        "$(generate_short_id '  7  ')" "7"

echo "== main 派发与未知参数 exit 2 =="
# 覆盖所有 generate_* 为标记桩 (含已被 eval 的 random/short_id)
for fn in generate_random generate_port generate_uuid generate_password generate_target generate_server_names generate_x25519 generate_short_id generate_short_ids generate_path; do
  eval "${fn}() { printf '%s' \"${fn}\"; }"
done
eval "$MAIN"
assert_eq "main --port 派发到 generate_port" "$(main --port 2>/dev/null)" "generate_port"
assert_eq "main --uuid 派发到 generate_uuid" "$(main --uuid 2>/dev/null)" "generate_uuid"
( main --bogus >/dev/null 2>&1 ); rc=$?
if [[ $rc -eq 2 ]]; then ok "main 未知参数 exit 2 (P1-3)"; else bad "main 未知参数应 exit 2, 实测 $rc"; fi
( main >/dev/null 2>&1 ); rc=$?
if [[ $rc -eq 2 ]]; then ok "main 无参数 exit 2"; else bad "main 无参数应 exit 2, 实测 $rc"; fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
