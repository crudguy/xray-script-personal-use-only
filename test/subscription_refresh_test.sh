#!/usr/bin/env bash
#
# 用例: core/handler.sh 的"配置变更 -> 订阅自动重生成"(P3-1)
#
# 背景 (为什么要测): 订阅是配置的"派生快照" —— 生成出来的链接里写死了域名/端口/UUID/SNI,
# 配置一改, 用户手上那份订阅就静默失效。新增的机制是: persist_script_config /
# persist_xray_config / handler_import_config 只"置脏"(SUB_REFRESH_DIRTY=1), 由 handler
# 的 main() 末尾统一调 refresh_subscription_after_config_change 收口重建一次。
#
# 这类"标志 + 收口"逻辑最容易出的两种错, 静态检查都看不出来:
#   1. 忘了在建订阅之前判"用户到底有没有订阅" -> 给没这需求的用户凭空造文件;
#   2. 把重建失败变成致命错误 -> 已经成功的配置变更被带崩。
# 本用例把这两种契约钉死。
#
# 做法: 临时沙箱里复制 core/ + i18n/, 把 handler.sh 的 `main "$@"` 换成测试驱动
#       (于是 $0/CUR_DIR/PROJECT_ROOT 与真实运行一致), 并把 SHARE_PATH / BACKUP_PATH
#       指向桩件 —— 只观测"有没有被调用、带什么参数", 不真的去生成订阅。
#
# 依赖: bash, jq。
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"

SB="$(mktemp -d "${TMPDIR:-/tmp}/xray-refresh-test.XXXXXX")"
cleanup() {
    if [[ "${XRAY_TEST_KEEP:-0}" == '1' ]]; then
        printf '\n(已保留沙箱: %s)\n' "${SB}" >&2
        return 0
    fi
    rm -rf "${SB}"
}
trap cleanup EXIT

fail=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
    printf '  FAIL %s\n' "$1"
    fail=1
}

# ---------------------------------------------------------------------------
# 1. 沙箱
# ---------------------------------------------------------------------------
mkdir -p "${SB}/home/.xray-script-personal-use-only"
cp -r "${REPO}/core" "${SB}/core"
cp -r "${REPO}/i18n" "${SB}/i18n"
export HOME="${SB}/home"
# 语言必须给真实值: load_i18n 用它拼 i18n/<lang>.json
printf '{"language":"zh","path":"/usr/local/xray-script-personal-use-only","xray":{"tag":"Vision"}}\n' \
    >"${SB}/home/.xray-script-personal-use-only/config.json"

# ---------------------------------------------------------------------------
# 2. 桩件: share.sh 只留痕并可按开关返回失败; backup.sh 恒成功
# ---------------------------------------------------------------------------
MARK="${SB}/mark.txt"
FAILFLAG="${SB}/fail.flag"
RESULT="${SB}/result.tsv"
: >"${MARK}"
: >"${RESULT}"

cat >"${SB}/share_stub.sh" <<'STUB'
#!/usr/bin/env bash
printf 'share.sh %s\n' "$*" >>"${_T_MARK}"
if [[ -f "${_T_FAIL_FLAG}" ]]; then exit 1; fi
exit 0
STUB

cat >"${SB}/backup_stub.sh" <<'STUB'
#!/usr/bin/env bash
printf 'backup.sh %s\n' "$*" >>"${_T_MARK}"
exit 0
STUB
chmod +x "${SB}/share_stub.sh" "${SB}/backup_stub.sh"

# ---------------------------------------------------------------------------
# 3. 驱动: 替换 handler.sh 的自动入口 + 把两个外部脚本指向桩件
# ---------------------------------------------------------------------------
cat >"${SB}/driver.txt" <<'DRIVER'
# ---------------- 测试驱动 (由 test/subscription_refresh_test.sh 注入, 非生产代码) ----------------
# 可选: 被测代码的 _common.sh 会把 PATH 覆盖成固定白名单, 若本机 jq 不在白名单内
# (如 Windows/MSYS 下放在别处), 由调用方通过 _T_SHIM 指定目录, 在此补回。
if [[ -n "${_T_SHIM:-}" ]]; then
    export PATH="${_T_SHIM}:${PATH}"
fi

emit() { printf '%s\t%s\n' "$1" "$2" >>"${_T_RESULT}"; }
calls() { wc -l <"${_T_MARK}" | tr -d ' '; }

# 场景执行器: 跑一次收口函数, 记录"被调了多少次 / DIRTY 终值 / 返回码"
run_case() {
    local name="$1" before after rc=0
    before="$(calls)"
    refresh_subscription_after_config_change || rc=$?
    after="$(calls)"
    emit "${name}.calls" "$((after - before))"
    emit "${name}.dirty" "${SUB_REFRESH_DIRTY}"
    emit "${name}.rc" "${rc}"
}

sub_present() { : >"${SCRIPT_CONFIG_DIR}/subscription-base64.txt"; }
sub_absent() { rm -f "${SCRIPT_CONFIG_DIR}"/subscription-*; }

# --- 场景 1: 没写过配置 (DIRTY=0) + 有订阅文件 -> 不该重建 ---
sub_present
SUB_REFRESH_DIRTY=0
run_case idle

# --- 场景 2: 写过配置但用户从没生成过订阅 -> 不该凭空造文件 ---
sub_absent
SUB_REFRESH_DIRTY=0
persist_script_config
emit 'changed_nosub.dirty_after_persist' "${SUB_REFRESH_DIRTY}"
run_case changed_nosub

# --- 场景 3: 写过配置 + 已有订阅 -> 重建恰好一次, 且 DIRTY 被清零 ---
sub_present
SUB_REFRESH_DIRTY=0
persist_script_config
run_case changed_withsub

# --- 场景 4: 重建失败 -> 不致命 (返回 0), 但仍尝试了一次, DIRTY 同样清零 ---
sub_present
: >"${_T_FAIL_FLAG}"
SUB_REFRESH_DIRTY=0
persist_script_config
run_case changed_fail
rm -f "${_T_FAIL_FLAG}"

# --- 场景 5: import 路径 (不经过 persist_*) 也必须置脏 ---
sub_present
SUB_REFRESH_DIRTY=0
handler_import_config 'archive.tar.gz' >/dev/null 2>&1 || true
emit 'import.dirty_after_import' "${SUB_REFRESH_DIRTY}"
run_case import

# --- 场景 6: 连续两次 persist 只应重建一次 (收口的意义) ---
sub_present
SUB_REFRESH_DIRTY=0
persist_script_config
persist_script_config
run_case double_persist

# --- 场景 7: 置脏后没人收口时, 标记必须还在 (证明置脏与清零是两个独立动作) ---
sub_present
SUB_REFRESH_DIRTY=0
persist_script_config
emit 'no_sink.dirty' "${SUB_REFRESH_DIRTY}"

# --- 场景 8: persist_xray_config 也是置脏点 (桩掉原子写与 xray 复核, 只验"是否置脏") ---
sub_present
XRAY_CONFIG='{"inbounds":[]}'
_atomic_write() { cat >"${_T_SINK}"; } # 不碰真实绝对路径, 落进沙箱
_verify_xray_config() { return 0; }
SUB_REFRESH_DIRTY=0
persist_xray_config
emit 'xraypersist.dirty_before' "${SUB_REFRESH_DIRTY}"
run_case xraypersist
DRIVER

# 两个 readonly 常量改指向桩件 (精确到行的前缀匹配, 避免空白差异)
awk -v share="${SB}/share_stub.sh" -v backup="${SB}/backup_stub.sh" '
    /^readonly SHARE_PATH=/  { print "readonly SHARE_PATH=\"" share "\"";  hits_share++; next }
    /^readonly BACKUP_PATH=/ { print "readonly BACKUP_PATH=\"" backup "\""; hits_backup++; next }
    { print }
    END { if (hits_share != 1 || hits_backup != 1) exit 3 }
' "${SB}/core/handler.sh" >"${SB}/core/handler.patched.sh" || {
    bad "改写 SHARE_PATH / BACKUP_PATH 失败 (生产代码结构变了?)"
    printf '\n结果: 失败\n'
    exit 1
}
mv "${SB}/core/handler.patched.sh" "${SB}/core/handler.sh"

if [[ "$(grep -c '^main "\$@"$' "${SB}/core/handler.sh")" -ne 1 ]]; then
    bad "core/handler.sh 里未找到唯一的入口行 main \"\$@\" (测试无法注入驱动)"
    printf '\n结果: 失败\n'
    exit 1
fi
awk -v drvfile="${SB}/driver.txt" '
    $0 == "main \"$@\"" {
        while ((getline ln < drvfile) > 0) print ln
        close(drvfile)
        hits++
        next
    }
    { print }
    END { if (hits != 1) exit 1 }
' "${SB}/core/handler.sh" >"${SB}/core/handler.patched.sh" || {
    bad "注入驱动失败"
    printf '\n结果: 失败\n'
    exit 1
}
mv "${SB}/core/handler.patched.sh" "${SB}/core/handler.sh"

# ---------------------------------------------------------------------------
# 4. 跑驱动
# ---------------------------------------------------------------------------
if ! _T_MARK="${MARK}" _T_RESULT="${RESULT}" _T_FAIL_FLAG="${FAILFLAG}" \
    _T_SINK="${SB}/sink.json" _T_SHIM="${XRAY_TEST_SHIM:-}" \
    bash "${SB}/core/handler.sh" >"${SB}/driver.log" 2>&1; then
    bad "驱动执行失败, 见下"
    sed 's/^/  | /' "${SB}/driver.log" | head -40
    printf '\n结果: 失败\n'
    exit 1
fi
ok "驱动执行完成 (8 个场景)"

got() { awk -v k="$1" -F'\t' '$1 == k {print $2}' "${RESULT}"; }
check() { # $1=键 $2=期望值 $3=描述
    local v
    v="$(got "$1")"
    if [[ "${v}" == "$2" ]]; then
        ok "$3 (=${v})"
    else
        bad "$3 (期望 $2, 实际 ${v:-<缺失>})"
    fi
}

# 场景 1: 没写过配置 -> 一次都不该调
check 'idle.calls' '0' '未写配置时不重建订阅'
check 'idle.rc' '0' '未写配置时返回 0'

# 场景 2: 写过配置但没订阅 -> 不该凭空造文件
check 'changed_nosub.dirty_after_persist' '1' 'persist_script_config 会置脏'
check 'changed_nosub.calls' '0' '没订阅文件时不重建 (不凭空造文件)'
check 'changed_nosub.dirty' '0' '无订阅时脏标记仍被消费'
check 'changed_nosub.rc' '0' '无订阅时返回 0'

# 场景 3: 写过配置 + 有订阅 -> 恰好重建一次
check 'changed_withsub.calls' '1' '有订阅时重建恰好一次'
check 'changed_withsub.dirty' '0' '重建后脏标记清零'
check 'changed_withsub.rc' '0' '重建成功返回 0'

# 场景 4: 重建失败不致命
check 'changed_fail.calls' '1' '重建失败仍尝试了一次'
check 'changed_fail.dirty' '0' '重建失败后脏标记仍清零'
check 'changed_fail.rc' '0' '重建失败不致命 (返回 0)'

# 场景 5: import 路径也要置脏
check 'import.dirty_after_import' '1' 'handler_import_config 会置脏'
check 'import.calls' '1' '导入后收口会重建订阅'
check 'import.rc' '0' '导入后收口返回 0'

# 场景 6: 连续两次 persist 只重建一次
check 'double_persist.calls' '1' '连续两次 persist 只重建一次 (收口去重)'

# 场景 7: 没人收口时标记必须还在
check 'no_sink.dirty' '1' '未收口时脏标记保持置位'

# 场景 8: persist_xray_config 也是置脏点
check 'xraypersist.dirty_before' '1' 'persist_xray_config 会置脏'
check 'xraypersist.calls' '1' 'Xray 配置变更后收口会重建订阅'
check 'xraypersist.rc' '0' 'Xray 配置变更后收口返回 0'

printf '\n结果: %s\n' "$([[ "${fail}" -eq 0 ]] && echo 通过 || echo 失败)"
exit "${fail}"
