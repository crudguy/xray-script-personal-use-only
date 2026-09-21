#!/usr/bin/env bash
# shellcheck disable=SC2034  # 同上: read_input/main/param_map 为 eval 注入的真实实现, GREEN/YELLOW/NC/CUR_FILE 由它们读取。
# read.sh 纯逻辑回归测试 (纯 bash)
#   锁定: read_input 标题/颜色/rule 多值提示; main 的 param_map 命中/未命中、
#        --short 额外提示、EOF 退出 1 (P0-1 关键修复).
set -u
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1" >&2; }
assert_eq() { local d="$1" g="$2" e="$3"; if [[ "$g" == "$e" ]]; then ok "$d"; else bad "$d (got[$g] exp[$e])"; fi; }

SRC='core/read.sh'
if [[ ! -r "$SRC" && -r "${0%/*}/../$SRC" ]]; then cd "${0%/*}/.." || exit 1; fi
TMPD="test/.tmp/read_$$"; rm -rf "$TMPD"; mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT
[[ -r "$SRC" ]] || { bad "找不到 $SRC"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# 抽取真实函数体 + param_map
RI="$(awk '/^function read_input\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
MAIN="$(awk '/^function main\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
PM="$(awk '/^declare -A param_map=\(/,/^)/' "$SRC")"
[[ -n "$RI" && -n "$MAIN" && -n "$PM" ]] || { bad "函数/映射抽取失败"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# 常量与桩件
GREEN='<G>'; YELLOW='<Y>'; NC='<NC>'; CUR_FILE='read'
_i18n() {
  case "$1" in
    .title.config) printf '配置' ;; .title.route) printf '路由规则' ;;
    .title.multiple_values) printf '多值' ;; .title.tip) printf '提示' ;;
    .read.short_id_tip) printf '短ID提示' ;; .title.warn) printf '警告' ;;
    .read.eof_abort) printf 'EOF中断' ;;
    .read.port) printf '请输入端口' ;; .read.domain) printf '请输入域名' ;;
    *) printf '' ;;
  esac
}
load_i18n() { :; }

eval "$PM"
eval "$RI"
eval "$MAIN"

echo "== read_input 标题/颜色/多值 =="
err="$(read_input "config" "请输入端口" 2>&1 1>/dev/null)"
if [[ "$err" == *"[配置]"* && "$err" == *"请输入端口"* ]]; then ok "config 类型: [配置] + msg"; else bad "config 异常: [$err]"; fi
err="$(read_input "rule" "请输入规则" 2>&1 1>/dev/null)"
if [[ "$err" == *"[路由规则]"* && "$err" == *"请输入规则"* && "$err" == *"多值"* ]]; then ok "rule 类型: [路由规则] + msg + 多值提示"; else bad "rule 异常: [$err]"; fi

echo "== main EOF 退出 1 (P0-1) =="
( main --port </dev/null ); rc=$?
if [[ $rc -eq 1 ]]; then ok "main --port EOF 退出 1"; else bad "EOF 应 exit 1, 实测 $rc"; fi

echo "== main 命中/未命中 param_map =="
out="$(echo "8080" | main --port 2>/dev/null)"; assert_eq "main --port 回显 stdin" "$out" "8080"
out="$(echo "x.com" | main domain 2>/dev/null)"; assert_eq "main 裸名 domain 兼容加 --" "$out" "x.com"
out="$(main --bogus 2>/dev/null)"
if [[ -z "$out" ]]; then ok "main --bogus 未命中: 静默返回无输出"; else bad "main --bogus 不应有输出: [$out]"; fi
err="$(echo "abc" | main --short 2>&1 1>/dev/null)"; out="$(echo "abc" | main --short 2>/dev/null)"
if [[ "$err" == *"提示"* && "$err" == *"短ID提示"* && "$out" == "abc" ]]; then ok "main --short 打印 tip 且回显输入"; else bad "main --short 异常: err[$err] out[$out]"; fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
