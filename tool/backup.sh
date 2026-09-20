#!/usr/bin/env bash
#
# Copyright (C) 2026 crudguy
#
# xray-script-personal-use-only:
#   https://github.com/crudguy/xray-script-personal-use-only
# =============================================================================
# 脚本名称: backup.sh
# 功能描述: 配置导出与导入 —— 备份 / 迁移 / 灾备。
#           --export [输出文件] [--with-docker]  把配置与证书打包为单个 tar.gz
#           --import <归档文件> [--yes]          从归档还原 (写前自动备份当前状态)
# 作者: crudguy
# 时间: 2026-09-19
# 版本: 1.0.0
# 依赖: bash, tar, gzip, jq, sha256sum, systemctl
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 导出对象之一, 也是导入后恢复运行状态的依据
#   - ${SCRIPT_CONFIG_DIR}/backup/:     默认备份输出目录
#   - /usr/local/etc/xray/config.json:  Xray 最终配置
#   - /usr/local/nginx/conf/:           Nginx 配置树 (含 certs/, 站点与证书)
#   - ${HOME}/.acme.sh/:                acme.sh 状态 (仅在使用中的域名)
#   - ${SCRIPT_CONFIG_DIR}/docker/:     WARP 数据 (需 --with-docker)
#
# 三条设计红线:
#   1. 恢复目标一律由本脚本的固定成员表 (_member_spec) 推导, **绝不采信归档内
#      给出的任何路径**。否则一个构造过的归档就能把文件写到 /etc 下任意位置,
#      而导入通常以 root 执行, 等于把 root 写权限交给归档作者。
#   2. 归档预检拒绝三类成员: 绝对路径 / 含 ".." 的路径 / 顶层既不是 manifest.json
#      也不在 payload/ 之下。解包时再用显式成员名二次收窄。
#   3. 导入前强制自动备份当前状态并同时解包留作回退点; 还原或复核失败时立即
#      用该回退点还原, 恢复原服务状态, 而不是把机器留在半新半旧的状态。
#
# 归档内容含私钥 (config.json 的 uuid/privateKey、certs/ 的 privkey.pem),
# 因此归档与解包目录分别收紧为 0600 / 0700, 并在退出时清理解包目录。
#
# 本脚本不单独处理语言参数: 由调用方 (handler.sh) 保证 i18n 已随项目目录就位。
# =============================================================================

# --- 共享头部: 严格模式 / ERR trap / PATH / 颜色 / 目录常量 / i18n 公共函数 ---
# 实际内容由 core/_common.sh 提供 (13 个脚本共用, 消除副本漂移); 设计取舍 (为何
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

# --- 目标路径常量 ---
# 与 core/handler.sh / service/ssl.sh 的同名常量保持一致, 改一处必须同步改三处。
readonly XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json" # Xray 最终配置文件
readonly NGINX_CONFIG_DIR="/usr/local/nginx/conf"           # Nginx 配置目录
readonly NGINX_BIN="/usr/local/nginx/sbin/nginx"            # 本项目编译的 Nginx
readonly ACME_HOME="${HOME}/.acme.sh"                       # acme.sh 状态目录
readonly DOCKER_DATA_DIR="${SCRIPT_CONFIG_DIR}/docker"      # WARP 数据
readonly BACKUP_DIR="${SCRIPT_CONFIG_DIR}/backup"           # 默认备份输出目录

# --- 归档格式常量 ---
readonly BACKUP_MAGIC='xray-script-personal-use-only-backup' # 归档标识 (防止误导入其它 tar.gz)
readonly BACKUP_SCHEMA=1                   # 结构版本; 不兼容时拒绝导入而非猜测
readonly MANIFEST_NAME='manifest.json'     # 归档内清单文件名
readonly PAYLOAD_DIR='payload'             # 归档内载荷根目录
readonly STAGE_PREFIX='xray-script-personal-use-only-bk.'    # 解包暂存目录前缀

# --- 成员表 ---
# 顺序即导出/展示顺序; 恢复目标由 _member_spec 按 id 推导 (见文件头红线 1)。
readonly -a MEMBER_IDS=(
    script_config
    xray_config
    nginx_conf
    nginx_confd
    nginx_modules
    nginx_sites
    nginx_sites_enabled
    nginx_web
    nginx_certs
    acme
    docker
)

# --- 暂存目录登记表 ---
# 统一由一个 EXIT trap 清理, 避免各处各设 trap 互相覆盖导致残留。
declare -a _CLEANUP_DIRS=()

# 主 shell 的 BASHPID —— 用于把清理动作限制在"脚本真正退出"那一刻。
# 背景: EXIT trap 会被子 shell 继承, 而本脚本大量使用 `x="$(func)"` 形式的命令
# 替换 (例如 _copy_member / _restore_payload)。若子 shell 退出时也执行清理, 它拿到
# 的是父 shell 登记表的副本, 会把父 shell 仍在使用的暂存目录一并删掉 ——
# 表现为打包/还原进行到一半"凭空"失败。故只在主 shell 退出时清理。
# 注: 必须用 BASHPID 而非 $$。子 shell 里 $$ 仍是父进程 PID, 分辨不出主/子。
readonly _CLEANUP_OWNER_BASHPID="${BASHPID}"

# =============================================================================
# 函数名称: _cleanup
# 功能描述: EXIT trap —— 清理本次运行登记的全部解包/暂存目录 (仅主 shell 执行)。
# 参数: 无
# 返回值: 恒为 0 (清理失败不改变脚本既有退出码)
# =============================================================================
function _cleanup() {
    # 子 shell 退出时不清理: 那些目录归父 shell 管 (见 _CLEANUP_OWNER_BASHPID 说明)
    [[ "${BASHPID}" == "${_CLEANUP_OWNER_BASHPID}" ]] || return 0
    local d=''
    if ((${#_CLEANUP_DIRS[@]} > 0)); then
        for d in "${_CLEANUP_DIRS[@]}"; do
            if [[ -n "${d}" ]]; then
                rm -rf "${d}"
            fi
        done
    fi
    _CLEANUP_DIRS=()
    return 0
}
trap '_cleanup' EXIT

# =============================================================================
# 函数名称: _info / _warn / _fail
# 功能描述: 统一的信息 / 警告 / 错误输出 (全部走 stderr, 不污染数据输出流)。
# 参数: $* 消息文本
# 返回值: _info / _warn 恒为 0; _fail 退出脚本 (退出码 1)
# =============================================================================
function _info() {
    echo -e "${GREEN}[$(_i18n '.title.info')]${NC} $*" >&2
}
function _warn() {
    echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $*" >&2
}
function _fail() {
    # $1=错误消息; $2=可选的可执行建议 (非空时以 [建议] 追加一行到 stderr)
    local msg="${1:-}" hint="${2:-}"
    echo -e "${RED}[$(_i18n '.title.error')]${NC} ${msg}" >&2
    if [[ -n "${hint}" ]]; then
        echo -e "${YELLOW}[$(_i18n '.title.hint')]${NC} ${hint}" >&2
    fi
    exit 1
}

# =============================================================================
# 函数名称: _usage
# 功能描述: 打印用法说明。
# 参数: 无
# 返回值: 恒为 0
# =============================================================================
function _usage() {
    _info "$(_i18n '.backup.usage')"
}

# =============================================================================
# 函数名称: _member_spec
# 功能描述: 按 id 返回成员的规格串 "<kind>|<绝对路径>"。
#           kind: file(单文件) / dir(目录内容) / acme(按域名筛选的 acme.sh 条目)
#           导出时该路径为源, 导入时为恢复目标 —— 两侧同源, 因此只需一张表。
# 参数:
#   $1: 成员 id
# 返回值: 0-成功 (stdout 打印规格串) 1-未知 id
# =============================================================================
function _member_spec() {
    case "${1:-}" in
    script_config) printf 'file|%s' "${SCRIPT_CONFIG_PATH}" ;;
    xray_config) printf 'file|%s' "${XRAY_CONFIG_PATH}" ;;
    nginx_conf) printf 'file|%s' "${NGINX_CONFIG_DIR}/nginx.conf" ;;
    nginx_confd) printf 'dir|%s' "${NGINX_CONFIG_DIR}/conf.d" ;;
    nginx_modules) printf 'dir|%s' "${NGINX_CONFIG_DIR}/modules-enabled" ;;
    nginx_sites) printf 'dir|%s' "${NGINX_CONFIG_DIR}/sites-available" ;;
    nginx_sites_enabled) printf 'dir|%s' "${NGINX_CONFIG_DIR}/sites-enabled" ;;
    nginx_web) printf 'dir|%s' "${NGINX_CONFIG_DIR}/web" ;;
    nginx_certs) printf 'dir|%s' "${NGINX_CONFIG_DIR}/certs" ;;
    acme) printf 'acme|%s' "${ACME_HOME}" ;;
    docker) printf 'dir|%s' "${DOCKER_DATA_DIR}" ;;
    *) return 1 ;;
    esac
}

# =============================================================================
# 函数名称: _tmp_base
# 功能描述: 选择暂存目录的父目录。优先用配置目录 (同分区, 且天然 700);
#           不可用时退回系统临时目录 (仍然把权限收紧到 700)。
# 参数: 无
# 返回值: 0 (stdout 打印目录路径)
# =============================================================================
function _tmp_base() {
    if [[ -d "${SCRIPT_CONFIG_DIR}" && -w "${SCRIPT_CONFIG_DIR}" ]]; then
        printf '%s' "${SCRIPT_CONFIG_DIR}"
    else
        printf '%s' "${TMPDIR:-/tmp}"
    fi
}

# =============================================================================
# 函数名称: _make_stage
# 功能描述: 创建一个 0700 暂存目录并登记到清理表。
# 参数:
#   $1: 后缀名 (仅用于目录名可读性, 如 export / import / rollback)
# 返回值: 0-成功 (stdout 打印路径) 1-失败
# =============================================================================
function _make_stage() {
    local suffix="${1:-stage}"
    local base=''
    local d=''
    base="$(_tmp_base)"
    d="$(mktemp -d "${base}/${STAGE_PREFIX}${suffix}.XXXXXXXX")" || return 1
    chmod 700 "${d}" 2>/dev/null || true
    _CLEANUP_DIRS+=("${d}")
    printf '%s' "${d}"
}

# =============================================================================
# 函数名称: _require_tools
# 功能描述: 确认导出/导入必需的外部命令齐备, 缺失时给出明确报错 (而非运行中途失败)。
# 参数: 无
# 返回值: 无 (缺失即 _fail)
# =============================================================================
function _require_tools() {
    local t=''
    for t in tar jq sha256sum; do
        command -v "${t}" >/dev/null 2>&1 || _fail "$(_i18n '.backup.err.missing_tool')${t}"
    done
}

# =============================================================================
# 函数名称: _domains_in_use
# 功能描述: 从脚本配置中提取当前在用的域名 (默认域名 / CDN 域名 / 各自定义站点域名),
#           用于只备份真正需要的 acme.sh 条目, 避免把整个 ~/.acme.sh 拖进归档。
# 参数:
#   $1: 脚本配置文件路径
# 返回值: 0 (stdout 逐行打印域名; 无域名时无输出)
# =============================================================================
function _domains_in_use() {
    local cfg_file="${1:-}"
    [[ -f "${cfg_file}" ]] || return 0
    jq -r '
        [ .nginx.domain, .nginx.cdn,
          ((.nginx.custom_sites // [])[] | .domain) ]
        | map(select(type == "string" and . != ""))
        | unique
        | .[]' "${cfg_file}" 2>/dev/null || true
}

# =============================================================================
# 函数名称: _count_entries
# 功能描述: 统计目录下的文件与符号链接条目数 (用于归档清单里的 files 字段)。
# 参数:
#   $1: 目录路径
# 返回值: 0 (stdout 打印数字; 统计失败时打印 0)
# =============================================================================
function _count_entries() {
    local dir="${1:-}"
    local n=''
    n="$(find "${dir}" \( -type f -o -type l \) 2>/dev/null | wc -l | tr -d ' ')" || n=0
    printf '%s' "${n:-0}"
}

# =============================================================================
# 函数名称: _copy_member
# 功能描述: 把单个成员的内容复制进暂存目录的 payload/<id>/ 下。
#           源不存在时返回 1 (由调用方记为"跳过"), 不视为错误。
# 参数:
#   $1: 成员 id
#   $2: 规格类型 (file / dir / acme)
#   $3: 源路径
#   $4: 暂存目录根
# 返回值: 0-成功 (stdout 打印条目数) 1-源不存在或复制失败
# =============================================================================
function _copy_member() {
    local id="${1:-}"
    local kind="${2:-}"
    local src="${3:-}"
    local stage="${4:-}"
    local dst="${stage}/${PAYLOAD_DIR}/${id}"
    local n=0
    local domain=''
    local one=''
    local found=0

    case "${kind}" in
    file)
        [[ -f "${src}" ]] || return 1
        mkdir -p "${dst}" || return 1
        # -p 保留权限位: 私钥类文件的 600 必须原样带进归档
        cp -p "${src}" "${dst}/" || return 1
        n=1
        ;;
    dir)
        [[ -d "${src}" ]] || return 1
        mkdir -p "${dst}" || return 1
        # "src/." 复制目录内容而非目录本身; -a 保留权限并原样保留符号链接
        # (sites-enabled/ 里全是指向 sites-available/ 的软链, 不能解引用)
        cp -a "${src}/." "${dst}/" || return 1
        n="$(_count_entries "${dst}")"
        ;;
    acme)
        [[ -d "${src}" ]] || return 1
        mkdir -p "${dst}" || return 1
        # acme.sh 的目录布局: <域名>/(RSA)、<域名>_ecc/(ECDSA)、<域名>.conf(续签记录)
        while IFS= read -r domain; do
            [[ -n "${domain}" ]] || continue
            for one in "${src}/${domain}" "${src}/${domain}_ecc" "${src}/${domain}.conf"; do
                if [[ -e "${one}" ]]; then
                    cp -a "${one}" "${dst}/" || return 1
                    found=1
                fi
            done
        done <<<"$(_domains_in_use "${SCRIPT_CONFIG_PATH}")"
        # 一个在用域名的条目都没找到时不算一个有效成员, 避免归档里出现空目录
        if ((found == 0)); then
            rm -rf "${dst}"
            return 1
        fi
        n="$(_count_entries "${dst}")"
        ;;
    *)
        return 1
        ;;
    esac
    printf '%s' "${n:-0}"
    return 0
}

# =============================================================================
# 函数名称: _do_export
# 功能描述: 导出配置与证书为单个 tar.gz。
#           1. 逐成员复制进暂存目录, 并记录哪些成员实际存在;
#           2. 生成 manifest.json (标识 / schema / 版本 / 时间 / 主机 / 协议 / 成员表);
#           3. 打包 manifest.json 与 payload/ (只打相对路径, 不含目录自身);
#           4. 归档收紧为 0600 并回显路径、大小、摘要。
# 参数:
#   $1: 输出文件路径 (空则用 ${BACKUP_DIR}/xray-script-personal-use-only-backup-<时间戳>.tar.gz)
#   $2: 1=含 docker 数据, 0=不含 (默认)
# 返回值: 无 (失败即 _fail)
# =============================================================================
function _do_export() {
    local out_path="${1:-}"
    local with_docker="${2:-0}"
    local stage=''
    local members_ndjson=''
    local id=''
    local spec=''
    local kind=''
    local src=''
    local n=''
    local manifest=''
    local included=0
    local skipped=0
    local ts=''
    local created=''
    local host=''
    local tag=''
    local ver=''
    local wd_bool='false'
    local sha=''
    local size=''

    _require_tools
    [[ -f "${SCRIPT_CONFIG_PATH}" ]] || _fail "$(_i18n '.backup.err.no_script_config')${SCRIPT_CONFIG_PATH}"

    _info "$(_i18n '.backup.export.scanning')"
    stage="$(_make_stage 'export')" || _fail "$(_i18n '.backup.err.mktemp')"
    # 必须在这里再登记一次: _make_stage 跑在 $( ) 子 shell 里, 它在子 shell 内做的
    # _CLEANUP_DIRS+= 不会回传给父 shell。只在函数内登记的话, 父 shell 的退出清理
    # 看不到该目录, 每次导出都会在 ${SCRIPT_CONFIG_DIR} 留下一个暂存目录
    # (内含配置与私钥副本), 越积越多。
    _CLEANUP_DIRS+=("${stage}")
    mkdir -p "${stage}/${PAYLOAD_DIR}" || _fail "$(_i18n '.backup.err.stage')"
    members_ndjson="${stage}/.members.ndjson"
    : >"${members_ndjson}"

    for id in "${MEMBER_IDS[@]}"; do
        # docker 数据可能很大 (WARP 数据), 默认不带, 需显式 --with-docker
        if [[ "${id}" == 'docker' && "${with_docker}" != '1' ]]; then
            continue
        fi
        spec="$(_member_spec "${id}")" || continue
        kind="${spec%%|*}"
        src="${spec#*|}"
        n=''
        if n="$(_copy_member "${id}" "${kind}" "${src}" "${stage}")"; then
            printf '{"id":"%s","kind":"%s","files":%s}\n' "${id}" "${kind}" "${n:-0}" >>"${members_ndjson}"
            included=$((included + 1))
            echo -e "  ${GREEN}+${NC} ${id} (${n:-0})" >&2
        else
            skipped=$((skipped + 1))
            echo -e "  ${YELLOW}-${NC} ${id} ($(_i18n '.backup.export.absent'))" >&2
        fi
    done

    ((included > 0)) || _fail "$(_i18n '.backup.err.nothing_to_export')"

    # 默认输出路径: 时间戳命名, 便于多次备份并存
    if [[ -z "${out_path}" ]]; then
        ts="$(date '+%Y%m%d-%H%M%S')"
        out_path="${BACKUP_DIR}/xray-script-personal-use-only-backup-${ts}.tar.gz"
    fi
    # 绝对化 (后续提示与 scp 都用它), 并确保父目录存在
    mkdir -p "$(dirname -- "${out_path}")" 2>/dev/null || _fail "$(_i18n '.backup.err.outdir')$(dirname -- "${out_path}")"
    out_path="$(cd -P -- "$(dirname -- "${out_path}")" && pwd -P)/$(basename -- "${out_path}")" || _fail "$(_i18n '.backup.err.outdir')${out_path}"

    # 注: 显式 if 而非 `(( )) && xxx` —— 后者在表达式为假时整条 AND 列表返回非 0,
    #     一旦它落在函数末尾或别处被误判就会触发 set -e, 不值得为省两行冒险。
    if ((with_docker == 1)); then
        wd_bool='true'
    fi
    created="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    host="$(hostname 2>/dev/null || echo unknown)"
    tag="$(jq -r '.xray.tag // ""' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)"
    ver="$(jq -r '.version // ""' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)"

    # 用 jq 组装清单: 手写 JSON 拼接很容易在域名/主机名含特殊字符时产出非法 JSON
    manifest="$(jq -n \
        --arg magic "${BACKUP_MAGIC}" \
        --argjson schema "${BACKUP_SCHEMA}" \
        --arg gen "${ver}" \
        --arg created "${created}" \
        --arg host "${host}" \
        --arg tag "${tag}" \
        --argjson wd "${wd_bool}" \
        --slurpfile m "${members_ndjson}" \
        '{magic:$magic, schema:$schema, generator_version:$gen, created:$created,
          host:$host, tag:$tag, with_docker:$wd, members:$m}')" || _fail "$(_i18n '.backup.err.manifest')"
    printf '%s\n' "${manifest}" >"${stage}/${MANIFEST_NAME}" || _fail "$(_i18n '.backup.err.manifest')"

    # 显式列出成员名打包: 不使用通配, 保证归档顶层结构固定且可被导入侧预检
    if ! tar -czf "${out_path}" -C "${stage}" "${MANIFEST_NAME}" "${PAYLOAD_DIR}"; then
        rm -f "${out_path}"
        _fail "$(_i18n '.backup.err.tar')"
    fi
    # 归档含私钥与 UUID, 只允许属主读写
    chmod 600 "${out_path}" 2>/dev/null || true

    sha="$(sha256sum "${out_path}" | cut -d' ' -f1)" || sha=''
    size="$(du -h "${out_path}" 2>/dev/null | cut -f1)" || size=''

    echo >&2
    _info "$(_i18n '.backup.export.done')"
    echo -e "  $(_i18n '.backup.label.file')     : ${out_path}" >&2
    echo -e "  $(_i18n '.backup.label.size')     : ${size:-?}" >&2
    echo -e "  $(_i18n '.backup.label.members')  : ${included} ($(_i18n '.backup.label.skipped') ${skipped})" >&2
    echo -e "  $(_i18n '.backup.label.sha256')   : ${sha:-?}" >&2
    echo >&2
    _warn "$(_i18n '.backup.export.secret_warn')"
    echo -e "  $(_i18n '.backup.export.hint')" >&2
}

# =============================================================================
# 函数名称: _validate_archive
# 功能描述: 归档安全性预检 —— 逐条检查 tar 成员清单, 拒绝:
#             a) 绝对路径;
#             b) 含 ".." 路径段 (目录穿越);
#             c) 顶层既非 manifest.json 也非 payload/ 之下。
#           任一命中即整体拒绝, 不做"部分导入"。
# 参数:
#   $1: 归档路径
# 返回值: 0-通过 1-不通过 (原因已打印到 stderr)
# =============================================================================
function _validate_archive() {
    local archive="${1:-}"
    local listing=''
    local line=''
    local probe=''
    local bad=0
    local saw_manifest=0

    listing="$(tar -tzf "${archive}" 2>/dev/null)" || {
        _warn "$(_i18n '.backup.err.archive_unsafe')"
        return 1
    }

    # 注: 用 here-string 逐行遍历而非管道 —— 管道会让循环跑在子 shell 里,
    #     bad / saw_manifest 的累加结果会随子 shell 一起丢掉。
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        probe="/${line}/"
        case "${probe}" in
        *'/../'*)
            echo -e "  ${RED}!${NC} ${line} ($(_i18n '.backup.err.bad_dotdot'))" >&2
            bad=1
            continue
            ;;
        esac
        case "${line}" in
        /*)
            echo -e "  ${RED}!${NC} ${line} ($(_i18n '.backup.err.bad_abs'))" >&2
            bad=1
            continue
            ;;
        esac
        case "${line}" in
        "${MANIFEST_NAME}") saw_manifest=1 ;;
        "${PAYLOAD_DIR}" | "${PAYLOAD_DIR}"/*) ;;
        *)
            echo -e "  ${RED}!${NC} ${line} ($(_i18n '.backup.err.bad_member'))" >&2
            bad=1
            ;;
        esac
    done <<<"${listing}"

    if ((bad != 0)); then
        _warn "$(_i18n '.backup.err.archive_unsafe')"
        return 1
    fi
    if ((saw_manifest == 0)); then
        _warn "$(_i18n '.backup.err.manifest_missing')"
        return 1
    fi
    return 0
}

# =============================================================================
# 函数名称: _restore_payload
# 功能描述: 把一个已解包的暂存目录按其 manifest 还原到本机。
#           只处理成员表里存在的 id —— 归档里出现的未知 id 会被跳过并告警,
#           这就是"不采信归档内路径"的落点。
# 参数:
#   $1: 已解包的暂存目录 (须含 manifest.json 与 payload/)
# 返回值: 0-全部成功 (stdout 打印还原成功的成员数) 1-有成员还原失败
# =============================================================================
function _restore_payload() {
    local stage="${1:-}"
    local id=''
    local spec=''
    local kind=''
    local dest=''
    local src=''
    local restored=0

    [[ -f "${stage}/${MANIFEST_NAME}" ]] || return 1

    while IFS= read -r id; do
        # 同上: jq 的 CRLF 输出会让 id 残留 CR, _member_spec 因此匹配不到而把它当成
        # "未知成员" 跳过 —— 表现为导入只还原最后一个成员, 其余配置静默丢失。
        id="${id%$'\r'}"
        [[ -n "${id}" ]] || continue
        if ! spec="$(_member_spec "${id}")"; then
            _warn "$(_i18n '.backup.import.unknown_member')${id}"
            continue
        fi
        kind="${spec%%|*}"
        dest="${spec#*|}"
        src="${stage}/${PAYLOAD_DIR}/${id}"
        [[ -e "${src}" ]] || continue
        case "${kind}" in
        file)
            # 单文件成员: payload/<id>/<basename> -> dest
            mkdir -p "$(dirname -- "${dest}")" || return 1
            cp -a "${src}/$(basename -- "${dest}")" "${dest}" || return 1
            ;;
        *)
            # 目录类成员: 合并式还原 (保留 payload 里没有的既有文件)
            mkdir -p "${dest}" || return 1
            cp -a "${src}/." "${dest}/" || return 1
            ;;
        esac
        restored=$((restored + 1))
        echo -e "  ${GREEN}✓${NC} ${id}" >&2
    done <<<"$(jq -r '.members[]?.id // empty' "${stage}/${MANIFEST_NAME}" 2>/dev/null || true)"

    # 脚本主配置含 UUID/私钥, 与 _atomic_write 的落盘权限保持一致
    if [[ -f "${SCRIPT_CONFIG_PATH}" ]]; then
        chmod 600 "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true
    fi

    printf '%s' "${restored}"
    return 0
}

# =============================================================================
# 函数名称: _verify_restored
# 功能描述: 还原后的语义复核 —— 用 xray 与 nginx 各自的配置校验模式各跑一遍。
#           工具或配置文件不存在时视为跳过 (不算失败), 与 handler.sh 的
#           _verify_xray_config 保持同样的宽容度。
# 参数: 无
# 返回值: 0-全部通过(或跳过) 1-有配置校验未通过
# =============================================================================
function _verify_restored() {
    local ok=0
    local nginx_bin=''

    if [[ -f "${XRAY_CONFIG_PATH}" ]] && command -v xray >/dev/null 2>&1; then
        if command -v jq >/dev/null 2>&1 && ! jq -e . "${XRAY_CONFIG_PATH}" >/dev/null 2>&1; then
            _warn "$(_i18n '.backup.import.xray_invalid_json')"
            ok=1
        elif xray run -test -config "${XRAY_CONFIG_PATH}" >/dev/null 2>&1; then
            _info "$(_i18n '.backup.import.xray_ok')"
        else
            _warn "$(_i18n '.backup.import.xray_test_failed')"
            ok=1
        fi
    fi

    if [[ -x "${NGINX_BIN}" ]]; then
        nginx_bin="${NGINX_BIN}"
    elif command -v nginx >/dev/null 2>&1; then
        nginx_bin="$(command -v nginx)"
    fi
    if [[ -n "${nginx_bin}" ]]; then
        # Nginx 的 -t 会把结果打到 stderr 并给出退出码, 故整体重定向后只看退出码
        if "${nginx_bin}" -t >/dev/null 2>&1; then
            _info "$(_i18n '.backup.import.nginx_ok')"
        else
            _warn "$(_i18n '.backup.import.nginx_test_failed')"
            ok=1
        fi
    fi
    return "${ok}"
}

# =============================================================================
# 函数名称: _service_stop / _service_start
# 功能描述: 停/启 systemd 服务。单元不存在时不报错 (全新机器上导入属正常场景),
#           启动失败只告警 —— 复核与提示仍要继续走完。
# 参数:
#   $1: 单元名 (xray / nginx)
# 返回值: 恒为 0
# =============================================================================
function _service_stop() {
    local unit="${1:-}"
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl cat "${unit}" >/dev/null 2>&1 || return 0
    systemctl stop "${unit}" >/dev/null 2>&1 || true
    return 0
}
function _service_start() {
    local unit="${1:-}"
    command -v systemctl >/dev/null 2>&1 || return 0
    if ! systemctl cat "${unit}" >/dev/null 2>&1; then
        _warn "$(_i18n '.backup.import.no_unit')${unit}"
        return 0
    fi
    systemctl start "${unit}" >/dev/null 2>&1 || _warn "$(_i18n '.backup.import.start_failed')${unit}"
    return 0
}

# =============================================================================
# 函数名称: _do_import
# 功能描述: 从归档还原本机配置。完整护栏序列:
#           1. 归档安全性预检 + manifest 标识/schema 校验 + 必需成员检查;
#           2. 展示归档元信息, 未经确认不写任何文件;
#           3. 自动导出当前状态作为回退点, 并解包备用;
#           4. 停服 -> 逐成员还原 -> xray/nginx 配置复核 -> 起服;
#           5. 任一步失败即用回退点还原并恢复服务, 不留半成品状态。
# 参数:
#   $1: 归档路径
#   $2: 1=跳过交互确认 (--yes), 0=需要确认
# 返回值: 无 (失败即 _fail)
# =============================================================================
function _do_import() {
    local archive="${1:-}"
    local assume_yes="${2:-0}"
    local stage=''
    local rollback_stage=''
    local pre_archive=''
    local created=''
    local host=''
    local tag=''
    local contents=''
    local wd=0
    local restored=0
    local answer=''

    [[ -n "${archive}" ]] || _fail "$(_i18n '.backup.err.import_usage')"
    [[ -f "${archive}" ]] || _fail "$(_i18n '.backup.err.archive_missing')${archive}"
    _require_tools

    _info "$(_i18n '.backup.import.validating')"
    _validate_archive "${archive}" || exit 1

    stage="$(_make_stage 'import')" || _fail "$(_i18n '.backup.err.mktemp')"
    _CLEANUP_DIRS+=("${stage}") # 见 _do_export 中的说明 (命令替换不传回数组改动)
    # 按显式成员名解包: 即使上面的清单预检被绕过, 这里也无法解出 payload/ 之外的内容
    tar -xzf "${archive}" -C "${stage}" "${MANIFEST_NAME}" "${PAYLOAD_DIR}" || _fail "$(_i18n '.backup.err.extract')"

    if ! jq -e --arg magic "${BACKUP_MAGIC}" --argjson schema "${BACKUP_SCHEMA}" \
        '.magic == $magic and .schema == $schema' "${stage}/${MANIFEST_NAME}" >/dev/null 2>&1; then
        _fail "$(_i18n '.backup.err.manifest_mismatch')"
    fi
    if ! jq -e 'any(.members[]?; .id == "script_config")' "${stage}/${MANIFEST_NAME}" >/dev/null 2>&1; then
        _fail "$(_i18n '.backup.err.manifest_incomplete')"
    fi

    # 元信息与内容清单 (只作展示, 不参与任何路径决策)
    created="$(jq -r '.created // "?"' "${stage}/${MANIFEST_NAME}" 2>/dev/null || true)"
    host="$(jq -r '.host // "?"' "${stage}/${MANIFEST_NAME}" 2>/dev/null || true)"
    tag="$(jq -r '.tag // "?"' "${stage}/${MANIFEST_NAME}" 2>/dev/null || true)"
    contents="$(jq -r '[.members[]?.id] | join(", ")' "${stage}/${MANIFEST_NAME}" 2>/dev/null || true)"
    wd="$(jq -r 'if .with_docker then 1 else 0 end' "${stage}/${MANIFEST_NAME}" 2>/dev/null || echo 0)"

    echo >&2
    echo -e "  $(_i18n '.backup.label.archive')  : ${archive}" >&2
    echo -e "  $(_i18n '.backup.label.created')  : ${created}" >&2
    echo -e "  $(_i18n '.backup.label.host')     : ${host}" >&2
    echo -e "  $(_i18n '.backup.label.tag')      : ${tag}" >&2
    echo -e "  $(_i18n '.backup.label.contents') : ${contents}" >&2
    echo >&2

    if [[ "${assume_yes}" != '1' ]]; then
        echo -en "${YELLOW}[$(_i18n '.title.warn')]${NC}" >&2
        echo -en " $(_i18n '.backup.import.confirm') [y/N]: " >&2
        # 无 TTY / 读到 EOF 时 read 返回非 0, 落空串即等价于"取消" (安全默认)
        read -r answer || answer=''
        case "${answer,,}" in
        y | yes) ;;
        *)
            _info "$(_i18n '.backup.import.cancelled')"
            return 0
            ;;
        esac
    fi

    # 回退点: 导出当前状态并立刻解包, 失败时无需再走一次校验
    # 先确认回退点做得出来: 导出以"本机已有脚本配置"为前提, 而 _do_export 在缺配置时
    # 会直接 _fail("请先完成安装") 并 exit —— 那会绕过下面这行 || 分支, 让用户在整个
    # 导入流程里看到一句与导入无关、且听不出"什么都没被改动"的报错。此处在尚未改动
    # 任何文件时提前拒绝, 给出准确文案。
    [[ -f "${SCRIPT_CONFIG_PATH}" ]] || _fail "$(_i18n '.backup.err.pre_backup_failed')"
    pre_archive="${BACKUP_DIR}/pre-import-$(date '+%Y%m%d-%H%M%S').tar.gz"
    _info "$(_i18n '.backup.import.pre_backup')"
    _do_export "${pre_archive}" "${wd}" || _fail "$(_i18n '.backup.err.pre_backup_failed')"
    rollback_stage="$(_make_stage 'rollback')" || _fail "$(_i18n '.backup.err.mktemp')"
    _CLEANUP_DIRS+=("${rollback_stage}") # 见 _do_export 中的说明 (命令替换不传回数组改动)
    tar -xzf "${pre_archive}" -C "${rollback_stage}" "${MANIFEST_NAME}" "${PAYLOAD_DIR}" \
        || _fail "$(_i18n '.backup.err.pre_backup_failed')"

    _info "$(_i18n '.backup.import.stopping')"
    _service_stop nginx
    _service_stop xray

    _info "$(_i18n '.backup.import.restoring')"
    if ! restored="$(_restore_payload "${stage}")"; then
        _warn "$(_i18n '.backup.import.rollback')"
        _restore_payload "${rollback_stage}" || true
        _service_start xray
        _service_start nginx
        _fail "$(_i18n '.backup.err.restore_failed')"
    fi

    if ! _verify_restored; then
        _warn "$(_i18n '.backup.import.verify_failed_rollback')"
        _restore_payload "${rollback_stage}" || true
        _service_start xray
        _service_start nginx
        _fail "$(_i18n '.backup.err.verify_failed')"
    fi

    _info "$(_i18n '.backup.import.starting')"
    _service_start xray
    _service_start nginx

    echo >&2
    _info "$(_i18n '.backup.import.done')${restored}"
    echo -e "  $(_i18n '.backup.label.pre_backup') : ${pre_archive}" >&2
    echo >&2
    _warn "$(_i18n '.backup.import.share_warn')"
}

# =============================================================================
# 函数名称: main
# 功能描述: 解析参数并分派到导出 / 导入。支持 --help。
# 参数:
#   $1: 动作 (--export | --import | --help)
#   $@: 其余参数 (位置参数为输出/输入文件; --with-docker / --yes 为开关)
# 返回值: 无 (由被调函数决定; 失败经 _fail 退出)
# =============================================================================
function main() {
    load_i18n

    local action="${1:-}"
    shift || true

    local arg=''
    local a=''
    local with_docker=0
    local assume_yes=0
    for a in "$@"; do
        case "${a}" in
        --with-docker) with_docker=1 ;;
        --yes | -y) assume_yes=1 ;;
        -h | --help) action='--help' ;;
        -*) _fail "$(_i18n '.backup.err.unknown_option')${a}" ;;
        *) arg="${a}" ;;
        esac
    done

    case "${action}" in
    --export) _do_export "${arg}" "${with_docker}" ;;
    --import) _do_import "${arg}" "${assume_yes}" ;;
    --help | '') _usage ;;
    *) _fail "$(_i18n '.backup.err.unknown_option')${action}" ;;
    esac
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
main "$@"
