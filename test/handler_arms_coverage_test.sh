#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_arms_coverage_test.sh
# 测试目标: handler.sh 里**最后 7 条零覆盖**分派臂的回归。
#
# 为什么需要本测试: 2026-09-26 全仓审计, 51 条 handler_* 臂中这 7 条在 test/ 下
#   一次都没出现过 —— 改坏了不会有任何用例变红:
#     handler_health / handler_net_status  体检与网络状态转发臂 (有前置守卫)
#     handler_traffic                      流量统计转发臂
#     handler_subscription                 订阅生成转发臂
#     handler_export_config                配置导出转发臂 (有失败兜底)
#     handler_read_xray_config             配置标签读取臂 (有入参校验)
#     handler_xray_version                 Xray 版本决策臂 (四分支 + 网络兜底)
#   它们多是"薄壳 + 前置守卫", 看着简单, 但薄壳恰恰最容易在重构中被改错参数或
#   丢掉守卫 —— 而且没有任何静态检查能发现。
#
# 场景分组 (对应本套测试的四类场景要求):
#   G1 契约     —— 7 条臂都定义、且都被 main() 的 case 覆盖 (CLI 断链能被发现)
#   G2 异常/权限 —— 前置守卫: check.sh 缺失时必须明确报错而非崩溃/静默
#   G3 正常流程 —— 三条转发臂的参数透传必须完整 (少一个参数就是另一条命令)
#   G4 边界/异常 —— 导出失败要兜底报错
#   G5 行为     —— 版本臂: latest / custom / 留空 / 具体版本号 + 稳定版哨兵 + 网络失败兜底
#   G6 行为     —— 配置标签非法入参必须拒绝 (exit 1), 不放行到后续写配
#   G7 行为     —— handler_install 下发给上游安装器的版本参数 (空值/坏值不得下发)
#   G8 行为     —— 装完按二进制回写实际版本; 解析失败不写空配置
#
# 实现: 从 core/handler.sh 抽**真实函数体** eval 注入 (不另写实现, 避免与源码漂移);
#   外部命令与输出助手用桩件替换。子脚本**刻意不带 set -e**: 本用例验的是
#   "控制流选了哪条分支", set -e 会在第一条非 0 处中断, 反而看不到后续分支。
#
# 依赖: bash, jq(仅静态检查段用), awk。不联外网 (curl 已被桩件替换)。
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$REPO"

# shellcheck source=_harness.sh
source "$(dirname -- "$0")/_harness.sh"
h_init 'handler_arms_coverage_test'
h_sandbox >/dev/null
SB="${H_SANDBOX}"
export SB

# ---------------------------------------------------------------------------
# 工具: 抽真实函数体
# ---------------------------------------------------------------------------
# HANDLER_SRC 可被 NEG 段指向"变异副本", 从而验证: 改坏源码后本用例真的会变红。
#   不做这步就无法区分"断言在守护"与"断言恒绿" —— 后者是最危险的假象。
extract_fn() { # $1=函数名
    awk -v fn="$1" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' \
        "${HANDLER_SRC:-core/handler.sh}"
}

# 7 条被测臂
ARMS=(
    handler_health
    handler_net_status
    handler_traffic
    handler_subscription
    handler_export_config
    handler_read_xray_config
    handler_xray_version
)

# ---------------------------------------------------------------------------
h_case 'G1 契约: 7 条臂均已定义, 且被 main() 的 case 覆盖'
# ---------------------------------------------------------------------------
# 意图: 防止"臂还在但 CLI 入口断链"或"CLI 还在但臂被删" —— 两者静态检查都发现不了,
#   表现是用户敲了命令却什么都不发生。
main_case="$(sed -n "$(grep -n '^function main()' core/handler.sh | cut -d: -f1),\$p" core/handler.sh)"
for arm in "${ARMS[@]}"; do
    h_assert_contains "G1 ${arm} 已定义" "$(extract_fn "${arm}")" 'function '"${arm}"
    h_assert_contains "G1 ${arm} 被 main case 调用" "${main_case}" "${arm}"
done

# ---------------------------------------------------------------------------
h_case 'G2 异常/权限: 前置守卫 —— check.sh 缺失时明确报错'
# ---------------------------------------------------------------------------
# 意图: handler_health / handler_net_status 都以 [[ -f "${CHECK_PATH}" ]] 开头。
#   守卫丢了或写成静默 return, 用户敲 --health 会看到"一片空白"却以为体检通过 ——
#   这是"失败伪装成成功", 比直接报错危险得多。
make_guard_runner() { # $1=臂名 $2=CHECK_PATH 是否指向存在的文件(1/0)
    local arm="$1" exists="$2"
    cat <<EOF
#!/usr/bin/env bash
CHECK_PATH="${SB}/fake-check.sh"
ERROR_LOG="${SB}/error.log"
_error() { printf '%s\n' "\${*}" >>"\${ERROR_LOG}"; exit 1; }
_i18n() { printf 'I18N[%s]' "\${1:-}"; }
_audit_log() { printf '%s %s\n' "\${1:-}" "\${2:-}" >>"${SB}/audit.log"; }
bash() { printf 'BASH %s\n' "\${*}" >>"${SB}/bash.log"; return 0; }
[[ "${exists}" -eq 1 ]] && : >"\${CHECK_PATH}" || rm -f "\${CHECK_PATH}"
$(extract_fn "${arm}")
${arm}
printf 'REACHED_END\n'
EOF
}

for arm in handler_health handler_net_status; do
    rm -f "${SB}/error.log" "${SB}/bash.log" "${SB}/audit.log"
    # --- 缺失: 必须报错且**不**转发 ---
    out="$(make_guard_runner "${arm}" 0 | bash -s 2>&1)" || true
    h_assert_contains "G2 ${arm} 缺失时报错(而非静默)" "$(cat "${SB}/error.log" 2>/dev/null)" 'I18N['
    h_assert_not_contains "G2 ${arm} 缺失时不得转发执行" "${out}" 'REACHED_END'
    h_assert_ok "G2 ${arm} 缺失时未调用 check.sh" \
        "$([[ -f "${SB}/bash.log" ]] && grep -c . "${SB}/bash.log" >/dev/null 2>&1 && echo 1 || echo 0)"
    # --- 存在: 正常转发 ---
    rm -f "${SB}/error.log" "${SB}/bash.log"
    out="$(make_guard_runner "${arm}" 1 | bash -s 2>&1)" || true
    h_assert_contains "G2 ${arm} 存在时转发到 check.sh" "$(cat "${SB}/bash.log" 2>/dev/null)" 'BASH'
    h_assert_contains "G2 ${arm} 转发后走到结尾" "${out}" 'REACHED_END'
done

# ---------------------------------------------------------------------------
h_case 'G3 正常流程: 三条转发臂的参数必须完整透传'
# ---------------------------------------------------------------------------
# 意图: 这三条都是 `bash "${XXX_PATH}" <子命令> "$@"`。少传 --subscription/--export
#   就会变成另一条语义的命令(变成打印分享链接 / 变成导入), 而 bash 的退出码可能
#   照样是 0 —— 属于"执行了, 但执行的不是你要的那件事"。
make_fwd_runner() { # $1=臂名 $2=路径变量名 $3=传给臂的参数
    local arm="$1" var="$2" args="$3"
    cat <<EOF
#!/usr/bin/env bash
${var}="${SB}/target.sh"
_error() { printf '%s\n' "\${*}" >>"${SB}/error.log"; exit 1; }
_i18n() { printf 'I18N[%s]' "\${1:-}"; }
_audit_log() { printf '%s %s\n' "\${1:-}" "\${2:-}" >>"${SB}/audit.log"; }
bash() { printf '%s\n' "\${*}" >>"${SB}/fwd.log"; return "${TARGET_RC:-0}"; }
$(extract_fn "${arm}")
${arm} ${args}
EOF
}

# traffic: 无参数转发
rm -f "${SB}/fwd.log"
make_fwd_runner handler_traffic TRAFFIC_PATH '' | bash -s >/dev/null 2>&1 || true
h_assert_contains "G3 traffic 转发到 traffic.sh" "$(cat "${SB}/fwd.log" 2>/dev/null)" "${SB}/target.sh"

# subscription: 必须带 --subscription, 且额外开关要透传
rm -f "${SB}/fwd.log"
make_fwd_runner handler_subscription SHARE_PATH '--no-qr' | bash -s >/dev/null 2>&1 || true
h_assert_contains "G3 subscription 带 --subscription" "$(cat "${SB}/fwd.log" 2>/dev/null)" '--subscription'
h_assert_contains "G3 subscription 透传额外开关 --no-qr" "$(cat "${SB}/fwd.log" 2>/dev/null)" '--no-qr'

# export_config: 必须带 --export, 且输出路径要透传
rm -f "${SB}/fwd.log"
make_fwd_runner handler_export_config BACKUP_PATH "${SB}/out.tar.gz" | bash -s >/dev/null 2>&1 || true
h_assert_contains "G3 export 带 --export" "$(cat "${SB}/fwd.log" 2>/dev/null)" '--export'
h_assert_contains "G3 export 透传输出路径" "$(cat "${SB}/fwd.log" 2>/dev/null)" "${SB}/out.tar.gz"

# ---------------------------------------------------------------------------
h_case 'G4 边界/异常: 转发目标失败时的兜底'
# ---------------------------------------------------------------------------
# 意图: handler_export_config 有 `|| _error`, 而 traffic/subscription 没有
#   (它们只展示信息, 失败由被调用方自己报错)。这个**差异是刻意设计** ——
#   导出失败若不报错, 用户会以为备份成功。断言它存在, 防止被"顺手统一"掉。
rm -f "${SB}/error.log" "${SB}/fwd.log"
TARGET_RC=1 make_fwd_runner handler_export_config BACKUP_PATH '' | bash -s >/dev/null 2>&1 || true
h_assert_contains "G4 export 失败时 _error 兜底" "$(cat "${SB}/error.log" 2>/dev/null)" 'I18N['

# ---------------------------------------------------------------------------
h_case 'G5 行为: 版本臂四分支与网络失败兜底'
# ---------------------------------------------------------------------------
# 意图: latest / custom / 留空(默认) / 具体版本号 四分支。网络失败时必须**留空由上层回退**,
#   不能因 set -e 直接终止整个安装 —— 否则一次 GitHub 抖动就装不上。
# jq 刻意用**真实** jq (不桩): 真实代码是 `curl ... | jq -r ...` 管道, 而"网络失败"
# 能否被兜住, 恰恰取决于 jq 收到空输入时会非 0 退出 —— 把 jq 也桩成恒成功, 这条
# 兜底就永远测不到 (curl 失败但管道退出码取 jq 的, 于是"失败"被吞成"成功")。
make_ver_runner() { # $1=入参 $2=curl 桩体
    # 这里**必须开 set -Eeuo pipefail**: 兜底的真实语义是"网络失败时不因 set -e
    # 终止整个安装"(源码注释即如此), 关掉 -e 后有无兜底的表现完全一样 ——
    # 断言会恒绿, 这正是 NEG4 第一次跑时暴露的问题。
    cat <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
declare -A CONFIG_DATA
SCRIPT_CONFIG='{"xray":{"version":"old"}}'
_error() { printf '%s\n' "\${*}" >>"${SB}/error.log"; exit 1; }
_i18n() { printf 'I18N[%s]' "\${1:-}"; }
_gh_url() { printf '%s' "\${1}"; }
exec_read() { printf 'READ %s\n' "\${*}" >>"${SB}/read.log"; CONFIG_DATA['version']='v9.9.9'; }
persist_script_config() { printf '%s' "\${SCRIPT_CONFIG}" >"${SB}/script_config.json"; }
curl() { printf 'CURL %s\n' "\${*}" >>"${SB}/curl.log"; ${2}; }
$(extract_fn handler_xray_version)
handler_xray_version "${1}"
printf 'VERSION=[%s]\n' "\${CONFIG_DATA['version']:-EMPTY}"
printf 'REACHED_END\n'
EOF
}

rm -f "${SB}/curl.log" "${SB}/read.log"
out="$(make_ver_runner latest "printf '%s' '[{\"tag_name\":\"v1.2.3\"}]'" | bash -s 2>&1)" || true
h_assert_contains "G5 latest 走 releases 列表接口" "$(cat "${SB}/curl.log" 2>/dev/null)" 'releases'
h_assert_contains "G5 latest 取到版本" "${out}" 'VERSION=[v1.2.3]'

rm -f "${SB}/curl.log" "${SB}/read.log"
out="$(make_ver_runner custom "printf '%s' '{\"tag_name\":\"v-should-not-be-used\"}'" | bash -s 2>&1)" || true
h_assert_contains "G5 custom 走交互读取" "$(cat "${SB}/read.log" 2>/dev/null)" 'READ version'
h_assert_not_contains "G5 custom 不联网" "$(cat "${SB}/curl.log" 2>/dev/null || true)" 'CURL'
h_assert_contains "G5 custom 版本来自读取" "${out}" 'VERSION=[v9.9.9]'

# 默认分支 (入参为空/未知): 走 /releases/latest 单对象接口
rm -f "${SB}/curl.log"
out="$(make_ver_runner '' "printf '%s' '{\"tag_name\":\"v7.7.7\"}'" | bash -s 2>&1)" || true
h_assert_contains "G5 默认分支走 releases/latest" "$(cat "${SB}/curl.log" 2>/dev/null)" 'releases/latest'
h_assert_contains "G5 默认分支取到版本" "${out}" 'VERSION=[v7.7.7]'

# 具体版本号 (如 v25.8.3): **直接采用且不联网** —— 下游把它交给 Xray-install 的 --version。
# 曾经的实现把非 latest/custom 的入参一律落进"取最新 release"分支, 用户显式指定的版本
# 被静默忽略 (不报错), 装出来的永远是最新版。
rm -f "${SB}/curl.log"
out="$(make_ver_runner 'v25.8.3' "printf '%s' '{\"tag_name\":\"v-should-not-be-used\"}'" | bash -s 2>&1)" || true
h_assert_contains "G5 具体版本号直接采用" "${out}" 'VERSION=[v25.8.3]'
h_assert_not_contains "G5 具体版本号不联网" "$(cat "${SB}/curl.log" 2>/dev/null || true)" 'CURL'

# 网络失败: curl 非 0 -> jq 收空输入非 0 -> 整条命令替换失败 -> 靠 || 兜底留空,
# 且**不能**因 set -e 终止整个安装 (一次 GitHub 抖动就装不上是最差的体验)
out="$(make_ver_runner latest 'return 7' | bash -s 2>&1)" || true
h_assert_contains "G5 网络失败时版本留空(由上层回退)" "${out}" 'VERSION=[EMPTY]'
h_assert_contains "G5 网络失败时不因 set -e 终止(走到函数末尾)" "${out}" 'REACHED_END'
h_assert_not_contains "G5 网络失败时不得调用 _error 终止" "${out}" 'I18N['

# 稳定版哨兵 'release': 菜单「2. 稳定版(默认)」与一键安装 (handler_quick_install) 传的
# 就是它。它**不是版本号**, 必须在此解析成具体 tag —— 78bcec5 把 case 拆成"具体版本号
# 字面采用"后, 哨兵落进了那一支并被原样下发给上游, 实测拼出 .../download/vrelease/... 而
# 404 (全新机器一键安装直接硬失败; 已装过的机器则是静默没升级)。
rm -f "${SB}/curl.log"
out="$(make_ver_runner 'release' "printf '%s' '{\"tag_name\":\"v8.8.8\"}'" | bash -s 2>&1)" || true
h_assert_contains "G5 release 哨兵走 releases/latest 解析" "$(cat "${SB}/curl.log" 2>/dev/null)" 'releases/latest'
h_assert_contains "G5 release 哨兵解析成具体 tag" "${out}" 'VERSION=[v8.8.8]'
h_assert_not_contains "G5 release 哨兵不得原样下发" "${out}" 'VERSION=[release]'

# 接口返回里没有 tag_name (形状变了/被限流页) -> 必须留空, 不能留下字面 null
# (null 会被当成版本号发出去 -> 拼出 .../download/vnull/... 也是 404)
out="$(make_ver_runner '' "printf '%s' '{}'" | bash -s 2>&1)" || true
h_assert_contains "G5 缺 tag_name 时留空而非字面 null" "${out}" 'VERSION=[EMPTY]'


# ---------------------------------------------------------------------------
h_case 'G6 行为: 配置标签入参校验 (非法入参不得放行)'
# ---------------------------------------------------------------------------
# 意图: handler_read_xray_config 是**写配置链路的第一道门**。若非法 tag 被放行,
#   后面会按未知分支读一堆参数并落盘, 生成一份"看起来正常但协议不对"的配置 ——
#   这类故障要到客户端连不上才被发现, 排查成本极高。
make_tag_runner() { # $1=tag
    cat <<EOF
#!/usr/bin/env bash
declare -A CONFIG_DATA
SCRIPT_CONFIG='{"nginx":{"ca":"ca@example.com"},"xray":{"rules":{"reset":null}}}'
_error() { printf '%s\n' "\${*}" >>"${SB}/error.log"; exit 1; }
_i18n() { printf 'I18N[%s]' "\${1:-}"; }
exec_check() { printf 'CHECK %s\n' "\${*}" >>"${SB}/check.log"
    [[ "\${2:-}" == 'vision' ]] && return 0 || return 1; }
exec_read() { printf '%s\n' "\${1}" >>"${SB}/read.log"; CONFIG_DATA["\${1}"]='x'; }
$(extract_fn handler_read_xray_config)
handler_read_xray_config "${1}"
printf 'TAG=[%s]\n' "\${CONFIG_DATA['tag']:-UNSET}"
EOF
}

# 非法入参: 必须 exit 1 且**一次都不读** (放行被拒绝在门口)
rm -f "${SB}/read.log" "${SB}/check.log"
rc=0
out="$(make_tag_runner 'nosuchproto' | bash -s 2>&1)" || rc=$?
h_assert_rc "G6 非法 tag 非 0 退出" "${rc}" '1'
h_assert_not_contains "G6 非法 tag 不得写入 CONFIG_DATA[tag]" "${out}" 'TAG=[nosuchproto'
h_assert_ok "G6 非法 tag 一次都不读参数" \
    "$([[ -f "${SB}/read.log" ]] && echo 1 || echo 0)"

# 空入参同样是非法
rm -f "${SB}/read.log"
rc=0
out="$(make_tag_runner '' | bash -s 2>&1)" || rc=$?
h_assert_rc "G6 空 tag 非 0 退出" "${rc}" '1'
h_assert_ok "G6 空 tag 一次都不读参数" \
    "$([[ -f "${SB}/read.log" ]] && echo 1 || echo 0)"

# 合法入参: 放行并按 vision 分支读 uuid / target
rm -f "${SB}/read.log"
out="$(make_tag_runner 'vision' | bash -s 2>&1)" || true
h_assert_contains "G6 合法 tag 写入 CONFIG_DATA[tag]" "${out}" 'TAG=[vision]'
h_assert_contains "G6 vision 分支读 uuid" "$(cat "${SB}/read.log" 2>/dev/null)" 'uuid'
h_assert_contains "G6 vision 分支读 target" "$(cat "${SB}/read.log" 2>/dev/null)" 'target'
h_assert_not_contains "G6 vision 分支不读 mKCP seed" "$(cat "${SB}/read.log" 2>/dev/null)" 'seed'

# ---------------------------------------------------------------------------
h_case 'G7 行为: handler_install 下发给上游安装器的版本参数'
# ---------------------------------------------------------------------------
# 意图: 上游 install-release.sh 的 `--version` 只接受具体 tag (它内部规范化成 v${X#v}
#   再拼下载 URL), 且该参数**后跟空值会直接 return 1** (其源码的 `-z "$2"` 分支)。
#   所以"没解析到具体版本"时整条参数都不能发 —— 不传时上游按自己的默认取最新稳定版;
#   发一个坏值 (哨兵 'release' / 字面 null) 反而会让它拼出 404 的下载地址。
#   这里用日志桩冒充上游脚本, 直接断言真实 argv。
make_install_runner() {
    {
        cat <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
declare -A CONFIG_DATA
CUR_FILE='handler'
XRAY_INSTALL_URL='https://example.invalid/install-release.sh'
XRAY_INSTALL_SHA256=''
# 输入经环境变量传入 (heredoc 里嵌多层引号容易出错): 空=配置缺键; __NULL__=显式 null
if [[ "${IN_VERSION_KEY:-}" == '__NULL__' ]]; then
    SCRIPT_CONFIG='{"xray":{"version":null}}'
elif [[ -n "${IN_VERSION_KEY:-}" ]]; then
    SCRIPT_CONFIG="{\"xray\":{\"version\":\"${IN_VERSION_KEY}\"}}"
else
    SCRIPT_CONFIG='{"xray":{}}'
fi
_error() { printf '%s\n' "$*" >>"${SB}/error.log"; exit 1; }
_i18n() { printf 'I18N[%s]' "${1:-}"; }
_gh_url() { printf '%s' "${1}"; }
_audit_log() { :; }
persist_script_config() { printf '%s' "${SCRIPT_CONFIG}" >"${SB}/script_config.json"; }
exec_read() { :; }
handler_bbr() { :; }
_ensure_logrotate() { :; }
heal_mkcp_finalmask() { :; }
export PATH="${SB}/bin:${PATH}"
cmd_exists() { return 0; }
curl() { local u="${!#}"; case "${u}" in *releases/latest) printf '%s' '{"tag_name":"v8.8.8"}' ;; *) printf '%s' '[]' ;; esac; }
_download_verified() { local l="${SB}/installer_link.sh"; rm -f "${l}"; ln -s "${STUBFILE:-${SB}/installer_stub.sh}" "${l}"; printf '%s' "${l}"; }
RUNNER
        extract_fn handler_xray_version
        extract_fn handler_install
        cat <<'RUNNER'
handler_install "${IN_ARG:-}" 'y'
printf 'ARGV=[%s]\n' "$(cat "${SB}/argv.log" 2>/dev/null || echo NONE)"
printf 'CONFIG_VERSION=[%s]\n' "${CONFIG_DATA['version']:-EMPTY}"
RUNNER
    }
}

cat >"${SB}/installer_stub.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SB}/argv.log"
exit 0
STUB
chmod +x "${SB}/installer_stub.sh"

# (1) 具体版本号: 必须原样带上 --version
rm -f "${SB}/argv.log"
out="$(make_install_runner | IN_ARG='v25.8.3' bash -s 2>&1)" || true
h_assert_contains "G7 具体版本号带 --version" "${out}" '--version v25.8.3'
h_assert_contains "G7 安装子命令形态不变" "${out}" 'ARGV=[install -u root'

# (2) 无版本入参 + 配置缺该键: 不得出现 --version (发空值会让上游直接 return 1)
rm -f "${SB}/argv.log"
out="$(make_install_runner | bash -s 2>&1)" || true
h_assert_contains "G7 缺键时仍调用安装器" "${out}" 'ARGV=[install -u root'
h_assert_not_contains "G7 缺键时不发 --version" "${out}" '--version'

# (3) 配置里是显式 null: 同样不得发 --version (jq 对 null 会给出字面 null)
rm -f "${SB}/argv.log"
out="$(make_install_runner | IN_VERSION_KEY='__NULL__' bash -s 2>&1)" || true
h_assert_not_contains "G7 显式 null 时不发 --version" "${out}" '--version'

# (4) 端到端: 菜单稳定版/一键安装传的哨兵 'release' -> 先解析成具体 tag 再下发
rm -f "${SB}/argv.log"
out="$(make_install_runner | IN_ARG='release' bash -s 2>&1)" || true
h_assert_contains "G7 release 哨兵解析成具体 tag 后下发" "${out}" '--version v8.8.8'
h_assert_not_contains "G7 绝不把 release 当版本号下发" "${out}" '--version release'

# (5) 老配置里**残留**的哨兵 'release' (78bcec5 期间一键安装把它当版本号写进了
#     .xray.version): 升级脚本后这些机器也必须能装 —— 它同样不能作为 --version 下发。
rm -f "${SB}/argv.log"
out="$(make_install_runner | IN_VERSION_KEY='release' bash -s 2>&1)" || true
h_assert_contains "G7 残留哨兵时仍调用安装器" "${out}" 'ARGV=[install -u root'
h_assert_not_contains "G7 残留 release 哨兵不下发 --version (老机器免重装自愈)" "${out}" '--version'

# ---------------------------------------------------------------------------
h_case 'G8 行为: 安装后回写实际版本 (以二进制为准)'
# ---------------------------------------------------------------------------
# 意图: .xray.version 原先**只有一个写入点**, 且在安装**之前** (handler_xray_version),
#   记的是"请求的版本"; 它与实际之间有三种漂移 —— 请求了但没换成(显示比实际新)、
#   在脚本外升级(显示比实际旧)、解析失败走兜底(显示与实装无关)。故装完后必须按二进制
#   读回并落盘。反向也断言: 解析失败时**不得**把配置写空 —— 写空会让状态栏红字报
#   "未安装", 且 handler_geodata_cron / handler_toggle_sniff_route_only 都以该字段非空
#   当"已安装"的代理判据。
cat >"${SB}/installer_verstub.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SB}/argv.log"
mkdir -p "${SB}/bin"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'printf "%%s\\n" "%s"\n' "${XRAY_VER_OUT-Xray 25.8.3 (go1.24.0 linux/amd64)}"
} >"${SB}/bin/xray"
chmod +x "${SB}/bin/xray"
exit 0
STUB
chmod +x "${SB}/installer_verstub.sh"

ver_run() { # $1=IN_ARG(可空)  $2=XRAY_VER_OUT(可空=报告为空)
    make_install_runner | STUBFILE="${SB}/installer_verstub.sh" IN_ARG="${1:-}" XRAY_VER_OUT="${2-}" bash -s 2>&1
}

# (a) 装成功: 回写成二进制报告的版本 (故意让"请求的版本"是 v8.8.8, 与实装不同 ——
#     这样才能区分"回写生效"与"只是把请求值写了一遍")
rm -f "${SB}/script_config.json"
out="$(ver_run 'release' 'Xray 25.8.3 (go1.24.0 linux/amd64)')" || true
h_assert_contains "G8 回写实装版本(带 v 前缀)" "${out}" 'CONFIG_VERSION=[v25.8.3]'
h_assert_eq "G8 实装版本已落盘" \
    "$(jq -r '.xray.version' "${SB}/script_config.json" 2>/dev/null || echo '<无配置>')" 'v25.8.3'

# (b) 报告本身自带 v: 不得变成 vv25.8.3 (归一必须幂等)
rm -f "${SB}/script_config.json"
out="$(ver_run 'release' 'Xray v25.8.3 (go1.24.0 linux/amd64)')" || true
h_assert_contains "G8 报告已带 v 时不重复加前缀" "${out}" 'CONFIG_VERSION=[v25.8.3]'

# (c) 读不到版本(输出形态变了/命令失败): 保留请求值, 绝不写空
rm -f "${SB}/script_config.json"
out="$(ver_run 'v25.8.3' '')" || true
h_assert_contains "G8 读不到版本时保留请求值" "${out}" 'CONFIG_VERSION=[v25.8.3]'
h_assert_eq "G8 读不到版本时不写空(落盘仍是请求值)" \
    "$(jq -r '.xray.version' "${SB}/script_config.json" 2>/dev/null || echo '<无配置>')" 'v25.8.3'

# (d) 解析失败时 handler_xray_version **不落盘** (配置逐字节未变)
printf '%s' '{"xray":{"version":"old"}}' >"${SB}/script_config.json"
cp "${SB}/script_config.json" "${SB}/sc_before.json"
out="$(make_ver_runner latest 'return 7' | bash -s 2>&1)" || true
h_assert_eq "G8 解析失败时配置逐字节未被改写" \
    "$(cat "${SB}/script_config.json" 2>/dev/null || echo MISSING)" \
    "$(cat "${SB}/sc_before.json" 2>/dev/null || echo MISSING)"

# (e) 正向对照(与 (d) 配对, 否则"未改写"这条恒真): 解析成功时照常落盘
out="$(make_ver_runner '' "printf '%s' '{\"tag_name\":\"v7.7.7\"}'" | bash -s 2>&1)" || true
h_assert_eq "G8 解析成功时照常落盘(反向对照)" \
    "$(jq -r '.xray.version' "${SB}/script_config.json" 2>/dev/null || echo '<无配置>')" 'v7.7.7'

# ---------------------------------------------------------------------------
h_case 'NEG 负向校验: 把源码改坏, 对应断言必须变红'
# ---------------------------------------------------------------------------
# 意图: 上面 G1~G6 全绿只说明"当前源码满足断言"。若断言写得恒真(比如匹配了一个
#   永远存在的串), 源码被改坏它也照样绿 —— 那种用例等于没写。这里逐个把真实源码
#   改坏, 确认断言**失去**了它依赖的东西, 从而证明用例真的在守护。

# NEG1: 删掉 health/net_status 的前置守卫 -> G2 的"缺失时报错"必须不再成立
sed '/\[\[ -f "\${CHECK_PATH}" \]\] || _error/d' core/handler.sh >"${SB}/h_noguard.sh"
for arm in handler_health handler_net_status; do
    rm -f "${SB}/error.log"
    out="$(HANDLER_SRC="${SB}/h_noguard.sh" make_guard_runner "${arm}" 0 | bash -s 2>&1)" || true
    h_assert_not_contains "NEG1 ${arm} 删守卫后不再报错(证明守卫被断言依赖)" \
        "$(cat "${SB}/error.log" 2>/dev/null)" 'I18N['
done

# NEG2: 去掉 subscription 转发的 --subscription -> G3 必须抓到缺失
sed 's/--subscription //' core/handler.sh >"${SB}/h_nosub.sh"
rm -f "${SB}/fwd.log"
HANDLER_SRC="${SB}/h_nosub.sh" make_fwd_runner handler_subscription SHARE_PATH '' |
    bash -s >/dev/null 2>&1 || true
h_assert_not_contains "NEG2 删 --subscription 后转发串不含它(证明参数被断言依赖)" \
    "$(cat "${SB}/fwd.log" 2>/dev/null)" '--subscription'

# NEG3: 去掉 export 的 || _error 兜底 -> G4 必须抓到
python3 - "${SB}" <<'PY' || true
import pathlib, sys
sb = pathlib.Path(sys.argv[1])
src = pathlib.Path('core/handler.sh').read_text()
needle = ' || _error "$(_i18n \'.handler.backup.export_failed\')"'
out = src.replace(needle, '')
(sb / 'h_noerr.sh').write_text(out)
PY
# 同样校验变异真落地 —— 否则"去掉兜底后仍报错"会被误读成兜底没被断言依赖
if [[ -f "${SB}/h_noerr.sh" ]] && ! cmp -s core/handler.sh "${SB}/h_noerr.sh"; then
    rm -f "${SB}/error.log"
    TARGET_RC=1 HANDLER_SRC="${SB}/h_noerr.sh" \
        make_fwd_runner handler_export_config BACKUP_PATH '' | bash -s >/dev/null 2>&1 || true
    h_assert_not_contains "NEG3 去掉 _error 兜底后不再报错(证明兜底被断言依赖)" \
        "$(cat "${SB}/error.log" 2>/dev/null)" 'I18N['
else
    h_skip 'NEG3 去掉 _error 兜底' '变异未落地(模式串不匹配源码), 该条实际未验证'
fi

# NEG4: 去掉版本臂的网络兜底 `|| CONFIG_DATA['version']=""` -> G5 必须抓到
python3 - "${SB}" <<'PY' || true
import pathlib, sys
sb = pathlib.Path(sys.argv[1])
src = pathlib.Path('core/handler.sh').read_text()
old = """ || CONFIG_DATA['version']=\"\""""
out = src.replace(old, '')
(sb / 'h_nofallback.sh').write_text(out)
PY
# 变异**必须**校验是否真落地: 模式串写错时副本与源文件相同, 断言会拿"没改过的源码"
# 去跑, 于是 NEG 恒失败(或恒成功)而看不出原因 —— 显式检查后至少会登记为 SKIP。
if [[ -f "${SB}/h_nofallback.sh" ]] && ! cmp -s core/handler.sh "${SB}/h_nofallback.sh"; then
    out="$(HANDLER_SRC="${SB}/h_nofallback.sh" make_ver_runner latest 'return 7' | bash -s 2>&1)" || true
    h_assert_not_contains "NEG4 去掉版本兜底后不再走到末尾(证明兜底被断言依赖)" \
        "${out}" 'REACHED_END'
else
    h_skip 'NEG4 去掉版本兜底' '变异未落地(模式串不匹配源码), 该条实际未验证'
fi

# NEG5: 把"具体版本号直接采用"改回"落进默认分支取最新 release" -> G5 新增断言必须抓到
python3 - "${SB}" <<'PY' || true
import pathlib, sys
sb = pathlib.Path(sys.argv[1])
src = pathlib.Path('core/handler.sh').read_text()
old = "CONFIG_DATA['version']=\"${xray_version}\""
new = "CONFIG_DATA['version']=\"$(curl -fsSL \"$(_gh_url 'https://api.github.com/repos/XTLS/Xray-core/releases/latest')\" | jq -r '.tag_name')\""
out = src.replace(old, new)
(sb / 'h_noexplicit.sh').write_text(out)
PY
if [[ -f "${SB}/h_noexplicit.sh" ]] && ! cmp -s core/handler.sh "${SB}/h_noexplicit.sh"; then
    out="$(HANDLER_SRC="${SB}/h_noexplicit.sh" make_ver_runner 'v25.8.3' "printf '%s' '{\"tag_name\":\"v-should-not-be-used\"}'" | bash -s 2>&1)" || true
    h_assert_not_contains "NEG5 改回取最新后不再采用传入版本(证明该分支被断言依赖)" \
        "${out}" 'VERSION=[v25.8.3]'
else
    h_skip 'NEG5 具体版本号分支' '变异未落地(模式串不匹配源码), 该条实际未验证'
fi

# NEG6: 去掉稳定版哨兵分支 ('release' 回落成"具体版本号") -> G5 的哨兵断言必须抓到
python3 - "${SB}" <<'PY' || true
import pathlib, sys
sb = pathlib.Path(sys.argv[1])
src = pathlib.Path('core/handler.sh').read_text()
old = '    "" | release)'
if old in src:
    (sb / 'h_norelease.sh').write_text(src.replace(old, '    "")', 1))
PY
if [[ -f "${SB}/h_norelease.sh" ]] && ! cmp -s core/handler.sh "${SB}/h_norelease.sh"; then
    out="$(HANDLER_SRC="${SB}/h_norelease.sh" make_ver_runner 'release' "printf '%s' '{\"tag_name\":\"v8.8.8\"}'" | bash -s 2>&1)" || true
    h_assert_contains "NEG6 去掉哨兵分支后 release 被原样采用(证明 G5 该断言依赖此分支)" \
        "${out}" 'VERSION=[release]'
else
    h_skip 'NEG6 稳定版哨兵分支' '变异未落地(模式串不匹配源码), 该条实际未验证'
fi

# NEG7: 去掉版本参数的"按需拼装"守卫 (改成无条件带上 --version) -> G7 的
#   "缺键时不发 --version" 必须变红。
#   注: `// empty` 与 `!= 'null'` 是**冗余的两道**, 只拆一道看不出效果 (拆了 jq 那道,
#   还有 `!= 'null'` 兜着) —— 所以这里拆的是参数拼装这一道。
python3 - "${SB}" <<'PY' || true
import pathlib, re, sys
sb = pathlib.Path(sys.argv[1])
src = pathlib.Path('core/handler.sh').read_text()
head = '        local version_arg="${CONFIG_DATA[\'version\']:-}"'
tail = '        fi'
pat = re.compile(re.escape(head) + r'\n(?:.*\n)*?' + re.escape(tail) + r'\n')
new = "        local -a installer_args=(install -u root --version \"${CONFIG_DATA['version']:-}\")\n"
out, n = pat.subn(lambda _m: new, src, count=1)
if n == 1:
    (sb / 'h_noargguard.sh').write_text(out)
PY
if [[ -f "${SB}/h_noargguard.sh" ]] && ! cmp -s core/handler.sh "${SB}/h_noargguard.sh"; then
    rm -f "${SB}/argv.log"
    out="$(HANDLER_SRC="${SB}/h_noargguard.sh" make_install_runner | bash -s 2>&1)" || true
    h_assert_contains "NEG7 去掉归一/拼装守卫后缺键也发 --version(证明该守卫被断言依赖)" \
        "${out}" '--version'
else
    h_skip 'NEG7 版本参数拼装守卫' '变异未落地(模式串不匹配源码), 该条实际未验证'
fi

# NEG8: 去掉"装完按二进制回写"整段 -> G8 的回写断言必须变红
#   注: 变异后 CONFIG_DATA['version'] 停在"请求的版本"(桩里是 v8.8.8), 所以只要断言
#   仍然成立就说明回写没生效 —— 这正是 G8(a) 能区分"回写"与"把请求值又写一遍"的原因。
python3 - "${SB}" <<'PY' || true
import pathlib, re, sys
sb = pathlib.Path(sys.argv[1])
src = pathlib.Path('core/handler.sh').read_text()
head = "        local installed_ver=''"
tail = '        fi'
pat = re.compile(re.escape(head) + r'\n(?:.*\n)*?' + re.escape(tail) + r'\n')
out, n = pat.subn(lambda _m: '', src, count=1)
if n == 1:
    (sb / 'h_nowriteback.sh').write_text(out)
PY
if [[ -f "${SB}/h_nowriteback.sh" ]] && ! cmp -s core/handler.sh "${SB}/h_nowriteback.sh"; then
    rm -f "${SB}/script_config.json"
    out="$(HANDLER_SRC="${SB}/h_nowriteback.sh" make_install_runner |
        STUBFILE="${SB}/installer_verstub.sh" IN_ARG='release' \
        XRAY_VER_OUT='Xray 25.8.3 (go1.24.0 linux/amd64)' bash -s 2>&1)" || true
    h_assert_not_contains "NEG8 去掉回写后不再出现实装版本(证明 G8 该断言依赖回写)" \
        "${out}" 'CONFIG_VERSION=[v25.8.3]'
else
    h_skip 'NEG8 装后回写' '变异未落地(模式串不匹配源码), 该条实际未验证'
fi

h_finish
