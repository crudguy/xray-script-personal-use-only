#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_renew_web_cron_arm_test.sh
# 测试目标: 四条此前零覆盖的"短臂"回归 —— handler_renew_ssl / handler_web /
#           handler_nginx_cron / handler_nginx_stop。
#
# 为什么需要本测试 (审计背景):
#   这四条都是"三五行代码、但每行都是一个契约"的类型, 正是最容易被顺手改坏的位置:
#     - handler_renew_ssl 是**顺序契约**: 必须先签后重启。证书没续上就重启 nginx, 会把
#       一份指向已过期证书的站点重新拉起来, 表现成"刚续完期结果站点还是红的"。
#       同理, nginx 没起来就不该去动 xray —— 否则故障面从一个服务扩成两个。
#     - handler_web 是**记账契约**: 它把 web 类型写进配置并 persist。服务没起来就记账,
#       下次体检会认为"web 已就绪", 而实际是死的。
#     - handler_nginx_cron 是**幂等契约**: 同一个菜单项在"开"与"关"之间来回切, 每次都
#       要能落到正确一侧; 且它读写的是用户**真实 crontab**, 误清空 = 别人的定时任务
#       一起没了 (去重 awk 和移除后的 `|| true` 就是为这个兜的)。
#     - handler_nginx_stop 是**容忍契约**: 非 SNI 模式切换会走到它, 而此时往往压根没装
#       nginx。这里任何一个 systemctl 非 0 都必须在 set -e 下被吸收掉。
#
# 锁定不变量:
#   [A] handler_renew_ssl
#     T1  顺序恒为 --renew -> nginx_restart -> xray_restart
#     T2  成功: rc 0 且无 ERROR
#     T3  --renew 失败 -> _error, 且**不**重启 nginx / xray (不扩大故障面)
#     T4  nginx 重启失败 -> _error, 且**不**重启 xray
#     T5  xray 重启失败 -> _error (前两步都已发生)
#   [B] handler_web
#     T6  顺序恒为 nginx_restart -> xray_restart -> persist
#     T7  入参缺省 -> 落盘 .nginx.web = normal
#     T8  入参 'foo' -> 落盘 foo (不得写死 normal)
#     T9  落盘保留原有字段
#     T10 nginx 重启失败 -> 不 persist (服务没起不能记账)
#     T11 xray 重启失败 -> 不 persist
#   [C] handler_nginx_cron (.nginx.version 是"nginx 是否装过"的判据)
#     T12 version 为 null -> 视作未安装: 不碰 crontab / 不 chmod
#     T13 version 键缺失 -> 同上
#     T14 version 为空串 -> 同上
#     T15 已安装 + 无既有任务 -> chmod a+x + 追加每日 3:00 任务, 打印 open_cron
#     T16 追加行内容精确 (含 --update --brotli 与静默重定向)
#     T17 无 crontab 时 (crontab -l 退出 1) 仍写入成功, rc 0
#     T18 保留既有条目, 新任务追加在末尾
#     T19 既有重复条目被去重 (awk '!x[$0]++')
#     T20 已安装 + 已有任务 -> 只移除该任务, 保留其它, 打印 close_cron, 不 chmod
#     T21 移除后为空 -> 写入空内容且 rc 0 (grep 无输出退出 1 由 || true 兜住)
#     T22 chmod 发生在写 crontab 之前
#   [D] handler_nginx_stop
#     T23 未安装 -> 提示 not_installed, 零 systemctl 调用, rc 0
#     T24 active + enabled -> stop + disable
#     T25 未 active + enabled -> 不 stop, 仍 disable
#     T26 active + 未 enable -> stop, 不 disable
#     T27 两者都不是 -> 都不做, rc 0
#     T28 stop 命令本身失败 -> rc 仍为 0 (容忍)
#     T29 disable 命令本身失败 -> rc 仍为 0 (容忍)
#
# 实现备注:
#   - 失败路径经 _error **exit 1** 或 set -e 中断, 一律在子 shell 里跑, 调用轨迹 / 退出
#     码 / 落盘配置经**文件**回传。
#   - crontab / chmod / systemctl 用 PATH shim 接管: 既不碰真实系统状态, 又能观测到
#     "有没有调用" 与 "调用顺序" (只看最终文件内容证不了"没碰过")。
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$REPO"

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available in this environment"
    exit 0
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1 (期望 [$3] 实际 [$2])"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1 (未包含 [$3]，实际 [$2])"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1 (不应包含 [$3]，实际 [$2])"; fi; }
count_lines() { # $1=pattern (允许以 - 开头) $2=文件
    if [[ -f "$2" ]]; then
        grep -c -- "$1" "$2" || true
    else
        printf '0'
    fi
}
extract_fn() { awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' "$1"; }
line_no() { # $1=文件 $2=目标行 -> 首个匹配行号 (0=无)
    if [[ -f "$1" ]]; then
        grep -n -F -m1 -- "$2" "$1" | cut -d: -f1 || true
    else
        printf '0'
    fi
}
line_exact() { # $1=文件 $2=整行内容 -> 首个**完全**匹配行号 (0=无)
    # 注: 不能用 grep -F 'CRONTAB:-' 去定位"写"调用 —— 它会把 'CRONTAB:-l' 一起匹配到,
    #     于是"顺序"断言退化成恒绿。
    if [[ -f "$1" ]]; then
        grep -n -x -F -m1 -- "$2" "$1" | cut -d: -f1 || true
    else
        printf '0'
    fi
}
getfile() { if [[ -f "$1" ]]; then cat "$1"; else printf ''; fi; }

echo "==== handler_renew_web_cron_arm_test ===="

SB=".workbuddy/tmp/rwcron_arm.$$"

renew_fn="$(extract_fn core/handler.sh handler_renew_ssl)"
web_fn="$(extract_fn core/handler.sh handler_web)"
cron_fn="$(extract_fn core/handler.sh handler_nginx_cron)"
stop_fn="$(extract_fn core/handler.sh handler_nginx_stop)"
for pair in "handler_renew_ssl:$renew_fn" "handler_web:$web_fn" "handler_nginx_cron:$cron_fn" "handler_nginx_stop:$stop_fn"; do
    assert_contains "T0 ${pair%%:*} 抽取成功" "${pair#*:}" 'function '
done

SC_BASE='{"version":"v-test","nginx":{"domain":"a.example.com","ca_server":"zerossl"}}'

mk_sandbox() {
    rm -rf "$SB"
    mkdir -p "$SB/bin"
    # crontab shim: -l 读快照文件 (不存在则按真实语义 exit 1), - 收 stdin 写回快照
    cat >"$SB/bin/crontab" <<SHIM
#!/usr/bin/env bash
printf 'CRONTAB:%s\n' "\$*" >>"$REPO/$SB/plog"
case "\${1:-}" in
-l)
    if [[ -f "$REPO/$SB/crontab.cur" ]]; then
        cat "$REPO/$SB/crontab.cur"
        exit 0
    fi
    printf 'no crontab for user\n' >&2
    exit 1
    ;;
-)
    # 注: 不能直接 cat 覆盖到快照 —— 追加分支是 "( crontab -l; echo 新行 ) | ... | crontab -",
    #     三个进程并发, 这里一开局就把快照截断, 前面那个 crontab -l 可能还没读, 于是读到
    #     空、既有的定时任务被静默丢掉。必须先收完 stdin 再原子替换。
    #     (heredoc 未加引号, 注释里**不能写反引号** —— 会被当命令替换执行, cat 无输入即挂死)
    cat >"$REPO/$SB/crontab.cur.new"
    mv -f "$REPO/$SB/crontab.cur.new" "$REPO/$SB/crontab.cur"
    exit 0
    ;;
*)
    exit 1
    ;;
esac
SHIM
    # chmod shim: 只记录, 不改真实权限
    cat >"$SB/bin/chmod" <<SHIM
#!/usr/bin/env bash
printf 'CHMOD:%s\n' "\$*" >>"$REPO/$SB/plog"
exit 0
SHIM
    chmod +x "$SB/bin/crontab" "$SB/bin/chmod"
}
mk_sandbox

plog() { getfile "$SB/plog"; }
outp() { getfile "$SB/out"; }
rc() { getfile "$SB/rc"; }
cfg() { getfile "$SB/cfg"; }
cron_now() { getfile "$SB/crontab.cur"; }
steps() { grep -oE '^(SSL:--renew|NGINX_RESTART|XRAY_RESTART|PERSIST)' "$SB/plog" 2>/dev/null | tr '\n' '>' || true; }

# ---------------------------------------------------------------------------
# 驱动 1: handler_renew_ssl
# 环境变量: RW_SSL_RC / RW_NGINX_RC / RW_XRAY_RC (各步的成败)
# ---------------------------------------------------------------------------
run_renew() {
    rm -f "$SB/plog" "$SB/rc" "$SB/out"
    (
        # shellcheck disable=SC2034
        CUR_FILE='handler'
        # shellcheck disable=SC2034
        SCRIPT_CONFIG="$SC_BASE"
        _error() { printf 'ERROR:%s\n' "$*" >>"$SB/plog"; exit 1; }
        exec_ssl() {
            printf 'SSL:%s\n' "$*" >>"$SB/plog"
            [[ "${RW_SSL_RC:-0}" == '0' ]]
        }
        handler_nginx_restart() {
            printf 'NGINX_RESTART\n' >>"$SB/plog"
            [[ "${RW_NGINX_RC:-0}" == '0' ]]
        }
        handler_restart() {
            printf 'XRAY_RESTART\n' >>"$SB/plog"
            [[ "${RW_XRAY_RC:-0}" == '0' ]]
        }
        eval "$renew_fn"
        handler_renew_ssl >"$SB/out" 2>&1
        printf '0' >"$SB/rc"
    ) || true
}

# ---------------------------------------------------------------------------
# 驱动 2: handler_web
# 环境变量: RW_WEB (入参) / RW_NGINX_RC / RW_XRAY_RC
# ---------------------------------------------------------------------------
run_web() {
    rm -f "$SB/plog" "$SB/rc" "$SB/out" "$SB/cfg" "$SB/run.sh"
    # 注: handler_web 里两个重启调用**没有** || 兜底, "服务没起就不记账"这条契约完全依赖
    #     set -e 中断。而 `( ... ) || true` 会让 errexit 在整个子 shell 内失效 —— bash 会
    #     把 `||` / `if` 上下文的抑制**向下传播**, 子 shell 里再写 `set -e` 也无效 (实测
    #     `( set -e; false; echo reached ) || true` 照样打印 reached)。放进子 shell 就永远
    #     测不到这条。故这里另起一个 bash 进程, 让被测函数跑在真实的 -e 之下。
    export RW_NGINX_RC="${RW_NGINX_RC:-0}"
    export RW_XRAY_RC="${RW_XRAY_RC:-0}"
    export RW_WEB="${RW_WEB:-}"
    cat >"$SB/run.sh" <<RUNSH
set -Eeuo pipefail
CUR_FILE='handler'
SCRIPT_CONFIG='$SC_BASE'
handler_nginx_restart() {
    printf 'NGINX_RESTART\n' >>"$REPO/$SB/plog"
    [[ "\${RW_NGINX_RC:-0}" == '0' ]]
}
handler_restart() {
    printf 'XRAY_RESTART\n' >>"$REPO/$SB/plog"
    [[ "\${RW_XRAY_RC:-0}" == '0' ]]
}
persist_script_config() {
    printf 'PERSIST\n' >>"$REPO/$SB/plog"
    printf '%s' "\${SCRIPT_CONFIG}" >"$REPO/$SB/cfg"
}
RUNSH
    printf '%s\n' "$web_fn" >>"$SB/run.sh"
    cat >>"$SB/run.sh" <<RUNSH
handler_web "\${RW_WEB}" >"$REPO/$SB/out" 2>&1
RUNSH
    (bash "$SB/run.sh"; printf '%s' "$?" >"$SB/rc") || true
}

# ---------------------------------------------------------------------------
# 驱动 3: handler_nginx_cron
# 环境变量: RW_SC (脚本配置) / CRON_INIT (既有 crontab 内容, \n 分隔)
# ---------------------------------------------------------------------------
run_cron() {
    rm -f "$SB/plog" "$SB/rc" "$SB/out"
    if [[ -n "${CRON_INIT:-}" ]]; then
        printf '%b\n' "$CRON_INIT" >"$SB/crontab.cur"
    else
        rm -f "$SB/crontab.cur"
    fi
    # 注: 与 run_web 同理 —— 本函数里有两处 `|| true` 是专门为了在 set -e 下吸收
    #     "crontab -l 无内容 / grep -v 全部被过滤" 这类**预期内非 0**(真实 crontab 就是
    #     这么表现的)。放进 `( ... ) || true` 跑, errexit 被关掉, 有没有这层兜底都一个
    #     结果, 断言会恒绿。故同样另起 bash 进程, 保留真实的 -e 语义。
    export RW_SC="${RW_SC:-$SC_BASE}"
    cat >"$SB/run.sh" <<RUNSH
set -Eeuo pipefail
CUR_FILE='handler'
SCRIPT_CONFIG="\${RW_SC}"
NGINX_PATH="$REPO/$SB/nginx.sh"
GREEN='' YELLOW='' NC=''
PATH="$REPO/$SB/bin:\${PATH}"
_i18n() { printf '%s' "\${1#.}"; }
RUNSH
    printf '%s\n' "$cron_fn" >>"$SB/run.sh"
    cat >>"$SB/run.sh" <<RUNSH
handler_nginx_cron >"$REPO/$SB/out" 2>&1
RUNSH
    (bash "$SB/run.sh"; printf '%s' "$?" >"$SB/rc") || true
}

# ---------------------------------------------------------------------------
# 驱动 4: handler_nginx_stop
# 环境变量: NG_INSTALLED / NG_ACTIVE_RC / NG_ENABLED_RC / NG_STOP_RC / NG_DISABLE_RC
# ---------------------------------------------------------------------------
run_stop() {
    rm -f "$SB/plog" "$SB/rc" "$SB/out"
    (
        # shellcheck disable=SC2034
        CUR_FILE='handler'
        # shellcheck disable=SC2034
        GREEN='' YELLOW='' NC=''
        _i18n() { printf '%s' "${1#.}"; }
        cmd_exists() { [[ "${NG_INSTALLED:-1}" == '1' ]]; }
        systemctl() {
            printf 'SCTL:%s\n' "$*" >>"$SB/plog"
            case "$*" in
            *'is-active'*) return "${NG_ACTIVE_RC:-0}" ;;
            *'is-enabled'*) return "${NG_ENABLED_RC:-0}" ;;
            *'stop'*) return "${NG_STOP_RC:-0}" ;;
            *'disable'*) return "${NG_DISABLE_RC:-0}" ;;
            esac
            return 0
        }
        eval "$stop_fn"
        handler_nginx_stop >"$SB/out" 2>&1
        printf '0' >"$SB/rc"
    ) || true
}

# ---------------------------------------------------------------------------
# [A] handler_renew_ssl
# ---------------------------------------------------------------------------
RW_SSL_RC=0 RW_NGINX_RC=0 RW_XRAY_RC=0 run_renew
assert_eq "T1 顺序: renew -> nginx -> xray" "$(steps)" 'SSL:--renew>NGINX_RESTART>XRAY_RESTART>'
assert_eq "T2 成功: rc 0" "$(rc)" '0'
assert_not_contains "T2 成功: 无 ERROR" "$(plog)" 'ERROR:'

RW_SSL_RC=1 RW_NGINX_RC=0 RW_XRAY_RC=0 run_renew
assert_contains "T3 renew 失败: _error" "$(plog)" 'ERROR:ssl renew failed'
assert_not_contains "T3 renew 失败: 不重启 nginx" "$(plog)" 'NGINX_RESTART'
assert_not_contains "T3 renew 失败: 不重启 xray" "$(plog)" 'XRAY_RESTART'
assert_eq "T3 renew 失败: 非零退出" "$(rc)" ''

RW_SSL_RC=0 RW_NGINX_RC=1 RW_XRAY_RC=0 run_renew
assert_contains "T4 nginx 重启失败: _error" "$(plog)" 'ERROR:nginx restart failed after renew'
assert_not_contains "T4 nginx 重启失败: 不重启 xray" "$(plog)" 'XRAY_RESTART'
assert_eq "T4 nginx 重启失败: 非零退出" "$(rc)" ''
assert_contains "T4 nginx 重启失败: renew 已发生" "$(plog)" 'SSL:--renew'

RW_SSL_RC=0 RW_NGINX_RC=0 RW_XRAY_RC=1 run_renew
assert_contains "T5 xray 重启失败: _error" "$(plog)" 'ERROR:xray restart failed after renew'
assert_eq "T5 xray 重启失败: 前两步都已发生" "$(steps)" 'SSL:--renew>NGINX_RESTART>XRAY_RESTART>'
assert_eq "T5 xray 重启失败: 非零退出" "$(rc)" ''

# ---------------------------------------------------------------------------
# [B] handler_web
# ---------------------------------------------------------------------------
RW_WEB='' RW_NGINX_RC=0 RW_XRAY_RC=0 run_web
assert_eq "T6 顺序: nginx -> xray -> persist" "$(steps)" 'NGINX_RESTART>XRAY_RESTART>PERSIST>'
assert_eq "T7 入参缺省: 落盘 web=normal" "$(echo "$(cfg)" | jq -r '.nginx.web')" 'normal'

RW_WEB='foo' RW_NGINX_RC=0 RW_XRAY_RC=0 run_web
assert_eq "T8 入参透传: 落盘 web=foo" "$(echo "$(cfg)" | jq -r '.nginx.web')" 'foo'
assert_eq "T9 落盘保留原有字段" "$(echo "$(cfg)" | jq -r '.nginx.ca_server')" 'zerossl'
assert_eq "T9 落盘保留 version" "$(echo "$(cfg)" | jq -r '.version')" 'v-test'

RW_WEB='' RW_NGINX_RC=1 RW_XRAY_RC=0 run_web
assert_not_contains "T10 nginx 重启失败: 不 persist" "$(plog)" 'PERSIST'
assert_eq "T10 nginx 重启失败: 未写出配置" "$(cfg)" ''
assert_eq "T10 nginx 重启失败: 非零退出 (靠 errexit 中断)" "$(rc)" '1'

RW_WEB='' RW_NGINX_RC=0 RW_XRAY_RC=1 run_web
assert_not_contains "T11 xray 重启失败: 不 persist" "$(plog)" 'PERSIST'
assert_eq "T11 xray 重启失败: 未写出配置" "$(cfg)" ''
assert_eq "T11 xray 重启失败: 非零退出" "$(rc)" '1'

# ---------------------------------------------------------------------------
# [C] handler_nginx_cron
# ---------------------------------------------------------------------------
EXPECT_LINE="0 3 * * * $REPO/$SB/nginx.sh --update --brotli >/dev/null 2>&1"

# 未安装三态: null / 键缺失 / 空串
RW_SC='{"nginx":{"version":null}}' CRON_INIT='' run_cron
assert_contains "T12 version=null: 提示 not_installed" "$(outp)" 'nginx.not_installed'
assert_eq "T12 version=null: 不碰 crontab" "$(count_lines 'CRONTAB:' "$SB/plog")" '0'
assert_eq "T12 version=null: 不 chmod" "$(count_lines 'CHMOD:' "$SB/plog")" '0'
assert_eq "T12 version=null: rc 0" "$(rc)" '0'

RW_SC='{"nginx":{}}' CRON_INIT='' run_cron
assert_contains "T13 version 键缺失: 提示 not_installed" "$(outp)" 'nginx.not_installed'
assert_eq "T13 version 键缺失: 不碰 crontab" "$(count_lines 'CRONTAB:' "$SB/plog")" '0'

RW_SC='{"nginx":{"version":""}}' CRON_INIT='' run_cron
assert_contains "T14 version 空串: 提示 not_installed" "$(outp)" 'nginx.not_installed'
assert_eq "T14 version 空串: 不碰 crontab" "$(count_lines 'CRONTAB:' "$SB/plog")" '0'

# 已安装 + 无既有任务 -> 开启
RW_SC='{"nginx":{"version":"1.27.0"}}' CRON_INIT='' run_cron
assert_contains "T15 开启: 打印 open_cron" "$(outp)" 'nginx.open_cron'
assert_contains "T15 开启: chmod a+x" "$(plog)" "CHMOD:a+x $REPO/$SB/nginx.sh"
assert_eq "T16 开启: 任务行内容精确" "$(cron_now)" "$EXPECT_LINE"
assert_eq "T17 无 crontab 时仍写入: rc 0" "$(rc)" '0'
assert_eq "T22 chmod 在写 crontab 之前" "$([[ "$(line_exact "$SB/plog" "CHMOD:a+x $REPO/$SB/nginx.sh")" -lt "$(line_exact "$SB/plog" 'CRONTAB:-')" ]] && echo yes || echo no)" 'yes'

# 保留既有条目
RW_SC='{"nginx":{"version":"1.27.0"}}' CRON_INIT='@daily /usr/bin/foo' run_cron
assert_eq "T18 保留既有条目并追加在末尾" "$(cron_now)" "@daily /usr/bin/foo
$EXPECT_LINE"

# 去重: 既有内容里有重复行 -> 只保留一条
RW_SC='{"nginx":{"version":"1.27.0"}}' CRON_INIT='@daily /usr/bin/foo\n@daily /usr/bin/foo' run_cron
assert_eq "T19 既有重复条目被去重" "$(cron_now)" "@daily /usr/bin/foo
$EXPECT_LINE"

# 已安装 + 已有任务 -> 关闭
RW_SC='{"nginx":{"version":"1.27.0"}}' CRON_INIT="@daily /usr/bin/foo\n$EXPECT_LINE" run_cron
assert_contains "T20 关闭: 打印 close_cron" "$(outp)" 'nginx.close_cron'
assert_eq "T20 关闭: 只留无关条目" "$(cron_now)" '@daily /usr/bin/foo'
assert_not_contains "T20 关闭: 任务行已移除" "$(cron_now)" 'nginx.sh'
assert_eq "T20 关闭: 不 chmod" "$(count_lines 'CHMOD:' "$SB/plog")" '0'
assert_eq "T20 关闭: rc 0" "$(rc)" '0'

# 移除后为空 -> 写空内容, 且 grep 无输出的退出码被 || true 兜住
RW_SC='{"nginx":{"version":"1.27.0"}}' CRON_INIT="$EXPECT_LINE" run_cron
assert_eq "T21 移除后为空: 写入空内容" "$(cron_now)" ''
assert_eq "T21 移除后为空: rc 0 (不被 pipefail 带崩)" "$(rc)" '0'

# ---------------------------------------------------------------------------
# [D] handler_nginx_stop
# ---------------------------------------------------------------------------
NG_INSTALLED=0 run_stop
assert_contains "T23 未安装: 提示 not_installed" "$(outp)" 'nginx.not_installed'
assert_eq "T23 未安装: 零 systemctl 调用" "$(count_lines 'SCTL:' "$SB/plog")" '0'
assert_eq "T23 未安装: rc 0" "$(rc)" '0'

NG_INSTALLED=1 NG_ACTIVE_RC=0 NG_ENABLED_RC=0 run_stop
assert_contains "T24 active+enabled: stop" "$(plog)" 'SCTL:-q stop nginx'
assert_contains "T24 active+enabled: disable" "$(plog)" 'SCTL:-q disable nginx'
assert_eq "T24 active+enabled: rc 0" "$(rc)" '0'

NG_INSTALLED=1 NG_ACTIVE_RC=1 NG_ENABLED_RC=0 run_stop
assert_not_contains "T25 未 active: 不 stop" "$(plog)" 'SCTL:-q stop nginx'
assert_contains "T25 未 active: 仍 disable" "$(plog)" 'SCTL:-q disable nginx'
assert_eq "T25 未 active: rc 0" "$(rc)" '0'

NG_INSTALLED=1 NG_ACTIVE_RC=0 NG_ENABLED_RC=1 run_stop
assert_contains "T26 未 enable: 仍 stop" "$(plog)" 'SCTL:-q stop nginx'
assert_not_contains "T26 未 enable: 不 disable" "$(plog)" 'SCTL:-q disable nginx'
assert_eq "T26 未 enable: rc 0" "$(rc)" '0'

NG_INSTALLED=1 NG_ACTIVE_RC=1 NG_ENABLED_RC=1 run_stop
assert_not_contains "T27 都无: 不 stop" "$(plog)" 'SCTL:-q stop nginx'
assert_not_contains "T27 都无: 不 disable" "$(plog)" 'SCTL:-q disable nginx'
assert_eq "T27 都无: rc 0" "$(rc)" '0'

NG_INSTALLED=1 NG_ACTIVE_RC=0 NG_ENABLED_RC=0 NG_STOP_RC=1 run_stop
assert_contains "T28 stop 失败: 调用已发出" "$(plog)" 'SCTL:-q stop nginx'
assert_eq "T28 stop 失败: rc 仍 0" "$(rc)" '0'

NG_INSTALLED=1 NG_ACTIVE_RC=0 NG_ENABLED_RC=0 NG_DISABLE_RC=1 run_stop
assert_contains "T29 disable 失败: 调用已发出" "$(plog)" 'SCTL:-q disable nginx'
assert_eq "T29 disable 失败: rc 仍 0" "$(rc)" '0'

# ---------------------------------------------------------------------------
# 负向校验 (NEG): 把源码改坏, 确认上面的断言真的会红
# ---------------------------------------------------------------------------
if [[ -z "${SKIP_NEG:-}" ]]; then
    gen_neg() { # $1=变异名
        python3 - "$1" <<'PY'
import sys, pathlib

# 每条变异落在哪个函数上 —— 用于确认改的是它, 而不是全仓同名的另一处
TARGET = {
    'renew_swap_order': 'handler_renew_ssl',
    'renew_no_error': 'handler_renew_ssl',
    'renew_nginx_no_error': 'handler_renew_ssl',
    'web_no_persist': 'handler_web',
    'web_hardcode_normal': 'handler_web',
    'web_persist_first': 'handler_web',
    'cron_null_version': 'handler_nginx_cron',
    'cron_no_chmod': 'handler_nginx_cron',
    'cron_no_dedup': 'handler_nginx_cron',
    'cron_remove_no_true': 'handler_nginx_cron',
    'stop_no_gate': 'handler_nginx_stop',
    'stop_disable_always': 'handler_nginx_stop',
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


src = pathlib.Path('core/handler.sh').read_text()
mode = sys.argv[1]
s = src
if mode == 'renew_swap_order':
    s = s.replace("""    exec_ssl '--renew' || _error "ssl renew failed"
    handler_nginx_restart || _error "nginx restart failed after renew\"""",
                  """    handler_nginx_restart || _error "nginx restart failed after renew"
    exec_ssl '--renew' || _error "ssl renew failed\"""", 1)
elif mode == 'renew_no_error':
    s = s.replace("""    exec_ssl '--renew' || _error "ssl renew failed\"""", """    exec_ssl '--renew' || true""", 1)
elif mode == 'renew_nginx_no_error':
    s = s.replace("""    handler_nginx_restart || _error "nginx restart failed after renew\"""",
                  """    handler_nginx_restart || true""", 1)
elif mode == 'web_no_persist':
    s = s.replace("""    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg web "${web}" '.nginx.web = $web')"
    persist_script_config""",
                  """    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg web "${web}" '.nginx.web = $web')\"""", 1)
elif mode == 'web_hardcode_normal':
    s = s.replace("""    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg web "${web}" '.nginx.web = $web')\"""",
                  """    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg web "normal" '.nginx.web = $web')\"""", 1)
elif mode == 'web_persist_first':
    s = s.replace("""    handler_nginx_restart
    handler_restart
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg web "${web}" '.nginx.web = $web')"
    persist_script_config""",
                  """    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg web "${web}" '.nginx.web = $web')"
    persist_script_config
    handler_nginx_restart
    handler_restart""", 1)
elif mode == 'cron_null_version':
    s = s.replace("""    if [[ -n "${NGINX_STATUS}" && "${NGINX_STATUS}" != 'null' ]]; then""",
                  """    if [[ -n "${NGINX_STATUS}" ]]; then""", 1)
elif mode == 'cron_no_chmod':
    s = s.replace("""            chmod a+x "${NGINX_PATH}\"""", """            :""", 1)
elif mode == 'cron_no_dedup':
    s = s.replace("""            ) | awk '!x[$0]++' | crontab -""", """            ) | cat | crontab -""", 1)
elif mode == 'cron_remove_no_true':
    s = s.replace("""            crontab -l 2>/dev/null | grep -v "${NGINX_PATH}" | crontab - || true""",
                  """            crontab -l 2>/dev/null | grep -v "${NGINX_PATH}" | crontab -""", 1)
elif mode == 'stop_no_gate':
    s = s.replace("""    if ! cmd_exists 'nginx'; then
        echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $(_i18n ".${CUR_FILE}.nginx.not_installed")" >&2
        return 0
    fi""", """    :""", 1)
elif mode == 'stop_disable_always':
    s = s.replace("""    systemctl -q is-enabled nginx && systemctl -q disable nginx || true""",
                  """    systemctl -q disable nginx || true""", 1)
else:
    raise SystemExit('unknown mode: ' + mode)
if s == src:
    raise SystemExit('改写未生效 (原文未命中): ' + mode)
tgt = TARGET[mode]
if fn_body(s, tgt) == fn_body(src, tgt):
    raise SystemExit('改写未落在 %s 上 (锚点命中了别处): %s' % (tgt, mode))
pathlib.Path('core/_neg_handler.sh').write_text(s)
PY
        sed 's#core/handler.sh#core/_neg_handler.sh#g' test/handler_renew_web_cron_arm_test.sh >test/neg_tmp_rwcron_arm_test.sh
    }

    neg_run() { # $1=说明 $2=期望 all-pass|has-fail
        local out
        out="$(cd "$REPO" && SKIP_NEG=1 bash "test/neg_tmp_rwcron_arm_test.sh" 2>&1 || true)"
        local n
        n="$(printf '%s\n' "$out" | grep -c '\[FAIL\]' || true)"
        if [[ "$2" == 'all-pass' ]]; then
            [[ "$n" == '0' ]] && ok || bad "NEG $1 基线应全绿, 实际 $n 条 FAIL"
        else
            [[ "$n" != '0' ]] && ok || bad "NEG $1 应检出失败, 实际 0 条 (断言恒绿!)"
        fi
    }

    for spec in \
        'renew_swap_order|先重启 nginx 再续期' \
        'renew_no_error|续期失败不中断' \
        'renew_nginx_no_error|nginx 重启失败不中断' \
        'web_no_persist|web 不落盘' \
        'web_hardcode_normal|web 类型写死 normal' \
        'web_persist_first|先记账再起服务' \
        'cron_null_version|version=null 当成已安装' \
        'cron_no_chmod|开启任务时不赋可执行位' \
        'cron_no_dedup|不做去重' \
        'cron_remove_no_true|移除分支不兜 grep 退出码' \
        'stop_no_gate|未安装判断被去掉' \
        'stop_disable_always|不判 enabled 直接 disable'; do
        m="${spec%%|*}"
        d="${spec#*|}"
        if gen_neg "$m" 2>/dev/null; then neg_run "$d" 'has-fail'; else bad "NEG 改写未生效: $m"; fi
    done

    rm -f core/_neg_handler.sh test/neg_tmp_rwcron_arm_test.sh
fi

rm -rf "$SB"

echo "---"
echo "==== handler_renew_web_cron_arm_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" == '0' ]]
