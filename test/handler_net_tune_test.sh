#!/usr/bin/env bash
# handler_net_tune 结构守卫测试 (纯 bash, 不写 /etc/sysctl.d, 无副作用)
#
# handler_net_tune 会向 /etc/sysctl.d/99-xray-script-personal-use-only-net.conf 写内核参数
# 并 `sysctl -p` 应用 —— 沙箱 /etc 只读, 无法真跑落盘, 故改为"抽取函数体并解析校验", 锁定:
#   1. keys / vals 两个数组长度相等 (错位是最危险的回归: 会把 tcp_wmem 的值写给 tcp_rmem 等);
#   2. 键名合法 (net.* / fs.*) 且无重复; 值格式为"单值"或"min def max"三段;
#   3. keys 与 vals 的完整映射与预期配方一致 (逐项快照, 配方变更须同步本期望);
#   4. 比较前用 _net_norm 归一化 (否则 "4096  87380" 与 "4096 87380" 会被误判为不等);
#   5. 只用 `sysctl -p <本文件>` 应用, 不用 `sysctl --system` (避免被整机其它坏配置带崩);
#   6. 取消路径安全默认 (read 失败/非 y 即不写), 文件走 _atomic_write 原子落地。
#
# 防回归: 数组增删但未同步 / 值写错位置 / 遗留 `sysctl --system` / 取消默认被改成"直接应用"。
# 运行: bash test/handler_net_tune_test.sh
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
# 断言基于"去注释后的代码", 避免命中注释里提到的反面示例 (如注释里的 `sysctl --system`)
#
# 注: 这里刻意**不用** `printf '%s' "$FUNC_CODE" | grep -q` —— FUNC_CODE 有 4KB+ (handler_net_tune
#     函数体 4109 字节), 而 bash 的 printf 在 4096 字节处 flush, 也就是要发两次 write。
#     `grep -q` 命中首行(第一块)就退出, 第二次 write 撞上已关闭的管道 -> printf 收 SIGPIPE,
#     管道在 pipefail 下返回 141, 于是"命中"被判定成"未命中" —— 判定随机翻红 (2026-09-24 在
#     CI 里实测偶发一次, 载荷只越过 4KB 边界 13 字节, 所以极难稳定复现)。
#     改用 `[[ == ]]` 变量匹配: 无子进程、无管道、无缓冲边界, 判定确定。
has() { if [[ "${FUNC_CODE}" == *"$1"* ]]; then ok; else bad "$2 (缺: $1)"; fi; }
hasnt() { if [[ "${FUNC_CODE}" != *"$1"* ]]; then ok; else bad "$2 (不应出现: $1)"; fi; }

# ---- T0 自我守卫: 代码里不得出现"printf 管道 + grep -q"的判定写法 ----
# 扫描前先剥掉整行注释 —— 否则本文件解释这件事的注释自己就会把守卫判红 (自匹配是这类
# 守卫最常见的假红来源)。模式拆成两段在不同行上拼接, 并要求 printf 与 grep -q 在**同一行**。
_p1='printf[^|]*'
_p2='\|[[:space:]]*grep -q'
if grep -vE '^[[:space:]]*#' "$0" | grep -qE "${_p1}${_p2}"; then
    bad "T0: 仍存在 printf 管道加 grep -q 的判定 (4KB 缓冲边界处会随机翻红)"
else ok; fi

# --- 抽取函数体 (不加载整个 handler.sh, 避免顶层副作用) ---
FUNC_SRC="$(awk '/^function handler_net_tune\(\) \{/{f=1} f{print} f&&/^}/{exit}' core/handler.sh)"
if [[ -z "$FUNC_SRC" ]]; then
    echo "  [FAIL] 无法从 core/handler.sh 抽取 handler_net_tune 函数体"
    exit 1
fi
# 去行内注释后的纯代码 (用于 has/hasnt, 且不误伤数组元素)
FUNC_CODE="$(printf '%s\n' "$FUNC_SRC" | sed -E 's/[[:space:]]+#.*$//' | grep -v '^[[:space:]]*$')"

# --- 抽取并清洗 keys / vals 数组元素 (去行内注释、空白、单引号) ---
extract_arr() { # $1 = local 变量名 (keys|vals)
    printf '%s\n' "$FUNC_SRC" | awk -v name="$1" '
        index($0, "local -a " name "=(") > 0 { grab=1; next }
        grab && /^[[:space:]]*\)/ { grab=0; next }
        grab { print }
    ' | sed -E "s/#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/'//g" | grep -v '^$'
}

KEYS="$(extract_arr keys)"
VALS="$(extract_arr vals)"
if [[ -z "$KEYS" || -z "$VALS" ]]; then
    echo "  [FAIL] 未能抽取 keys / vals 数组内容"
    exit 1
fi

KCOUNT="$(printf '%s\n' "$KEYS" | grep -c .)"
VCOUNT="$(printf '%s\n' "$VALS" | grep -c .)"

# ---- T1 数组长度相等 (防错位) ----
if [[ "$KCOUNT" -eq "$VCOUNT" ]]; then ok; else bad "T1: keys(${KCOUNT}) 与 vals(${VCOUNT}) 长度不等 (会错位)"; fi

# ---- T2 键名合法 ----
bad_keys="$(printf '%s\n' "$KEYS" | grep -vE '^(net|fs)\.[a-z0-9_.-]+$' || true)"
if [[ -z "$bad_keys" ]]; then ok; else bad "T2: 非法 sysctl 键名: $(printf '%s' "$bad_keys" | tr '\n' '|')"; fi

# ---- T3 键名无重复 ----
dup_keys="$(printf '%s\n' "$KEYS" | sort | uniq -d)"
if [[ -z "$dup_keys" ]]; then ok; else bad "T3: 重复键名: $(printf '%s' "$dup_keys" | tr '\n' '|')"; fi

# ---- T4 值格式: 单值或三段 "min def max" ----
bad_vals="$(printf '%s\n' "$VALS" | grep -vE '^[0-9]+( [0-9]+){0,2}$' || true)"
if [[ -z "$bad_vals" ]]; then ok; else bad "T4: 非法值格式: $(printf '%s' "$bad_vals" | tr '\n' '|')"; fi

# ---- T5 完整映射快照 (配方变更须同步此处期望) ----
EXPECT_KEYS="net.core.somaxconn
net.ipv4.tcp_max_syn_backlog
net.core.rmem_max
net.core.wmem_max
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
fs.file-max
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_tw_reuse
net.ipv4.tcp_fastopen"
EXPECT_VALS="65535
65535
134217728
134217728
4096 87380 134217728
4096 65536 134217728
1000000
0
1
3"
if [[ "$KEYS" == "$EXPECT_KEYS" ]]; then ok; else bad "T5: keys 顺序/内容与预期配方不符"; fi
if [[ "$VALS" == "$EXPECT_VALS" ]]; then ok; else bad "T5: vals 顺序/内容与预期配方不符"; fi

# ---- T6 语义与安全契约 (静态) ----
has "_net_norm" "T6: 比较前后值应经 _net_norm 归一化 (空白差异不应误判)"
has 'sysctl -p "${sysctl_file}"' "T6: 应只应用本文件 (sysctl -p <本文件>)"
hasnt "sysctl --system" "T6: 不应使用 sysctl --system (会连带加载整机其它配置)"
has "_atomic_write" "T6: 写 sysctl 文件应走 _atomic_write 原子落地"
has "read -r confirm" "T6: 应用前应交互确认"
has "y | yes" "T6: 确认分支应显式接受 y/yes, 其余视为取消"

# ---- T7 幂等与安全默认: 无变化即返回, 取消也返回 0 ----
noop_guard="$(
    printf '%s\n' "$FUNC_CODE" | grep -cE 'return 0' || true
)"
if [[ "${noop_guard}" -ge 2 ]]; then ok; else bad "T7: 应存在多处 return 0 (无变化/取消均属正常结束)"; fi

echo
echo "==== handler_net_tune_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
