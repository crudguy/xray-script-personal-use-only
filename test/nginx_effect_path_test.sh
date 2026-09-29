#!/usr/bin/env bash
# =============================================================================
# 测试名称: nginx_effect_path_test.sh
# 测试目标: 锁定「让 Nginx 配置真正生效」这条路径与托管方式解耦 —— 也就是
#           nginx_apply_config 的三档回退、_nginx_is_running 的真身判据,
#           以及两个调用方 (test_and_reload_nginx / handler_nginx_restart) 的口径。
#
# 背景 (真实缺陷):
#   接入既有 Nginx (宝塔/aaPanel/手动编译) 后, "配置写对了却没生效" —— 因为这些机器上
#   常常只有 /etc/init.d/nginx, 而 systemd 由 systemd-sysv-generator **生成**的 unit
#   **不带 ExecReload**, 于是 `systemctl reload nginx` 报 "Job type reload is not
#   applicable"; 同样 `systemctl is-active nginx` 会对一个跑得好好的 Nginx 答 inactive
#   (它不跟踪"实际是谁起的"), 使重启后的复查误报失败、或让 OCSP 刷新整段被跳过。
#
# 覆盖:
#   N1 行为 —— _nginx_is_running 用真实进程验证: 无进程 / 目标在跑 / 只有别家同名二进制
#              在跑 / 前缀带相对成分, 四种情形判定必须正确 (后两种正是"只按进程名判"会错的);
#   A1 行为 —— nginx_apply_config: systemd unit 可用时优先走它;
#   A2 行为 —— unit 在但 reload 不受支持 -> 依次回退 /etc/init.d/nginx -> 目标二进制 -s reload;
#   A3 行为 —— 三种托管方式全部不可用 -> 返回非 0 (调用方才好决定告警还是报错);
#   A4 行为 —— 未运行时只走"启动"路径 (systemd -> init.d -> 裸跑目标二进制);
#   A5 行为 —— restart 模式走 restart, 不用 reload 冒充;
#   T1 行为 —— test_and_reload_nginx: 校验落在**目标二进制**上, 失败不落地;
#   R1 行为 —— handler_nginx_restart: 复查用 _nginx_is_running, 不再依赖 systemctl is-active;
#   R2 行为 —— 无 systemd unit 的机器上, 重启流程完全不碰 systemctl;
#   NEG 负向 —— (a) 删掉 `-s reload` 兜底 -> A2 必须变红; (b) _nginx_is_running 丢掉真身
#               比对 -> N1 的"别家进程"情形必须变红。两条都用 cmp 自证变异真落地。
#
# 运行: bash test/nginx_effect_path_test.sh
# =============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s%s\n' "$1" "${2:+ ($2)}"; }
assert_eq() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got=$(printf '%q' "$2") want=$(printf '%q' "$3")"; fi
}
assert_contains() {
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing $(printf '%q' "$3")"; fi
}
assert_not_contains() {
    if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "unexpected $(printf '%q' "$3")"; fi
}
count_lines() { grep -c -- "$1" "$2" 2>/dev/null || true; }

SB="$ROOT/.workbuddy/tmp/nginx_effect.$$"
LOG="$SB/oplog"
rm -rf "$SB" 2>/dev/null || true
mkdir -p "$SB"
# 后台假进程 (下面用 /bin/sleep 的副本冒充 nginx) 的兜底回收
BGPIDS=''
cleanup() {
    local p=''
    for p in ${BGPIDS}; do kill "${p}" 2>/dev/null || true; done
    rm -rf "$SB" 2>/dev/null || true
}
trap cleanup EXIT

COMMON='core/_common.sh'
HANDLER='core/handler.sh'

fn_of() { # $1=file $2=fn
    awk -v fn="$2" 'index($0, "function " fn "() {") == 1 { f=1 } f { print } f && /^}$/ { exit }' "$1"
}

# ---------------------------------------------------------------------------
# 假目标二进制: 记录每次调用, 并按 RBIN_FAIL 指定的实参子串注入失败
# ---------------------------------------------------------------------------
make_fake_bin() { # $1=prefix
    mkdir -p "$1/sbin"
    cat >"$1/sbin/nginx" <<FAKE
#!/usr/bin/env bash
printf 'BIN:%s\n' "\$*" >>"$LOG"
if [[ -n "\${RBIN_FAIL:-}" && "\$*" == *"\${RBIN_FAIL}"* ]]; then
    exit 1
fi
exit 0
FAKE
    chmod +x "$1/sbin/nginx"
}

# 假 SysV 启动脚本 (面板机器上真实存在的那种)
make_fake_init() { # $1=路径
    cat >"$1" <<FAKEINIT
#!/usr/bin/env bash
printf 'INIT:%s\n' "\$*" >>"$LOG"
if [[ -n "\${RINIT_FAIL:-}" && "\$*" == *"\${RINIT_FAIL}"* ]]; then
    exit 1
fi
exit 0
FAKEINIT
    chmod +x "$1"
}

# ---------------------------------------------------------------------------
# 驱动 A: nginx_apply_config
# 环境变量: RMODE(reload|restart) RUNIT RRUNNING RINIT RSYS_RC RBIN_FAIL RINIT_FAIL
# ---------------------------------------------------------------------------
build_apply_runner() { # $1=输出文件 $2=prefix
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' "NGINX_PREFIX_DIR='$2'"
        printf '%s\n' "LOG='$LOG'"
        printf '%s\n' 'cmd_exists() { command -v "$1" >/dev/null 2>&1; }'
        printf '%s\n' '_nginx_service_unit_exists() { [[ "${RUNIT:-0}" == "1" ]]; }'
        printf '%s\n' '_nginx_is_running() { [[ "${RRUNNING:-0}" == "1" ]]; }'
        printf '%s\n' '_nginx_init_script() { printf "%s" "${RINIT:-}"; }'
        printf '%s\n' 'systemctl() { printf "SYSTEMCTL:%s\n" "$*" >>"$LOG"; [[ "${RSYS_RC:-0}" == "0" ]]; }'
        # 裸 nginx 的桩: 实现里若漏用目标二进制, 会被记成 BARE:, 断言直接变红
        printf '%s\n' 'nginx() { printf "BARE:%s\n" "$*" >>"$LOG"; return 1; }'
        fn_of "$COMMON" '_nginx_binary'
        fn_of "$COMMON" 'nginx_apply_config'
        printf '%s\n' 'rc=0'
        printf '%s\n' 'nginx_apply_config "${RMODE:-reload}" || rc=$?'
        printf '%s\n' 'printf "RC=%s\n" "$rc"'
    } >"$1"
}

run_apply() { # $1=场景名 (用于隔离日志)
    rm -f "$LOG"
    : >"$LOG"
    bash "$SB/apply_runner.sh" >"$SB/out" 2>&1 || true
    cat "$SB/out"
}
apply_log() { cat "$LOG" 2>/dev/null || true; }

PREFIX="$SB/prefix"
make_fake_bin "$PREFIX"
FAKEINIT="$SB/fake-init.d-nginx"
make_fake_init "$FAKEINIT"
build_apply_runner "$SB/apply_runner.sh" "$PREFIX"

echo "==== nginx_effect_path_test ===="
echo "-- [A] nginx_apply_config: 三档回退 --"

# 单一真源: nginx_apply_config 必须在 core/_common.sh —— service/ssl.sh 的签发/续期
# (改写成 ACME 挑战配置后要重新加载 nginx) 与 handler 的站点部署共用同一实现;
# 一旦有人把它搬回 handler.sh, ssl.sh 就会拿到 command not found 或长出第二份实现。
assert_contains "A0: nginx_apply_config 在 _common.sh (handler 与 ssl.sh 共用)" \
    "$(fn_of "$COMMON" 'nginx_apply_config')" 'function nginx_apply_config() {'
assert_eq "A0: handler.sh 里不再重复定义" "$(fn_of "$HANDLER" 'nginx_apply_config')" ''

# A1 unit 可用 -> 优先 systemctl reload
rm -f "$LOG"; : >"$LOG"
out="$(RUNIT=1 RRUNNING=1 RSYS_RC=0 RMODE=reload run_apply)"
assert_contains "A1 unit 可用: rc 0" "$out" 'RC=0'
assert_contains "A1 unit 可用: 用 systemctl reload" "$(apply_log)" 'SYSTEMCTL:-q reload nginx'
assert_eq "A1 unit 可用: 不再调目标二进制" "$(count_lines 'BIN:' "$LOG")" '0'

# A2 ★核心：unit 在但 reload 不被支持 (宝塔那种生成 unit) -> 回退
rm -f "$LOG"; : >"$LOG"
out="$(RUNIT=1 RRUNNING=1 RSYS_RC=1 RINIT="$FAKEINIT" RINIT_FAIL='' RMODE=reload run_apply)"
assert_contains "A2 systemctl reload 失败: 回退到 init.d" "$(apply_log)" 'INIT:reload'
assert_contains "A2 systemctl reload 失败: 整体 rc 0 (不再误判失败)" "$out" 'RC=0'

rm -f "$LOG"; : >"$LOG"
out="$(RUNIT=1 RRUNNING=1 RSYS_RC=1 RINIT='' RMODE=reload run_apply)"
assert_contains "A2 无 init.d 时: 回退到目标二进制 -s reload" "$(apply_log)" 'BIN:-s reload'
assert_contains "A2 无 init.d 时: 整体 rc 0" "$out" 'RC=0'

# A3 全不可用 -> 非 0 (调用方据此告警/报错)
rm -f "$LOG"; : >"$LOG"
out="$(RUNIT=0 RRUNNING=1 RINIT='' RBIN_FAIL='-s reload' RMODE=reload run_apply)"
assert_contains "A3 三档全失败: rc 非 0" "$out" 'RC=1'

# A4 未运行 -> 启动路径 (systemd / init.d / 裸跑目标二进制)
rm -f "$LOG"; : >"$LOG"
out="$(RUNIT=1 RRUNNING=0 RSYS_RC=0 RMODE=reload run_apply)"
assert_contains "A4 未运行: 走 systemctl start" "$(apply_log)" 'SYSTEMCTL:-q start nginx'
assert_eq "A4 未运行: 不发 reload 信号" "$(count_lines 'BIN:-s reload' "$LOG")" '0'

rm -f "$LOG"; : >"$LOG"
out="$(RUNIT=0 RRUNNING=0 RINIT="$FAKEINIT" RMODE=reload run_apply)"
assert_contains "A4 未运行+无 unit: 走 init.d start" "$(apply_log)" 'INIT:start'

rm -f "$LOG"; : >"$LOG"
out="$(RUNIT=0 RRUNNING=0 RINIT='' RMODE=reload run_apply)"
assert_contains "A4 未运行+无 unit+无 init.d: 裸跑目标二进制" "$(apply_log)" 'BIN:'
assert_contains "A4 裸跑目标二进制: rc 0" "$out" 'RC=0'

# A5 restart 模式
rm -f "$LOG"; : >"$LOG"
out="$(RUNIT=1 RRUNNING=1 RSYS_RC=0 RMODE=restart run_apply)"
assert_contains "A5 restart: 用 systemctl restart" "$(apply_log)" 'SYSTEMCTL:-q restart nginx'
assert_eq "A5 restart: 不用 reload 冒充" "$(count_lines 'reload' "$LOG")" '0'

rm -f "$LOG"; : >"$LOG"
out="$(RUNIT=0 RRUNNING=1 RINIT='' RBIN_FAIL='' RMODE=restart run_apply)"
assert_contains "A5 restart 无 unit: 先 -s stop" "$(apply_log)" 'BIN:-s stop'
assert_contains "A5 restart 无 unit: 再裸跑拉起" "$(apply_log)" 'BIN:'
assert_contains "A5 restart 无 unit: rc 0" "$out" 'RC=0'

# ---------------------------------------------------------------------------
# 驱动 T: test_and_reload_nginx —— 校验必须落在目标二进制上
# ---------------------------------------------------------------------------
build_tar_runner() { # $1=输出文件 $2=prefix
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' "NGINX_PREFIX_DIR='$2'"
        printf '%s\n' "LOG='$LOG'"
        printf '%s\n' 'ensure_nginx_support_files() { [[ "${RSUP_RC:-0}" == "0" ]]; }'
        printf '%s\n' 'nginx() { printf "BARE:%s\n" "$*" >>"$LOG"; return 1; }'
        printf '%s\n' 'nginx_apply_config() { printf "APPLY:%s\n" "${1:-}" >>"$LOG"; [[ "${RAPPLY_RC:-0}" == "0" ]]; }'
        fn_of "$COMMON" '_nginx_binary'
        fn_of "$HANDLER" 'test_and_reload_nginx'
        printf '%s\n' 'rc=0'
        printf '%s\n' 'test_and_reload_nginx || rc=$?'
        printf '%s\n' 'printf "RC=%s\n" "$rc"'
    } >"$1"
}
build_tar_runner "$SB/tar_runner.sh" "$PREFIX"

echo "-- [T] test_and_reload_nginx --"
rm -f "$LOG"; : >"$LOG"
out="$(RBIN_FAIL='' RAPPLY_RC=0 bash "$SB/tar_runner.sh" 2>&1 || true)"
assert_contains "T1 校验用目标二进制 (-t)" "$(apply_log)" 'BIN:-t'
assert_eq "T1 不用裸 nginx 校验" "$(count_lines 'BARE:' "$LOG")" '0'
assert_contains "T1 落地走 nginx_apply_config reload" "$(apply_log)" 'APPLY:reload'
assert_contains "T1 rc 0" "$out" 'RC=0'

rm -f "$LOG"; : >"$LOG"
out="$(RBIN_FAIL='-t' RAPPLY_RC=0 bash "$SB/tar_runner.sh" 2>&1 || true)"
assert_contains "T1 校验失败: rc 非 0" "$out" 'RC=1'
assert_eq "T1 校验失败: 不落地" "$(count_lines 'APPLY:' "$LOG")" '0'

rm -f "$LOG"; : >"$LOG"
out="$(RBIN_FAIL='' RAPPLY_RC=1 bash "$SB/tar_runner.sh" 2>&1 || true)"
assert_contains "T1 落地失败: rc 非 0" "$out" 'RC=1'

rm -f "$LOG"; : >"$LOG"
out="$(RSUP_RC=1 bash "$SB/tar_runner.sh" 2>&1 || true)"
assert_contains "T1 支持文件补齐失败: rc 非 0" "$out" 'RC=1'
assert_eq "T1 支持文件补齐失败: 不校验" "$(count_lines 'BIN:' "$LOG")" '0'

# ---------------------------------------------------------------------------
# 驱动 R: handler_nginx_restart —— 复查不依赖 systemctl is-active
# ---------------------------------------------------------------------------
build_restart_runner() { # $1=输出文件
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' "LOG='$LOG'"
        printf '%s\n' "CUR_FILE='handler'"
        printf '%s\n' '_i18n() { printf "%s" "$1"; }'
        printf '%s\n' '_error() { printf "ERROR:%s\n" "$*" >>"$LOG"; exit 1; }'
        printf '%s\n' 'cmd_exists() { [[ "${RHAS_NGINX:-1}" == "1" ]]; }'
        printf '%s\n' 'ensure_nginx_support_files() { return 0; }'
        printf '%s\n' 'nginx_apply_config() { printf "APPLY:%s\n" "${1:-}" >>"$LOG"; [[ "${RAPPLY_RC:-0}" == "0" ]]; }'
        printf '%s\n' '_nginx_service_unit_exists() { [[ "${RUNIT:-0}" == "1" ]]; }'
        printf '%s\n' '_nginx_is_running() { [[ "${RRUNNING:-0}" == "1" ]]; }'
        printf '%s\n' 'systemctl() { printf "SYSTEMCTL:%s\n" "$*" >>"$LOG"; [[ "${RSYS_RC:-0}" == "0" ]]; }'
        printf '%s\n' 'sleep() { :; }' # 复查轮询用, 别真等 5 秒
        fn_of "$HANDLER" 'handler_nginx_restart'
        printf '%s\n' 'rc=0'
        printf '%s\n' 'handler_nginx_restart || rc=$?'
        printf '%s\n' 'printf "RC=%s\n" "$rc"'
    } >"$1"
}
build_restart_runner "$SB/restart_runner.sh"

echo "-- [R] handler_nginx_restart --"
rm -f "$LOG"; : >"$LOG"
out="$(RAPPLY_RC=0 RRUNNING=1 RUNIT=1 RSYS_RC=0 bash "$SB/restart_runner.sh" 2>&1 || true)"
assert_contains "R1 重启走 apply('restart')" "$(apply_log)" 'APPLY:restart'
assert_contains "R1 复查通过: rc 0" "$out" 'RC=0'
assert_eq "R1 复查不再问 systemctl is-active" "$(count_lines 'is-active' "$LOG")" '0'

# unit 在但 is-active 会失败 (生成 unit 的常态) —— 复查仍必须通过
rm -f "$LOG"; : >"$LOG"
out="$(RAPPLY_RC=0 RRUNNING=1 RUNIT=1 RSYS_RC=1 bash "$SB/restart_runner.sh" 2>&1 || true)"
assert_contains "R1 is-active 失败也不影响复查 (目标进程在跑)" "$out" 'RC=0'

rm -f "$LOG"; : >"$LOG"
out="$(RAPPLY_RC=0 RRUNNING=0 RUNIT=1 RSYS_RC=0 bash "$SB/restart_runner.sh" 2>&1 || true)"
assert_contains "R1 进程没起来: _error verify_failed" "$(apply_log)" 'ERROR:.handler.nginx.verify_failed'

rm -f "$LOG"; : >"$LOG"
out="$(RAPPLY_RC=1 RRUNNING=1 RUNIT=1 RSYS_RC=0 bash "$SB/restart_runner.sh" 2>&1 || true)"
assert_contains "R1 apply 失败: _error verify_failed" "$(apply_log)" 'ERROR:.handler.nginx.verify_failed'

rm -f "$LOG"; : >"$LOG"
out="$(RAPPLY_RC=0 RRUNNING=1 RUNIT=0 RSYS_RC=0 bash "$SB/restart_runner.sh" 2>&1 || true)"
assert_eq "R2 无 systemd unit: 全程不碰 systemctl" "$(count_lines 'SYSTEMCTL:' "$LOG")" '0'
assert_contains "R2 无 systemd unit: 仍 rc 0" "$out" 'RC=0'

rm -f "$LOG"; : >"$LOG"
out="$(RHAS_NGINX=0 bash "$SB/restart_runner.sh" 2>&1 || true)"
assert_contains "R2 未安装: 明确报 not_installed" "$(apply_log)" 'ERROR:.handler.nginx.not_installed'

# ---------------------------------------------------------------------------
# 驱动 N1: _nginx_is_running —— 用**真实进程**验证真身判据
# ---------------------------------------------------------------------------
build_running_runner() { # $1=输出文件
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' 'cmd_exists() { command -v "$1" >/dev/null 2>&1; }'
        fn_of "$COMMON" '_nginx_binary'
        fn_of "$COMMON" '_nginx_is_running'
        printf '%s\n' 'if _nginx_is_running; then printf "RUNNING\n"; else printf "NOT_RUNNING\n"; fi'
    } >"$1"
}
build_running_runner "$SB/running_runner.sh"

SELF="$SB/self"
OTHER="$SB/other"
XRAY="$SB/xray"
ABSENT="$SB/absent"
mkdir -p "$SELF/sbin" "$OTHER/sbin" "$XRAY/sbin"
# 用 /bin/sleep 的副本冒充 nginx: 进程的 exe 真身就等于这个路径, 可被 ps -C nginx 命中
cp /bin/sleep "$SELF/sbin/nginx"
cp /bin/sleep "$OTHER/sbin/nginx"

echo "-- [N1] _nginx_is_running (真实进程) --"
out="$(NGINX_PREFIX_DIR="$SELF" bash "$SB/running_runner.sh" 2>&1 || true)"
assert_contains "N1 无 nginx 进程: 判未运行" "$out" 'NOT_RUNNING'

"$SELF/sbin/nginx" 30 &
bg1=$!
BGPIDS="${BGPIDS} ${bg1}"
sleep 0.4
out="$(NGINX_PREFIX_DIR="$SELF" bash "$SB/running_runner.sh" 2>&1 || true)"
assert_contains "N1 目标那份在跑: 判运行" "$out" 'RUNNING'
out="$(cd "$SB" && NGINX_PREFIX_DIR='self' bash "$SB/running_runner.sh" 2>&1 || true)"
assert_contains "N1 相对前缀: 仍须判运行 (真身比对要做路径归一)" "$out" 'RUNNING'
out="$(NGINX_PREFIX_DIR="$XRAY" bash "$SB/running_runner.sh" 2>&1 || true)"
assert_contains "N1 只有别家同名二进制在跑: 目标判未运行" "$out" 'NOT_RUNNING'
out="$(NGINX_PREFIX_DIR="$ABSENT" bash "$SB/running_runner.sh" 2>&1 || true)"
assert_contains "N1 前缀下没有二进制: 判未运行" "$out" 'NOT_RUNNING'

kill "$bg1" 2>/dev/null || true
wait "$bg1" 2>/dev/null || true
out="$(NGINX_PREFIX_DIR="$SELF" bash "$SB/running_runner.sh" 2>&1 || true)"
assert_contains "N1 进程退出后: 判未运行" "$out" 'NOT_RUNNING'

# ---------------------------------------------------------------------------
# 负向校验
# ---------------------------------------------------------------------------
echo "-- [NEG] 负向校验 --"
# 两条变异都落在 core/_common.sh (搬迁后两处实现同在此文件): (a) 动 nginx_apply_config,
# (b) 动 _nginx_is_running。各写一份原文副本 + 各用独立输出文件, 互不干扰。
COMMON_BAK="$SB/_common_orig.sh"
cp "$COMMON" "$COMMON_BAK"

neg_mutate() { # $1=源文件(原文副本) $2=mode $3=输出文件
    python3 - "$1" "$3" "$2" <<'PY'
import pathlib
import sys

# argv: [0]='-' [1]=源文件 [2]=输出文件 [3]=mode
src = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
out_path = sys.argv[2]
mode = sys.argv[3]
if mode == 'no_bin_reload_fallback':
    old = """    if [[ "${op}" == 'reload' ]]; then
        # 与托管方式完全无关的一条: 直接给目标那份发重载信号 (pid 取自它自己的配置)
        if "${bin}" -s reload; then return 0; fi
"""
    new = """    if [[ "${op}" == 'reload' ]]; then
        : # NEG: 兜底已移除
"""
elif mode == 'running_by_name':
    old = """        if [[ -n "${exe}" && "${exe}" == "${bin}" ]]; then
            return 0
        fi"""
    new = """        if [[ -n "${exe}" ]]; then
            return 0
        fi"""
else:
    raise SystemExit('unknown mode: ' + mode)
if old not in src:
    raise SystemExit('NEG 改写未命中 (实现已演进, 需更新锚点): ' + mode)
src = src.replace(old, new, 1)
pathlib.Path(out_path).write_text(src, encoding='utf-8')
PY
}

# (a) 删掉 -s reload 兜底 -> A2 那条"无 init.d 时回退到目标二进制"必须变红
if neg_mutate "$COMMON_BAK" 'no_bin_reload_fallback' "$SB/_common_neg_a.sh"; then
    if cmp -s "$COMMON_BAK" "$SB/_common_neg_a.sh"; then
        bad "NEG(a) 变异未落地 (文件与原文一致)"
    else
        ok "NEG(a) 变异已落地"
        COMMON="$SB/_common_neg_a.sh"
        build_apply_runner "$SB/apply_neg.sh" "$PREFIX"
        rm -f "$LOG"; : >"$LOG"
        out="$(RUNIT=1 RRUNNING=1 RSYS_RC=1 RINIT='' RBIN_FAIL='' RMODE=reload bash "$SB/apply_neg.sh" 2>&1 || true)"
        assert_not_contains "NEG(a) 破损版: 不再回退到 -s reload" "$(apply_log)" 'BIN:-s reload'
        assert_contains "NEG(a) 破损版: 直接判失败 (证明 A2 非恒真)" "$out" 'RC=1'
        COMMON='core/_common.sh'
    fi
else
    bad "NEG(a) 改写未生效"
fi

# (b) 丢掉真身比对 (只按进程名判) -> "只有别家二进制在跑" 必须被误判为运行
if neg_mutate "$COMMON_BAK" 'running_by_name' "$SB/_common_neg.sh"; then
    if cmp -s "$COMMON_BAK" "$SB/_common_neg.sh"; then
        bad "NEG(b) 变异未落地 (文件与原文一致)"
    else
        ok "NEG(b) 变异已落地"
        COMMON="$SB/_common_neg.sh"
        build_running_runner "$SB/running_neg.sh"
        "$OTHER/sbin/nginx" 30 &
        bg2=$!
        BGPIDS="${BGPIDS} ${bg2}"
        sleep 0.4
        out="$(NGINX_PREFIX_DIR="$XRAY" bash "$SB/running_neg.sh" 2>&1 || true)"
        assert_contains "NEG(b) 破损版把'别家在跑'误判为运行 (证明 N1 非恒真)" "$out" 'RUNNING'
        kill "$bg2" 2>/dev/null || true
        wait "$bg2" 2>/dev/null || true
        COMMON='core/_common.sh'
    fi
else
    bad "NEG(b) 改写未生效"
fi

echo
echo "==== nginx_effect_path_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
