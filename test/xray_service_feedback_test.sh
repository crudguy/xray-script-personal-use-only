#!/usr/bin/env bash
# =============================================================================
# 测试名称: xray_service_feedback_test.sh
# 测试目标: 主菜单 4/5/6 (启动 / 停止 / 重启) 三条服务臂的执行反馈 ——
#           handler_start / handler_stop / handler_restart, 以及它们新依赖的
#           _xray_unit_exists / _xray_autostart_text, plus main.sh 的暂停挂载。
#
# 为什么需要本测试 (用户可见缺陷):
#   这三条臂原实现全程 `systemctl -q` 静默, **成功路径一个字都不打印**。交互场景下的
#   后果不是"输出少", 而是"看起来根本没执行": 用户选 4 → 屏幕无任何变化 → 下一帧
#   菜单重绘 (banner+状态+菜单约 33 行) 把上面一屏顶走 → 用户以为脚本卡住或没生效。
#   又因为都没打印, **误报与漏报同形态**: 端口被占导致没起来、Xray 压根没装,
#   在界面上都等于"静默"。所以本测试锁的不是 rc, 而是"每种结局都有一句人话":
#
#   [1] 四条结局必须各有输出: 正在做 / 早已如此(幂等) / 做成了 / 没做成(含排查建议)。
#       断言方式是把 print_* 的输出字符串作为契约 —— 这也是它们唯一能被观测的方式。
#   [2] stop 必须有"停止后复查": 旧实现发完 systemctl stop 就直接记审计成功,
#       进程僵住时会误报"已停止"。这里用一个可注入失败的 systemctl shim 抓它。
#   [3] unit 缺失要尽早报错: systemctl 对"unit 不存在"和"启动失败"都返回非 0,
#       不前置 `systemctl cat` 拦截, 用户只会先白等 5 秒轮询再看一句泛化错误。
#   [4] 占位符必须真的被替换: 结果行带 ${autostart}, 若哪天退化成未替换的字面量,
#       用户会看到"开机自启: ${autostart}" —— 这条专门盯着它。
#
# 沙箱方式: systemctl 换成有状态 shim (active/enabled 各自一个文件, start/stop/
#           restart 的可失败性由环境变量注入); sleep 换成 no-op, 免得失败用例真等 5 秒。
#           函数体用 awk 从源码抽取后 eval 注入 (不 source 整个 handler.sh, 它末尾会 main)。
#
# 锁定不变量:
#   [A] handler_start
#     T1  未运行 -> 打印 starting + 结果行, 且服务变为 active
#     T2  开机自启未启用时自动 enable, 结果行显示 autostart_yes
#     T3  结果行的 ${autostart} 占位符已被真实替换 (不含字面量)
#     T4  已在运行 -> 打印 start_already, 不打印 starting, 且不调用 systemctl start
#     T5  unit 缺失 -> 直接报 no_unit, 且不发任何 systemctl 动作
#     T6  start 失败 -> 报 start.verify_failed + fail_hint, rc 非 0
#   [B] handler_stop
#     T7  运行中 -> 打印 stopping + 结果行(autostart_no, 因顺带 disable), rc 0
#     T8  未运行 -> 打印 stop_already, 不打印 stopping, 且不调用 systemctl stop
#     T9  unit 缺失 -> 报 no_unit
#     T10 stop 失败 -> 报 stop.verify_failed (旧实现在此误报成功!)
#   [C] handler_restart
#     T11 运行中 -> 打印 restarting + 结果行, 且调用的是 restart
#     T12 未运行 -> 打印 restart_to_start, 退化为 start (不调用 restart)
#     T13 重启前先 self-heal mKCP finalmask (heal_mkcp_finalmask 被调用)
#     T14 unit 缺失 -> 报 no_unit
#     T15 restart 失败 -> 报 restart.verify_failed + fail_hint
#   [D] main.sh 交互/非交互分层
#     D1  菜单 4/5/6 执行后都挂 _pause_after_action (否则结果行被重绘顶走)
#     D2  CLI 直达入口 --start/--stop/--restart 保持不挂暂停 (要能进 cron)
#   [E] i18n 供给
#     E1  zh/en 双份都得有本次新增的键且非空 (漏译会让这些反馈整句变空白)
#
# 负向校验 (NEG): 见文件末尾 —— 逐条把源码改坏, 确认上面的断言真的会红。
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$REPO"

HANDLER_SRC="core/handler.sh"
MAIN_SRC="core/main.sh"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available in this environment"
    exit 0
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1 (期望 [$3] 实际 [$2])"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1 (未包含 [$3]，实际 [$2])"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1 (不应包含 [$3]，实际 [$2])"; fi; }
getfile() { if [[ -f "$1" ]]; then cat "$1"; else printf ''; fi; }

SB=".workbuddy/tmp/svcfb.$$"

# ---------------------------------------------------------------------------
# 沙箱: systemctl / sleep shim
#   systemctl shim 是**有状态**的: $SB/st.active 存 active|inactive(其它一律视为停),
#   $SB/st.enabled 存 yes|no。所有调用写 $SB/sys.log, 便于断言"到底有没有真的去 stop"。
#   失败注入: SVC_START_FAIL / SVC_STOP_FAIL / SVC_RESTART_FAIL / SVC_ENABLE_FAIL
#             SVC_NO_UNIT (连 unit 都没有; cat 返回非 0, is-active/is-enabled 一律失败)
# ---------------------------------------------------------------------------
mk_sandbox() {
    rm -rf "$SB"
    mkdir -p "$SB/bin"
    cat >"$SB/bin/systemctl" <<SHIM
#!/usr/bin/env bash
LOG="$PWD/$SB/sys.log"
ACT="$PWD/$SB/st.active"
ENA="$PWD/$SB/st.enabled"
args=()
for a in "\$@"; do
    [[ "\$a" == '-q' ]] && continue
    args+=("\$a")
done
set -- "\${args[@]}"
verb="\${1:-}"
printf 'CALL:%s\n' "\$verb" >>"\$LOG"
[[ "\${SVC_NO_UNIT:-}" == '1' ]] && exit 1
active() { [[ -f "\$ACT" && "\$(cat "\$ACT")" == 'active' ]]; }
case "\$verb" in
# 注: 每个分支都要自己退出 —— 若落到 esac 之后的统一 exit 0, 查询动作会恒为"是"
#     (曾导致 is-active 永远返回 0, 于是 start 幂等分支与 restart 分支全被跳过, 断言假绿)。
cat)        exit 0 ;;
is-active)  active; exit \$? ;;
is-enabled) [[ -f "\$ENA" && "\$(cat "\$ENA")" == 'yes' ]]; exit \$? ;;
enable)     [[ "\${SVC_ENABLE_FAIL:-}" == '1' ]] && exit 1
            printf 'yes\n' >"\$ENA"; exit 0 ;;
disable)    printf 'no\n' >"\$ENA"; exit 0 ;;
start)      [[ "\${SVC_START_FAIL:-}" == '1' ]] && { printf 'inactive\n' >"\$ACT"; exit 1; }
            printf 'active\n' >"\$ACT"; exit 0 ;;
stop)       [[ "\${SVC_STOP_FAIL:-}" == '1' ]] && { printf 'active\n' >"\$ACT"; exit 1; }
            printf 'inactive\n' >"\$ACT"; exit 0 ;;
restart)    [[ "\${SVC_RESTART_FAIL:-}" == '1' ]] && { printf 'inactive\n' >"\$ACT"; exit 1; }
            printf 'active\n' >"\$ACT"; exit 0 ;;
esac
exit 0
SHIM
    cat >"$SB/bin/sleep" <<'SHIM'
#!/usr/bin/env bash
# no-op: 轮询等待在测试里不需要真等 (失败路径原本会 sleep 5 秒)
exit 0
SHIM
    chmod +x "$SB/bin/systemctl" "$SB/bin/sleep"
    reset_state inactive yes
    : >"$SB/sys.log"
}

# $1=active|inactive  $2=yes|no(开机自启)
reset_state() { printf '%s\n' "$1" >"$SB/st.active"; printf '%s\n' "$2" >"$SB/st.enabled"; }

# ---------------------------------------------------------------------------
# 抽取真函数体
# ---------------------------------------------------------------------------
extract_fn() { awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' "$1"; }

unit_fn="$(extract_fn "${HANDLER_SRC}" _xray_unit_exists)"
auto_fn="$(extract_fn "${HANDLER_SRC}" _xray_autostart_text)"
start_fn="$(extract_fn "${HANDLER_SRC}" handler_start)"
stop_fn="$(extract_fn "${HANDLER_SRC}" handler_stop)"
restart_fn="$(extract_fn "${HANDLER_SRC}" handler_restart)"
i18nsub_fn="$(extract_fn core/_common.sh _i18n_sub)"

for pair in "unit_fn:_xray_unit_exists" "auto_fn:_xray_autostart_text" \
    "start_fn:handler_start" "stop_fn:handler_stop" "restart_fn:handler_restart" \
    "i18nsub_fn:_i18n_sub"; do
    v="${pair%%:*}"
    if [[ -z "${!v}" ]]; then
        echo "SKIP: 抽取 ${pair#*:} 失败 (源码结构变了?)"
        exit 0
    fi
done

# ---------------------------------------------------------------------------
# 驱动: 在子 shell 里装配桩件后跑目标函数。
#   _i18n 桩返回键名本身; 但三条 *_done 文案返回带 ${autostart} 占位符的假体,
#   这样既能看到"走了哪条文案", 又能验证占位符被 _i18n_sub 真的替换掉了。
# ---------------------------------------------------------------------------
run_svc() { # $1=start|stop|restart
    (
        export PATH="$PWD/$SB/bin:$PATH"
        # shellcheck disable=SC2034
        XRAY_CONFIG_PATH="$PWD/$SB/no-such-config.json"
        _i18n() {
            case "${1#.}" in
            handler.svc.start_done | handler.svc.stop_done | handler.svc.restart_done)
                printf '%s' 'RESULT[${autostart}]' ;;
            *) printf '%s' "${1#.}" ;;
            esac
        }
        print_info() { printf 'INFO:%s\n' "$*"; }
        print_pass() { printf 'PASS:%s\n' "$*"; }
        print_warn() { printf 'WARN:%s\n' "$*"; }
        _error() {
            printf 'ERR:%s\n' "$1"
            [[ -n "${2:-}" ]] && printf 'HINT:%s\n' "$2"
            exit "${MOCK_RC:-1}"
        }
        _ensure_xray_runtime_dirs() { :; }
        heal_mkcp_finalmask() { printf 'HEAL:mkcp\n'; }
        _audit_log() { printf 'AUDIT:%s\n' "$1" >>"$PWD/$SB/audit.log"; :; }
        eval "$i18nsub_fn"
        eval "$unit_fn"
        eval "$auto_fn"
        eval "$start_fn"
        eval "$stop_fn"
        eval "$restart_fn"
        "handler_$1"
    )
}

drive() { # $1=start|stop|restart; 环境由调用方注入 -> 设 $OUT/$RC
    # 只跑**一次**: 目标函数会改变 shim 状态 (start 后变 active), 跑两次的话
    # 第二次是在被第一次改过的状态上执行 —— 日志里会冒出本不该出现的动作,
    # rc 也不再对应上一次可惜的动作 (这个坑本身就会制造假绿)。
    local raw rcx=0
    raw="$(run_svc "$1" 2>&1)" || rcx=$?
    OUT="$raw"
    RC="$rcx"
}
syslog() { getfile "$SB/sys.log"; }

echo "=== Xray 服务启停反馈测试 ==="

# ---------------------------------------------------------------------------
echo "-- [A] handler_start --"
mk_sandbox
reset_state inactive no
drive start
assert_contains "T1 未运行: 打印正在启动" "$OUT" 'INFO:handler.svc.starting'
assert_contains "T1 未运行: 打印结果行" "$OUT" 'PASS:RESULT['
assert_eq "T1 未运行: rc 0" "$RC" '0'
assert_eq "T1 未运行: 服务进入 active" "$(cat "$SB/st.active")" 'active'

mk_sandbox
reset_state inactive no
drive start
assert_contains "T2 自启缺失时自动 enable -> 结果行显示已启用" "$OUT" 'PASS:RESULT[handler.svc.autostart_yes]'
assert_contains "T2 确实调用了 systemctl enable" "$(syslog)" 'CALL:enable'

assert_not_contains "T3 结果行不含未替换的占位符" "$OUT" '${autostart}'

mk_sandbox
reset_state active yes
drive start
assert_contains "T4 已运行: 打印幂等提示" "$OUT" 'INFO:handler.svc.start_already'
assert_not_contains "T4 已运行: 不打印正在启动" "$OUT" 'INFO:handler.svc.starting'
assert_not_contains "T4 已运行: 不重复 systemctl start" "$(syslog)" 'CALL:start'

mk_sandbox
reset_state inactive yes
SVC_NO_UNIT=1 drive start
assert_contains "T5 unit 缺失: 报 no_unit" "$OUT" 'ERR:handler.svc.no_unit'
assert_eq "T5 unit 缺失: rc 非 0" "$RC" '1'
assert_not_contains "T5 unit 缺失: 不发起停动作" "$(syslog)" 'CALL:start'

mk_sandbox
reset_state inactive yes
SVC_START_FAIL=1 drive start
assert_contains "T6 启动失败: 报复查未通过" "$OUT" 'ERR:handler.start.verify_failed'
assert_contains "T6 启动失败: 附排查建议" "$OUT" 'HINT:handler.svc.fail_hint'
assert_eq "T6 启动失败: rc 非 0" "$RC" '1'

# ---------------------------------------------------------------------------
echo "-- [B] handler_stop --"
mk_sandbox
reset_state active yes
drive stop
assert_contains "T7 运行中: 打印正在停止" "$OUT" 'INFO:handler.svc.stopping'
assert_contains "T7 运行中: 结果行显示自启已禁用" "$OUT" 'PASS:RESULT[handler.svc.autostart_no]'
assert_eq "T7 运行中: 服务已停" "$(cat "$SB/st.active")" 'inactive'
assert_eq "T7 运行中: rc 0" "$RC" '0'

mk_sandbox
reset_state inactive no
drive stop
assert_contains "T8 未运行: 打印无需停止" "$OUT" 'INFO:handler.svc.stop_already'
assert_not_contains "T8 未运行: 不打印正在停止" "$OUT" 'INFO:handler.svc.stopping'
assert_not_contains "T8 未运行: 不调用 systemctl stop" "$(syslog)" 'CALL:stop'

mk_sandbox
reset_state active yes
SVC_NO_UNIT=1 drive stop
assert_contains "T9 unit 缺失: 报 no_unit" "$OUT" 'ERR:handler.svc.no_unit'

mk_sandbox
reset_state active yes
SVC_STOP_FAIL=1 drive stop
assert_contains "T10 停止失败: 报复查未通过 (旧实现在此误报成功)" "$OUT" 'ERR:handler.stop.verify_failed'
assert_eq "T10 停止失败: rc 非 0" "$RC" '1'

# ---------------------------------------------------------------------------
echo "-- [C] handler_restart --"
mk_sandbox
reset_state active yes
drive restart
assert_contains "T11 运行中: 打印正在重启" "$OUT" 'INFO:handler.svc.restarting'
assert_contains "T11 运行中: 结果行显示自启已启用" "$OUT" 'PASS:RESULT[handler.svc.autostart_yes]'
assert_contains "T11 运行中: 真的调用了 restart" "$(syslog)" 'CALL:restart'
assert_eq "T11 运行中: rc 0" "$RC" '0'

mk_sandbox
reset_state inactive no
drive restart
assert_contains "T12 未运行: 说明改为启动" "$OUT" 'INFO:handler.svc.restart_to_start'
assert_not_contains "T12 未运行: 不调用 restart" "$(syslog)" 'CALL:restart'
assert_contains "T12 未运行: 退化为 start" "$(syslog)" 'CALL:start'

mk_sandbox
reset_state active yes
drive restart
assert_contains "T13 重启前先自愈 mKCP finalmask" "$OUT" 'HEAL:mkcp'

mk_sandbox
reset_state active yes
SVC_NO_UNIT=1 drive restart
assert_contains "T14 unit 缺失: 报 no_unit" "$OUT" 'ERR:handler.svc.no_unit'

mk_sandbox
reset_state active yes
# 注: 真实链路里 `restart` 失败后会走 `|| systemctl start xray` 兜底 —— 只让 restart 失败
# 会被兜底救回来并报成功, 所以"起不来"必须是两条路都失败 (端口被占正是这个形态)。
SVC_RESTART_FAIL=1 SVC_START_FAIL=1 drive restart
assert_contains "T15 重启失败: 报复查未通过" "$OUT" 'ERR:handler.restart.verify_failed'
assert_contains "T15 重启失败: 附排查建议" "$OUT" 'HINT:handler.svc.fail_hint'
assert_eq "T15 重启失败: rc 非 0" "$RC" '1'

# ---------------------------------------------------------------------------
echo "-- [D] main.sh 交互/非交互分层 --"
# 只取主菜单 processes_index 的 case 块: 8 空格缩进的 "4) exec_handler" 在
# 多个子菜单里都有 (配置管理/BBR/自定义站点...), 全仓匹配会把它们一并算进来。
awk '/^function processes_index\(\)/ { g = 1 } g { print } g && /^        esac$/ { exit }' "${MAIN_SRC}" >"$SB/index_case"

assert_eq "D1a 主菜单 4/5/6 三行齐备" "$(grep -cE "^        (4|5|6)\) exec_handler" "$SB/index_case")" '3'
assert_eq "D1b 菜单 4/5/6 三行都挂了暂停" "$(grep -cE "^        (4|5|6)\) exec_handler.*_pause_after_action" "$SB/index_case")" '3'
for pair in "4:--start" "5:--stop" "6:--restart"; do
    n="${pair%%:*}"
    p="${pair#*:}"
    grep -Eq "^        ${n}\) exec_handler '${p}'; _pause_after_action ;;" "${MAIN_SRC}" &&
        ok "D1-${n} 菜单 ${n} 挂暂停" || bad "D1-${n} 菜单 ${n} 未挂暂停"
done
for p in --start --stop --restart; do
    grep -Eq "^    ${p}\) exec_handler '${p}' ;;" "${MAIN_SRC}" &&
        ok "D2 ${p} CLI 入口保持无暂停" || bad "D2 ${p} CLI 入口缺少转发或被加了暂停"
done

echo "-- [E] i18n 供给 --"
python3 - <<'PY'
import json, pathlib, sys

KEYS = {
    'handler.svc': ['starting', 'stopping', 'restarting', 'start_already', 'stop_already',
                    'restart_to_start', 'start_done', 'stop_done', 'restart_done',
                    'autostart_yes', 'autostart_no', 'no_unit', 'fail_hint'],
    'handler.stop': ['verify_failed'],
}
bad = 0
for lang in ('zh', 'en'):
    d = json.loads(pathlib.Path(f'i18n/{lang}.json').read_text(encoding='utf-8'))
    for seg, keys in KEYS.items():
        cur = d
        for part in seg.split('.'):
            cur = cur.get(part, {})
        for k in keys:
            if not isinstance(cur.get(k), str) or not cur[k].strip():
                print(f'  [FAIL] E1 {lang}.json 缺键或为空: {seg}.{k}')
                bad = 1
sys.exit(1) if bad else print(None)
PY
if [[ $? -eq 0 ]]; then ok "E1 zh/en 双份 i18n 键齐备且非空"; else FAIL=$((FAIL + 1)); fi

# ---------------------------------------------------------------------------
# 负向校验 (NEG): 把源码改坏, 确认上面的断言真的会红
# ---------------------------------------------------------------------------
if [[ -z "${SKIP_NEG:-}" ]]; then
    gen_neg() { # $1=变异名
        python3 - "$1" <<'PY' || return 1
import pathlib
import sys

# 每条变异必须落在指定函数体内 —— 防止锚点命中全仓同名的另一处
TARGET = {
    'drop_starting_info': 'handler_start',
    'drop_done_pass': 'handler_start',
    'drop_unit_check': 'handler_start',
    'autostart_not_substituted': 'handler_start',
    'swap_stop_branches': 'handler_stop',
    'drop_stop_verify': 'handler_stop',
    'restart_no_restarting': 'handler_restart',
    'restart_no_hint': 'handler_restart',
}


def fn_body(text, name):
    out, g = [], False
    for line in text.splitlines():
        if line.startswith('function %s() {' % name):
            g = True
        if g:
            out.append(line)
        if g and line == '}':
            break
    return '\n'.join(out)


mode = sys.argv[1]
src_h = pathlib.Path('core/handler.sh').read_text()
src_m = pathlib.Path('core/main.sh').read_text()

if mode == 'menu_no_pause':
    s = src_m.replace("        4) exec_handler '--start'; _pause_after_action ;;",
                      "        4) exec_handler '--start' ;;", 1)
    if s == src_m:
        raise SystemExit('改写未生效: ' + mode)
    pathlib.Path('core/_neg_main.sh').write_text(s)
    sys.exit(0)

s = src_h
if mode == 'drop_starting_info':
    s = s.replace("""    else
        print_info "$(_i18n '.handler.svc.starting')"
    fi""", """    else
        :
    fi""", 1)
elif mode == 'drop_done_pass':
    s = s.replace("""    print_pass "$(_i18n_sub '.handler.svc.start_done' '${autostart}' "$(_xray_autostart_text)")"
""", "", 1)
elif mode == 'drop_unit_check':
    s = s.replace("""    _xray_unit_exists || _error "$(_i18n '.handler.svc.no_unit')"
    local was_active='n'""", """    local was_active='n'""", 1)
elif mode == 'autostart_not_substituted':
    # 结果行改用 _i18n 而非 _i18n_sub: 占位符不再被替换, 用户会看到字面 ${autostart}
    s = s.replace('''_i18n_sub '.handler.svc.start_done' '${autostart}' "$(_xray_autostart_text)"''',
                  '''_i18n '.handler.svc.start_done''', 1)
elif mode == 'swap_stop_branches':
    s = s.replace("""    if [[ "${was_active}" == 'y' ]]; then
        print_info "$(_i18n '.handler.svc.stopping')"
    else
        print_info "$(_i18n '.handler.svc.stop_already')"
    fi""", """    if [[ "${was_active}" == 'y' ]]; then
        print_info "$(_i18n '.handler.svc.stop_already')"
    else
        print_info "$(_i18n '.handler.svc.stopping')"
    fi""", 1)
elif mode == 'drop_stop_verify':
    s = s.replace("""    if systemctl -q is-active xray; then
        _audit_log 'stop.failed' 'xray'
        _error "$(_i18n '.handler.stop.verify_failed')" "$(_i18n '.handler.svc.fail_hint')"
    fi""", """    :""", 1)
elif mode == 'restart_no_restarting':
    s = s.replace("""        print_info "$(_i18n '.handler.svc.restarting')\"""", """        :""", 1)
elif mode == 'restart_no_hint':
    s = s.replace("""_error "$(_i18n '.handler.restart.verify_failed')" "$(_i18n '.handler.svc.fail_hint')\"""",
                  """_error "$(_i18n '.handler.restart.verify_failed')\"""", 1)
else:
    raise SystemExit('unknown mode: ' + mode)

if s == src_h:
    raise SystemExit('改写未生效 (原文未命中): ' + mode)
tgt = TARGET[mode]
if fn_body(s, tgt) == fn_body(src_h, tgt):
    raise SystemExit('改写未落在 %s 上 (锚点命中了别处): %s' % (tgt, mode))
pathlib.Path('core/_neg_handler.sh').write_text(s)
PY
        case "$1" in
        menu_no_pause)
            sed -e 's#core/main.sh#core/_neg_main.sh#g' test/xray_service_feedback_test.sh >test/neg_tmp_svcfb_test.sh ;;
        *)
            sed -e 's#core/handler.sh#core/_neg_handler.sh#g' test/xray_service_feedback_test.sh >test/neg_tmp_svcfb_test.sh ;;
        esac
    }

    neg_run() { # $1=说明
        local out n
        out="$(cd "$REPO" && SKIP_NEG=1 bash "test/neg_tmp_svcfb_test.sh" 2>&1 || true)"
        n="$(printf '%s\n' "$out" | grep -c '\[FAIL\]' || true)"
        if [[ "$n" != '0' ]]; then
            ok
        else
            bad "NEG $1 应检出失败, 实际 0 条 (断言恒绿!)"
        fi
    }

    for spec in \
        'drop_starting_info|启动时不打印"正在启动"' \
        'drop_done_pass|启动成功不打印结果摘要' \
        'drop_unit_check|去掉 unit 缺失前置检查' \
        'autostart_not_substituted|结果行占位符不再替换' \
        'swap_stop_branches|停止两分支文案对调' \
        'drop_stop_verify|去掉停止后复查 (误报成功)' \
        'restart_no_restarting|重启时不打印"正在重启"' \
        'restart_no_hint|重启失败不给排查建议' \
        'menu_no_pause|菜单 4 不再暂停'; do
        m="${spec%%|*}"
        d="${spec#*|}"
        if gen_neg "$m" 2>/dev/null; then neg_run "$d"; else bad "NEG 改写未生效: $m"; fi
    done

    rm -f core/_neg_handler.sh core/_neg_main.sh test/neg_tmp_svcfb_test.sh
fi

rm -rf "$SB"

echo "---"
echo "==== xray_service_feedback_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" == '0' ]]
