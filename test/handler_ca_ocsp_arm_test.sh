#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_ca_ocsp_arm_test.sh
# 测试目标: 证书颁发机构切换 (handler_ca_server) 与 OCSP stapling 自适应
#           (handler_update_ocsp_config) 这两条零覆盖臂的**决策层 + 回滚层**回归。
#
# 为什么需要本测试 (审计背景):
#   这两条是 P1 "改证书/改 Nginx 现场" 里后果最不对称的一对:
#     - handler_ca_server 会把**所有在用域名**逐个重新签发。中途失败却不回滚 = 一部分
#       域名是 A 机构的证书、另一部分是 B 机构 —— 到期时间错开、续期任务打架, 用户
#       只会在某个深夜收到"证书已过期"时才发现问题。它的回滚循环是唯一的兜底。
#     - handler_update_ocsp_config 直接用 sed -i 改写**正在运行的 nginx.conf**。LE 不支持
#       OCSP stapling, 不注释掉就 `nginx -t` 直接红; 反过来从 LE 切回 ZeroSSL 不取消
#       注释 = 白丢一层 stapling。两侧刅成 literary "只刅一半" 都是业务损失。
#   此前两条全仓零覆盖。
#
# 锁定不变量:
#   [A] 入参 / 现存值的归一化
#     T1  非法 CA 入参 (非 zerossl|letsencrypt) -> 回退 zerossl
#     T2  入参大小写混合 -> 决策按小写比较, **落盘值必须是小写** (喂给用户/其它脚本读的是它)
#     T3  SCRIPT_CONFIG 里 ca_server 缺失 / null / 非法 -> 视作 zerossl
#   [B] 目标 == 当前
#     T4  只刷新 OCSP (update_ocsp target y), 不重签 / 不 set-ca / 不 persist
#     T5  大小写不同也算相同 (ZeroSSL vs zerossl)
#   [C] 重签发清单构造
#     T6  主域 + CDN + 自定义站点全部纳入, 顺序 = domain -> cdn -> custom_sites
#     T7  cdn == domain -> 只签一次 (去重)
#     T8  cdn 为 null/空 -> 不纳入
#     T9  无 custom_sites 键 -> 不报错, 不影响前两项
#     T10 主域为 null/空 -> 不纳入
#   [D] 成功路径
#     T11 每个域名都带 --ca=<target> 签发
#     T12 SCRIPT_CONFIG 写 ca_server 后 persist 落盘
#     T13 exec_ssl --set-ca <target> 在 persist 之后
#     T14 收尾必刷 OCSP: update_ocsp(<target>, 'y')
#     T15 set-ca 失败 -> _error "failed to set acme default ca"
#   [E] 失败回滚 (本次唯一真正危险的路径)
#     T16 第 2 个域名失败 -> 对**已切换**的每个域名用 --ca=<current> 重签
#     T17 回滚顺序 == 切换顺序
#     T18 回滚后 set-ca <current> + update_ocsp(<current>, 'y')
#     T19 _error 退出, 且**没有** persist (config 保持原 CA)
#     T20 第 1 个就失败 -> switched 为空: 不发起任何回滚重签, 但仍回切 set-ca 与 OCSP
#   [F] handler_update_ocsp_config
#     T21 nginx.conf 不存在 -> rc 0 且不创建文件 (不该凭空产出配置)
#     T22 letsencrypt -> ssl_stapling / ssl_stapling_verify 被注释, 缩进保留
#     T23 幂等: 同方向连续两次结果与一次相同
#     T24 副作用面: ssl_stapling_file / 已注释行 / 无关指令不受影响
#     T25 zerossl -> 取消注释恢复 (含 "#ssl_stapling on" 无空格形态)
#     T26 非法 CA 值 -> 按 zerossl 处理 (保守: 保持 stapling 启用)
#     T27 need_reload != y -> 不校验不重载
#     T28 need_reload=y + nginx 在 + is-active -> nginx -t 后 reload
#     T29 nginx -t 失败 -> _error 退出, 且**不** reload
#     T30 nginx 命令不存在 -> 不动作
#     T31 nginx 服务未 active -> 不 reload (本函数不负责拉起)
#
# 实现备注:
#   - 被测函数会写回全局 SCRIPT_CONFIG, 失败路径经 _error **exit 1** —— 一律在子 shell
#     里跑, 日志 / 退出码 / 配置快照经**文件**回传。
#   - 通过 stub "handler_update_ocsp_config" 记录 CA 臂的调用; OCSP 自身的 sed 行为
#     另用真 nginx.conf 文件单独断言, 两边互不干扰。
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
getfile() { if [[ -f "$1" ]]; then cat "$1"; else printf ''; fi; }

echo "==== handler_ca_ocsp_arm_test ===="

SB=".workbuddy/tmp/caocsp_arm.$$"

ca_fn="$(extract_fn core/handler.sh handler_ca_server)"
ocsp_fn="$(extract_fn core/handler.sh handler_update_ocsp_config)"
for pair in "handler_ca_server:$ca_fn" "handler_update_ocsp_config:$ocsp_fn"; do
    assert_contains "T0 ${pair%%:*} 抽取成功" "${pair#*:}" 'function '
done

# 基准脚本配置: 主域 + CDN + 两个自定义站点, 当前 CA = zerossl
SC_BASE='{"version":"v-test","xray":{},"nginx":{"domain":"a.example.com","cdn":"cdn.example.com","ca_server":"zerossl","custom_sites":[{"domain":"s1.example.com","scheme":"https","host":"127.0.0.1","port":8443},{"domain":"s2.example.com","scheme":"http","host":"10.0.0.1","port":8080}]}}'

NGINX_CONF_TPL='http {
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_stapling_file /etc/xray-script-personal-use-only/ocsp.der;
    ssl_protocols TLSv1.3;
}
'

mk_sandbox() {
    rm -rf "$SB"
    mkdir -p "$SB/nginx" "$SB/script"
    printf '%s' "$NGINX_CONF_TPL" >"$SB/nginx/nginx.conf"
}

reset_conf() { printf '%s' "$NGINX_CONF_TPL" >"$SB/nginx/nginx.conf"; }

mk_sandbox

# ---------------------------------------------------------------------------
# 驱动 1: handler_ca_server
# 环境变量:
#   CA_TARGET        目标 CA (空 = 走函数默认 zerossl)
#   CA_SC            覆盖基准 SCRIPT_CONFIG
#   CS_FAIL_DOMAIN   该域名签发失败 (触发回滚)
#   CS_SETCA_RC      exec_ssl --set-ca 的成败
# ---------------------------------------------------------------------------
run_ca() {
    rm -f "$SB/plog" "$SB/cfg" "$SB/rc" "$SB/out"
    (
        # shellcheck disable=SC2034
        CUR_FILE='handler'
        SCRIPT_CONFIG="${CA_SC:-$SC_BASE}"
        exec_ssl() {
            printf 'SSL:%s\n' "$*" >>"$SB/plog"
            case "${1:-}" in
            '--set-ca')
                [[ "${CS_SETCA_RC:-0}" == '0' ]]
                ;;
            '--issue')
                local d=''
                local a=''
                for a in "$@"; do
                    [[ "$a" == --domain=* ]] && d="${a#--domain=}"
                done
                if [[ -n "${CS_FAIL_DOMAIN:-}" && "$d" == "${CS_FAIL_DOMAIN}" ]]; then
                    return 1
                fi
                return 0
                ;;
            *) return 0 ;;
            esac
        }
        handler_update_ocsp_config() { printf 'OCSP:%s\n' "$*" >>"$SB/plog"; return 0; }
        persist_script_config() {
            printf 'PERSIST\n' >>"$SB/plog"
            printf '%s' "${SCRIPT_CONFIG}" >"$SB/cfg"
        }
        _error() {
            printf 'ERROR:%s\n' "$*" >>"$SB/plog"
            exit 1
        }
        eval "$ca_fn"
        handler_ca_server "${CA_TARGET:-}" >"$SB/out" 2>&1
        printf '0' >"$SB/rc"
    ) || true
}

ca_log() { getfile "$SB/plog"; }
ca_cfg() { getfile "$SB/cfg"; }
ca_rc() { [[ -f "$SB/rc" ]] && printf '0' || printf '1'; }

# ---------------------------------------------------------------------------
# 驱动 2: handler_update_ocsp_config
# 环境变量:
#   O_CA / O_RELOAD   入参
#   O_NGINX_T_RC      nginx -t 的成败
#   O_ACTIVE_RC       systemctl is-active nginx 的成败
#   O_HAS_NGINX       nginx 命令是否存在
# ---------------------------------------------------------------------------
run_ocsp() {
    rm -f "$SB/oplog" "$SB/rc" "$SB/out"
    (
        # shellcheck disable=SC2034
        CUR_FILE='handler'
        # shellcheck disable=SC2034
        NGINX_CONFIG_DIR="$SB/nginx"
        nginx() {
            printf 'NGINX:%s\n' "$*" >>"$SB/oplog"
            [[ "${O_NGINX_T_RC:-0}" == '0' ]]
        }
        systemctl() {
            printf 'SYSTEMCTL:%s\n' "$*" >>"$SB/oplog"
            [[ "${O_ACTIVE_RC:-0}" == '0' ]]
        }
        cmd_exists() { [[ "${O_HAS_NGINX:-1}" == '1' ]]; }
        _error() {
            printf 'ERROR:%s\n' "$*" >>"$SB/oplog"
            exit 1
        }
        eval "$ocsp_fn"
        handler_update_ocsp_config "${O_CA:-zerossl}" "${O_RELOAD:-n}" >"$SB/out" 2>&1
        printf '0' >"$SB/rc"
    ) || true
}

ocsp_log() { getfile "$SB/oplog"; }

echo "-- [A] 归一化 --"

# T1 非法 CA 入参 -> zerossl
CA_TARGET='gts' run_ca
assert_eq "T1 非法 CA 入参: rc" "$(ca_rc)" '0'
assert_contains "T1 非法 CA 入参: 回切 zerossl 后与当前相同, 只刷 OCSP" "$(ca_log)" 'OCSP:zerossl y'
assert_eq "T1 非法 CA 入参: 未落盘" "$(ca_cfg)" ''

# T2 大小写混合入参 -> 决策按小写比较, 落盘小写
CA_TARGET='LEtsEncrypt' CA_SC="$(printf '%s' "$SC_BASE" | jq -c '.nginx.ca_server = "zerossl"')" run_ca
assert_eq "T2 大小写混合: rc" "$(ca_rc)" '0'
assert_eq "T2 大小写混合: 落盘 value" "$(printf '%s' "$(ca_cfg)" | jq -r '.nginx.ca_server')" 'letsencrypt'
assert_contains "T2 大小写混合: 目标 != 当前 -> 发起重签" "$(ca_log)" 'SSL:--issue --domain=a.example.com'

# T3 现存 ca_server 缺失 / null / 非法 -> 视作 zerossl (目标 zerossl 时应走"相同"分支)
for bad_ca in '' 'null' 'GTS'; do
    if [[ "$bad_ca" == '' ]]; then
        sc="$(printf '%s' "$SC_BASE" | jq -c 'del(.nginx.ca_server)')"
    else
        sc="$(printf '%s' "$SC_BASE" | jq -c --arg v "$bad_ca" '.nginx.ca_server = $v')"
    fi
    CA_TARGET='zerossl' CA_SC="$sc" run_ca
    assert_contains "T3 现存 CA [${bad_ca:-缺失}] 视作 zerossl: 不重签" "$(ca_log)" 'OCSP:zerossl y'
    assert_not_contains "T3 现存 CA [${bad_ca:-缺失}] 视作 zerossl: 无 issue" "$(ca_log)" 'SSL:--issue'
done

echo "-- [B] 目标 == 当前 --"

# T4/T5 相同 (含大小写不同) -> 只刷 OCSP
CA_TARGET='letsencrypt' CA_SC="$(printf '%s' "$SC_BASE" | jq -c '.nginx.ca_server = "letsencrypt"')" run_ca
assert_eq "T4 目标==当前: rc" "$(ca_rc)" '0'
assert_eq "T4 目标==当前: 只 1 条 OCSP" "$(count_lines 'OCSP:' "$SB/plog")" '1'
assert_contains "T4 目标==当前: OCSP 带 y" "$(ca_log)" 'OCSP:letsencrypt y'
assert_not_contains "T4 目标==当前: 不 set-ca" "$(ca_log)" 'SSL:--set-ca'
assert_eq "T4 目标==当前: 不 persist" "$(ca_cfg)" ''

CA_TARGET='ZeroSSL' CA_SC="$(printf '%s' "$SC_BASE" | jq -c '.nginx.ca_server = "zerossl"')" run_ca
assert_eq "T5 大小写不同视为相同: 不重签" "$(count_lines 'SSL:--issue' "$SB/plog")" '0'
assert_contains "T5 大小写不同视为相同: 刷 OCSP" "$(ca_log)" 'OCSP:ZeroSSL y'

echo "-- [C] 重签发清单 --"

# T6 全量: domain -> cdn -> s1 -> s2
CA_TARGET='letsencrypt' CA_SC="$SC_BASE" run_ca
p="$SB/plog"
assert_eq "T6 清单顺序: a 早于 cdn" "$([[ "$(line_no "$p" 'SSL:--issue --domain=a.example.com')" -lt "$(line_no "$p" 'SSL:--issue --domain=cdn.example.com')" ]] && echo yes || echo no)" 'yes'
assert_eq "T6 清单顺序: cdn 早于 s1" "$([[ "$(line_no "$p" 'SSL:--issue --domain=cdn.example.com')" -lt "$(line_no "$p" 'SSL:--issue --domain=s1.example.com')" ]] && echo yes || echo no)" 'yes'
assert_eq "T6 清单顺序: s1 早于 s2" "$([[ "$(line_no "$p" 'SSL:--issue --domain=s1.example.com')" -lt "$(line_no "$p" 'SSL:--issue --domain=s2.example.com')" ]] && echo yes || echo no)" 'yes'
assert_eq "T6 清单总数 4" "$(count_lines 'SSL:--issue' "$p")" '4'

# T7 cdn == domain -> 只签一次
CA_TARGET='letsencrypt' CA_SC="$(printf '%s' "$SC_BASE" | jq -c '.nginx.cdn = .nginx.domain')" run_ca
assert_eq "T7 cdn==domain 去重: 出现 0 次 cdn 签发" "$(count_lines 'SSL:--issue --domain=cdn.example.com' "$SB/plog")" '0'
assert_eq "T7 cdn==domain 去重: 总数为 3" "$(count_lines 'SSL:--issue' "$SB/plog")" '3'

# T8 cdn 为 null -> 不纳入
CA_TARGET='letsencrypt' CA_SC="$(printf '%s' "$SC_BASE" | jq -c '.nginx.cdn = null')" run_ca
assert_eq "T8 cdn=null: 总数 3" "$(count_lines 'SSL:--issue' "$SB/plog")" '3'
assert_eq "T8 cdn=null: rc" "$(ca_rc)" '0'

# T9 无 custom_sites 键
CA_TARGET='letsencrypt' CA_SC="$(printf '%s' "$SC_BASE" | jq -c 'del(.nginx.custom_sites)')" run_ca
assert_eq "T9 无 custom_sites: 总数 2" "$(count_lines 'SSL:--issue' "$SB/plog")" '2'
assert_eq "T9 无 custom_sites: rc" "$(ca_rc)" '0'

# T10 主域 null -> 不纳入
CA_TARGET='letsencrypt' CA_SC="$(printf '%s' "$SC_BASE" | jq -c '.nginx.domain = null')" run_ca
assert_eq "T10 主域=null: 不签主域" "$(count_lines 'SSL:--issue --domain=a.example.com' "$SB/plog")" '0'
assert_contains "T10 主域=null: cdn 仍在" "$(ca_log)" 'SSL:--issue --domain=cdn.example.com'

echo "-- [D] 成功路径 --"

CA_TARGET='letsencrypt' CA_SC="$SC_BASE" run_ca
p="$SB/plog"
assert_eq "T11 每个域名都带目标 CA: --ca=letsencrypt 计数 4" "$(count_lines 'SSL:--issue --domain=.*--ca=letsencrypt' "$p")" '4'
assert_eq "T12 persist: 落盘 ca_server" "$(printf '%s' "$(ca_cfg)" | jq -r '.nginx.ca_server')" 'letsencrypt'
assert_eq "T13 顺序: persist 早于最终 set-ca" "$([[ "$(line_no "$p" 'PERSIST')" -lt "$(line_no "$p" 'SSL:--set-ca --ca=letsencrypt')" ]] && echo yes || echo no)" 'yes'
assert_contains "T14 收尾刷 OCSP(target,y)" "$(ca_log)" 'OCSP:letsencrypt y'
assert_eq "T14 rc" "$(ca_rc)" '0'

# T15 set-ca 失败 -> _error
CS_SETCA_RC=1 CA_TARGET='letsencrypt' CA_SC="$SC_BASE" run_ca
assert_eq "T15 set-ca 失败: rc 非 0" "$(ca_rc)" '1'
assert_contains "T15 set-ca 失败: _error 提示" "$(ca_log)" 'ERROR:failed to set acme default ca'

echo "-- [E] 失败回滚 --"

# T16-T19 第 2 个域名 (cdn) 失败
CA_TARGET='letsencrypt' CA_SC="$SC_BASE" CS_FAIL_DOMAIN='cdn.example.com' run_ca
lg="$(ca_log)"
assert_eq "T16 回滚 rc 非 0" "$(ca_rc)" '1'
assert_contains "T16 回滚: 已切换的 a 用旧 CA 重签" "$lg" 'SSL:--issue --domain=a.example.com --ca=zerossl'
assert_not_contains "T16 回滚: 未成功的 cdn 不在回滚名单" "$lg" 'SSL:--issue --domain=cdn.example.com --ca=zerossl'
assert_eq "T16 回滚: 回滚重签 1 条" "$(count_lines 'SSL:--issue --domain=.*--ca=zerossl' "$SB/plog")" '1'
assert_contains "T17 回滚: set-ca 回切 old" "$lg" 'SSL:--set-ca --ca=zerossl'
assert_contains "T18 回滚: 刷 OCSP(current,y)" "$lg" 'OCSP:zerossl y'
assert_contains "T18 回滚: _error" "$lg" 'ERROR:'
assert_eq "T19 回滚: 未 persist (未半途改 CA)" "$(ca_cfg)" ''

# T17 顺序: 切换顺序 -> 回滚顺序 (两个都成功过)
CA_TARGET='letsencrypt' CA_SC="$SC_BASE" CS_FAIL_DOMAIN='s2.example.com' run_ca
p="$SB/plog"
n_a="$(grep -n -F -- '--domain=a.example.com --ca=zerossl' "$p" | tail -1 | cut -d: -f1)"
n_cdn="$(grep -n -F -- '--domain=cdn.example.com --ca=zerossl' "$p" | tail -1 | cut -d: -f1)"
n_s1="$(grep -n -F -- '--domain=s1.example.com --ca=zerossl' "$p" | tail -1 | cut -d: -f1)"
assert_eq "T17 回滚顺序: a 早于 cdn" "$([[ "$n_a" -lt "$n_cdn" ]] && echo yes || echo no)" 'yes'
assert_eq "T17 回滚顺序: cdn 早于 s1" "$([[ "$n_cdn" -lt "$n_s1" ]] && echo yes || echo no)" 'yes'
assert_eq "T17 回滚条数 3" "$(count_lines 'SSL:--issue --domain=.*--ca=zerossl' "$p")" '3'

# T20 第 1 个就失败 -> switched 为空
CA_TARGET='letsencrypt' CA_SC="$SC_BASE" CS_FAIL_DOMAIN='a.example.com' run_ca
lg="$(ca_log)"
assert_eq "T20 首个失败: 无回滚重签" "$(count_lines 'SSL:--issue --domain=a.example.com --ca=zerossl' "$SB/plog")" '0'
assert_contains "T20 首个失败: 仍回切 set-ca" "$lg" 'SSL:--set-ca --ca=zerossl'
assert_contains "T20 首个失败: 仍刷 OCSP(current)" "$lg" 'OCSP:zerossl y'
assert_eq "T20 首个失败: rc 非 0" "$(ca_rc)" '1'
assert_eq "T20 首个失败: 未 persist" "$(ca_cfg)" ''

echo "-- [F] handler_update_ocsp_config --"

# T21 nginx.conf 不存在
rm -f "$SB/nginx/nginx.conf"
O_CA='letsencrypt' O_RELOAD='y' run_ocsp
assert_eq "T21 conf 缺失: rc 0" "$(ca_rc)" '0'
assert_eq "T21 conf 缺失: 不创建文件" "$([[ -e "$SB/nginx/nginx.conf" ]] && echo yes || echo no)" 'no'
mk_sandbox

# T22 letsencrypt -> 注释
reset_conf
O_CA='letsencrypt' run_ocsp
c="$(getfile "$SB/nginx/nginx.conf")"
assert_contains "T22 LE: 注释 ssl_stapling on" "$c" '    # ssl_stapling on;'
assert_contains "T22 LE: 注释 ssl_stapling_verify on" "$c" '    # ssl_stapling_verify on;'
assert_contains "T22 LE: 缩进保留" "$c" '    # ssl_stapling on;'
assert_eq "T22 LE: rc" "$(ca_rc)" '0'

# T23 幂等
O_CA='letsencrypt' run_ocsp
assert_eq "T23 LE 二次调用: 内容不变" "$(getfile "$SB/nginx/nginx.conf")" "$c"
assert_contains "T23 LE 二次调用: 不重复加 #" "$(getfile "$SB/nginx/nginx.conf")" '    # ssl_stapling on;'
assert_not_contains "T23 LE 二次调用: 无双井号" "$(getfile "$SB/nginx/nginx.conf")" '# # ssl_stapling'

# T24 副作用面
assert_contains "T24 LE: ssl_stapling_file 不受影响" "$(getfile "$SB/nginx/nginx.conf")" 'ssl_stapling_file /etc/xray-script-personal-use-only/ocsp.der;'
assert_contains "T24 LE: 无关指令不动" "$(getfile "$SB/nginx/nginx.conf")" 'ssl_protocols TLSv1.3;'

# T25 zerossl -> 取消注释恢复
printf 'http {\n    # ssl_stapling on;\n    #ssl_stapling_verify on;\n}\n' >"$SB/nginx/nginx.conf"
O_CA='zerossl' run_ocsp
c2="$(getfile "$SB/nginx/nginx.conf")"
assert_contains "T25 zerossl: 恢复 ssl_stapling on" "$c2" '    ssl_stapling on;'
assert_contains "T25 zerossl: 恢复 ssl_stapling_verify on" "$c2" '    ssl_stapling_verify on;'
assert_not_contains "T25 zerossl: 不留 #" "$c2" '#'

# T26 非法 CA -> 按 zerossl
reset_conf
O_CA='gts' run_ocsp
assert_not_contains "T26 非法 CA: 不注释 stapling" "$(getfile "$SB/nginx/nginx.conf")" '# ssl_stapling'
assert_contains "T26 非法 CA: 保持启用" "$(getfile "$SB/nginx/nginx.conf")" '    ssl_stapling on;'

# T27 need_reload != y
reset_conf
O_CA='letsencrypt' O_RELOAD='n' run_ocsp
assert_eq "T27 need_reload=n: 不调用 nginx" "$(count_lines 'NGINX:' "$SB/oplog")" '0'
assert_eq "T27 need_reload=n: 不调用 systemctl" "$(count_lines 'SYSTEMCTL:' "$SB/oplog")" '0'

# T28 need_reload=y + nginx 在 + active
reset_conf
O_CA='letsencrypt' O_RELOAD='y' run_ocsp
assert_eq "T28 reload=y: nginx -t 被调用" "$(count_lines 'NGINX:-t' "$SB/oplog")" '1'
assert_contains "T28 reload=y: systemctl reload" "$(ocsp_log)" 'SYSTEMCTL:-q reload nginx'
assert_contains "T28 reload=y: 先 is-active" "$(ocsp_log)" 'SYSTEMCTL:-q is-active nginx'
assert_eq "T28 reload=y: rc" "$(ca_rc)" '0'

# T29 nginx -t 失败
reset_conf
O_CA='letsencrypt' O_RELOAD='y' O_NGINX_T_RC=1 run_ocsp
assert_eq "T29 nginx -t 失败: rc 非 0" "$(ca_rc)" '1'
assert_contains "T29 nginx -t 失败: _error" "$(ocsp_log)" 'ERROR:nginx.conf check failed after OCSP toggle'
assert_not_contains "T29 nginx -t 失败: 不 reload" "$(ocsp_log)" 'SYSTEMCTL:-q reload nginx'

# T30 nginx 命令不存在
reset_conf
O_CA='letsencrypt' O_RELOAD='y' O_HAS_NGINX=0 run_ocsp
assert_contains "T30 无 nginx 命令: 仍完成注释切换" "$(getfile "$SB/nginx/nginx.conf")" '# ssl_stapling on;'
assert_eq "T30 无 nginx 命令: 不重载" "$(count_lines 'SYSTEMCTL:' "$SB/oplog")" '0'
assert_eq "T30 无 nginx 命令: rc 0" "$(ca_rc)" '0'

# T31 nginx 未 active -> 不 reload
reset_conf
O_CA='letsencrypt' O_RELOAD='y' O_ACTIVE_RC=1 O_NGINX_T_RC=0 run_ocsp
assert_eq "T31 未 active: 不做 nginx -t" "$(count_lines 'NGINX:' "$SB/oplog")" '0'
assert_eq "T31 未 active: 不 reload" "$(count_lines 'SYSTEMCTL:-q reload nginx' "$SB/oplog")" '0'
assert_contains "T31 未 active: 仍探测 is-active" "$(ocsp_log)" 'SYSTEMCTL:-q is-active nginx'

# ---------------------------------------------------------------------------
# 负向校验
# ---------------------------------------------------------------------------
# 注: NEG 副本由 sed 自本文件生成, 内部同样带着这段 —— 不设 SKIP_NEG 就会无限套娃。
if [[ "${SKIP_NEG:-0}" == '1' ]]; then
    echo "== NEG 段已跳过 (副本被拉起) =="
    rm -rf "$SB"
    echo "---"
    echo "==== handler_ca_ocsp_arm_test: PASS=$PASS FAIL=$FAIL ===="
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
if mode == 'no_rollback_loop':
    s = s.replace("""        for rollback_domain in "${switched_domains[@]}"; do
            exec_ssl '--issue' "--domain=${rollback_domain}" "--ca=${current_ca_server}" || true
        done""", """        :""", 1)
elif mode == 'rollback_no_setca':
    s = s.replace("""        exec_ssl '--set-ca' "--ca=${current_ca_server}" || true""", """        :""", 1)
elif mode == 'no_persist_ca':
    s = s.replace("""    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg caServer "${target_ca_server,,}" '.nginx.ca_server = $caServer')"
    persist_script_config""", """    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg caServer "${target_ca_server,,}" '.nginx.ca_server = $caServer')\"""", 1)
elif mode == 'ca_no_lower':
    s = s.replace("""jq --arg caServer "${target_ca_server,,}" '.nginx.ca_server = $caServer'""",
                  """jq --arg caServer "${target_ca_server}" '.nginx.ca_server = $caServer'""", 1)
elif mode == 'cdn_no_dedup':
    s = s.replace("""if [[ -n "${cdn_domain}" && "${cdn_domain}" != 'null' && "${cdn_domain}" != "${domain}" ]]; then""",
                  """if [[ -n "${cdn_domain}" && "${cdn_domain}" != 'null' ]]; then""", 1)
elif mode == 'no_custom_loop':
    s = s.replace("""    while IFS= read -r reissue_domain; do
        [[ -n "${reissue_domain}" ]] || continue
        reissue_targets+=("${reissue_domain}")
    done < <(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.custom_sites // [] | .[] | .domain')""", """    :""", 1)
elif mode == 'same_no_ocsp':
    s = s.replace("""        handler_update_ocsp_config "${target_ca_server}" 'y'
        return 0""", """        return 0""", 1)
elif mode == 'ocsp_le_no_comment':
    s = s.replace("""        sed -i -E 's|^([[:space:]]*)ssl_stapling([[:space:]]+on;)|\\1# ssl_stapling\\2|' "${nginx_conf}\"""", """        :""", 1)
elif mode == 'ocsp_no_reload_gate':
    s = s.replace("""if [[ "${need_reload}" == 'y' ]] && cmd_exists 'nginx' && systemctl -q is-active nginx; then""",
                  """if true; then""", 1)
else:
    raise SystemExit('unknown mode: ' + mode)
if s == src:
    raise SystemExit('改写未生效 (原文未命中): ' + mode)
pathlib.Path('core/_neg_handler.sh').write_text(s)
PY
    sed 's#core/handler.sh#core/_neg_handler.sh#g' test/handler_ca_ocsp_arm_test.sh >test/neg_tmp_caocsp_arm_test.sh
}

neg_run() { # $1=说明 $2=期望 all-pass|has-fail
    local out
    out="$(cd "$REPO" && SKIP_NEG=1 bash "test/neg_tmp_caocsp_arm_test.sh" 2>&1 || true)"
    local n
    n="$(printf '%s\n' "$out" | grep -c '\[FAIL\]' || true)"
    if [[ "$2" == 'all-pass' ]]; then
        [[ "$n" == '0' ]] && ok || bad "NEG $1 基线应全绿, 实际 $n 条 FAIL"
    else
        [[ "$n" != '0' ]] && ok || bad "NEG $1 应检出失败, 实际 0 条 (断言恒绿!)"
    fi
}

if gen_neg 'no_rollback_loop' 2>/dev/null; then neg_run "失败后不回滚已切域名" 'has-fail'; else bad "NEG 改写未生效: no_rollback_loop"; fi
if gen_neg 'rollback_no_setca' 2>/dev/null; then neg_run "回滚后不回切 set-ca" 'has-fail'; else bad "NEG 改写未生效: rollback_no_setca"; fi
if gen_neg 'no_persist_ca' 2>/dev/null; then neg_run "成功路径不 persist 新 CA" 'has-fail'; else bad "NEG 改写未生效: no_persist_ca"; fi
if gen_neg 'ca_no_lower' 2>/dev/null; then neg_run "落盘 CA 不做小写归一" 'has-fail'; else bad "NEG 改写未生效: ca_no_lower"; fi
if gen_neg 'cdn_no_dedup' 2>/dev/null; then neg_run "cdn 与主域同值不判重" 'has-fail'; else bad "NEG 改写未生效: cdn_no_dedup"; fi
if gen_neg 'no_custom_loop' 2>/dev/null; then neg_run "漏收自定义站点域名" 'has-fail'; else bad "NEG 改写未生效: no_custom_loop"; fi
if gen_neg 'same_no_ocsp' 2>/dev/null; then neg_run "同 CA 时不刷新 OCSP" 'has-fail'; else bad "NEG 改写未生效: same_no_ocsp"; fi
if gen_neg 'ocsp_le_no_comment' 2>/dev/null; then neg_run "LE 不注释 ssl_stapling" 'has-fail'; else bad "NEG 改写未生效: ocsp_le_no_comment"; fi
if gen_neg 'ocsp_no_reload_gate' 2>/dev/null; then neg_run "OCSP reload 不做门控" 'has-fail'; else bad "NEG 改写未生效: ocsp_no_reload_gate"; fi

rm -f core/_neg_handler.sh test/neg_tmp_caocsp_arm_test.sh
rm -rf "$SB"

echo "---"
echo "==== handler_ca_ocsp_arm_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" == '0' ]]
