#!/usr/bin/env bash
#
# Copyright (C) 2026 crudguy
#
# xray-script-personal-use-only:
#   https://github.com/crudguy/xray-script-personal-use-only
# =============================================================================
# 脚本名称: read.sh
# 功能描述: 根据传入的参数，从国际化 (i18n) 配置文件中读取对应的提示信息，
#           并从标准输入读取用户输入，返回用户输入的内容。
#           主要用于交互式配置脚本，提供多语言支持。
# 作者: crudguy
# 时间: 2026-09-19
# 版本: 1.0.0
# 依赖: bash, jq, cut, sed
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言设置 (language)
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
# =============================================================================

# --- 共享头部: 严格模式 / ERR trap / PATH / 颜色 / 目录常量 / i18n 公共函数 ---
# 实际内容由 core/_common.sh 提供 (13 个脚本共用, 消除副本漂移); 设计取舍 (为何
# install.sh 不在此列, 为何用 $0 而非 BASH_SOURCE, 为何 PATH 是白名单而非追加) 见该文件。
# 注: 下面这行刻意留在每个脚本里 —— shellcheck 的 `set -e` 判定不跨 source,
#     移走会让本脚本内的 `cd` 全被误报 SC2164。
set -Eeuo pipefail

_XRAY_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
if [[ ! -f "${_XRAY_SCRIPT_DIR}/_common.sh" ]]; then
    printf '\033[31m[错误]\033[0m 脚本文件不完整: 缺少 %s\n' "_common.sh" >&2
    printf '        (请重新克隆仓库, 或运行 install.sh 重新下载)\n' >&2
    exit 1
fi
# shellcheck source=_common.sh
source "${_XRAY_SCRIPT_DIR}/_common.sh"

# =============================================================================
# 函数名称: read_input
# 功能描述: 根据类型和消息内容，在终端打印格式化的提示信息。
# 参数:
#   $1: 类型 (type) - "config" 或 "rule"，决定提示信息的颜色和标题前缀
#   $2: 消息内容 (msg) - 具体的提示文本
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function read_input() {
    local type="${1:-}"      # 获取类型参数
    local color="$GREEN" # 默认颜色为绿色
    # 从 i18n 数据中读取 "配置" 的标题
    local title
    title="$(_i18n '.title.config')"

    # 如果类型是 "rule"
    if [[ "$type" == "rule" ]]; then
        color="$YELLOW" # 设置颜色为黄色
        # 从 i18n 数据中读取 "路由规则" 的标题
        title="$(_i18n '.title.route')"
    fi

    local msg="${2:-}" # 获取消息内容参数

    # 如果类型是 "rule"，在消息后追加 "(可设置多个值)" 的提示
    if [[ "$type" == "rule" ]]; then
        msg="$msg ($(_i18n '.title.multiple_values'))"
    fi

    # 使用指定颜色和标题打印提示信息到标准错误输出
    printf "${color}[%s]${NC} %s " "${title}" "${msg}" >&2
}

# =============================================================================
# 函数名称: print_target_presets
# 功能描述: 打印 .target 预设清单, 让用户在"留空 = 随机选"时知道候选都有哪些。
#           清单直接读 config.json 的 .target 键 —— 与 generate.sh 的
#           generate_target 随机取值同源, 不会出现"提示里列的和实际随机池不一致"。
# 参数: 无 (读全局 SCRIPT_CONFIG_PATH)
# 返回值: 恒 0
# 说明: 为什么只列域名、不给编号 —— 这个输入框收的是**域名**, 敲 "3" 会被
#       check_domain_security 判成格式非法; 一旦编号化, 等于诱导用户去敲数字。
#       所以只把候选摊开, 回车交给随机。全部输出到 stderr, 不污染 stdout 的返回值。
# =============================================================================
function print_target_presets() {
    # jq 失败 (config.json 缺失 / 字段缺失) 时取到空串 -> 静默跳过, 不打断输入流程
    local list=''
    list="$(jq -r '.target | keys | join(" ")' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)"
    if [[ -z "${list}" ]]; then
        return 0
    fi

    local -a names=()
    read -r -a names <<<"${list}"

    printf "${GREEN}[%s]${NC} %s\n" "$(_i18n '.title.config')" "$(_i18n '.read.target_presets')" >&2

    # 每行 4 个 (不引入 paste/fold 等外部命令, 保持 PATH 白名单下的最小依赖)
    local i=0 name
    for name in "${names[@]}"; do
        if ((i % 4 == 0)); then
            printf '    %s' "${name}" >&2
        else
            printf '  %s' "${name}" >&2
        fi
        i=$((i + 1))
        if ((i % 4 == 0)); then
            printf '\n' >&2
        fi
    done
    if ((i % 4 != 0)); then
        printf '\n' >&2
    fi
    return 0
}

# --- 参数映射表 ---
# 定义一个关联数组，将命令行选项映射到配置文件中的 JSON 路径。
# 键是命令行选项，值是用逗号分隔的类型和字段名。
# 类型用于 read_input 函数区分提示样式，字段名用于从 i18n 文件获取具体文本。
declare -A param_map=(
    ["--version"]="config,version"
    ["--rules"]="config,rules"
    ["--block-bt"]="config,block_bt"
    ["--block-cn"]="config,block_cn"
    ["--block-ad"]="config,block_ad"
    ["--auto-geo"]="config,auto_geo"
    ["--port"]="config,port"
    ["--uuid"]="config,uuid"
    ["--fallback"]="config,fallback"
    ["--seed"]="config,seed"
    ["--password"]="config,password"
    ["--target"]="config,target"
    ["--only-change-domain"]="config,only_change_domain"
    ["--domain"]="config,domain"
    ["--cdn"]="config,cdn"
    ["--custom-domain"]="config,custom_domain"
    ["--remove-cert"]="config,remove_cert"
    ["--proxy-target"]="config,proxy_target"
    ["--site-index"]="config,site_index"
    ["--email"]="config,email"
    ["--switch-ca"]="config,switch_ca"
    ["--short"]="config,short"
    ["--path"]="config,path"
    ["--warp-ip"]="rule,warp_ip"
    ["--warp-domain"]="rule,warp_domain"
    ["--block-ip"]="rule,block_ip"
    ["--block-domain"]="rule,block_domain"
)

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 加载国际化数据。
#           2. 检查传入的第一个参数是否在预定义的参数映射表中。
#           3. 如果存在，则解析其对应的类型和字段。
#           4. 从 i18n 数据中获取该字段的提示文本。
#           5. 对于特定参数 (--short / --target)，额外打印提示信息
#              (--target 还会列出 .target 预设清单, 见 print_target_presets)。
#           6. 调用 read_input 显示提示。
#           7. 从标准输入读取用户输入并输出。
# 参数:
#   $1: 命令行选项 (例如 --port, --uuid)
#   $@: 剩余参数 (此脚本中未使用)
# 返回值: 用户输入的内容 (echo 输出)
# =============================================================================
function main() {
    # 加载国际化数据
    load_i18n

    local option="${1:-}"
    # 兼容调用方直接传入裸参数名，例如 custom-domain
    if [[ -n "${option}" && "${option}" != --* ]]; then
        option="--${option}"
    fi

    # 检查传入的参数是否存在于参数映射表中，如果不存在则直接返回
    [[ -z "${param_map[$option]}" ]] && return

    # 使用 IFS (Internal Field Separator) 将映射表中的值分割为 type 和 field
    IFS=',' read -r type field <<<"${param_map[$option]}"

    # 构造 i18n 文件中的键名 (例如: read.port, read.uuid)
    local key="${CUR_FILE}.${field}"

    # 从 i18n 数据中读取该键对应的提示文本
    local prompt=""
    prompt="$(_i18n ".$key")"

    # 对于 --short 参数，额外打印一条关于 Short ID 格式的提示
    if [[ "${option}" == "--short" ]]; then
        echo -e "${YELLOW}[$(_i18n '.title.tip')]${NC} $(_i18n '.read.short_id_tip')" >&2
    fi

    # 对于 --target 参数，额外打印"它是什么"+"预设清单"。
    # 背景: 原提示只有一句"请输入目标域名 target (默认随机选择)", 用户极易误解成
    #   "随便填个域名" —— 实际它是 Reality 的伪装目标 (core/handler.sh 写进
    #   realitySettings.target), 不需要解析到本机, 但必须是能正常访问、支持
    #   TLS 1.3 与 X25519 的站点。把候选预设摊开也让"回车随机"变得可预期。
    if [[ "${option}" == "--target" ]]; then
        echo -e "${YELLOW}[$(_i18n '.title.tip')]${NC} $(_i18n '.read.target_hint')" >&2
        print_target_presets
    fi

    # 调用 read_input 函数显示提示信息
    read_input "$type" "$prompt"

    # 从标准输入读取一行用户输入。
    # 注: EOF (Ctrl+D / stdin 被重定向耗尽 / 无终端) 时**必须以非 0 退出**, 不能吞成空串 ——
    #     调用方 (handler.sh:exec_read) 靠这个退出码区分"用户回答了一个空值"与"根本没有输入源"。
    #     此前把 read 的失败就地兜成空串, 于是 EOF 被伪装成"用户答了个空值": 空串必然
    #     通不过校验, 调用方的重试循环立刻再次读到 EOF —— 每轮 fork 一个本脚本、无任何
    #     退让地空转 (cron / 管道 / `< /dev/null` 下 CPU 打满, 见审计报告 P0-1)。
    #     这类失败重来多少次都一样, 必须由调用方一次性失败退出, 不能靠重试掩盖。
    if ! read -r input; then
        printf "${YELLOW}[%s]${NC} %s\n" "$(_i18n '.title.warn')" "$(_i18n ".${CUR_FILE}.eof_abort")" >&2
        exit 1
    fi

    # 输出用户输入的内容
    echo "$input"
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
main "$@"
