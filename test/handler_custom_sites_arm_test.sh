#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_custom_sites_arm_test.sh
# 测试目标: 自定义反代站点链路的**决策层 + 回滚层**回归 —— handler_custom_sites 分发
#           及其五个分支 (list / add / update / delete, update 内含四个子函数)。
#
# 为什么需要本测试 (审计背景):
#   这是 P1 "改 Nginx 现场" 里**写稿面最宽**的一条: 每笔操作同时 touching 四处状态 ——
#   站点 conf 文件、sites-enabled 软链、stream.conf、SCRIPT_CONFIG.custom_sites。任何一步
#   失败而其余已落盘, 就会留下"配好了但 nginx -t 红"或"能跑但重启即丢"的半成品。
#   它的回滚块写得极啰嗦 (每条路径三到五步), 但也正因为啰嗦, 复制粘贴时最容易漏条理
#   —— 此前全仓零覆盖, 这类"少一行 rm"的偏差没有任何东西会报警。
#
#   本测试在**真实文件系统**上跑真 cp/mv/ln/rm 与真 render_custom_site_config /
#   _replace_in_file / parse_proxy_target / rollback_stream_config_backup, 只把"进程外"
#   的 exec_ssl / reload / ensure 桩掉, 因此能断言到"新 conf 真的渲染出来了 / 软链真的
#   指向新 conf / 回滚后旧 conf 内容真的回来了"这类此前无人看守的结果。
#
# 锁定不变量:
#   [A] 分发 (handler_custom_sites)
#     T1  list -> 只调用 show_custom_sites_list
#     T2  add / update / delete -> 各自 (/ 不串台)
#     T3  未知动作 -> _error "unsupported custom site action: ..."
#     T4  空动作 -> 同上
#   [B] 空清单早退
#     T5  update count=0 -> 只 show list, 不读 site-index, 不 persist, rc 0
#     T6  delete count=0 -> 同上
#   [C] add
#     T7  交互顺序: custom-domain 早于 proxy-target
#     T8  代理目标格式非法 -> _error, 且不渲染 / 不签发 / 不 persist
#     T9  custom_sites 键缺失时新建数组
#     T10 port 以 JSON **number** 落盘 (--argjson 而非 --arg)
#     T11 stream.conf 存在 -> 备份到 SCRIPT_CONFIG_DIR
#     T12 stream.conf 不存在 -> 不建备份且不中断 (等价于新建场景)
#     T13 签发失败 -> _error, 无渲染 / 无 config / 无 persist
#     T14 模板缺失 (render 失败) -> 回滚 stream + stop-renew + _error, 不 persist
#     T15 渲染产物: 域名 / socket / upstream 三处占位被替换
#     T16 sites-enabled 软链指向新的 available 文件
#     T17 rebuild_stream_config 收到**含新站点**的 JSON
#     T18 成功: persist 落盘 + 末尾清掉 stream 备份
#     T19 软链失败 (sites-enabled 目录缺失) -> 删 conf + 回滚 stream + stop-renew + _error
#     T20 reload 失败 -> 删 conf/软链 + 回滚 stream + stop-renew + 重试 reload + _error,
#        且**不得** persist (新站点不能进配置)
#   [D] update —— 四个子函数各管一段
#     T21 exec_read 'site-index', 且 CONFIG_DATA['site-count'] 已预置为真实条数
#     T22 两次输入均为空 -> 域名与代理目标都保持旧值 -> 走 same 分支 (不签发)
#     T23 same 分支 + 目标确有变化 -> 提示 "仅更新 upstream"
#     T24 same 分支 -> render 覆写同一份 conf, upstream 变成新目标
#     T25 same 分支 -> rebuild + reload + persist(第 idx 项被替换, 数组长度不变)
#     T26 prepare: 旧 conf 被备份, 成功后备份被清理
#     T27 same 分支 render 失败 -> 备份恢复原 conf + 回滚 stream + _error, 不 persist
#     T28 same 分支 reload 失败 -> 恢复旧 conf + 重建旧软链 + 回滚 stream + 重试 + _error
#     T29 换域名: 先签发新域**再**渲染 (顺序不可逆)
#     T30 换域名: 删除旧 conf 与旧软链
#     T31 换域名成功 -> stop-renew **旧域** (不得停新域)
#     T32 换域名 reload 失败 -> 删新 + 恢复旧 + 旧软链 + 回滚 + stop-renew 新域 + _error
#     T33 无输入源 (read EOF) -> _error input_unavailable, 不落任何现场改动
#     T34 prepare 在两个源文件都缺失时**返回 0** (刻意用 if 而非 [[ ]] &&, 否则 serving
#        函数最后一条会返回 1 触发 set -e / ERR trap)
#   [E] delete
#     T35 count=0 -> return 0 (同 T5)
#     T36 按 idx = 序号-1 精确删除 (index=2 时删掉第二条)
#     T37 站点 conf / 软链不存在时不中断: 流程走到 stop-renew 且 rc 0
#     T38 成功 -> 删 conf/软链 + rebuild + reload + persist(少一项) + stop-renew
#     T39 成功后 conf 备份被清理
#     T40 reload 失败 -> 备份恢复 + 重建软链 + 回滚 stream + 重试 + _error, 不 persist
#
# 实现备注:
#   - update 的四个子函数靠 bash 动态作用域读写父函数的 local —— 必须由父函数
#     handler_custom_site_update 驱动, 单独调用子函数拿不到上下文。
#   - 被测函数会把结果写回全局 SCRIPT_CONFIG, 失败路径经 _error **exit 1** —— 一律在
#     子 shell 里跑, 日志 / 退出码 / 配置快照经**文件**回传。
#   - get_custom_site_socket_name 依赖 openssl/shasum (沙箱可能都没有), 桩为定值;
#     它自己的哈希派生不在本用例的守卫范围内。
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
line_no() { if [[ -f "$1" ]]; then grep -n -F -m1 -- "$2" "$1" | cut -d: -f1 || true; else printf '0'; fi; }
getfile() { if [[ -f "$1" ]]; then cat "$1"; else printf ''; fi; }

echo "==== handler_custom_sites_arm_test ===="

SB=".workbuddy/tmp/csites_arm.$$"

# ---------------------------------------------------------------------------
# 真实函数体
# ---------------------------------------------------------------------------
FN_LIST=(
    handler_custom_sites handler_custom_site_list handler_custom_site_add
    handler_custom_site_update _custom_site_read_inputs _custom_site_prepare
    _custom_site_apply_same _custom_site_apply_change handler_custom_site_delete
    parse_proxy_target render_custom_site_config get_custom_sites_count
    get_custom_site_json_by_index rollback_stream_config_backup
    read_custom_site_domain_update read_custom_site_proxy_target_update
)
declare -A FN_SRC
for f in "${FN_LIST[@]}"; do
    FN_SRC["$f"]="$(extract_fn core/handler.sh "$f")"
    assert_contains "T0 ${f} 抽取成功" "${FN_SRC[$f]}" 'function '
done
repl_fn="$(extract_fn core/_common.sh _replace_in_file)"
assert_contains "T0 _replace_in_file 抽取成功" "$repl_fn" 'function '

declare -A CONFIG_DATA

# 基准配置: 两个自定义站点
SC_BASE='{"version":"v-test","xray":{},"nginx":{"domain":"a.example.com","cdn":null,"custom_sites":[{"domain":"s1.example.com","scheme":"https","host":"127.0.0.1","port":8443},{"domain":"s2.example.com","scheme":"http","host":"10.0.0.1","port":8080}]}}'
SC_EMPTY='{"version":"v-test","xray":{},"nginx":{"domain":"a.example.com","cdn":null}}'

SITE_CONF_TPL='server {
    server_name example.com;
    listen 443 quic;
    add_header Alt-Svc '"'"'h3=":443"'"'"' always;
    location / {
        proxy_pass PROXY_TARGET;
        proxy_http_version 1.1;
    }
    location @fallback {
        proxy_pass http://unix:/dev/shm/nginx/custom_site.sock;
    }
}
'

mk_sandbox() {
    rm -rf "$SB"
    mkdir -p "$SB/nginx/sites-available" "$SB/nginx/sites-enabled" "$SB/nginx/modules-enabled" "$SB/script"
    mkdir -p "$SB/repo/nginx/conf/sites-available"
    printf '%s' "$SITE_CONF_TPL" >"$SB/repo/nginx/conf/sites-available/custom-site.example.com.conf"
    printf 'stream-old\n' >"$SB/nginx/modules-enabled/stream.conf"
    # cp/mv shim: 成功路径会 rm 掉 stream 备份、"还原"也是 mv 完就消失 —— 这类**发生过
    # 但事后无痕**的动作只能靠调用记录观测 (否则断言恒绿: 有没有做都看不出来)。
    mkdir -p "$SB/bin"
    cat >"$SB/bin/cp" <<CPSHIM
#!/usr/bin/env bash
printf 'CP:%s\\n' "\$*" >>"$REPO/$SB/plog"
exec "$(command -v cp)" "\$@"
CPSHIM
    cat >"$SB/bin/mv" <<MVSHIM
#!/usr/bin/env bash
printf 'MV:%s\\n' "\$*" >>"$REPO/$SB/plog"
exec "$(command -v mv)" "\$@"
MVSHIM
    chmod +x "$SB/bin/cp" "$SB/bin/mv"
    cat >"$SB/read.sh" <<'RSEOF'
#!/usr/bin/env bash
case "${1:-}" in
'--custom-domain')
    [[ "${CS_EOF:-0}" == '1' ]] && exit 1
    printf '%s' "${CS_DOMAIN_INPUT:-}"
    ;;
'--proxy-target')
    [[ "${CS_EOF:-0}" == '1' ]] && exit 1
    printf '%s' "${CS_PROXY_INPUT:-}"
    ;;
*) exit 1 ;;
esac
exit 0
RSEOF
    chmod +x "$SB/read.sh"
}

mk_sandbox

# ---------------------------------------------------------------------------
# 驱动
# 环境变量:
#   CS_SC           覆盖基准 SCRIPT_CONFIG
#   CS_ADD_DOMAIN / CS_ADD_PROXY       add/update 的交互输入
#   CS_INDEX        site-index (update/delete 选择序号, 默认 1)
#   CS_DOMAIN_INPUT / CS_PROXY_INPUT   read.sh 的返回值 (空 = 回车保持旧值)
#   CS_EOF=1        read.sh 以非 0 退出 (模拟无输入源)
#   CS_ENSURE_RC / CS_ISSUE_RC / CS_RELOAD_RC / CS_CHECK_RC   各外部环节成败
#   CS_NO_TEMPLATE=1  删掉站点模板 (让 render 失败)
#   CS_NO_ENABLED=1   删掉 sites-enabled 目录 (让 ln 失败)
# ---------------------------------------------------------------------------
run_cs() { # $1=action
    rm -f "$SB/plog" "$SB/cfg" "$SB/rc" "$SB/out"
    (
        # shellcheck disable=SC2034
        CUR_FILE='handler'
        # shellcheck disable=SC2034
        GREEN=$'\033[32m'
        # shellcheck disable=SC2034
        YELLOW=$'\033[33m'
        # shellcheck disable=SC2034
        RED=$'\033[31m'
        # shellcheck disable=SC2034
        NC=$'\033[0m'
        SCRIPT_CONFIG="${CS_SC:-$SC_BASE}"
        # shellcheck disable=SC2034
        NGINX_CONFIG_DIR="$SB/nginx"
        # shellcheck disable=SC2034
        SCRIPT_CONFIG_DIR="$SB/script"
        # shellcheck disable=SC2034
        CONFIG_DIR="$SB/repo"
        # shellcheck disable=SC2034
        READ_PATH="$SB/read.sh"
        PATH="$REPO/$SB/bin:$PATH"
        _i18n() { printf '%s' "${1#.}"; }
        # 注: read.sh 是被 bash 拉起的**子进程**, 交互返回值必须 export 才传得进去 ——
        #     export 只在子 shell 内生效, 不会污染调用方环境。逐个取 `${x:-}` 兜底是
        #     必须的: 直接 `export CS_X` 而它未定义时, set -u 会判"未绑定变量"把整个
        #     子 shell 带走 (实测症状: 每条用例都静默 rc=1, 日志一片空白)。
        CS_EOF="${CS_EOF:-0}"
        CS_DOMAIN_INPUT="${CS_DOMAIN_INPUT:-}"
        CS_PROXY_INPUT="${CS_PROXY_INPUT:-}"
        export CS_EOF CS_DOMAIN_INPUT CS_PROXY_INPUT
        print_warn() { printf 'WARN:%s\n' "$*" >>"$SB/plog"; }
        _warn() { print_warn "$@"; }
        _error() {
            printf 'ERROR:%s\n' "$*" >>"$SB/plog"
            exit 1
        }
        ensure_nginx_support_files() {
            printf 'ENSURE\n' >>"$SB/plog"
            [[ "${CS_ENSURE_RC:-0}" == '0' ]]
        }
        align_site_http3() { printf 'ALIGN:%s\n' "${1:-}" >>"$SB/plog"; return 0; }
        get_custom_site_socket_name() { printf 'sockhash'; }
        get_custom_site_upstream_name() { printf 'custom_site_sockhash'; }
        rebuild_stream_config() { printf 'REBUILD:%s\n' "${1:-}" >>"$SB/plog"; }
        write_stream_config() { :; }
        test_and_reload_nginx() {
            printf 'RELOAD\n' >>"$SB/plog"
            [[ "${CS_RELOAD_RC:-0}" == '0' ]]
        }
        exec_ssl() {
            printf 'SSL:%s\n' "$*" >>"$SB/plog"
            case "${1:-}" in
            '--issue') [[ "${CS_ISSUE_RC:-0}" == '0' ]] ;;
            *) return 0 ;;
            esac
        }
        exec_read() {
            printf 'READ:%s' "${1:-}" >>"$SB/plog"
            [[ "${1:-}" == 'site-index' ]] && printf ' count=%s' "${CONFIG_DATA['site-count']:-}" >>"$SB/plog"
            printf '\n' >>"$SB/plog"
            case "${1:-}" in
            'custom-domain') CONFIG_DATA['custom-domain']="${CS_ADD_DOMAIN:-}" ;;
            'proxy-target') CONFIG_DATA['proxy-target']="${CS_ADD_PROXY:-}" ;;
            'site-index') CONFIG_DATA['site-index']="${CS_INDEX:-1}" ;;
            esac
            return 0
        }
        exec_check() {
            printf 'CHECK:%s\n' "$*" >>"$SB/plog"
            case "${1:-}" in
            '--proxy-target') printf '%s' "${2:-}"; [[ "${CS_CHECK_RC:-0}" == '0' ]] ;;
            *) [[ "${CS_CHECK_RC:-0}" == '0' ]] ;;
            esac
        }
        show_custom_sites_list() { printf 'LIST\n' >>"$SB/plog"; }
        persist_script_config() {
            printf 'PERSIST\n' >>"$SB/plog"
            printf '%s' "${SCRIPT_CONFIG}" >"$SB/cfg"
        }
        eval "$repl_fn"
        local fn=''
        for fn in "${FN_LIST[@]}"; do
            eval "${FN_SRC[$fn]}"
        done
        handler_custom_sites "$1" >"$SB/out" 2>&1
        printf '0' >"$SB/rc"
    ) || true
}

log() { getfile "$SB/plog"; }
cfg() { getfile "$SB/cfg"; }
rc() { if [[ -f "$SB/rc" ]]; then printf '0'; else printf '1'; fi; }
outp() { getfile "$SB/out"; }
conf_of() { getfile "$SB/nginx/sites-available/$1.conf"; }

echo "-- [A] 分发 --"

mk_sandbox
CS_SC="$SC_BASE" run_cs 'list'
assert_eq "T1 list: rc" "$(rc)" '0'
assert_eq "T1 list: 调用 show list" "$(count_lines 'LIST:' "$SB/plog")" '0'
assert_contains "T1 list: LIST 记录存在" "$(log)" 'LIST'
assert_eq "T1 list: 不做任何 SSL 动作" "$(count_lines 'SSL:' "$SB/plog")" '0'
assert_eq "T1 list: 不 persist" "$(cfg)" ''

mk_sandbox
CS_SC="$SC_BASE" CS_ADD_DOMAIN='new.example.com' CS_ADD_PROXY='https://10.1.1.1:9443' run_cs 'add'
assert_eq "T2 add 走通" "$(rc)" '0'
assert_contains "T2 add: 签发新域" "$(log)" 'SSL:--issue --domain=new.example.com'

mk_sandbox
CS_SC="$SC_BASE" CS_INDEX=1 CS_PROXY_INPUT='https://9.9.9.9:9443' run_cs 'update'
assert_eq "T2 update 走通" "$(rc)" '0'
assert_contains "T2 update: 先 show list" "$(log)" 'LIST'
assert_eq "T2 update: 确实无 issue" "$(count_lines 'SSL:--issue' "$SB/plog")" '0'

mk_sandbox
CS_SC="$SC_BASE" CS_INDEX=1 run_cs 'delete'
assert_eq "T2 delete 走通" "$(rc)" '0'
assert_contains "T2 delete: stop-renew 被删站点" "$(log)" 'SSL:--stop-renew --domain=s1.example.com'

mk_sandbox
CS_SC="$SC_BASE" run_cs 'purge'
assert_eq "T3 未知动作: rc 非 0" "$(rc)" '1'
assert_contains "T3 未知动作: _error" "$(log)" 'ERROR:unsupported custom site action: purge'

mk_sandbox
CS_SC="$SC_BASE" run_cs ''
assert_eq "T4 空动作: rc 非 0" "$(rc)" '1'
assert_contains "T4 空动作: _error" "$(log)" 'ERROR:unsupported custom site action:'

echo "-- [B] 空清单早退 --"

mk_sandbox
CS_SC="$SC_EMPTY" run_cs 'update'
assert_contains "T5 update count=0: show list" "$(log)" 'LIST'
assert_eq "T5 update count=0: 不读 site-index" "$(count_lines 'READ:site-index' "$SB/plog")" '0'
assert_eq "T5 update count=0: 不 persist" "$(cfg)" ''
assert_eq "T5 update count=0: rc" "$(rc)" '0'

mk_sandbox
CS_SC="$SC_EMPTY" run_cs 'delete'
assert_contains "T6 delete count=0: show list" "$(log)" 'LIST'
assert_eq "T6 delete count=0: 不读 site-index" "$(count_lines 'READ:site-index' "$SB/plog")" '0'
assert_eq "T6 delete count=0: rc" "$(rc)" '0'

echo "-- [C] add --"

mk_sandbox
CS_SC="$SC_EMPTY" CS_ADD_DOMAIN='new.example.com' CS_ADD_PROXY='https://10.1.1.1:9443' run_cs 'add'
p="$SB/plog"
assert_eq "T7 交互顺序: 域名早于代理目标" "$([[ "$(line_no "$p" 'READ:custom-domain')" -lt "$(line_no "$p" 'READ:proxy-target')" ]] && echo yes || echo no)" 'yes'

mk_sandbox
CS_SC="$SC_EMPTY" CS_ADD_DOMAIN='new.example.com' CS_ADD_PROXY='not-a-url' run_cs 'add'
assert_eq "T8 目标非法: rc 非 0" "$(rc)" '1'
assert_contains "T8 目标非法: _error" "$(log)" 'ERROR:failed to parse proxy target'
assert_eq "T8 目标非法: 不 render" "$(count_lines 'ENSURE' "$SB/plog")" '0'
assert_eq "T8 目标非法: 不 persist" "$(cfg)" ''

# T9/T10/T11/T15-T18 成功路径
mk_sandbox
CS_SC="$SC_EMPTY" CS_ADD_DOMAIN='new.example.com' CS_ADD_PROXY='https://10.1.1.1:9443' run_cs 'add'
lg() { getfile "$SB/plog"; }
assert_eq "T9 custom_sites 缺失时新建: rc" "$(rc)" '0'
assert_eq "T9 custom_sites: 长度 1" "$(cfg | jq -r '.nginx.custom_sites | length')" '1'
assert_eq "T10 port 类型 number" "$(cfg | jq -r '.nginx.custom_sites[0].port | type')" 'number'
assert_eq "T10 port 值" "$(cfg | jq -r '.nginx.custom_sites[0].port')" '9443'
assert_eq "T10 host/scheme" "$(cfg | jq -r '.nginx.custom_sites[0].scheme + " " + .nginx.custom_sites[0].host')" 'https 10.1.1.1'
assert_contains "T11 stream 备份: ensure 被调用" "$(lg)" 'ENSURE'
assert_contains "T11 stream 备份: cp 记录存在" "$(lg)" "CP:-f $SB/nginx/modules-enabled/stream.conf $SB/script/stream.conf.custom-sites.bak"
c="$(conf_of 'new.example.com')"
assert_contains "T15 渲染: 占位域名被替换" "$c" 'server_name new.example.com;'
assert_not_contains "T15 渲染: 模板域名残留" "$c" 'server_name example.com;'
assert_contains "T15 渲染: PROXY_TARGET 被替换" "$c" 'proxy_pass https://10.1.1.1:9443;'
assert_not_contains "T15 渲染: PROXY_TARGET 残留" "$c" 'PROXY_TARGET'
assert_contains "T15 渲染: socket 占位被替换" "$c" 'unix:/dev/shm/nginx/sockhash.sock'
assert_contains "T15 渲染: 调了 HTTP/3 对齐" "$(lg)" 'ALIGN:'
assert_eq "T16 软链指向新 available" "$([[ -L "$SB/nginx/sites-enabled/new.example.com.conf" ]] && readlink "$SB/nginx/sites-enabled/new.example.com.conf" || echo none)" "$SB/nginx/sites-available/new.example.com.conf"
assert_contains "T17 rebuild 收到含新站点的 JSON" "$(lg)" '"domain": "new.example.com"'
assert_contains "T17 rebuild JSON 保留原主域" "$(lg)" '"domain": "a.example.com"'
assert_contains "T18 persist 落盘" "$(lg)" 'PERSIST'
assert_eq "T18 成功后清理流备份" "$([[ -e "$SB/script/stream.conf.custom-sites.bak" ]] && echo yes || echo no)" 'no'

# T12 无 stream.conf -> 不建备份且不中断
mk_sandbox
rm -f "$SB/nginx/modules-enabled/stream.conf"
CS_SC="$SC_EMPTY" CS_ADD_DOMAIN='new.example.com' CS_ADD_PROXY='https://10.1.1.1:9443' run_cs 'add'
assert_eq "T12 无 stream.conf: rc" "$(rc)" '0'
assert_not_contains "T12 无 stream.conf: 未发生备份 cp" "$(lg)" 'stream.conf.custom-sites.bak'

# T13 签发失败
mk_sandbox
CS_ISSUE_RC=1 CS_SC="$SC_EMPTY" CS_ADD_DOMAIN='new.example.com' CS_ADD_PROXY='https://10.1.1.1:9443' run_cs 'add'
assert_eq "T13 签发失败: rc 非 0" "$(rc)" '1'
assert_contains "T13 签发失败: _error" "$(log)" 'ERROR:failed to issue certificate for new.example.com'
assert_eq "T13 签发失败: 未渲染" "$([[ -e "$SB/nginx/sites-available/new.example.com.conf" ]] && echo yes || echo no)" 'no'
assert_eq "T13 签发失败: 未 persist" "$(cfg)" ''

# T14 模板缺失 -> render 失败
mk_sandbox
rm -f "$SB/repo/nginx/conf/sites-available/custom-site.example.com.conf"
CS_SC="$SC_EMPTY" CS_ADD_DOMAIN='new.example.com' CS_ADD_PROXY='https://10.1.1.1:9443' run_cs 'add'
assert_eq "T14 render 失败: rc 非 0" "$(rc)" '1'
assert_contains "T14 render 失败: _error" "$(log)" 'ERROR:failed to render custom site config'
assert_contains "T14 render 失败: 回滚 stream" "$(log)" 'SSL:--stop-renew --domain=new.example.com'
assert_eq "T14 render 失败: 未 persist" "$(cfg)" ''

# T19 软链失败
mk_sandbox
rm -rf "$SB/nginx/sites-enabled"
CS_SC="$SC_EMPTY" CS_ADD_DOMAIN='new.example.com' CS_ADD_PROXY='https://10.1.1.1:9443' run_cs 'add'
assert_eq "T19 软链失败: rc 非 0" "$(rc)" '1'
assert_contains "T19 软链失败: _error" "$(log)" 'ERROR:failed to enable custom site config'
assert_eq "T19 软链失败: conf 被清" "$([[ -e "$SB/nginx/sites-available/new.example.com.conf" ]] && echo yes || echo no)" 'no'
assert_contains "T19 软链失败: stop-renew" "$(log)" 'SSL:--stop-renew --domain=new.example.com'
assert_eq "T19 软链失败: 未 persist" "$(cfg)" ''

# T20 reload 失败
mk_sandbox
rm -f "$SB/nginx/modules-enabled/stream.conf"
CS_RELOAD_RC=1 CS_SC="$SC_EMPTY" CS_ADD_DOMAIN='new.example.com' CS_ADD_PROXY='https://10.1.1.1:9443' run_cs 'add'
lg() { getfile "$SB/plog"; }
assert_eq "T20 reload 失败: rc 非 0" "$(rc)" '1'
assert_contains "T20 reload 失败: _error" "$(lg)" 'ERROR:failed to apply custom site new.example.com'
assert_eq "T20 reload 失败: conf 被清" "$([[ -e "$SB/nginx/sites-available/new.example.com.conf" ]] && echo yes || echo no)" 'no'
assert_eq "T20 reload 失败: 软链被清" "$([[ -e "$SB/nginx/sites-enabled/new.example.com.conf" ]] && echo yes || echo no)" 'no'
assert_contains "T20 reload 失败: stop-renew" "$(lg)" 'SSL:--stop-renew --domain=new.example.com'
assert_eq "T20 reload 失败: 重试 reload" "$(count_lines 'RELOAD' "$SB/plog")" '2'
assert_eq "T20 reload 失败: 不 persist" "$(cfg)" ''
assert_eq "T20 reload 失败: stream.conf 被删除 (无备份时不留空壳)" "$([[ -e "$SB/nginx/modules-enabled/stream.conf" ]] && echo yes || echo no)" 'no'

echo "-- [D] update --"

# 预置: 旧站点 conf 与软链
mk_sandbox
printf 'server { server_name s1.example.com; proxy_pass https://127.0.0.1:8443; }\n' >"$SB/nginx/sites-available/s1.example.com.conf"
ln -sf "$SB/nginx/sites-available/s1.example.com.conf" "$SB/nginx/sites-enabled/s1.example.com.conf"
CS_SC="$SC_BASE" CS_INDEX=1 run_cs 'update'
lg() { getfile "$SB/plog"; }
assert_eq "T21 site-index 读取" "$(count_lines 'READ:site-index count=2' "$SB/plog")" '1'
assert_eq "T22 空输入: 保持旧域名, 不签发" "$(count_lines 'SSL:--issue' "$SB/plog")" '0'
assert_eq "T22 空输入: rc" "$(rc)" '0'
assert_contains "T22 空输入: 走 same 分支并渲染同一份 conf" "$(conf_of 's1.example.com')" 'server_name s1.example.com;'
# T24/T25/T26 目标有变化

mk_sandbox
printf 'server { server_name s1.example.com; proxy_pass https://127.0.0.1:8443; }\n' >"$SB/nginx/sites-available/s1.example.com.conf"
ln -sf "$SB/nginx/sites-available/s1.example.com.conf" "$SB/nginx/sites-enabled/s1.example.com.conf"
CS_SC="$SC_BASE" CS_INDEX=1 CS_PROXY_INPUT='https://9.9.9.9:9443' run_cs 'update'
lg() { getfile "$SB/plog"; }
assert_contains "T23 upstream 提示 (目标确有变化)" "$(outp)" 'custom_sites.upstream_only'
assert_eq "T24 upstream 被替换: rc" "$(rc)" '0'
assert_contains "T24 upstream 被替换" "$(conf_of 's1.example.com')" 'proxy_pass https://9.9.9.9:9443;'
assert_contains "T25 rebuild" "$(lg)" 'REBUILD:'
assert_contains "T25 reload" "$(lg)" 'RELOAD'
assert_contains "T25 persist" "$(lg)" 'PERSIST'
assert_eq "T25 数组长度不变" "$(cfg | jq -r '.nginx.custom_sites | length')" '2'
assert_eq "T25 第 1 项被替换" "$(cfg | jq -r '.nginx.custom_sites[0].host')" '9.9.9.9'
assert_eq "T25 第 2 项不动" "$(cfg | jq -r '.nginx.custom_sites[1].host')" '10.0.0.1'
assert_eq "T25 port 为 number" "$(cfg | jq -r '.nginx.custom_sites[0].port | type')" 'number'
assert_contains "T26 prepare: 备份已生成并清理" "$(lg)" 'PERSIST'
assert_eq "T26 prepare: 备份已清理" "$([[ -e "$SB/script/s1.example.com.custom-site.bak.conf" ]] && echo yes || echo no)" 'no'
assert_eq "T26 prepare: stream 备份已清理" "$([[ -e "$SB/script/stream.conf.custom-sites.bak" ]] && echo yes || echo no)" 'no'

# T27 same 分支 render 失败 -> 恢复旧 conf
mk_sandbox
printf 'server { server_name s1.example.com; proxy_pass OLD_UPSTREAM; }\n' >"$SB/nginx/sites-available/s1.example.com.conf"
ln -sf "$SB/nginx/sites-available/s1.example.com.conf" "$SB/nginx/sites-enabled/s1.example.com.conf"
rm -f "$SB/repo/nginx/conf/sites-available/custom-site.example.com.conf"
CS_SC="$SC_BASE" CS_INDEX=1 CS_PROXY_INPUT='https://9.9.9.9:9443' run_cs 'update'
assert_eq "T27 render 失败: rc 非 0" "$(rc)" '1'
assert_contains "T27 render 失败: _error" "$(log)" 'ERROR:failed to render custom site config'
assert_eq "T27 render 失败: 旧 conf 内容被还原" "$(conf_of 's1.example.com')" 'server { server_name s1.example.com; proxy_pass OLD_UPSTREAM; }'
# 内容相同并不能证明"还原真的发生过" —— 模板 cp 失败时旧 conf 本来就没被动过。
# 真正能区分的是"备份被 mv 回原路径"这个动作本身 (靠 mv shim 记录观测)。
assert_contains "T27 render 失败: 备份确实被 mv 回旧路径" "$(lg)" "MV:-f $SB/script/s1.example.com.custom-site.bak.conf $SB/nginx/sites-available/s1.example.com.conf"
assert_eq "T27 render 失败: 不 persist" "$(cfg)" ''

# T28 same 分支 reload 失败
mk_sandbox
printf 'server { server_name s1.example.com; proxy_pass OLD_UPSTREAM; }\n' >"$SB/nginx/sites-available/s1.example.com.conf"
ln -sf "$SB/nginx/sites-available/s1.example.com.conf" "$SB/nginx/sites-enabled/s1.example.com.conf"
CS_RELOAD_RC=1 CS_SC="$SC_BASE" CS_INDEX=1 CS_PROXY_INPUT='https://9.9.9.9:9443' run_cs 'update'
assert_eq "T28 reload 失败: rc 非 0" "$(rc)" '1'
assert_contains "T28 reload 失败: _error" "$(log)" 'ERROR:failed to update custom site s1.example.com'
assert_eq "T28 reload 失败: 旧 conf 还原" "$(conf_of 's1.example.com')" 'server { server_name s1.example.com; proxy_pass OLD_UPSTREAM; }'
assert_contains "T28 reload 失败: 备份被 mv 回旧路径" "$(lg)" "MV:-f $SB/script/s1.example.com.custom-site.bak.conf $SB/nginx/sites-available/s1.example.com.conf"
assert_eq "T28 reload 失败: 旧软链仍指向 available" "$(readlink "$SB/nginx/sites-enabled/s1.example.com.conf")" "$SB/nginx/sites-available/s1.example.com.conf"
assert_eq "T28 reload 失败: 重试 reload" "$(count_lines 'RELOAD' "$SB/plog")" '2'
assert_eq "T28 reload 失败: 不 persist" "$(cfg)" ''

# T29-T31 换域名
mk_sandbox
printf 'server { server_name s1.example.com; }\n' >"$SB/nginx/sites-available/s1.example.com.conf"
ln -sf "$SB/nginx/sites-available/s1.example.com.conf" "$SB/nginx/sites-enabled/s1.example.com.conf"
CS_SC="$SC_BASE" CS_INDEX=1 CS_DOMAIN_INPUT='new.example.com' run_cs 'update'
lg() { getfile "$SB/plog"; }
p="$SB/plog"
assert_eq "T29 换域: rc" "$(rc)" '0'
assert_eq "T29 换域顺序: issue 早于 ENSURE(渲染)" "$([[ "$(line_no "$p" 'SSL:--issue --domain=new.example.com')" -lt "$(line_no "$p" 'ENSURE')" ]] && echo yes || echo no)" 'yes'
assert_eq "T30 换域: 旧 conf 被删" "$([[ -e "$SB/nginx/sites-available/s1.example.com.conf" ]] && echo yes || echo no)" 'no'
assert_eq "T30 换域: 旧软链被删" "$([[ -e "$SB/nginx/sites-enabled/s1.example.com.conf" ]] && echo yes || echo no)" 'no'
assert_eq "T30 换域: 新 conf 存在" "$([[ -f "$SB/nginx/sites-available/new.example.com.conf" ]] && echo yes || echo no)" 'yes'
assert_contains "T31 stop-renew 旧域" "$(lg)" 'SSL:--stop-renew --domain=s1.example.com'
assert_eq "T31 不停新域续签" "$(count_lines 'SSL:--stop-renew --domain=new.example.com' "$p")" '0'
assert_eq "T31 落盘第 1 项为新域" "$(cfg | jq -r '.nginx.custom_sites[0].domain')" 'new.example.com'

# T32 换域 reload 失败
mk_sandbox
printf 'server { server_name s1.example.com; OLD_MARKER; }\n' >"$SB/nginx/sites-available/s1.example.com.conf"
ln -sf "$SB/nginx/sites-available/s1.example.com.conf" "$SB/nginx/sites-enabled/s1.example.com.conf"
CS_RELOAD_RC=1 CS_SC="$SC_BASE" CS_INDEX=1 CS_DOMAIN_INPUT='new.example.com' CS_PROXY_INPUT='https://7.7.7.7:8443' run_cs 'update'
assert_eq "T32 换域 reload 失败: rc 非 0" "$(rc)" '1'
assert_contains "T32 换域 reload 失败: _error" "$(log)" 'ERROR:failed to switch custom site domain s1.example.com -> new.example.com'
assert_eq "T32 换域 reload 失败: 新 conf 被清" "$([[ -e "$SB/nginx/sites-available/new.example.com.conf" ]] && echo yes || echo no)" 'no'
assert_contains "T32 换域 reload 失败: 旧 conf 恢复" "$(conf_of 's1.example.com')" 'OLD_MARKER'
assert_eq "T32 换域 reload 失败: 旧软链恢复" "$(readlink "$SB/nginx/sites-enabled/s1.example.com.conf")" "$SB/nginx/sites-available/s1.example.com.conf"
assert_contains "T32 换域 reload 失败: stop-renew 新域" "$(log)" 'SSL:--stop-renew --domain=new.example.com'
assert_eq "T32 换域 reload 失败: 不 persist" "$(cfg)" ''

# T33 无输入源 (EOF)
mk_sandbox
CS_EOF=1 CS_SC="$SC_BASE" CS_INDEX=1 run_cs 'update'
assert_eq "T33 EOF: rc 非 0" "$(rc)" '1'
assert_contains "T33 EOF: _error" "$(log)" 'ERROR:handler.input_unavailable'
assert_eq "T33 EOF: 不 persist" "$(cfg)" ''

# T34 prepare 在两源文件都缺失时不得让流程中断
mk_sandbox
rm -f "$SB/nginx/modules-enabled/stream.conf"
CS_SC="$SC_BASE" CS_INDEX=1 CS_PROXY_INPUT='https://9.9.9.9:9443' run_cs 'update'
assert_eq "T34 prepare 全缺失: rc 0" "$(rc)" '0'
assert_contains "T34 prepare 全缺失: 仍渲染" "$(log)" 'ENSURE'
assert_contains "T34 prepare 全缺失: 仍 persist" "$(log)" 'PERSIST'

# T34b prepare 的返回值本身: 它在 update 链路里被**裸调用** (没有 || true / if 包裹),
#      若写成 `[[ -f x ]] && cp`, 一旦两个源文件都缺失, 函数最后一条命令返回 1, 调用点
#      会被 set -e + ERR trap 判成"脚本内部错误"。故必须恒返回 0。
run_prepare() { # $1=场景: both(两个源文件都在) / none(都缺失)
    rm -f "$SB/prc" "$SB/plog"
    (
        # shellcheck disable=SC2034
        NGINX_CONFIG_DIR="$SB/nginx"
        # shellcheck disable=SC2034
        SCRIPT_CONFIG_DIR="$SB/script"
        PATH="$REPO/$SB/bin:$PATH"
        eval "${FN_SRC[_custom_site_prepare]}"
        _measure() {
            # 注: 以下状态变量全部由 eval 注入的 _custom_site_prepare 经 bash 动态作用域
            #     读写 —— shellcheck 看不到跨 eval 的数据流, 逐条前置 SC2034 (directive
            #     必须独占一行, 贴在 local 之前)。
            # shellcheck disable=SC2034
            local old_domain='s1.example.com'
            # shellcheck disable=SC2034
            local new_domain='s1.example.com'
            # shellcheck disable=SC2034
            local old_conf_path=''
            # shellcheck disable=SC2034
            local new_conf_path=''
            # shellcheck disable=SC2034
            local old_link_path=''
            # shellcheck disable=SC2034
            local new_link_path=''
            # shellcheck disable=SC2034
            local old_conf_backup=''
            # shellcheck disable=SC2034
            local stream_backup="${SCRIPT_CONFIG_DIR}/stream.conf.custom-sites.bak"
            local prc=0
            _custom_site_prepare || prc=$?
            printf '%s' "${prc}" >"$SB/prc"
        }
        _measure "$1"
    ) || true
}
mk_sandbox
printf 'server { server_name s1.example.com; OLD_MARKER; }\n' >"$SB/nginx/sites-available/s1.example.com.conf"
run_prepare 'both'
assert_eq "T34b prepare 源文件齐全: rc 0" "$(getfile "$SB/prc")" '0'
assert_contains "T34b prepare 源文件齐全: 真的备份了 conf" "$(getfile "$SB/plog")" "CP:-f $SB/nginx/sites-available/s1.example.com.conf $SB/script/s1.example.com.custom-site.bak.conf"
assert_contains "T34b prepare 源文件齐全: 真的备份了 stream" "$(getfile "$SB/plog")" "CP:-f $SB/nginx/modules-enabled/stream.conf $SB/script/stream.conf.custom-sites.bak"
mk_sandbox
rm -f "$SB/nginx/sites-available/s1.example.com.conf" "$SB/nginx/modules-enabled/stream.conf"
run_prepare 'none'
assert_eq "T34b prepare 源文件全缺失: rc 0 (不得短接成非 0)" "$(getfile "$SB/prc")" '0'
assert_not_contains "T34b prepare 源文件全缺失: 不产生 cp" "$(getfile "$SB/plog")" 'CP:'

# T34c update 侧的非法代理目标: 走到这里说明输入侧校验被绕过 (脚本化调用 / 二次过滤),
#      必须友好报错并原地停住, 而不是带着空 port 继续 —— 空 port 会让 jq --argjson
#      报错并把整份 updated_script_config 置空, 最终被误报成 "failed to render"。
mk_sandbox
CS_SC="$SC_BASE" CS_INDEX=1 CS_PROXY_INPUT='not-a-url' run_cs 'update'
assert_eq "T34c update 目标非法: rc 非 0" "$(rc)" '1'
assert_contains "T34c update 目标非法: _error" "$(log)" 'ERROR:failed to parse proxy target'
assert_not_contains "T34c update 目标非法: 不得走到渲染" "$(log)" 'ENSURE'
assert_eq "T34c update 目标非法: 不 persist" "$(cfg)" ''

echo "-- [E] delete --"

mk_sandbox
CS_SC="$SC_EMPTY" CS_INDEX=1 run_cs 'delete'
assert_contains "T35 delete count=0: show list" "$(log)" 'LIST'
assert_eq "T35 delete count=0: rc" "$(rc)" '0'
assert_eq "T35 delete count=0: 不读 site-index" "$(count_lines 'READ:site-index' "$SB/plog")" '0'

# T36/T37/T38/T39 正常删除第 2 条
mk_sandbox
printf 'server { server_name s2.example.com; }\n' >"$SB/nginx/sites-available/s2.example.com.conf"
ln -sf "$SB/nginx/sites-available/s2.example.com.conf" "$SB/nginx/sites-enabled/s2.example.com.conf"
CS_SC="$SC_BASE" CS_INDEX=2 run_cs 'delete'
lg() { getfile "$SB/plog"; }
assert_eq "T36 按 index-1 删除: rc" "$(rc)" '0'
assert_eq "T36 删掉的是第 2 条" "$(cfg | jq -r '.nginx.custom_sites[0].domain')" 's1.example.com'
assert_eq "T36 剩余长度 1" "$(cfg | jq -r '.nginx.custom_sites | length')" '1'
assert_eq "T38 conf 被删" "$([[ -e "$SB/nginx/sites-available/s2.example.com.conf" ]] && echo yes || echo no)" 'no'
assert_eq "T38 软链被删" "$([[ -e "$SB/nginx/sites-enabled/s2.example.com.conf" ]] && echo yes || echo no)" 'no'
assert_contains "T38 rebuild" "$(lg)" 'REBUILD:'
assert_contains "T38 reload" "$(lg)" 'RELOAD'
assert_contains "T38 stop-renew" "$(lg)" 'SSL:--stop-renew --domain=s2.example.com'
assert_eq "T39 备份已清理" "$([[ -e "$SB/script/s2.example.com.custom-site.bak.conf" ]] && echo yes || echo no)" 'no'

# T37 源 conf 缺失时不中断
mk_sandbox
CS_SC="$SC_BASE" CS_INDEX=1 run_cs 'delete'
assert_eq "T37 源 conf 缺失: rc 0" "$(rc)" '0'
assert_contains "T37 源 conf 缺失: 仍 stop-renew" "$(log)" 'SSL:--stop-renew --domain=s1.example.com'
assert_contains "T37 源 conf 缺失: 仍 persist" "$(log)" 'PERSIST'

# T40 reload 失败
mk_sandbox
printf 'server { server_name s1.example.com; OLD_MARKER; }\n' >"$SB/nginx/sites-available/s1.example.com.conf"
ln -sf "$SB/nginx/sites-available/s1.example.com.conf" "$SB/nginx/sites-enabled/s1.example.com.conf"
CS_RELOAD_RC=1 CS_SC="$SC_BASE" CS_INDEX=1 run_cs 'delete'
assert_eq "T40 reload 失败: rc 非 0" "$(rc)" '1'
assert_contains "T40 reload 失败: _error" "$(log)" 'ERROR:failed to delete custom site s1.example.com'
assert_contains "T40 reload 失败: conf 从备份恢复" "$(conf_of 's1.example.com')" 'OLD_MARKER'
assert_eq "T40 reload 失败: 软链恢复" "$(readlink "$SB/nginx/sites-enabled/s1.example.com.conf")" "$SB/nginx/sites-available/s1.example.com.conf"
assert_eq "T40 reload 失败: 重试 reload" "$(count_lines 'RELOAD' "$SB/plog")" '2'
assert_eq "T40 reload 失败: 不 persist" "$(cfg)" ''

# ---------------------------------------------------------------------------
# 负向校验
# ---------------------------------------------------------------------------
if [[ "${SKIP_NEG:-0}" == '1' ]]; then
    echo "== NEG 段已跳过 (副本被拉起) =="
    rm -rf "$SB"
    echo "---"
    echo "==== handler_custom_sites_arm_test: PASS=$PASS FAIL=$FAIL ===="
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
if mode == 'add_no_stream_backup':
    s = s.replace("""    [[ -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" ]] && cp -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${stream_backup}" """.rstrip() + "\n", "", 1)
elif mode == 'add_reload_fail_no_cleanup':
    s = s.replace("""        rm -f "${conf_path}" "${link_path}"
        rollback_stream_config_backup "${stream_backup}\"""", """        rollback_stream_config_backup "${stream_backup}\"""", 1)
elif mode == 'same_no_restore':
    s = s.replace("""        [[ -f "${old_conf_backup}" ]] && mv -f "${old_conf_backup}" "${old_conf_path}"
        rollback_stream_config_backup "${stream_backup}"
        _error "failed to render custom site config\"""", """        rollback_stream_config_backup "${stream_backup}"
        _error "failed to render custom site config\"""", 1)
elif mode == 'change_no_stop_renew_old':
    s = s.replace("""    exec_ssl '--stop-renew' "--domain=${old_domain}" || true
}""", """}""", 1)
elif mode == 'delete_idx_no_minus':
    s = s.replace("""    updated_script_config="$(echo "${SCRIPT_CONFIG}" | jq --argjson idx "$((site_index - 1))" 'del(.nginx.custom_sites[$idx])')\"""", """    updated_script_config="$(echo "${SCRIPT_CONFIG}" | jq --argjson idx "${site_index}" 'del(.nginx.custom_sites[$idx])')\"""", 1)
elif mode == 'prepare_short_circuit':
    s = s.replace("""    if [[ -f "${old_conf_path}" ]]; then
        cp -f "${old_conf_path}" "${old_conf_backup}"
    fi
    if [[ -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" ]]; then
        cp -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${stream_backup}"
    fi""", """    [[ -f "${old_conf_path}" ]] && cp -f "${old_conf_path}" "${old_conf_backup}"
    [[ -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" ]] && cp -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${stream_backup}\"""", 1)
elif mode == 'count_zero_no_return':
    s = s.replace("""    ((custom_site_count > 0)) || return 0""", """    :""", 1)
elif mode == 'add_no_persist':
    s = s.replace("""    rm -f "${stream_backup}"
    SCRIPT_CONFIG="${updated_script_config}"
    persist_script_config""", """    rm -f "${stream_backup}"
    SCRIPT_CONFIG="${updated_script_config}\"""", 1)
elif mode == 'dispatch_unknown_no_error':
    s = s.replace("""    *) _error "unsupported custom site action: ${1:-}" ;;""", """    *) : ;;""", 1)
else:
    raise SystemExit('unknown mode: ' + mode)
if s == src:
    raise SystemExit('改写未生效 (原文未命中): ' + mode)
pathlib.Path('core/_neg_handler.sh').write_text(s)
PY
    sed 's#core/handler.sh#core/_neg_handler.sh#g' test/handler_custom_sites_arm_test.sh >test/neg_tmp_csites_arm_test.sh
}

neg_run() { # $1=说明 $2=期望 all-pass|has-fail
    local out
    out="$(cd "$REPO" && SKIP_NEG=1 bash "test/neg_tmp_csites_arm_test.sh" 2>&1 || true)"
    local n
    n="$(printf '%s\n' "$out" | grep -c '\[FAIL\]' || true)"
    if [[ "$2" == 'all-pass' ]]; then
        [[ "$n" == '0' ]] && ok || bad "NEG $1 基线应全绿, 实际 $n 条 FAIL"
    else
        [[ "$n" != '0' ]] && ok || bad "NEG $1 应检出失败, 实际 0 条 (断言恒绿!)"
    fi
}

if gen_neg 'add_no_stream_backup' 2>/dev/null; then neg_run "add 不备份 stream.conf" 'has-fail'; else bad "NEG 改写未生效: add_no_stream_backup"; fi
if gen_neg 'add_reload_fail_no_cleanup' 2>/dev/null; then neg_run "add 重载失败不清新站 conf" 'has-fail'; else bad "NEG 改写未生效: add_reload_fail_no_cleanup"; fi
if gen_neg 'same_no_restore' 2>/dev/null; then neg_run "same 分支渲染失败不还原旧 conf" 'has-fail'; else bad "NEG 改写未生效: same_no_restore"; fi
if gen_neg 'change_no_stop_renew_old' 2>/dev/null; then neg_run "换域名后不停旧域续签" 'has-fail'; else bad "NEG 改写未生效: change_no_stop_renew_old"; fi
if gen_neg 'delete_idx_no_minus' 2>/dev/null; then neg_run "delete 不下标减一" 'has-fail'; else bad "NEG 改写未生效: delete_idx_no_minus"; fi
if gen_neg 'prepare_short_circuit' 2>/dev/null; then neg_run "prepare 用 [[ ]] && 短接导致返回非 0" 'has-fail'; else bad "NEG 改写未生效: prepare_short_circuit"; fi
if gen_neg 'count_zero_no_return' 2>/dev/null; then neg_run "空清单不早退" 'has-fail'; else bad "NEG 改写未生效: count_zero_no_return"; fi
if gen_neg 'add_no_persist' 2>/dev/null; then neg_run "add 成功不落盘" 'has-fail'; else bad "NEG 改写未生效: add_no_persist"; fi
if gen_neg 'dispatch_unknown_no_error' 2>/dev/null; then neg_run "未知动作不报错" 'has-fail'; else bad "NEG 改写未生效: dispatch_unknown_no_error"; fi

rm -f core/_neg_handler.sh test/neg_tmp_csites_arm_test.sh
rm -rf "$SB"

echo "---"
echo "==== handler_custom_sites_arm_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" == '0' ]]
