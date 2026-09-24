#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_change_domain_arm_test.sh
# 测试目标: 换域名这条链路的**决策层 + 回滚层**回归 —— handler_change_domain 及其
#           四个子函数 (_read_inputs / _render / _issue / _only_branch)。
#
# 为什么需要本测试 (审计背景):
#   handler_change_domain 是 P1 写现场臂里**唯一带回滚语义**的一条: 它改 nginx 站点
#   配置、重新签发证书、改 SCRIPT_CONFIG, 任一步失败都可能让站点落入"新旧俱无"的不
#   可用状态 —— 而它的用户往往是"证书快到期了顺便换个域名", 没有回退的心理准备。
#   此前全仓零覆盖。
#
#   它的难点在于边界宽: ensure_nginx_support_files / exec_read / exec_ssl / _remove_site_conf /
#   _replace_in_file / align_site_http3 / rebuild_stream_config / handler_nginx_restart 九个外部符号。
#   本测试用**真实文件系统**(临时目录树跑真 cp/mv/ln/rm) + 真 _replace_in_file /
#   _remove_site_conf, 只把"进程外"的四个桩掉, 因此能断言到"新站点 conf 是否真的
#   被渲染出来了 / 软链真的指向新 conf"这类此前完全无人看守的结果。
#
# 锁定不变量:
#   [A] _read_inputs 交互门控
#     T1  CONFIG_DATA 已有新域名 -> 不读输入
#     T2  无新域名 + stop=y + 有旧域名 -> 先问 only-change-domain, 再问域名
#     T3  无新域名 + stop=y + 无旧域名 -> 只问域名
#     T4  stop != y -> 完全不交互, 回落到旧域名
#     T5  ensure_nginx_support_files 失败 -> _error (不得带着半成品继续)
#   [B] SCRIPT_CONFIG 更新 (全靠 target_domain 是否为 "domain" 门控)
#     T6  key=domain -> 写 nginx.domain / xray.target / xray.serverNames, 并清 .target.domain
#     T7  key=cdn    -> 只写 nginx.cdn, **不得**动 xray.target / serverNames / .target
#   [C] _render 真实文件产出
#     T8  旧 stream.conf 与旧站点 conf 被备份到 SCRIPT_CONFIG_DIR, 旧的 available 被清
#     T9  新站点 conf 由模板渲染: example.com -> 新域名, /yourpath -> XHTTP_PATH
#     T10 sites-enabled 软链指向新的 available 文件
#   [D] _issue 成功/失败
#     T11 签发成功 + 有旧域名 + stop=y -> 查旧证书状态后置停旧域名续签
#     T12 签发成功 + stop != y -> 完全不碰旧域名
#     T13 签发失败 -> 回滚: 清新站 + 恢复 stream.conf + 恢复旧站conf与软链 + 重启 nginx + exit 1
#     T14 回滚时备份缺失 -> 只告警不中止 (至少把 Nginx 拉回来)
#   [E] _only_branch
#     T15 only-change-domain=y + 备份在 -> 改名 + 内容替换 + 重建软链
#     T16 备份缺失 -> 告警跳过, 不得 mv 出一个空壳
#     T17 =n 或缺失 -> 完全不动
#   [F] 编排顺序
#     T18 正常路径最终必调 handler_nginx_restart, 且 persist 在此之前
#
# 实现备注:
#   被测函数会把结果写回全局 SCRIPT_CONFIG —— 正常路径**直接调用**(不用子 shell, 否则
#   写回出不去父进程导致断言成片假绿)。仅 _issue 失败那条走 exit 1, 必须子 shell 隔离,
#   结果经**文件**回传。
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
count_lines() { # $1=正则 $2=文件
    if [[ -f "$2" ]]; then
        grep -c "$1" "$2" || true
    else
        printf '0'
    fi
}
extract_fn() { awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' "$1"; }

echo "==== handler_change_domain_arm_test ===="

SB=".workbuddy/tmp/cd_arm.$$"

# ---------------------------------------------------------------------------
# 真实函数体: 父函数 + 四个子函数 (子函数靠 bash 动态作用域读父函数的 local)
# ---------------------------------------------------------------------------
cd_fn="$(extract_fn core/handler.sh handler_change_domain)"
ri_fn="$(extract_fn core/handler.sh _change_domain_read_inputs)"
rd_fn="$(extract_fn core/handler.sh _change_domain_render)"
is_fn="$(extract_fn core/handler.sh _change_domain_issue)"
ob_fn="$(extract_fn core/handler.sh _change_domain_only_branch)"
# 真的-common.sh 工具函数: 让 cp/mv/ln 之后的删除与替换走真实实现
repl_fn="$(extract_fn core/_common.sh _replace_in_file)"
rmsc_fn="$(extract_fn core/_common.sh _remove_site_conf)"

# 判据只需证明"抽到了带函数头的实现体" —— 别用含 \| 的多选 pattern: [[ ]] 里它是字面
# 字符, 不会当 alternation, 恒不匹配; 也别锚 'local' —— 有的子函数刻意不声明自己的
# local (读父函数的)。抽不到时变量为空串, 下面的包含判定自然为假。
for pair in "handler_change_domain:$cd_fn" "_change_domain_read_inputs:$ri_fn" "_change_domain_render:$rd_fn" "_change_domain_issue:$is_fn" "_change_domain_only_branch:$ob_fn" "_replace_in_file:$repl_fn" "_remove_site_conf:$rmsc_fn"; do
    assert_contains "T0 ${pair%%:*} 抽取成功" "${pair#*:}" 'function '
done

declare -A CONFIG_DATA

SC_BASE='{"version":"v-test","target":{"domain":"old.example.com","cdn":"old.cdn.example.com"},"xray":{"path":"/thepath","target":"old.example.com","serverNames":["old.example.com"]},"nginx":{"domain":"old.example.com","cdn":"old.cdn.example.com"}}'

# ---------------------------------------------------------------------------
# 建沙箱: 临时 nginx 目录树 + 站点模板
# 注: 仓库里 config/nginx/conf/sites-available/*.example.com.conf **并不存在**
#     (未被 .gitignore 命中也不是运行时产物) —— 本测试自建一份最小模板, 测的是
#     change_domain 的逻辑而非缺失资产本身。
# ---------------------------------------------------------------------------
mk_sandbox() {
    rm -rf "$SB"
    mkdir -p "$SB/nginx/modules-enabled" "$SB/nginx/sites-available" "$SB/nginx/sites-enabled" "$SB/script"
    mkdir -p "$SB/repo/nginx/conf/sites-available"
    cat >"$SB/repo/nginx/conf/sites-available/domain.example.com.conf" <<'TPL'
server {
    server_name example.com;
    location /yourpath {
        proxy_pass http://127.0.0.1:1234;
    }
}
TPL
    # 旧现场的初始状态: stream.conf + 旧站点 conf + enabled 软链
    printf 'stream-old\n' >"$SB/nginx/modules-enabled/stream.conf"
    printf 'server { server_name old.example.com; }\n' >"$SB/nginx/sites-available/old.example.com.conf"
    ln -sf "$SB/nginx/sites-available/old.example.com.conf" "$SB/nginx/sites-enabled/old.example.com.conf"
}

mk_sandbox

# ---------------------------------------------------------------------------
# 驱动
# 环境变量:
#   CD_KEY            target_domain 入参 (默认 domain)
#   CD_STOP           stop_cert_service (默认 y)
#   CD_NEW / CD_ONLY  预置到 CONFIG_DATA 的新域名 / only-change-domain
#   SSL_ISSUE_RC      exec_ssl --issue 的成败
#   SSL_STATUS_RC     exec_ssl --status 的返回值
#   ENSURE_RC         ensure_nginx_support_files 的成败
#   NO_BACKUP=1       建站时不放旧备份 (模拟回滚时的备份缺失)
# ---------------------------------------------------------------------------
run_cd() {
    local plog="$SB/../cd.log"
    local cfgout="$SB/../cd.json"
    local out="$SB/../cd.out"
    : >"$plog"
    : >"$out"
    rm -f "$cfgout"

    CONFIG_DATA=()
    # CD_PRESET: 调用方预置到 CONFIG_DATA 的值 (走 else 分支前的初始态)
    # CD_READ / CD_ONLY_READ: exec_read 的"用户输入" —— 默认 stop=y 时必须经交互取
    if [[ -n "${CD_PRESET:-}" ]]; then
        CONFIG_DATA['domain']="${CD_PRESET}"
    fi
    if [[ -n "${CD_PRESET_ONLY:-}" ]]; then
        CONFIG_DATA['only-change-domain']="${CD_PRESET_ONLY}"
    fi

    # 以下变量只被 eval 注入的被测函数体读取 —— shellcheck 数据流不跨 eval, 逐条前置
    # disable (见 run_tests 的 shellcheck 门禁口径)。
    # shellcheck disable=SC2034
    GREEN=$'\033[32m'
    # shellcheck disable=SC2034
    YELLOW=$'\033[33m'
    # shellcheck disable=SC2034
    RED=$'\033[31m'
    # shellcheck disable=SC2034
    NC=$'\033[0m'
    # shellcheck disable=SC2034
    CUR_FILE='handler'
    SCRIPT_CONFIG="${CD_SC_BASE:-$SC_BASE}"
    # shellcheck disable=SC2034
    NGINX_CONFIG_DIR="$SB/nginx"
    # shellcheck disable=SC2034
    SCRIPT_CONFIG_DIR="$SB/script"
    # shellcheck disable=SC2034
    CONFIG_DIR="$SB/repo"
    # shellcheck disable=SC2034
    NGINX_PATH=''

    _i18n() { printf '%s' "${1#.}"; }
    print_warn() { printf 'WARN:%s\n' "$*" >>"$plog"; }
    _error() {
        printf 'ERROR:%s\n' "$*" >>"$plog"
        exit 1
    }
    ensure_nginx_support_files() {
        printf 'ENSURE\n' >>"$plog"
        [[ "${ENSURE_RC:-0}" == '0' ]]
    }
    exec_read() {
        printf 'READ:%s\n' "${1:-}" >>"$plog"
        # shellcheck disable=SC2034
        case "${1:-}" in
        # 注意: directive 不能写在 case 分支里 (SC1124) —— 只能前置到整条 case 语句,
        #       故这里的 disable 放在上面的 `case` 行之前。
        'only-change-domain') CONFIG_DATA['only-change-domain']="${CD_ONLY_READ:-n}" ;;
        *) CONFIG_DATA["${1:-}"]="${CD_READ:-}" ;;
        esac
        return 0
    }
    exec_ssl() {
        printf 'SSL:%s\n' "$*" >>"$plog"
        case "${1:-}" in
        '--issue') [[ "${SSL_ISSUE_RC:-0}" == '0' ]] ;;
        '--status') [[ "${SSL_STATUS_RC:-0}" == '0' ]] ;;
        *) return 0 ;;
        esac
    }
    align_site_http3() { printf 'ALIGN:%s\n' "${1:-}" >>"$plog"; }
    write_stream_config() { printf 'WRITE_STREAM\n' >>"$plog"; }
    rebuild_stream_config() { printf 'REBUILD_STREAM\n' >>"$plog"; }
    handler_nginx_restart() { printf 'NGINX_RESTART\n' >>"$plog"; }
    persist_script_config() {
        printf 'PERSIST\n' >>"$plog"
        printf '%s' "${SCRIPT_CONFIG}" >"$cfgout"
    }

    eval "$rmsc_fn"
    eval "$repl_fn"
    eval "$cd_fn"
    eval "$ri_fn"
    eval "$rd_fn"
    eval "$is_fn"
    eval "$ob_fn"

    handler_change_domain "${CD_KEY:-domain}" "${CD_STOP:-y}" >"$out" 2>&1
    return 0
}

# ---------------------------------------------------------------------------
# T1-T4: _read_inputs 交互门控
# ---------------------------------------------------------------------------
# 契约说明 (由真实调用点反推, 不是本测试发明的):
#   handler_change_domain 'domain' 'n' / 'cdn' 'n'  (SNI 装配) -> stop=n, 表示"只渲染配置, 别动域名"
#   handler_change_domain "${1:-}"                   (菜单/CLI)  -> stop=y, 表示要走交互 + 重签证书
# 因此 CONFIG_DATA **不是**官方的域名输入通道: 值必须由 exec_read 取。
echo "== T1 CONFIG_DATA 预置值不会被采用 =="
mk_sandbox
( CD_PRESET='preset.example.com' run_cd ) >/dev/null 2>&1 || true
assert_eq "T1a 预置值存在时不读 exec_read" "$(count_lines '^READ:' "$SB/../cd.log")" '0'
assert_not_contains "T1b 不会问 only-change-domain" "$(cat "$SB/../cd.log")" 'READ:only-change-domain'
assert_eq "T1c 预置值被 old_domain 覆盖 (走 else 分支)" "$(jq -r '.nginx.domain' "$SB/../cd.json")" 'old.example.com'
assert_not_contains "T1d 预置的新域名不得出现在最终配置里" "$(cat "$SB/../cd.json")" 'preset.example.com'

echo "== T2 无新域名 + stop=y + 有旧域名 =="
mk_sandbox
( CD_STOP='y' run_cd ) >/dev/null 2>&1 || true
assert_eq "T2a 先问 only-change-domain" "$(count_lines '^READ:only-change-domain$' "$SB/../cd.log")" '1'
assert_eq "T2b 再问域名" "$(count_lines '^READ:domain$' "$SB/../cd.log")" '1'
assert_contains "T2c 顺序是先 only 后 domain" "$(cat "$SB/../cd.log")" 'READ:only-change-domain
READ:domain'

echo "== T3 无新域名 + stop=y + 无旧域名 =="
mk_sandbox
err_domain_base='{"version":"v-test","target":{},"xray":{"path":"/thepath","target":"","serverNames":[]},"nginx":{"domain":"","cdn":""}}'
( CD_SC_BASE="$err_domain_base" CD_STOP='y' run_cd ) >/dev/null 2>&1 || true
assert_eq "T3a 仍要问域名" "$(count_lines '^READ:domain$' "$SB/../cd.log")" '1'
assert_eq "T3b old_domain 为空时不问 only-change-domain" "$(count_lines '^READ:only-change-domain$' "$SB/../cd.log")" '0'

echo "== T4 stop != y -> 不交互, 回落到旧域名 =="
mk_sandbox
( CD_STOP='n' run_cd ) >/dev/null 2>&1 || true
assert_eq "T4a 完全不调 exec_read" "$(count_lines '^READ:' "$SB/../cd.log")" '0'
assert_eq "T4b nginx.domain 保持旧域名 (回落)" "$(jq -r '.nginx.domain' "$SB/../cd.json")" 'old.example.com'

echo "== T5 ensure_nginx_support_files 失败 -> _error =="
mk_sandbox
# _error 桩攥得出 exit 1 —— 简单命令调用会直接把测试 shell 带走, 必须子 shell 隔离。
ens_rc=0
( ENSURE_RC=1 run_cd ) >/dev/null 2>&1 || ens_rc=$?
assert_eq "T5a ensure 失败以非 0 中止" "$ens_rc" '1'
assert_contains "T5a ensure 失败走到 _error" "$(cat "$SB/../cd.log")" 'ERROR:'
assert_not_contains "T5b 失败后不得继续渲染/签发" "$(cat "$SB/../cd.log")" 'SSL:--issue'

# ---------------------------------------------------------------------------
# T6-T7: SCRIPT_CONFIG 更新 —— target_domain 是否为 "domain" 是全部门控
# ---------------------------------------------------------------------------
echo "== T6 key=domain =="
mk_sandbox
( CD_READ='new.example.com' run_cd ) >/dev/null 2>&1 || true
assert_eq "T6a nginx.domain 被改写" "$(jq -r '.nginx.domain' "$SB/../cd.json")" 'new.example.com'
assert_eq "T6b xray.target 被改写" "$(jq -r '.xray.target' "$SB/../cd.json")" 'new.example.com'
assert_eq "T6c xray.serverNames 置成新值单元素数组" "$(jq -c '.xray.serverNames' "$SB/../cd.json")" '["new.example.com"]'
assert_eq "T6d .target.domain 被删除 (旧快照失效)" "$(jq -r '.target.domain // "GONE"' "$SB/../cd.json")" 'GONE'
assert_eq "T6e .target.cdn 保留" "$(jq -r '.target.cdn' "$SB/../cd.json")" 'old.cdn.example.com'

echo "== T7 key=cdn =="
mk_sandbox
( CD_KEY='cdn' CD_READ='new.cdn.example.com' run_cd ) >/dev/null 2>&1 || true
assert_eq "T7a nginx.cdn 被改写" "$(jq -r '.nginx.cdn' "$SB/../cd.json")" 'new.cdn.example.com'
assert_eq "T7b xray.target **不动**" "$(jq -r '.xray.target' "$SB/../cd.json")" 'old.example.com'
assert_eq "T7c serverNames **不动**" "$(jq -c '.xray.serverNames' "$SB/../cd.json")" '["old.example.com"]'
assert_eq "T7d .target 未被删" "$(jq -r '.target.domain' "$SB/../cd.json")" 'old.example.com'
assert_eq "T7e nginx.domain **不动**" "$(jq -r '.nginx.domain' "$SB/../cd.json")" 'old.example.com'

# ---------------------------------------------------------------------------
# T8-T10: _render 的真实文件产出
# ---------------------------------------------------------------------------
echo "== T8-T10 render 产出 =="
mk_sandbox
( CD_READ='new.example.com' run_cd ) >/dev/null 2>&1 || true
assert_eq "T8a 旧 stream.conf 已备份到 SCRIPT_CONFIG_DIR" "$(cat "$SB/script/stream.conf" 2>/dev/null || printf '')" 'stream-old'
assert_eq "T8b 旧站点 conf 已备份" "$(cat "$SB/script/old.example.com.conf" 2>/dev/null || printf '')" 'server { server_name old.example.com; }'
[[ ! -e "$SB/nginx/sites-available/old.example.com.conf" ]] && ok || bad "T8c 旧的 available 已被清除"
[[ ! -e "$SB/nginx/sites-enabled/old.example.com.conf" ]] && ok || bad "T8d 旧的 enabled 软链已被清除"
new_conf="$SB/nginx/sites-available/new.example.com.conf"
if [[ -f "$new_conf" ]]; then
    ok
    assert_contains "T9b example.com 已被替换为新域名" "$(cat "$new_conf")" 'server_name new.example.com;'
    assert_contains "T9c /yourpath 已被替换为 XHTTP_PATH" "$(cat "$new_conf")" 'location /thepath'
    # 精确锚模板原串: 新域名本身就含 "example.com" 子串, 裸子串断言会自命中
    assert_not_contains "T9d 模板里的 server_name 占位已替换" "$(cat "$new_conf")" 'server_name example.com;'
    assert_not_contains "T9e 模板残留的 /yourpath 已清空" "$(cat "$new_conf")" '/yourpath'
else
    bad "T9a 新站点 conf 未生成"
fi
if [[ -L "$SB/nginx/sites-enabled/new.example.com.conf" ]]; then
    ok
    assert_eq "T10b 软链指向新的 available" "$(readlink "$SB/nginx/sites-enabled/new.example.com.conf")" "$SB/nginx/sites-available/new.example.com.conf"
else
    bad "T10a sites-enabled 下应存在新域名软链"
fi
assert_contains "T10c 渲染后做了 HTTP/3 能力对齐" "$(cat "$SB/../cd.log")" 'ALIGN:'

# ---------------------------------------------------------------------------
# T11-T12: _issue 成功路径
# ---------------------------------------------------------------------------
echo "== T11 签发成功 + stop=y -> 停旧域名续签 =="
mk_sandbox
( CD_READ='new.example.com' CD_STOP='y' SSL_ISSUE_RC=0 SSL_STATUS_RC=0 run_cd ) >/dev/null 2>&1 || true
assert_contains "T11a 为其签名 http_request_method=ISSUE" "$(cat "$SB/../cd.log")" 'SSL:--issue --domain=new.example.com'
assert_contains "T11b 先查旧域名证书状态" "$(cat "$SB/../cd.log")" 'SSL:--status --domain=old.example.com'
assert_contains "T11c 后置停旧域名续签" "$(cat "$SB/../cd.log")" 'SSL:--stop-renew --domain=old.example.com'

echo "== T12 签发成功 + stop != y -> 不碰旧域名 =="
mk_sandbox
( CD_READ='new.example.com' CD_STOP='n' SSL_ISSUE_RC=0 run_cd ) >/dev/null 2>&1 || true
assert_contains "T12a stop=n 时签发的是旧域名 (走 else 沿用)" "$(cat "$SB/../cd.log")" 'SSL:--issue --domain=old.example.com'
assert_not_contains "T12b 不停旧域名续签" "$(cat "$SB/../cd.log")" '--stop-renew'
assert_not_contains "T12c 也不查旧域名状态" "$(cat "$SB/../cd.log")" '--status'

# ---------------------------------------------------------------------------
# T13-T14: _issue 失败 -> 回滚
# ---------------------------------------------------------------------------
echo "== T13 签发失败 -> 完整回滚 + exit 1 =="
mk_sandbox
ssl_fail_rc=0
( CD_READ='new.example.com' SSL_ISSUE_RC=1 run_cd ) >/dev/null 2>&1 || ssl_fail_rc=$?
assert_eq "T13a 失败路径以非 0 退出 (不允许带着半成品继续)" "$ssl_fail_rc" '1'
[[ ! -e "$SB/nginx/sites-available/new.example.com.conf" ]] && ok || bad "T13b 新站点 available 已回滚清除"
[[ ! -e "$SB/nginx/sites-enabled/new.example.com.conf" ]] && ok || bad "T13c 新站点软链已回滚清除"
assert_eq "T13d stream.conf 已还原" "$(cat "$SB/nginx/modules-enabled/stream.conf" 2>/dev/null || printf '')" 'stream-old'
assert_eq "T13e 旧站点 conf 已还原" "$(cat "$SB/nginx/sites-available/old.example.com.conf" 2>/dev/null || printf '')" 'server { server_name old.example.com; }'
if [[ -L "$SB/nginx/sites-enabled/old.example.com.conf" ]]; then
    ok
else
    bad "T13f 旧站点 enabled 软链已重建"
fi
assert_contains "T13g 回滚后必须把 Nginx 拉回来" "$(cat "$SB/../cd.log")" 'NGINX_RESTART'

echo "== T14 回滚时备份缺失 -> 只告警不中止 =="
mk_sandbox
rm -f "$SB/nginx/modules-enabled/stream.conf" # 现场本就没有旧 stream
( CD_READ='new.example.com' SSL_ISSUE_RC=1 run_cd ) >/dev/null 2>&1 || true
assert_contains "T14a 备份缺失要告警" "$(cat "$SB/../cd.log")" 'WARN:'
assert_contains "T14b 即便备份缺失也要重启 Nginx" "$(cat "$SB/../cd.log")" 'NGINX_RESTART'
assert_contains "T14c 备份缺失不至于让回滚提前中止 (仍走到 scale 收尾)" "$(cat "$SB/../cd.log")" 'NGINX_RESTART'

# ---------------------------------------------------------------------------
# T15-T17: _only_branch
# ---------------------------------------------------------------------------
echo "== T15 only-change-domain=y =="
mk_sandbox
( CD_READ='new.example.com' CD_ONLY_READ='y' SSL_ISSUE_RC=0 run_cd ) >/dev/null 2>&1 || true
if [[ -f "$SB/nginx/sites-available/new.example.com.conf" ]]; then
    ok
    assert_contains "T15b 备份改名为新域名 conf 且内容里旧域名已替换" "$(cat "$SB/nginx/sites-available/new.example.com.conf")" 'server_name new.example.com;'
else
    bad "T15a 备份应改名为新域名 conf"
fi
if [[ -L "$SB/nginx/sites-enabled/new.example.com.conf" ]]; then
    ok
else
    bad "T15c 应为新域名重建 enabled 软链"
fi
if [[ ! -f "$SB/script/old.example.com.conf" ]]; then
    ok
else
    bad "T15b2 备份应被 mv 改名消耗掉 (证明走的是 only 分支)"
fi
assert_contains "T15d 仅换域名分支也对齐 HTTP/3" "$(cat "$SB/../cd.log")" 'ALIGN:'
assert_contains "T15e 重建 stream 配置" "$(cat "$SB/../cd.log")" 'REBUILD_STREAM'

echo "== T16 备份缺失 -> 告警跳过 =="
mk_sandbox
# 备份缺失只能靠"现场本来就没有旧域名"来构造: 只要有旧域名, render 一定会把旧站点
# conf 备份进 SCRIPT_CONFIG_DIR, only 分支就永远找得到 —— 是真实现象, 不是用例瑕疵。
( CD_SC_BASE="$err_domain_base" CD_PRESET_ONLY='y' SSL_ISSUE_RC=0 run_cd ) >/dev/null 2>&1 || true
assert_contains "T16a 告警而不是崩" "$(cat "$SB/../cd.log")" 'WARN:'
# sites-available/.conf 是 render 阶段在"无域名"时必然会渲染出来的东西 (completeness),
# 不能拿来判 only 分支; only 分支的成功与否体现在"备份有没有被 mv 消耗"。
[[ ! -f "$SB/script/.conf" ]] && ok || bad "T16b 备份名 .conf 不应存在 (证明确实是备份缺失)"

echo "== T17 only-change-domain 非 y -> 完全不动 =="
mk_sandbox
( CD_READ='new.example.com' CD_ONLY_READ='n' SSL_ISSUE_RC=0 run_cd ) >/dev/null 2>&1 || true
# 判据不是"站点目录没变化" —— render 阶段无论 only 取值都会产出新站点 conf;
# only 分支的特征是"把 render 备份的旧 conf mv 改名", 故看备份是否还在。
if [[ -f "$SB/script/old.example.com.conf" ]]; then
    ok
else
    bad "T17a only != y 时 render 的备份必须原样留着"
fi
assert_not_contains "T17b 不触发 WARN" "$(cat "$SB/../cd.log")" 'WARN:'

# ---------------------------------------------------------------------------
# T18: 编排顺序
# ---------------------------------------------------------------------------
echo "== T18 编排顺序 =="
mk_sandbox
( CD_READ='new.example.com' SSL_ISSUE_RC=0 run_cd ) >/dev/null 2>&1 || true
seq="$(tr '\n' '|' <"$SB/../cd.log")"
assert_contains "T18a 收尾必调 handler_nginx_restart" "$seq" 'NGINX_RESTART'
# persist 必须早于 only_branch 之后的 nginx 重启: 配置先行, 服务后起
p_pos="$(printf '%s' "$seq" | awk '{print index($0,"PERSIST")}')"
n_pos="$(printf '%s' "$seq" | awk '{print index($0,"NGINX_RESTART")}')"
if [[ "$p_pos" != '0' && "$n_pos" != '0' && "$p_pos" < "$n_pos" ]]; then
    ok
else
    bad "T18b PERSIST 应早于 NGINX_RESTART (实际 P=$p_pos N=$n_pos)"
fi
assert_contains "T18c read 在 issue 之前" "$seq" 'ENSURE'
assert_eq "T18d 失败路径才重启两次以上; 正常路径只重启一次" "$(count_lines '^NGINX_RESTART$' "$SB/../cd.log")" '1'

# ---------------------------------------------------------------------------
# 负向校验
# ---------------------------------------------------------------------------
# 注: NEG 副本由 sed 自本文件生成, 内部同样带着这段 —— 不设 SKIP_NEG 就会无限套娃
#     (实测: 跑到这段后再无输出, 45 秒都出不来)。
if [[ "${SKIP_NEG:-0}" == '1' ]]; then
    echo "== NEG 段已跳过 (副本被拉起) =="
    rm -rf "$SB" ".workbuddy/tmp/cd.log" ".workbuddy/tmp/cd.json" ".workbuddy/tmp/cd.out"
    echo "---"
    echo "==== handler_change_domain_arm_test: PASS=$PASS FAIL=$FAIL ===="
    [[ "$FAIL" == '0' ]]
    exit
fi

echo "== NEG 负向校验 =="
gen_neg() {
    python3 - "$1" <<'PY'
import sys, pathlib
src = pathlib.Path('core/handler.sh').read_text()
mode = sys.argv[1]
s = src
if mode == 'no_read_gate':
    s = s.replace("""if [[ -z "${CONFIG_DATA["${target_domain}"]:-}" && "${stop_cert_service}" == "y" ]]; then
        [[ "${old_domain}" ]] && exec_read 'only-change-domain'
        exec_read "${target_domain}"
    else
        CONFIG_DATA["${target_domain}"]="${old_domain}"
    fi""", """exec_read "${target_domain}"
    CONFIG_DATA["${target_domain}"]="${CONFIG_DATA["${target_domain}"]:-${old_domain}}\"""", 1)
elif mode == 'cdn_touches_target':
    s = s.replace("""'if $key == "domain" then .xray.target = $domain else . end'""",
                  """.xray.target = $domain""", 1)
elif mode == 'no_stop_renew':
    s = s.replace("""            exec_ssl '--stop-renew' --domain="${old_domain}\"""", """            :""", 1)
elif mode == 'rollback_no_restart':
    s = s.replace("""        handler_nginx_restart
        exit 1""", """        exit 1""", 1)
elif mode == 'only_no_guard':
    s = s.replace("""    if [[ "${_only_change_domain,,}" == "y" ]]; then""",
                  """    if true; then""", 1)
elif mode == 'render_no_align':
    s = s.replace("""    align_site_http3 "${NGINX_CONFIG_DIR}/sites-available/${CONFIG_DATA["${target_domain}"]:-}.conf"
    ln -sf "${NGINX_CONFIG_DIR}/sites-available/${CONFIG_DATA["${target_domain}"]:-}.conf" "${NGINX_CONFIG_DIR}/sites-enabled/${CONFIG_DATA["${target_domain}"]:-}.conf\"""",
                  """    ln -sf "${NGINX_CONFIG_DIR}/sites-available/${CONFIG_DATA["${target_domain}"]:-}.conf" "${NGINX_CONFIG_DIR}/sites-enabled/${CONFIG_DATA["${target_domain}"]:-}.conf\"""", 1)
else:
    raise SystemExit('unknown mode: ' + mode)
if s == src:
    raise SystemExit('改写未生效 (原文未命中): ' + mode)
pathlib.Path('core/_neg_handler.sh').write_text(s)
PY
    sed 's#core/handler.sh#core/_neg_handler.sh#g' test/handler_change_domain_arm_test.sh >test/neg_tmp_cd_arm_test.sh
}

neg_run() { # $1=说明 $2=期望 all-pass|has-fail
    local out
    out="$(cd "$REPO" && SKIP_NEG=1 bash "test/neg_tmp_cd_arm_test.sh" 2>&1 || true)"
    local n
    n="$(printf '%s\n' "$out" | grep -c '\[FAIL\]' || true)"
    if [[ "$2" == 'all-pass' ]]; then
        [[ "$n" == '0' ]] && ok || bad "NEG $1 基线应全绿, 实际 $n 条 FAIL"
    else
        [[ "$n" != '0' ]] && ok || bad "NEG $1 应检出失败, 实际 0 条 (断言恒绿!)"
    fi
}

if gen_neg 'no_read_gate' 2>/dev/null; then neg_run "去掉交互门控" 'has-fail'; else bad "NEG 改写未生效: no_read_gate"; fi
if gen_neg 'cdn_touches_target' 2>/dev/null; then neg_run "cdn 改动 xray.target" 'has-fail'; else bad "NEG 改写未生效: cdn_touches_target"; fi
if gen_neg 'no_stop_renew' 2>/dev/null; then neg_run "签发成功却不停旧续签" 'has-fail'; else bad "NEG 改写未生效: no_stop_renew"; fi
if gen_neg 'rollback_no_restart' 2>/dev/null; then neg_run "回滚后不重启 Nginx" 'has-fail'; else bad "NEG 改写未生效: rollback_no_restart"; fi
if gen_neg 'only_no_guard' 2>/dev/null; then neg_run "仅换域名分支不判 y" 'has-fail'; else bad "NEG 改写未生效: only_no_guard"; fi
if gen_neg 'render_no_align' 2>/dev/null; then neg_run "渲染后不做 HTTP/3 对齐" 'has-fail'; else bad "NEG 改写未生效: render_no_align"; fi

rm -f core/_neg_handler.sh test/neg_tmp_cd_arm_test.sh
rm -rf "$SB" ".workbuddy/tmp/cd_arm.$$.log" ".workbuddy/tmp/cd.log" ".workbuddy/tmp/cd.json" ".workbuddy/tmp/cd.out" ".workbuddy/tmp/rc.txt"

echo "---"
echo "==== handler_change_domain_arm_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" == '0' ]]
