#!/usr/bin/env bash
# show_sni_config 行为等价测试 (纯 bash, 全 stub, 无外部依赖)
#
# show_sni_config 已被拆为"编排器 + 5 个 _sni_block_* 组函数"。本测试用桩件记录
# 各组对依赖函数的调用序列, 锁定拆分后**可观察行为与拆分前逐一等价**:
#   1. 5 组按 vision -> xhttp_reality -> tls_down -> xhttp_cdn -> reality_down 顺序执行;
#   2. 每组设置正确的 CLIENT_CONFIG[tag] (经 show_config 桩回读验证);
#   3. 组 1 不重取 common (沿用当前 CLIENT_CONFIG); 组 2~5 每组先 get_common_config 2;
#   4. 组 1~4 各以 show_config 收尾; 组 5 不以 show_config 收尾 (由调用方补);
#   5. 组 4 会清空 XHTTP_EXTRA。
#
# 防回归: 调换组顺序 / 漏调某 link 生成函数 / 给组 5 误加 show_config / 丢掉 XHTTP_EXTRA 清空。
# 运行: bash test/show_sni_config_test.sh
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

PASS=0
FAIL=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  [FAIL] $3"; echo "    got : $(printf '%s' "$1" | tr '\n' '|')"; echo "    want: $(printf '%s' "$2" | tr '\n' '|')"; fi; }

# --- 抽取编排器与 5 个组函数 (不加载整个 share.sh, 避免其顶层副作用) ---
extract_fn() {
    awk -v name="$1" '$0 ~ ("^function " name "\\(\\) \\{") {f=1} f{print} f&&/^}/{exit}' core/share.sh
}
SRC=""
for fn in show_sni_config _sni_block_vision_reality _sni_block_xhttp_reality \
    _sni_block_tls_down _sni_block_xhttp_cdn _sni_block_reality_down; do
    body="$(extract_fn "$fn")"
    if [[ -z "$body" ]]; then
        echo "  [FAIL] 未能从 core/share.sh 抽取 $fn"
        exit 1
    fi
    SRC="${SRC}${body}"$'\n'
done

# --- 桩件: 记录调用序列; show_config 回读当前 tag 以验证 tag 设置 ---
declare -A CLIENT_CONFIG=()
XHTTP_EXTRA="sentinel" # 初值非空, 用于验证组 4 是否清空
LOG=""
log() { LOG="${LOG}$1"$'\n'; }

get_vision_share_link() { log "link:vision"; }
get_fallback_xhttp_share_link() { log "link:fb_xhttp"; }
get_tls_down_json() { log "json:tls_down"; }
get_sni_tls_down_share_link() { log "link:sni_tls_down"; }
get_sni_tls_share_link() { log "link:sni_tls(extra=${XHTTP_EXTRA})"; }
get_reality_down_json() { log "json:reality_down"; }
get_sni_reality_down_share_link() { log "link:sni_reality_down"; }
get_common_config() { log "common:$1"; }
show_config() { log "show:${CLIENT_CONFIG[tag]:-}"; }

eval "$SRC"
show_sni_config

EXPECT="link:vision
show:sni_vision_reality
common:2
link:fb_xhttp
show:sni_xhttp_reality
common:2
json:tls_down
link:sni_tls_down
show:sni_tls_down
common:2
link:sni_tls(extra=)
show:sni_xhttp_cdn
common:2
json:reality_down
link:sni_reality_down"
LOG_TRIMMED="${LOG%$'\n'}" # log() 每项带尾换行, 比较前去掉末尾空行
assert_eq "$LOG_TRIMMED" "$EXPECT" "T1: 调用序列应与拆分前逐一等价 (组顺序/tag/link/show_config/XHTTP_EXTRA 清空)"

# ---- T2 组 5 末项不是 show_config (由调用方补展示) ----
last_line="$(printf '%s\n' "$LOG_TRIMMED" | sed -n '$p')"
assert_eq "$last_line" "link:sni_reality_down" "T2: 组 5 应以 link 生成收尾, 不应自带 show_config"

# ---- T3 静态守卫: 编排器只含 5 个组调用, 不含裸的业务调用 ----
ORCH="$(extract_fn show_sni_config)"
orch_calls="$(printf '%s\n' "$ORCH" | grep -oE '^[[:space:]]+_[a-z_]+' | tr -d ' ' | sort | tr '\n' ' ')"
assert_eq "$orch_calls" "_sni_block_reality_down _sni_block_tls_down _sni_block_vision_reality _sni_block_xhttp_cdn _sni_block_xhttp_reality " "T3: 编排器应只调用 5 个 _sni_block_* (无裸业务调用)"

echo
echo "==== show_sni_config_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
