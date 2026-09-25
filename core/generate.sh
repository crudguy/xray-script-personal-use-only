#!/usr/bin/env bash
#
# Copyright (C) 2026 crudguy
#
# xray-script-personal-use-only:
#   https://github.com/crudguy/xray-script-personal-use-only
# =============================================================================
# 脚本名称: generate.sh
# 功能描述: 生成各种随机或唯一标识符，如端口、UUID、密码、路径等，用于项目配置。
# 作者: crudguy
# 时间: 2026-09-19
# 版本: 1.0.0
# 依赖: bash, od, jq, xray (可选), openssl (用于 generate_short_id)
# 配置: 需要 ${SCRIPT_CONFIG_DIR}/config.json 文件支持 generate_target 和 generate_server_names 功能
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
if [[ ! -f "${_XRAY_SCRIPT_DIR}/_common.sh" ]]; then
    printf '\033[31m[错误]\033[0m 脚本文件不完整: 缺少 %s\n' "_common.sh" >&2
    printf '        (请重新克隆仓库, 或运行 install.sh 重新下载)\n' >&2
    exit 1
fi
# shellcheck source=_common.sh
source "${_XRAY_SCRIPT_DIR}/_common.sh"

# =============================================================================
# 函数名称: generate_random
# 功能描述: 生成一个随机数。如果不提供参数或参数无效，则生成一个无符号32位随机整数；
#           如果提供了有效的最小值和最大值，则生成该范围内的随机整数。
# 参数:
#   $1 (可选): 自定义最小值 (custom_min)
#   $2 (可选): 自定义最大值 (custom_max)
# 返回值: 生成的随机数 (echo 输出)
# =============================================================================
function generate_random() {
    local custom_min=${1:-}
    local custom_max=${2:-}

    # 使用 /dev/urandom 生成一个无符号32位随机整数
    local random
    random=$(od -An -N4 -tu4 </dev/urandom)

    # 检查自定义的最小值和最大值是否为有效正整数，并且最小值小于最大值
    if [[ ${custom_min} =~ ^[0-9]+$ && ${custom_max} =~ ^[0-9]+$ ]] && ((custom_min < custom_max)); then
        # 计算范围大小
        local range=$((custom_max - custom_min + 1))
        # 使用取模运算将随机数映射到指定范围内，并加上最小值偏移
        echo $((random % range + custom_min))
    else
        # 如果参数无效，则直接输出原始随机数
        echo "${random}"
    fi
}

# =============================================================================
# 函数名称: generate_port
# 功能描述: 生成一个可用的随机端口号 (1025 - 65535)。
#           避开 0-1024 的系统保留端口。
# 参数: 无
# 返回值: 生成的端口号 (echo 输出)
# =============================================================================
function generate_port() {
    # 调用 generate_random 函数，指定范围为 1025 到 65535
    echo "$(generate_random 1025 65535)"
}

# =============================================================================
# 函数名称: generate_uuid
# 功能描述: 生成一个 UUID。如果系统安装了 `xray` 命令，优先使用它来生成；
#           否则使用系统自带的 `/proc/sys/kernel/random/uuid`。
# 参数:
#   $1 (可选): 输入字符串，用于生成基于该输入的 UUID (需要 xray 支持)
# 返回值: 生成的 UUID 字符串 (echo 输出)
# =============================================================================
function generate_uuid() {
    local input="${1:-}"
    local uuid=''

    # 检查系统中是否存在 xray 命令
    if command -v xray &>/dev/null; then
        # 如果没有提供输入参数
        if [[ -z "${input}" ]]; then
            # 直接生成一个新的 UUID
            uuid=$(xray uuid)
        # 如果提供的输入参数已经是标准格式的 UUID
        elif [[ "${input}" =~ ^[0-9a-fA-F]{8}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{12}$ ]]; then
            # 则直接使用该输入作为 UUID
            uuid=${input}
        else
            # 否则，使用提供的输入字符串生成一个基于该输入的 UUID
            uuid=$(xray uuid -i "${input}")
        fi
    else
        # 如果没有安装 xray，则使用系统方法生成 UUID
        uuid=$(cat /proc/sys/kernel/random/uuid)
    fi
    # 输出生成的 UUID
    echo "${uuid}"
}

# =============================================================================
# 函数名称: generate_password
# 功能描述: 生成一个随机密码，长度在 16 到 64 个字符之间。
#           密码由数字、大小写字母以及部分特殊字符 (!@$%*) 组成。
# 参数: 无
# 返回值: 生成的随机密码 (echo 输出)
# =============================================================================
function generate_password() {
    # 首先生成一个 16 到 64 之间的随机数作为密码长度
    local length
    length=$(generate_random 16 64)

    # 先定量读取随机字节，过滤出目标字符集，再截取前 length 个字符作为密码。
    #
    # 注: 这里**不能**写成 `cat /dev/urandom | tr ... | fold -w $length | head -n 1`。
    #     head 取到第一行就退出，而 /dev/urandom 是无限流，上游的 fold/tr/cat 必定
    #     收到 SIGPIPE(退出码 141)；在 `set -o pipefail` + ERR trap 下，整条管道会被
    #     判为失败，实测一键安装刷出多条
    #       [错误] 脚本在第 123 行意外失败 (退出码 141): head -n 1
    #     新写法让链路的每一环都读到 EOF —— head 定量读、cut 读完整条流 —— 不产生 SIGPIPE。
    #     1024 字节随机数据过滤后仍剩 240+ 个可用字符，远多于长度上限 64。
    head -c 1024 /dev/urandom | tr -dc '0-9a-zA-Z!@$%*' | cut -c "1-${length}"
}

# =============================================================================
# 函数名称: generate_target
# 功能描述: 从配置文件 ${SCRIPT_CONFIG_PATH} 的 'target' 键中，
#           随机选择一个键名作为目标。
# 参数: 无 (依赖内部 generate_random 生成随机索引)
# 返回值: 随机选中的 target 键名 (echo 输出)
# 注意: 需要确保 ${SCRIPT_CONFIG_PATH} 文件存在且格式正确 (包含 .target 键)
# =============================================================================
function generate_target() {
    # 生成一个随机数作为索引
    local random
    random=$(generate_random)

    # 使用 jq 读取配置文件，获取 .target 对象的所有键名(keys)，
    # 然后计算随机索引对键名数组长度取模，从而随机选择一个键名
    jq -r --argjson random "${random}" '.target | keys | .[$random % length?]' "${SCRIPT_CONFIG_PATH}"
}

# =============================================================================
# 函数名称: generate_server_names
# 功能描述: 为给定的 target 生成或获取其对应的服务器名称列表。
#           如果 target 在配置文件中不存在，则将其添加到 .target 对象中，
#           其值为一个仅包含该 target 名称的数组。
#           最后返回该 target 对应的服务器名称数组。
# 参数:
#   $1: 目标名称 (target)
# 返回值: JSON 格式的数组，包含服务器名称 (echo 输出)
# 注意: 会修改 ${SCRIPT_CONFIG_PATH} 文件内容
# =============================================================================
function generate_server_names() {
    local target=${1:-} # 获取目标名称参数

    # 使用 jq 读取并可能修改配置文件内容：
    # 如果 .target 对象中已存在 $key (即 $target)，
    # 则返回原配置；
    # 否则，将新的键值对 ($target: [$target]) 添加到 .target 对象中
    local SCRIPT_CONFIG
    SCRIPT_CONFIG=$(jq --arg key "${target}" '
    if .target | has($key) then
        .
    else
        .target += { ($key): [$key] }
    end
    ' "${SCRIPT_CONFIG_PATH}")

    # 将修改后的配置内容写回配置文件
    printf '%s\n' "${SCRIPT_CONFIG}" | _atomic_write "${SCRIPT_CONFIG_PATH}"

    # 从修改后的配置中提取并输出指定 target 的服务器名称列表
    echo "${SCRIPT_CONFIG}" | jq --arg key "${target}" '.target[$key]'
}

# =============================================================================
# 函数名称: generate_x25519
# 功能描述: 使用 xray 命令生成一对 X25519 密钥（私钥和公钥）。
# 参数: 无
# 返回值: 以逗号分隔的字符串 "私钥,公钥" (echo 输出)
# 注意: 需要确保系统已安装 xray 命令
# =============================================================================
function generate_x25519() {
    # 调用 xray x25519 命令生成密钥对，输出通常为两行：
    # Private key: <private_key>
    # Public key: <public_key>
    local X25519_KEY
    X25519_KEY=$(xray x25519)

    # 使用 sed 提取第一行中的私钥部分
    local PRIVATE_KEY
    PRIVATE_KEY=$(echo "${X25519_KEY}" | sed -ne '1s/.*:\s*//p')
    # 使用 sed 提取第二行中的公钥部分
    local PUBLIC_KEY
    PUBLIC_KEY=$(echo "${X25519_KEY}" | sed -ne '2s/.*:\s*//p')
    # 使用 sed 提取第三行中的哈希部分
    local HASH32
    HASH32=$(echo "${X25519_KEY}" | sed -ne '3s/.*:\s*//p')

    # 将私钥和公钥，以及哈希用逗号连接后输出
    echo "${PRIVATE_KEY},${PUBLIC_KEY},${HASH32}"
}

# =============================================================================
# 函数名称: generate_short_id
# 功能描述: 生成一个指定长度的 Short ID (十六进制字符串)。
#           如果输入是 0-8 的数字，则生成对应长度的 ID；
#           如果输入是 0，则返回空字符串；
#           其他情况（包括非数字输入）则随机生成 0-8 位的 ID。
# 参数:
#   $1 (可选): 指定的长度 (0-8) 或任意输入
# 返回值: 生成的 Short ID (echo 输出)
# 注意: 需要 openssl 命令支持
# =============================================================================
function generate_short_id() {
    local input=${1:-} # 获取输入参数

    # 使用 sed 去除输入参数首尾的空白字符
    local trimmed_input
    trimmed_input=$(echo "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    local length=''

    # 检查处理后的输入是否为 0-8 的数字
    if [[ $trimmed_input =~ ^[0-8]$ ]]; then
        # 如果是，则使用该数字作为长度
        length=$trimmed_input
    else
        # 如果不是，则生成一个 0-8 之间的随机长度
        length=$(generate_random 0 8)
    fi

    # 如果长度为 0，则输出空字符串
    # 否则，使用 openssl 生成指定长度的十六进制随机字符串
    [[ ${length} -eq 0 ]] && echo "" || echo "$(openssl rand -hex ${length})"
}

# =============================================================================
# 函数名称: generate_short_ids
# 功能描述: 批量生成多个 Short ID。
#           对于每个输入参数：如果是 0-8 的数字，则生成对应长度的 ID；
#           否则，直接将输入作为 ID (需为十六进制字符串)。
#           最终输出一个去重并按长度排序的 JSON 数组。
# 参数:
#   $@: 一系列参数，每个参数代表一个 Short ID 的生成要求或直接值
# 返回值: JSON 格式的数组，包含去重并排序后的 Short ID (echo 输出)
# 注意: 依赖 jq 进行数组处理和去重排序
# =============================================================================
function generate_short_ids() {
    local -a ids=()
    local -a args=()

    # 将所有输入参数按空格分割并存入 args 数组
    IFS=' ' read -r -a args <<<"$@"

    # 遍历每个输入参数
    local _short_id=''
    for arg in "${args[@]}"; do
        # 如果参数是 0-8 的数字
        if [[ $arg =~ ^[0-8]$ ]]; then
            # 调用 generate_short_id 生成对应长度的 ID，
            # 并使用 jq -R 将其转换为 JSON 字符串格式后添加到 ids 数组
            # 用 while read 逐行读入: 原来的 `ids+=( $(...) )` 未加引号会按 IFS 拆词
            # (SC2207); 且 jq -R 无输入时不追加元素 —— 这里两者行为都保持。
            while IFS= read -r _short_id; do
                ids+=("${_short_id}")
            done < <(generate_short_id "${arg}" | jq -R)
        else
            # 如果不是数字，则直接将参数作为 ID 值，
            # 同样使用 jq -R 转换为 JSON 字符串格式后添加到 ids 数组
            while IFS= read -r _short_id; do
                ids+=("${_short_id}")
            done < <(echo "${arg}" | jq -R)
        fi
    done

    # 将 ids 数组中的所有元素作为独立参数传递给 echo，
    # 然后通过管道传递给 jq：
    # -s : 将多个输入项收集到一个数组中
    # unique : 对数组进行去重
    # sort_by(length) : 按字符串长度对数组元素进行排序
    echo "${ids[@]}" | jq -s 'unique | sort_by(length)'
}

# =============================================================================
# 函数名称: generate_path
# 功能描述: 生成一个随机的 URL 路径，以 '/' 开头。
#           路径由 16 到 64 个随机字母和数字组成。
# 参数: 无
# 返回值: 生成的随机路径字符串 (echo 输出)
# =============================================================================
function generate_path() {
    # 生成一个 16 到 64 之间的随机数作为路径长度
    local length
    length=$(generate_random 16 64)

    # 先定量读取随机字节，过滤出字母和数字，再截取前 length 个字符作为路径主体。
    #
    # 注: 与 generate_password 同源 —— 旧写法用 `head -n 1` 收尾无限流会导致 SIGPIPE(141)。
    #     本行的后果比密码那处更严重: 它是"命令替换赋值", 管道失败即赋值失败, 脚本会在
    #     `echo /${domain_path}` 之前被 ERR trap 退出, 最终**输出为空字符串** ——
    #     调用方会把空路径写进配置(实测 `generate.sh --path` 只打印错误、不打印路径)。
    local domain_path
    domain_path=$(head -c 1024 /dev/urandom | tr -dc 'a-zA-Z0-9' | cut -c "1-${length}")

    # 在路径主体前加上 '/' 并输出
    echo "/${domain_path}"
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。根据传入的第一个参数 (option)
#           调用相应的生成函数并输出结果。
# 参数:
#   $1: 操作选项 (e.g., --port, --uuid, --password 等)
#   $@: 剩余参数，传递给被调用的具体函数
# 返回值: 无 (调用具体函数并输出其结果)
# =============================================================================
function main() {
    local option="${1:-}"
    shift             # 移除第一个参数，剩下的参数留给具体函数处理

    # 使用 case 语句根据选项调用对应的函数
    case "${option}" in
    --random) generate_random ;;                  # 生成随机数
    --port) generate_port ;;                      # 生成端口
    --uuid) generate_uuid "$@" ;;                 # 生成 UUID
    --password) generate_password ;;              # 生成密码
    --target) generate_target "$@" ;;             # 生成目标
    --server-names) generate_server_names "$@" ;; # 生成服务器名称列表
    --x25519) generate_x25519 ;;                  # 生成 X25519 密钥对
    --short-id) generate_short_id "$@" ;;         # 生成单个 Short ID
    --short-ids) generate_short_ids "$@" ;;       # 生成多个 Short ID
    --path) generate_path ;;                      # 生成路径
    # P1-3: 未知参数不再静默成功 (原本无 `*)` 分支, 传错 -> 什么都不做 -> exit 0)。
    #   退出码 EXIT_USAGE(=2) = 用法错误, 便于脚本化调用方区分"参数拼错"与"执行成功"。
    #   注: generate.sh 不加载 i18n, 故用硬编码英文提示。
    *)
        printf '%s: %s\n' "Unknown or unsupported option" "${option}" >&2
        printf 'Supported: --random --port --uuid --password --target --server-names --x25519 --short-id --short-ids --path\n' >&2
        exit "${EXIT_USAGE}"
        ;;
    esac
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
main "$@"
