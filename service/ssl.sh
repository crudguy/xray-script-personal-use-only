#!/usr/bin/env bash
# =============================================================================
# 脚本名称: ssl.sh
# 脚本仓库: https://github.com/crudguy/xray-script-personal-use-only
# 功能描述: 使用 acme.sh 管理 SSL 证书的脚本。
#           支持安装/更新/卸载 acme.sh，签发/续期/停止续期证书，
#           检查证书状态和信息，以及管理 Nginx 配置。
# 作者: crudguy
# 时间: 2026-09-19
# 版本: 1.0.0
# 依赖: bash, curl, wget, git, jq, sed, awk, grep, nginx, systemctl, acme.sh
# 配置:
#   - ${HOME}/.acme.sh/: acme.sh 的默认安装和数据目录
#   - ${NGINX_CONFIG_PATH}/: Nginx 配置文件目录
#   - ${ACME_WEBROOT_PATH}/: 用于 HTTP-01 挑战的临时 webroot 目录
#   - ${SSL_CERT_PATH}/: 存放签发证书的目录
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言设置 (language)
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
# 相关链接:
#   - acme.sh 官方仓库: https://github.com/acmesh-official/acme.sh
#   - ZeroSSL CA: https://zerossl.com/
#
# Copyright (C) 2026 crudguy
# =============================================================================

# --- 共享头部: 严格模式 / ERR trap / PATH / 颜色 / 目录常量 / i18n 公共函数 ---
# 实际内容由 core/_common.sh 提供 (所有 source 它的脚本共用, 消除副本漂移);
#   共用数此前写作 13 —— 那个随容器方案一起下线的服务脚本没了之后就不再是这个数,
#   故此处不再写死绝对值 (写死就得跟着增删一起改, 只会再次漂移)。设计取舍 (为何
# install.sh 不在此列, 为何用 $0 而非 BASH_SOURCE, 为何 PATH 是白名单而非追加) 见该文件。
# 注: 下面这行刻意留在每个脚本里 —— shellcheck 的 `set -e` 判定不跨 source,
#     移走会让本脚本内的 `cd` 全被误报 SC2164。
set -Eeuo pipefail

_XRAY_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
if [[ ! -f "${_XRAY_SCRIPT_DIR}/../core/_common.sh" ]]; then
    printf '\033[31m[错误]\033[0m 脚本文件不完整: 缺少 %s\n' "../core/_common.sh" >&2
    printf '        (请重新克隆仓库, 或运行 install.sh 重新下载)\n' >&2
    exit 1
fi
# shellcheck source=../core/_common.sh
source "${_XRAY_SCRIPT_DIR}/../core/_common.sh"

readonly NGINX_CONFIG_PATH='/usr/local/nginx/conf'
readonly ACME_WEBROOT_PATH='/var/www/_zerossl'
readonly SSL_CERT_PATH="${NGINX_CONFIG_PATH}/certs"

# 域名格式正则: 定义已迁至 core/_common.sh 作为单一来源 (与 core/check.sh 的
# valid_domain() 共用), 此处不再重复定义, 直接复用 _common.sh 注入的 DOMAIN_REGEX。
# 用途: 校验证书域名参数, 防止 ".."、"*"、"/" 等非法字符进入 rm -rf / openssl / grep -E。

# 邮箱格式正则 (单一来源: core/_common.sh 的 EMAIL_REGEX; 与 DOMAIN_REGEX 同类处理,
#  由 _common.sh 注入本文件, 不再保留副本 —— test/ssl_test.sh 的 T6b 锁定该模式)。
# 用途: 校验 ACME 账号邮箱 —— 该值会以 `sh -s email=...` 作为位置参数传给 acme.sh
# 安装器, 不校验的话畸形输入会一路带到证书签发, 最后以"acme.sh 报错"的形式暴露,
# 用户无从判断是自己填错还是脚本坏了。与域名同等对待, 在入口就拦下。

# --- 全局变量声明 ---
declare ACTION=''
declare DOMAIN=''
declare ACCOUNT_EMAIL=''
declare CA_SERVER=''
declare CA_SERVER_EXPLICIT=0





# =============================================================================
# 函数名称: normalize_ca_server
# 功能描述: 规范化 CA 参数，仅允许 zerossl / letsencrypt，非法值回落 zerossl。
# 参数:
#   $1: 原始 CA 参数
# 返回值: 标准化后的 CA 名称
# =============================================================================
function normalize_ca_server() {
    local ca_server="${1:-}"
    case "${ca_server,,}" in
    zerossl | letsencrypt)
        echo "${ca_server,,}"
        ;;
    *)
        echo 'zerossl'
        ;;
    esac
}

# =============================================================================
# 函数名称: get_config_ca_server
# 功能描述: 从脚本配置读取 nginx.ca_server，并执行标准化。
# 返回值: 标准化后的 CA 名称
# =============================================================================
function get_config_ca_server() {
    local config_ca_server
    config_ca_server="$(jq -r '.nginx.ca_server' "${SCRIPT_CONFIG_PATH}" || true)"
    normalize_ca_server "${config_ca_server}"
}

# =============================================================================
# 函数名称: resolve_ca_server
# 功能描述: 解析当前生效 CA。
#           优先使用命令行 --ca 显式值；否则回退到 config.json 的 nginx.ca_server。
# 返回值: 无（更新全局变量 CA_SERVER）
# =============================================================================
function resolve_ca_server() {
    if [[ -z "${CA_SERVER}" ]]; then
        CA_SERVER="$(get_config_ca_server)"
    fi
    CA_SERVER="$(normalize_ca_server "${CA_SERVER}")"
}

# =============================================================================
# 函数名称: set_default_ca
# 功能描述: 显式设置 acme.sh 默认 CA（不触发签发动作）。
#           供 handler 的事务切换在重签成功后调用，保证后续 cron/续签一致。
# 返回值: 0-设置成功；非0-设置失败
# =============================================================================
function set_default_ca() {
    resolve_ca_server
    [[ -x "${HOME}/.acme.sh/acme.sh" ]] || print_error "$(_i18n ".${CUR_FILE}.set_ca.not_installed")"
    "${HOME}/.acme.sh/acme.sh" --set-default-ca --server "${CA_SERVER}" || print_error "$(_i18n ".${CUR_FILE}.install.fail_set_ca")"
}

# acme.sh 安装链路的供应链锁定。
#
# 背景 (为什么必须有这两个默认值): 本项目为所有第三方安装脚本设计了
# `_download_verified` 三重体检 (体积 / SHA256 摘要 / bash 语法), Xray 安装脚本
# (core/handler.sh 的 XRAY_INSTALL_SHA256) 已内置摘要; 但本文件原先引用了一个**从未被定义**
# 的 ACME_SH_INSTALL_SHA256, `${VAR:-}` 恒为空 => 摘要体检被静默跳过, 只剩"体积≥512B
# 与 bash -n"两道弱校验, 而下载物随后以 root 身份执行。这里补上真实摘要以堵住该缺口。
#
# 摘要为实测所得 (同一 URL 三次独立拉取结果逐字节一致), 升级版本时应同步更新:
#   curl -fsSL https://get.acme.sh | sha256sum
#
# ACME_SH_REF 的作用: 官方 bootstrap 内部按 $BRANCH 拼接第二阶段地址
#   https://raw.githubusercontent.com/acmesh-official/acme.sh/$BRANCH/acme.sh
# 不设则取浮动的 master (移动靶); 钉住后第二阶段地址才是确定的。
#
# ⚠️ 残余风险 (本方案无法覆盖): 该 bootstrap 内部执行 `$_get "$_url" | sh`,
# 即第二阶段仍然是"边下边执行"且未做摘要校验 —— 这是上游自带写法, 锁定本文件只能
# 保证【第一阶段】来源可信。要彻底消除需改用离线安装 (取 pinned tag 的 acme.sh 本体
# + 校验摘要 + `--install`), 属安装方式变更, 未在本改动中实施。
declare ACME_SH_INSTALL_SHA256="${ACME_SH_INSTALL_SHA256-8681df828f7765a351a4fc708a46fc3f7f383c0155fe4b19002d20e5c4ee5431}"
declare ACME_SH_REF="${ACME_SH_REF-3.1.6}"

# =============================================================================
# 函数名称: _ssl_renew_cron_present
# 功能描述: 判定 acme.sh 的自动续期定时任务是否**真的**落在 crontab 里。
# 参数: 无
# 返回值: 0=已就位  1=缺失, 或本机根本没有 crontab (环境不支持定时)
# 背景 (为什么必须自己判一次, 不能只看 acme.sh 的退出码):
#   acme.sh 3.1.6 的 install 主流程是
#       if [ -z "$_nocron" ]; then installcronjob "$_c_home"; fi      (acme.sh:8246)
#   —— **没有 || return**。而 installcronjob 在找不到 crontab / fcrontab 时是
#       _err "crontab/fcrontab doesn't exist, so we cannot install cron jobs."
#       _err "Your certs will not be renewed automatically."
#       return 1                                                      (acme.sh:7510-7513)
#   于是"cron 装失败"与"装成功"对外是同一个退出码, 上层无从分辨, 表现就是**静默**:
#   用户以为配好了自动续期, 实际证书 90 天后过期且无人知晓。本项目此前完全依赖它
#   且从不校验, 故在此补一道自检。
# 注: crontab -l 在用户尚无任何条目时退出 1 并往 stderr 打 "no crontab for ...",
#     这里 2>/dev/null 丢掉; pipefail 下该非 0 会传播, 所以整条管道必须放进 if 条件
#     (set -e 不介入条件判定) —— 否则"还没有任何定时任务"会被当成脚本崩溃。
# =============================================================================
function _ssl_renew_cron_present() {
    cmd_exists 'crontab' || return 1
    # 先滤掉注释行再匹配: crontab 里一行以 # 开头的备忘 (比如手抄的续签命令) 也含
    # "acme.sh --cron", 不过滤就会被当成"定时任务已就位" —— 误判方向恰好是**不告警**,
    # 正是本函数要防的那件事, 所以这一步不能省。
    #
    # 另: 这里刻意不用"管道 + grep -q"的一步写法 (2026-09-26 改)。pipefail 下 grep -q
    # 一找到匹配就退出, 上游 grep -v 写管道时可能收 SIGPIPE(141), 于是整条管道非 0
    # —— 而"非 0"在本函数里被解读成"定时任务缺失", 一个 SIGPIPE 就能让自检把明明
    # 装好的定时任务判成没装 (误判方向依旧是不告警)。故整段落变量、滤注释后用
    # bash 内建的通配比对, 全程不产生可被打断的管道。
    local cron_txt=''
    cron_txt="$(crontab -l 2>/dev/null || true)"
    # grep -v 在"全是注释行"时输出为空且退出 1, || true 兜住 (set -e 下命令替换的非 0
    # 会中断本函数); 它不带 -q, 会读完整个输入, 不会让上游收 SIGPIPE。
    cron_txt="$(printf '%s\n' "${cron_txt}" | grep -v '^[[:space:]]*#' || true)"
    [[ "${cron_txt}" == *'acme.sh --cron'* ]]
}

# =============================================================================
# 函数名称: _ssl_ensure_renew_cron
# 功能描述: acme.sh 就位后自检自动续期定时任务; 缺失则先尝试补装一次, 仍不成就
#           **明确告警**并给出手动补救命令 —— 绝不静默。
# 参数: 无
# 返回值: 恒 0
# 设计取舍:
#   - 用 print_warn 而非 print_error: 证书此刻是有效的, 只是"未来不会自动续"。
#     属于"必须让用户知道", 不是"中断安装" —— exit 1 会让已装好的 acme.sh 与已签发
#     的证书一起停在半路, 那比晚点发现更糟。
#   - 只在检测到缺失时才动用户的 crontab (补装), 正常情况下不碰。
#   - 补装失败不重试: --install-cronjob 失败的原因基本都是环境性的 (没有 cron /
#     crontab 不可写), 重试不会变好, 只会拖慢安装。
# =============================================================================
function _ssl_ensure_renew_cron() {
    if _ssl_renew_cron_present; then
        return 0
    fi

    if cmd_exists 'crontab'; then
        "${HOME}/.acme.sh/acme.sh" --install-cronjob >/dev/null 2>&1 || true
        if _ssl_renew_cron_present; then
            return 0
        fi
    fi

    print_warn "$(_i18n ".${CUR_FILE}.cron.missing")"
    print_warn "$(_i18n ".${CUR_FILE}.cron.hint")"
}

# =============================================================================
# 函数名称: install_acme_sh
# 功能描述: 安装 acme.sh 脚本。
# 参数: 无 (使用全局变量 ACCOUNT_EMAIL)
# 返回值: 无 (安装成功或失败后退出)
# =============================================================================
function install_acme_sh() {
    if [[ -e "${HOME}/.acme.sh/acme.sh" ]]; then
        print_info "$(_i18n ".${CUR_FILE}.install.already_installed")"
        # 已安装也要再确认一次: 定时任务可能被后来的操作清掉 (如重装系统 cron、
        # 或用户手动 crontab -r)。此时什么都不做就等于默认"还在"。
        _ssl_ensure_renew_cron
        return 0
    fi

    print_info "$(_i18n ".${CUR_FILE}.install.start")"
    resolve_ca_server

    # 下载 acme.sh 安装脚本 → 完整性体检 → 执行 (取代原 `curl ... | sh` 管道)
    # 用 `sh -s email=... < 文件` 从已校验的本地文件读取脚本, 与管道写法语义一致
    # ($0 同为 sh, $1 同为 email=...), 但避免了"边下边执行"。
    local acme_installer=''
    if ! acme_installer="$(_download_verified 'https://get.acme.sh' "${ACME_SH_INSTALL_SHA256}")"; then
        print_error "$(_i18n ".${CUR_FILE}.install.fail_download")"
    fi
    # BRANCH 前缀赋值只作用于本次 sh: bootstrap 会把它拼进第二阶段 URL (见上方 ACME_SH_REF 说明)。
    # 若不传, 上游默认取浮动的 master。
    BRANCH="${ACME_SH_REF}" sh -s email="${ACCOUNT_EMAIL}" <"${acme_installer}" || print_error "$(_i18n ".${CUR_FILE}.install.fail_download")"
    rm -f "${acme_installer}"

    # 关闭自动升级: 上游 --auto-upgrade 会安装一个定时任务, 把钉住的 3.1.6 漂回浮动版本,
    # 破坏供应链锁定。需要升级时请显式运行 ssl.sh --update (同分支内升级, 不会漂走)。
    "${HOME}/.acme.sh/acme.sh" --upgrade || print_error "$(_i18n ".${CUR_FILE}.install.fail_autoupgrade")"

    "${HOME}/.acme.sh/acme.sh" --set-default-ca --server "${CA_SERVER}" || print_error "$(_i18n ".${CUR_FILE}.install.fail_set_ca")"

    # 自动续期定时任务自检: 装完必须确认它真在 crontab 里, 不能默认"acme.sh 应该装好了"。
    # 上面每一步的 || print_error 只保证 acme.sh 本体可用, 与"续期会不会自动发生"无关 ——
    # 那件事由 acme.sh 自己写 crontab, 而它把失败吞掉了 (见 _ssl_renew_cron_present 注释)。
    _ssl_ensure_renew_cron
}

# =============================================================================
# 函数名称: update_acme_sh
# 功能描述: 更新 acme.sh 脚本。
# 参数: 无
# 返回值: 无 (更新成功或失败后退出)
# =============================================================================
function update_acme_sh() {
    print_info "$(_i18n ".${CUR_FILE}.update.start")"

    "${HOME}/.acme.sh/acme.sh" --upgrade || print_error "$(_i18n ".${CUR_FILE}.update.fail")"
}

# =============================================================================
# 函数名称: purge_acme_sh
# 功能描述: 卸载 acme.sh 并删除相关目录。
# 参数: 无
# 返回值: 无 (卸载成功后打印信息并退出)
# =============================================================================
function purge_acme_sh() {
    print_info "$(_i18n ".${CUR_FILE}.purge.start")"

    if [[ -e "${HOME}/.acme.sh/acme.sh" ]]; then
        "${HOME}/.acme.sh/acme.sh" --upgrade --auto-upgrade 0 || print_warn "$(_i18n ".${CUR_FILE}.purge.fail_disable_autoupgrade")"
        "${HOME}/.acme.sh/acme.sh" --uninstall || print_warn "$(_i18n ".${CUR_FILE}.purge.fail_uninstall_cmd")"
    fi

    rm -rf "${HOME}/.acme.sh" "${ACME_WEBROOT_PATH}" "${NGINX_CONFIG_PATH}/certs"
    print_info "$(_i18n ".${CUR_FILE}.purge.success")"
}

# =============================================================================
# 函数名称: issue_certificate
# 功能描述: 为指定域名签发 SSL 证书。
# 参数: 无 (使用全局变量 DOMAIN)
# 返回值: 无 (签发成功或失败后退出)
# =============================================================================
function issue_certificate() {
    if [[ ${#DOMAIN} -eq 0 ]]; then
        print_error "$(_i18n ".${CUR_FILE}.issue.no_domain")"
    fi

    local cert_path="${SSL_CERT_PATH}/${DOMAIN}"
    resolve_ca_server

    print_info "$(_i18n ".${CUR_FILE}.issue.start")"

    [[ -d "${ACME_WEBROOT_PATH}" ]] || mkdir -vp "${ACME_WEBROOT_PATH}" || print_error "$(_i18n_sub ".${CUR_FILE}.issue.fail_create_acme_dir" '${ACME_WEBROOT_PATH}' "${ACME_WEBROOT_PATH}")"
    [[ -d "${cert_path}" ]] || mkdir -vp "${cert_path}" || print_error "$(_i18n_sub ".${CUR_FILE}.issue.fail_create_cert_dir" '${cert_path}' "${cert_path}")"

    local nginx_conf="${NGINX_CONFIG_PATH}/nginx.conf"
    local nginx_conf_bak="${nginx_conf}.ssl_script.bak"
    local nginx_conf_modified=0

    if [[ -f "${nginx_conf}" ]]; then
        cp -f "${nginx_conf}" "${nginx_conf_bak}" || print_error "$(_i18n_sub ".${CUR_FILE}.issue.fail_backup_nginx" '${nginx_conf}' "${nginx_conf}")"
        nginx_conf_modified=1
        # 健壮性修复: 签发期间 nginx.conf 被改写为"仅 ACME 挑战"最小配置; 此前仅在成功路径
        # 手动还原, 任意中途 print_error 退出 (如重载/启动失败或签发失败) 都会让线上配置停留在
        # 损坏态。挂 EXIT trap 兜底, 无论成功/失败/被信号打断, 都先把原配置还原再退出。
        trap '[[ ${nginx_conf_modified} -eq 1 && -f "${nginx_conf_bak}" ]] && mv -f "${nginx_conf_bak}" "${nginx_conf}"; trap - EXIT' EXIT
    fi

    cat >"${nginx_conf}" <<EOF
user                 root;
pid                  /run/nginx.pid;
worker_processes     1;
events {
    worker_connections  1024;
}
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    server {
        listen       80;
        location ^~ /.well-known/acme-challenge/ {
            root ${ACME_WEBROOT_PATH};
        }
    }
}
EOF

    if systemctl is-active --quiet nginx; then
        nginx -t && systemctl reload nginx || print_error "$(_i18n ".${CUR_FILE}.issue.fail_reload_nginx")"
    else
        # 如果未运行，则测试配置并启动
        nginx -t && systemctl start nginx || print_error "$(_i18n ".${CUR_FILE}.issue.fail_start_nginx")"
    fi

    local issue_output=''
    local issue_status=1
    local issue_retry=1
    local issue_retry_message=''
    local -a issue_args=(
        --issue -d "${DOMAIN}"
        --webroot "${ACME_WEBROOT_PATH}"
        --keylength ec-256
        --accountkeylength ec-256
        --server "${CA_SERVER}"
    )
    if [[ "${CA_SERVER}" == 'zerossl' ]]; then
        issue_args+=(--ocsp)
    fi
    if [[ ${CA_SERVER_EXPLICIT} -eq 1 ]]; then
        issue_args+=(--force)
    fi

    if [[ "${CA_SERVER}" == 'letsencrypt' ]]; then
        issue_status=1
        for issue_retry in 1 2 3; do
            issue_retry_message="$(_i18n_sub ".${CUR_FILE}.issue.letsencrypt_retry" '${attempt}' "${issue_retry}")"
            print_warn "${issue_retry_message}"
            issue_output="$("${HOME}/.acme.sh/acme.sh" "${issue_args[@]}" 2>&1)"
            issue_status=$?
            [[ -n "${issue_output}" ]] && printf "%s\n" "${issue_output}" >&2
            [[ ${issue_status} -eq 0 ]] && break
        done
        if [[ ${issue_status} -ne 0 ]]; then
            mv -f "${nginx_conf_bak}" "${nginx_conf}"
            print_error "$(_i18n ".${CUR_FILE}.issue.letsencrypt_fail")"
        fi
    else
        issue_output="$("${HOME}/.acme.sh/acme.sh" "${issue_args[@]}" 2>&1)"
        issue_status=$?
        [[ -n "${issue_output}" ]] && printf "%s\n" "${issue_output}" >&2
        if [[ ${issue_status} -ne 0 ]]; then
            if [[ ${CA_SERVER_EXPLICIT} -eq 0 && "${issue_output,,}" == *"pending"* && "${issue_output,,}" == *"the ca is processing your order"* ]]; then
                print_warn "$(_i18n ".${CUR_FILE}.issue.zerossl_pending_switch")"
                CA_SERVER='letsencrypt'
                local new_script_config
                new_script_config="$(jq --arg caServer "${CA_SERVER}" '.nginx.ca_server = $caServer' "${SCRIPT_CONFIG_PATH}")"
                printf '%s\n' "${new_script_config}" | _atomic_write "${SCRIPT_CONFIG_PATH}"

                issue_args=(
                    --issue -d "${DOMAIN}"
                    --webroot "${ACME_WEBROOT_PATH}"
                    --keylength ec-256
                    --accountkeylength ec-256
                    --server "${CA_SERVER}"
                )
                issue_status=1
                for issue_retry in 1 2 3; do
                    issue_retry_message="$(_i18n_sub ".${CUR_FILE}.issue.letsencrypt_retry" '${attempt}' "${issue_retry}")"
                    print_warn "${issue_retry_message}"
                    issue_output="$("${HOME}/.acme.sh/acme.sh" "${issue_args[@]}" 2>&1)"
                    issue_status=$?
                    [[ -n "${issue_output}" ]] && printf "%s\n" "${issue_output}" >&2
                    [[ ${issue_status} -eq 0 ]] && break
                done
                if [[ ${issue_status} -ne 0 ]]; then
                    mv -f "${nginx_conf_bak}" "${nginx_conf}"
                    print_error "$(_i18n ".${CUR_FILE}.issue.letsencrypt_fail")"
                fi
            else
                print_warn "$(_i18n ".${CUR_FILE}.issue.fail_first_attempt")"
                local -a debug_issue_args=("${issue_args[@]}" --debug)
                "${HOME}/.acme.sh/acme.sh" "${debug_issue_args[@]}"
                mv -f "${nginx_conf_bak}" "${nginx_conf}"
                print_error "$(_i18n ".${CUR_FILE}.issue.fail_ecc_issue")"
            fi
        fi
    fi

    # 签发成功后，恢复原始 Nginx 配置 (同时清掉兜底 trap, 避免脚本末尾重复触发)
    mv -f "${nginx_conf_bak}" "${nginx_conf}"
    nginx_conf_modified=0
    trap - EXIT

    # 安装签发的证书到指定路径，并设置 Nginx 重载命令
    "${HOME}/.acme.sh/acme.sh" --install-cert --ecc -d "${DOMAIN}" \
        --key-file "${cert_path}/privkey.pem" \
        --fullchain-file "${cert_path}/fullchain.pem" \
        --reloadcmd "nginx -t && systemctl reload nginx" || print_error "$(_i18n ".${CUR_FILE}.issue.fail_install_cert")"
    # 私钥收紧为 640 —— 降权后的 nginx worker 以 nginx 身份运行 (config/nginx/conf/nginx.conf:4
    # 的 `user nginx;`), 属组可读即够用; 不再 world-readable, 降低私钥被其它本机用户或被入侵
    # 进程读取的风险。fullchain 是公开证书链, 保持 644 无害。
    # chown root:nginx 把属组切到 nginx, 配合 640 让 worker 可读; 若主机无 nginx 组 (极端情况),
    # chown 失败则回退 644, 避免 nginx 因读不到私钥而启动失败。
    # 收紧失败必须让用户看见: 私钥是长期凭据, 静默留在 world-readable 等于把泄露
    # 风险藏起来 —— 用户以为已经加固, 实际同机任何用户/被入侵进程都能读走。
    if chown root:nginx "${cert_path}/privkey.pem" 2>/dev/null; then
        chmod 640 "${cert_path}/privkey.pem" 2>/dev/null ||
            print_warn "$(_i18n ".${CUR_FILE}.issue.privkey_perm_warn")"
    else
        # 无 nginx 组时仍需让 nginx 读得到私钥, 只能放宽; 但这属于"降级", 要明确告知
        chmod 644 "${cert_path}/privkey.pem" 2>/dev/null || true
        print_warn "$(_i18n ".${CUR_FILE}.issue.privkey_perm_warn")"
    fi
    # fullchain 为公开证书链, 保持 644 (幂等, acme.sh 续签重新拷贝后权限可能被重置)
    chmod 644 "${cert_path}/fullchain.pem" 2>/dev/null || true
}

# =============================================================================
# 函数名称: renew_certificates
# 功能描述: 强制续期所有由 acme.sh 管理的 SSL 证书。
# 参数: 无
# 返回值: 无 (续期成功或失败后退出)
# =============================================================================
function renew_certificates() {
    # 打印续期信息
    print_info "$(_i18n ".${CUR_FILE}.renew.start")"

    "${HOME}/.acme.sh/acme.sh" --cron --force || print_error "$(_i18n ".${CUR_FILE}.renew.fail")"
}

# =============================================================================
# 函数名称: stop_renew_certificates
# 功能描述: 停止对指定域名的证书续期。
# 参数: 无 (使用全局变量 DOMAIN)
# 返回值: 无 (操作成功或失败后打印信息)
# =============================================================================
function stop_renew_certificates() {
    # 打印停止续期信息
    print_info "$(_i18n ".${CUR_FILE}.stop_renew.start")"

    # 检查是否提供了域名
    if [[ ${#DOMAIN} -gt 0 ]]; then
        # 执行 acme.sh 的移除命令（停止续期）
        "${HOME}/.acme.sh/acme.sh" --remove -d "${DOMAIN}" --ecc || print_warn "$(_i18n ".${CUR_FILE}.stop_renew.fail_cmd")"
        # 删除该域名的 acme.sh 本地存储目录
        rm -rf "${HOME}/.acme.sh/${DOMAIN}_ecc"
        rm -rf "${NGINX_CONFIG_PATH}/certs/${DOMAIN}"
    else
        # 如果未提供域名，则打印警告
        print_warn "$(_i18n ".${CUR_FILE}.stop_renew.no_domain")"
    fi
}

# =============================================================================
# 函数名称: check_cron_jobs
# 功能描述: 检查 acme.sh 的自动续期定时任务设置, 并顺带跑一次续签判定。
# 参数: 无
# 返回值: 无 (打印检查信息)
# 注: 旧实现只执行 `acme.sh --cron`, 那是"跑一次续签"而不是"检查定时任务设置" ——
#     与函数名和 .check_cron.start 的文案都不符。想确认定时任务在不在的维护者会拿到
#     错答案 (看到续签跑了一遍, 却不知道定时任务压根没装)。故改为先真查一次 crontab,
#     再保留原有的续签动作 (不破坏 --check-cron 既有语义)。
# =============================================================================
function check_cron_jobs() {
    # 打印检查信息
    print_info "$(_i18n ".${CUR_FILE}.check_cron.start")"

    if _ssl_renew_cron_present; then
        print_pass "$(_i18n ".${CUR_FILE}.check_cron.present")"
    else
        print_warn "$(_i18n ".${CUR_FILE}.cron.missing")"
        print_warn "$(_i18n ".${CUR_FILE}.cron.hint")"
    fi

    # 执行 acme.sh 的 cron 检查命令
    "${HOME}/.acme.sh/acme.sh" --cron --home "${HOME}/.acme.sh"
}

# =============================================================================
# 函数名称: check_certificate_status
# 功能描述: 检查指定域名的证书是否已由 acme.sh 管理。
# 参数: 无 (使用全局变量 DOMAIN)
# 返回值: 0-证书存在 1-证书不存在 (由命令检查结果决定)
# =============================================================================
function check_certificate_status() {
    # 检查是否提供了域名
    if [[ ${#DOMAIN} -eq 0 ]]; then
        print_error "$(_i18n ".${CUR_FILE}.status.no_domain")"
    fi

    # 从 acme.sh 列表中查找匹配的域名
    local main_domain
    main_domain=$(
        "${HOME}/.acme.sh/acme.sh" --list --home "${HOME}/.acme.sh" |
            grep -E "^${DOMAIN//./\\.}" |
            awk '{print $1}'
    ) || true

    # 比较找到的域名与提供的域名
    [[ "${main_domain}" == "${DOMAIN}" ]]
}

# =============================================================================
# 函数名称: show_certificate_info
# 功能描述: 显示指定域名证书的详细信息。
# 参数: 无 (使用全局变量 DOMAIN)
# 返回值: 无 (打印证书信息)
# =============================================================================
function show_certificate_info() {
    # 检查是否提供了域名
    if [[ ${#DOMAIN} -eq 0 ]]; then
        print_error "$(_i18n ".${CUR_FILE}.info.no_domain")"
    fi

    # 打印显示信息
    print_info "$(_i18n ".${CUR_FILE}.info.start")"

    # 执行 acme.sh 的信息显示命令
    "${HOME}/.acme.sh/acme.sh" --info -d "${DOMAIN}"
}

# =============================================================================
# 函数名称: show_help
# 功能描述: 显示脚本的使用帮助信息。
# 参数: 无
# 返回值: 无 (打印帮助信息后 exit 0)
# =============================================================================
function show_help() {
    # 从 i18n 数据中读取帮助信息的各个部分
    local usage
    usage="$(_i18n_sub ".${CUR_FILE}.help.usage" '${script_name}' "$0")"
    local commands_title
    commands_title="$(_i18n ".${CUR_FILE}.help.commands_title")"
    local cmd_install
    cmd_install="$(_i18n ".${CUR_FILE}.help.cmd_install")"
    local cmd_update
    cmd_update="$(_i18n ".${CUR_FILE}.help.cmd_update")"
    local cmd_purge
    cmd_purge="$(_i18n ".${CUR_FILE}.help.cmd_purge")"
    local cmd_issue
    cmd_issue="$(_i18n ".${CUR_FILE}.help.cmd_issue")"
    local cmd_renew
    cmd_renew="$(_i18n ".${CUR_FILE}.help.cmd_renew")"
    local cmd_stop_renew
    cmd_stop_renew="$(_i18n ".${CUR_FILE}.help.cmd_stop_renew")"
    local cmd_check_cron
    cmd_check_cron="$(_i18n ".${CUR_FILE}.help.cmd_check_cron")"
    local cmd_info
    cmd_info="$(_i18n ".${CUR_FILE}.help.cmd_info")"
    local cmd_status
    cmd_status="$(_i18n ".${CUR_FILE}.help.cmd_status")"
    local cmd_set_ca
    cmd_set_ca="$(_i18n ".${CUR_FILE}.help.cmd_set_ca")"
    local cmd_help
    cmd_help="$(_i18n ".${CUR_FILE}.help.cmd_help")"
    local options_title
    options_title="$(_i18n ".${CUR_FILE}.help.options_title")"
    local opt_domain
    opt_domain="$(_i18n ".${CUR_FILE}.help.opt_domain")"
    local opt_email
    opt_email="$(_i18n ".${CUR_FILE}.help.opt_email")"
    local opt_ca
    opt_ca="$(_i18n ".${CUR_FILE}.help.opt_ca")"

    # 使用 here document 打印帮助信息
    cat <<EOF
${usage}
${commands_title}:
  --install           ${cmd_install}
  --update            ${cmd_update}
  --purge             ${cmd_purge}
  --issue             ${cmd_issue}
  --renew             ${cmd_renew}
  --stop-renew        ${cmd_stop_renew}
  --check-cron        ${cmd_check_cron}
  --info              ${cmd_info}
  --status            ${cmd_status}
  --set-ca            ${cmd_set_ca}
  --help              ${cmd_help}
${options_title}:
  --domain            ${opt_domain}
  --email             ${opt_email}
  --ca                ${opt_ca}
EOF
    # 退出脚本，状态码为 0 (成功)
    exit 0
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 加载国际化数据。
#           2. 解析命令行参数。
#           3. 根据参数执行相应的操作函数。
# 参数:
#   $@: 所有命令行参数
# 返回值: 无 (协调调用其他函数完成操作)
# =============================================================================
function main() {
    # 加载国际化数据
    load_i18n

    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
        # 匹配操作命令
        --install | --update | --purge | --issue | --renew | --stop-renew | --check-cron | --status | --info | --set-ca)
            ACTION="${1#--}" # 提取操作名称
            ;;
        # 匹配域名选项
        --domain=*)
            DOMAIN="${1#*=}" # 提取域名
            # 格式校验: 非法域名 (如 ".."、含斜杠) 会污染 rm -rf / openssl / grep -E 参数
            [[ "${DOMAIN}" =~ ${DOMAIN_REGEX} ]] || print_error "$(_i18n ".${CUR_FILE}.domain.invalid")"
            ;;
        # 匹配邮箱选项
        --email=*)
            ACCOUNT_EMAIL="${1#*=}" # 提取邮箱
            # 与 --domain 同等对待: 入口即校验, 不让畸形邮箱一路带到 acme.sh
            [[ "${ACCOUNT_EMAIL}" =~ ${EMAIL_REGEX} ]] || print_error "$(_i18n ".${CUR_FILE}.email.invalid")"
            ;;
        --ca=*)
            CA_SERVER="${1#*=}"
            CA_SERVER_EXPLICIT=1
            ;;
        # 匹配帮助或未知选项
        --help | *)
            show_help # 显示帮助并退出
            ;;
        esac
        shift
    done

    [[ -z ${ACTION} ]] && show_help

    # 根据 ACTION 变量的值调用相应的函数
    case "${ACTION}" in
    install) install_acme_sh ;;            # 安装 acme.sh
    update) update_acme_sh ;;              # 更新 acme.sh
    purge) purge_acme_sh ;;                # 卸载 acme.sh
    issue) issue_certificate ;;            # 签发证书
    renew) renew_certificates ;;           # 续期证书
    stop-renew) stop_renew_certificates ;; # 停止续期
    check-cron) check_cron_jobs ;;         # 检查 cron
    status) check_certificate_status ;;    # 检查状态
    info) show_certificate_info ;;         # 显示信息
    set-ca) set_default_ca ;;
    esac
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
main "$@"
