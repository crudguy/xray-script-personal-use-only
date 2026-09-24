#!/usr/bin/env bash
# =============================================================================
# 脚本名称: _common.sh
# 功能描述: xray-script-personal-use-only 项目的共享头部 —— 由 core/ service/ tool/ 下的脚本 source,
#           统一提供: 严格模式与 ERR trap、PATH、颜色常量、目录常量、
#           i18n 文本缓存与查询 (_i18n / load_i18n)、原子写入 (_atomic_write)、
#           GitHub 加速前缀拼接 (_gh_url)。
# 作者: crudguy
# 时间: 2026-09-19
# 版本: 1.0.0
# 依赖: bash; jq (仅 load_i18n / _i18n 需要)
#
# 本文件不单独执行, 只被 source, 因此没有 main 入口。
#
# 为什么收敛到这一个文件:
#   此前各业务脚本各自复制同一份同源头部, 已经出现明显的漂移 —— CUR_FILE 有 2 种
#   写法、SCRIPT_CONFIG_DIR 有 3 种注释形态、load_i18n 有 3 种排版、颜色定义有 2 种
#   顺序、_gh_url 被复制了 6 份。同时 shellcheck 按单文件分析, 把公共声明整片误报成
#   "赋值后未使用"(SC2034) 与 "引用但未赋值"(SC2154), 把真问题淹没在噪声里。
#   收敛后这两类告警只剩本文件内的少数几处, 用就地 disable 精确标注 (见下)。
#
# 哪些脚本不使用本文件:
#   - install.sh: 被单独下载到 ${HOME}/xray-script-personal-use-only.sh 执行 (见 README 安装说明),
#                 运行当时仓库还不存在, 必须保持单文件自包含。且它的 CUR_FILE 语义是
#                 "带扩展名的自更新目标名"(用于 rm/cp/bash 自身), 与本文件 (去扩展名,
#                 用作 i18n 键前缀) 不同义 —— 合并会静默破坏自更新。
#   - config/*:   与主流程无关的独立示例脚本 (nginx 限流测试、WARP 自启), 模板不同。
#
# Copyright (C) 2026 crudguy
# =============================================================================

# 本文件是"共享头部": 下列常量只被 source 方使用, shellcheck 按单文件分析看不到
# 跨文件引用, 会把它们整片报成"赋值后未使用"。逐条拆回各脚本反而重建了本批次
# 正要消除的漂移, 故在此做文件级标注 (仅本文件生效)。
# shellcheck disable=SC2034

# 严格模式: -E(ERR trap 可继承) -e(命令失败即退出) -u(未定义变量报错) -o pipefail(管道任一环失败即失败)
# 注 1: 不再内置 -x —— xtrace 会把含密钥/口令的完整命令行写进 stderr;
#       需要排查时用 XRAY_SCRIPT_DEBUG=1 临时开启。
# 注 2: 调用方脚本**也各自声明了这一行**, 此处再写一次是刻意的 ——
#       ① 本文件可能被单独 source (夹具/测试), 需要自带严格模式;
#       ② shellcheck 的 set -e 判定不跨 source, 脚本侧必须自己声明,
#          否则脚本内所有 `cd` 都会被误报 SC2164 (实测新增 16 条)。
set -Eeuo pipefail
# rc 由 trap 内的 $? 赋值; shellcheck 的数据流不跨越 trap 的单引号, 属结构性误报。
# shellcheck disable=SC2154
# 未预期失败时给出可定位的诊断 (行号 + 命令), 避免"静默退出"
trap 'rc=$?; printf "\033[31m[错误]\033[0m 脚本在第 %s 行意外失败 (退出码 %s): %s\n" "${LINENO}" "${rc}" "${BASH_COMMAND}" >&2; exit "${rc}"' ERR
# Ctrl+C (SIGINT) / SIGTERM: 明确告知并以 130 走正常退出路径。
# 为什么要有: 此前只有 ERR trap, 长操作 (下载源码 / 申请证书 / 编译 Nginx) 中途按
#   Ctrl+C 会**直接终止进程**, 于是各脚本自己注册的 EXIT 清理逻辑全部不执行 ——
#   典型后果是 ssl.sh 已挂上的 nginx.conf 备份恢复不触发, 站点配置停在改了一半的
#   状态; 临时目录也会残留在磁盘上。这里显式 exit 130, 让 EXIT trap 有机会收尾。
# 注: 用 exit (而非让信号默认终止) 才能触发 EXIT trap; 130 是 shell 对 SIGINT 的
#   惯例退出码, 便于 cron / 外部脚本据此判断"是被人为中断的"。
trap 'printf "\n\033[33m[提示]\033[0m 收到中断信号, 正在退出 (退出码 130)\n" >&2; exit 130' INT TERM
# 临时调试开关 (排查问题时设置 XRAY_SCRIPT_DEBUG=1)
if [[ "${XRAY_SCRIPT_DEBUG:-0}" == '1' ]]; then set -x; fi
:

# --- 环境与常量设置 ---
# 将常用路径添加到 PATH 环境变量，确保脚本能在不同环境中找到所需命令。
# 注: 这里**刻意用固定白名单覆盖, 而不是追加 ${PATH}**。本脚本族以 root 运行,
#     继承调用者的 PATH 会带来真实的提权面 —— 常见教程建议把工具目录
#     (`export PATH=$PATH:/root/xxx/bin`) 写进 shell 配置, 一旦该目录可被非 root
#     写入, 脚本调用的 curl/jq/tar 就可能被同名恶意程序抢先命中。
#     该白名单是 sudo 默认 secure_path 的超集, 已覆盖脚本实际依赖的全部命令:
#     jq curl wget systemctl sed awk grep cut tr sort uniq tar unzip gzip openssl
#     gpg crontab flock mktemp nginx xray ss lsof 等 (均在 /bin /sbin /usr/bin
#     /usr/sbin /usr/local/bin /usr/local/sbin /snap/bin 之内)。
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:/snap/bin
export PATH

# 定义颜色代码，用于在终端输出带颜色的信息
# 注: 必须用 ANSI-C 引号 $'...' 让 \033 成为真正的 ESC 控制字符, 而非字面反斜杠序列。
#     否则在 printf '%s' "${GREEN}" 这类"转义在参数里"的调用中会被原样打印成
#     "\033[32m" 乱码 (菜单的 echo -e 路径能解释, 但体检查看的 printf %s 不能)。
readonly GREEN=$'\033[32m'  # 绿色
readonly YELLOW=$'\033[33m' # 黄色
readonly RED=$'\033[31m'    # 红色
readonly NC=$'\033[0m'      # 无颜色（重置）

# 获取当前脚本的目录、文件名（不含扩展名）和项目根目录的绝对路径。
# 注 1: 必须用 $0 而不是 BASH_SOURCE —— source 不会改变 $0, 因此 $0 始终是"最初被
#       执行的那个脚本"; 若改用 BASH_SOURCE, 在被 source 的本文件里会得到
#       core/_common.sh, 于是 service/ 与 tool/ 下脚本的 CUR_DIR 会全部错成 core/。
# 注 2: 声明与赋值必须拆开写。合并成 `readonly CUR_DIR="$(...)"` 会屏蔽命令替换的
#       返回码, cd 失败时 CUR_DIR 会静默变成空串, 之后所有派生路径跟着错, 极难排查。
if ! _xray_cur_dir="$(cd -P -- "$(dirname -- "$0")" && pwd -P)" || [[ -z "${_xray_cur_dir}" ]]; then
    printf '\033[31m[错误]\033[0m 无法解析脚本所在目录 (脚本路径: %s)\n' "${0:-?}" >&2
    exit 1
fi
readonly CUR_DIR="${_xray_cur_dir}" # 当前脚本所在目录
if ! _xray_cur_file="$(basename "$0" | sed 's/\..*//')" || [[ -z "${_xray_cur_file}" ]]; then
    printf '\033[31m[错误]\033[0m 无法解析脚本文件名 (脚本路径: %s)\n' "${0:-?}" >&2
    exit 1
fi
readonly CUR_FILE="${_xray_cur_file}" # 当前脚本文件名 (不含扩展名, 用作 i18n 键前缀)
if ! _xray_proj_root="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" || [[ -z "${_xray_proj_root}" ]]; then
    printf '\033[31m[错误]\033[0m 无法解析项目根目录 (当前目录: %s)\n' "${CUR_DIR}" >&2
    exit 1
fi
readonly PROJECT_ROOT="${_xray_proj_root}" # 项目根目录
unset _xray_cur_dir _xray_cur_file _xray_proj_root

# 统一项目名 (单一来源): 数据目录与 WARP 镜像名均由 SCRIPT_NAME 派生, 改名只改这一处
readonly SCRIPT_NAME='xray-script-personal-use-only'
readonly WARP_IMAGE="${SCRIPT_NAME}-warp"
# 定义配置文件和相关目录的路径
readonly SCRIPT_CONFIG_DIR="${HOME}/.${SCRIPT_NAME}"              # 主配置文件目录
readonly I18N_DIR="${PROJECT_ROOT}/i18n"                       # 国际化文件目录
readonly CONFIG_DIR="${PROJECT_ROOT}/config"                   # 配置文件目录
readonly SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_DIR}/config.json" # 脚本主配置文件路径

# 域名格式正则 (单一来源): core/check.sh 的 valid_domain() 与 service/ssl.sh 的 --domain
# 校验共用, 防止 ".."、"*"、"/" 等非法字符进入 rm -rf / openssl / grep -E。集中定义可
# 杜绝副本漂移 (历史上 check.sh 与 ssl.sh 各有一份, 改一处漏一处)。
readonly DOMAIN_REGEX="^([a-zA-Z0-9]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"
readonly EMAIL_REGEX='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' # 邮箱地址 (单一来源,
#  与 DOMAIN_REGEX 同理: core/check.sh 与 service/ssl.sh 共用, 消除副本漂移)

# 退出码约定 (单一来源): 用法错误统一用 EXIT_USAGE, 与"正常 0 / 真实故障 1"区分开。
#   原本 check.sh / generate.sh / handler.sh 三处 main() 的 `*` 未知参数分支各写裸 `exit 2`,
#   散落且语义不显; 收口为常量便于统一维护, 也避免将来误改某一处退出码 —— 监控/cron 依赖
#   exit 2 识别"参数拼错", 改错一处会让 `core/check.sh --heath` 误报。
readonly EXIT_USAGE=2

# --- 全局变量声明 ---
# 语言参数: main.sh / install.sh 在解析 --lang 时写入, 供 load_i18n 优先采用。
# 注: 其它脚本不写它, 但保留声明可让 `${LANG_PARAM}` 在 set -u 下安全引用。
declare LANG_PARAM=''

# --- 第三方引导脚本的 GitHub 加速代理 (可选, 默认直连) ---
# 面向国内网络: raw.githubusercontent.com / api.github.com / github.com 常被阻断或极慢。
# 设 GH_PROXY 为反代前缀 (形如 https://ghfast.top) 即自动为下列域名加前缀;
# 留空 (默认) 时不做任何改写, 与历史版本行为完全一致。
declare GH_PROXY="${GH_PROXY-}"

# --- i18n 文本缓存 ---
# 将 i18n JSON 一次性展平为 "点分路径 => 文本" 的关联数组, 避免每次取文案都 fork jq 进程。
declare -A I18N_MAP=()

# =============================================================================
# 函数名称: _i18n
# 功能描述: 从 i18n 关联数组缓存中读取文本 (纯 bash 实现, 不 fork 子进程)。
# 参数:
#   $1: 点分路径键名 (例如 "menu.index.option1")
# 返回值: 直接打印对应文本; 键不存在时打印空字符串
# 备注: 恒返回 0 (纯 printf), 所以 `local x="$(_i18n ...)"` 拆不拆行语义等价。
# =============================================================================
function _i18n() {
    # 兼容两种键形态: 调用点沿用 jq 风格 ".a.b.c", 展平后的映射键为 "a.b.c",
    # 此处统一剥离可选的前导点, 避免查表落空导致文案渲染为空串。
    printf '%s' "${I18N_MAP[${1#.}]:-}"
}

function _i18n_sub() {
    # 纯 bash 占位符替换: 替代 "_i18n '...' | sed "s|${ph}|${val}|""。
    # 动机: 原 sed 写法有两类隐患 ——
    #   1) 替换值含 sed 定界符(|)或 & 时, & 会被当"整行匹配"注入、| 破坏表达式;
    #   2) 替换值为空时 sed 退化为 s|| 非法表达式, 在 set -Eeuo pipefail + ERR trap 下直接中止脚本。
    # 本函数用字符串字面量逐段拼接, 零子进程、对任意值内容(含 | & 空串)安全。
    # 用法: _i18n_sub <i18n-key> <ph1> <val1> [<ph2> <val2> ...]
    #   <ph> 为 i18n 文本中的占位符名(含 ${ }), 例如 '${domain}';
    #   <val> 为要填入的 shell 变量表达式, 例如 "${domain}"。
    local key="${1:-}"
    shift || true
    local text=''
    text="$(_i18n "$key")"
    local ph='' val='' out='' rest='' pre=''
    while [[ $# -ge 2 ]]; do
        ph="${1}"; val="${2}"; shift 2 || true
        [[ -n "${ph}" ]] || continue
        out=''; rest="${text}"
        while :; do
            pre="${rest%%"$ph"*}"
            if [[ "$pre" == "$rest" ]]; then
                out+="${rest}"; break
            fi
            out+="${pre}${val}"
            rest="${rest#*"$ph"}"
        done
        text="${out}"
    done
    printf '%s' "${text}"
}

function _replace_in_file() {
    # 纯 bash 就地文本替换: 替代 "sed -i \"s|ph|val|g\" file"。
    # 动机: 原 sed -i 写法有两类隐患 ——
    #   1) 替换值含定界符(|)或 & 时, & 被当"整行匹配"注入、| 破坏表达式;
    #   2) 当搜索串本身来自变量(如旧域名)且为空时, sed 退化为 s|| 非法表达式,
    #      在 set -Eeuo pipefail + ERR trap 下直接中止脚本。
    # 本函数用字符串字面量逐段拼接, 对任意内容安全; 经临时文件 + rename 原子落盘,
    # 并恢复原文件权限位(避免 sed -i 在部分平台改变属主可读性的副作用)。
    # 用法: _replace_in_file <file> <search> <replacement>
    local file="${1:-}" search="${2:-}" repl="${3:-}"
    [[ -n "${file}" && -f "${file}" ]] || return 1
    local content='' out='' rest='' pre='' tmp='' mode=''
    content="$(cat "${file}")" || return 1
    # 搜索串为空时无法定义"替换什么", 直接原样返回(否则下方 ${rest#*"$search"} 退化为
    # ${rest#*} 零宽匹配导致死循环); 空搜索在语义上等价于"不替换"。
    [[ -z "${search}" ]] && return 0
    out=''; rest="${content}"
    while :; do
        pre="${rest%%"$search"*}"
        if [[ "$pre" == "$rest" ]]; then
            out+="${rest}"; break
        fi
        out+="${pre}${repl}"
        rest="${rest#*"$search"}"
    done
    mode="$(stat -c '%a' "${file}" 2>/dev/null || echo 644)"
    tmp="$(mktemp "${file}.XXXXXX")" || return 1
    if ! printf '%s' "${out}" >"${tmp}"; then
        rm -f "${tmp}"; return 1
    fi
    mv -f "${tmp}" "${file}" || { rm -f "${tmp}"; return 1; }
    chmod "${mode:-644}" "${file}"
}


# --- 菜单排版宽度 (单一来源) ---
# 标题行与分隔线共用此列宽, 保证各级菜单标题栏左右对齐一致。
# 54 与原分隔线的 54 个 '-' 保持一致, 且能容纳中英文标题 (最长 "xray-script-personal-use-only" 29 列)。
declare _MENU_RULE_WIDTH="${_MENU_RULE_WIDTH:-54}"
# _disp_width 的输出通道 (避免用命令替换 $() 取宽度时 fork 子进程)
declare _DISP_WIDTH=0

# =============================================================================
# 函数名称: _disp_width
# 功能描述: 计算字符串在终端中的显示列宽 (CJK 双宽感知), 结果写入全局 _DISP_WIDTH。
#           纯 bash 实现, 不 fork wc/wcwidth。做法: 局部锁定 LC_ALL=C 后按字节遍历
#           UTF-8, 依首字节判定序列长度与占宽:
#             0x00-0x7F ASCII               1 列
#             0xC0-0xDF 2 字节 (拉丁扩展)     1 列
#             0xE0-0xEF 3 字节 (CJK/全角)     2 列
#             0xF0-0xF4 4 字节 (emoji 等)     2 列
#             0x80-0xBF 孤立续字节 (容错)      1 列
#           用全局输出而非命令替换, 是为避免每条标题多 fork 一个子进程。
# 参数: $1=字符串
# 返回值: 无 (结果写入全局变量 _DISP_WIDTH)
# =============================================================================
function _disp_width() {
    local s="${1:-}"
    local LC_ALL=C                  # 局部锁定字节语义, 不污染调用方 locale
    local width=0 i=0 n=0 b=0
    n="${#s}"
    while (( i < n )); do
        printf -v b '%d' "'${s:i:1}"
        if (( b < 0x80 )); then
            width=$(( width + 1 )); i=$(( i + 1 ))
        elif (( b < 0xE0 )); then
            width=$(( width + 1 )); i=$(( i + 2 ))
        elif (( b < 0xF0 )); then
            width=$(( width + 2 )); i=$(( i + 3 ))
        else
            width=$(( width + 2 )); i=$(( i + 4 ))
        fi
    done
    _DISP_WIDTH="${width}"
}

# =============================================================================
# 函数名称: _menu_rule
# 功能描述: 打印一条定宽分隔线, 宽度 = _MENU_RULE_WIDTH, 与 _menu_title 同源,
#           使标题栏与分隔线永远对齐 (旧写法是散落在各处的字面量 '----...----')。
# 参数: 无
# 返回值: 通过 stdout 打印分隔线
# =============================================================================
function _menu_rule() {
    local out='' i=0
    for (( i = 0; i < _MENU_RULE_WIDTH; i++ )); do
        out+='-'
    done
    printf '%s
' "${out}"
}

# =============================================================================
# 函数名称: _menu_title
# 功能描述: 打印定宽标题行, 替代散落的 '------------------ <文本> ------------------'。
#           文本按显示宽度居中, 左右以 '-' 填充至 _MENU_RULE_WIDTH 列; 文本过长
#           (无法容纳) 时原样打印, 不截断, 不报错。
# 参数: $1=标题文本
# 返回值: 通过 stdout 打印标题行
# =============================================================================
function _menu_title() {
    local text="${1:-}"
    local total="${_MENU_RULE_WIDTH}"
    local w pad left right ld='' rd='' i=0
    _disp_width "${text}"
    w="${_DISP_WIDTH}"
    if (( w + 2 > total )); then
        printf '%s
' "${text}"
        return 0
    fi
    pad=$(( total - w - 2 ))         # 两侧各留 1 个空格包裹文本
    left=$(( pad / 2 ))
    right=$(( pad - left ))
    for (( i = 0; i < left; i++ )); do ld+='-'; done
    for (( i = 0; i < right; i++ )); do rd+='-'; done
    printf '%s %s %s
' "${ld}" "${text}" "${rd}"
}

# =============================================================================
# 函数名称: load_i18n
# 功能描述: 加载国际化 (i18n) 数据。
#           1. 从 config.json 读取语言设置。
#           2. 如果设置为 "auto"，则尝试从系统环境变量 $LANG 推断语言。
#           3. 根据确定的语言，加载对应的 JSON i18n 文件。
#           4. 将文件内容展平并载入全局关联数组 I18N_MAP。
# 参数: 无
# 返回值: 无 (填充全局关联数组 I18N_MAP)
# 退出码: i18n 文件不存在时输出错误并退出脚本 (exit 1)
# =============================================================================
function load_i18n() {
    # 运行期内 i18n 文件不会变化; 主循环每轮会多次进入本函数,
    # 若每次都重展平 683 键 JSON 会无谓 fork 大量 jq 子进程。已加载则跳过。
    if [[ -n "${I18N_MAP[*]:-}" ]]; then
        return 0
    fi
    # 从配置文件中读取语言设置
    # 注: 拆声明以规避 SC2155; jq 失败(如 config.json 缺失)时 lang 保持空串, 与原合并写法语义一致
    local lang=''
    lang="$(jq -r '.language' "${SCRIPT_CONFIG_PATH}" || true)"

    # 如果语言设置为 "auto"，则使用系统环境变量 LANG 的第一部分作为语言代码
    if [[ "$lang" == "auto" ]]; then
        lang=$(echo "$LANG" | cut -d'_' -f1)
    fi

    # 构造 i18n 文件的完整路径
    local i18n_file="${I18N_DIR}/${lang}.json"

    # 检查 i18n 文件是否存在
    if [[ ! -f "${i18n_file}" ]]; then
        # 文件不存在时，根据语言输出不同的错误信息
        if [[ "$lang" == "zh" ]]; then
            echo -e "${RED}[错误]${NC} 文件不存在: ${i18n_file}" >&2
        else
            echo -e "${RED}[Error]${NC} File Not Found: ${i18n_file}" >&2
        fi
        # 退出脚本，错误码为 1
        exit 1
    fi

    # 一次性将 i18n JSON 展平为 "点分路径<Tab>文本" 并载入关联数组缓存,
    # 之后所有文案查询都走 _i18n (纯 bash), 不再为每条文案 fork 一个 jq 进程。
    # 注: jq 的 @tsv 会把值里的制表符/换行/反斜杠转义为 \t/\n/\\, 故不会破坏分隔。
    I18N_MAP=()
    local i18n_key='' i18n_val=''
    while IFS=$'\t' read -r i18n_key i18n_val; do
        # 兼容 Windows/Git Bash 下 jq 输出 CRLF: 剥离行尾 \r (Linux 下 jq 输出 LF, 无副作用)
        i18n_key="${i18n_key%$'\r'}"
        i18n_val="${i18n_val%$'\r'}"
        [[ -n "${i18n_key}" ]] && I18N_MAP["${i18n_key}"]="${i18n_val}"
    done < <(jq -r 'paths(scalars) as $p | [($p | map(tostring) | join(".")), (getpath($p) | tostring)] | @tsv' "${i18n_file}")
}

# =============================================================================
# 函数名称: _atomic_write
# 功能描述: 将标准输入的内容原子写入目标文件。
#           先写入目标文件所在目录下的临时文件, 再通过 rename 覆盖目标文件,
#           避免写入过程中断 (如 Ctrl+C、断电、OOM) 导致目标文件被截断或损坏。
# 参数:
#   $1: 目标文件路径
# 返回值: 0-写入成功 1-写入失败
# =============================================================================
function _atomic_write() {
    local target_path="${1:-}" # 目标文件路径
    local tmp_path=''      # 临时文件路径

    # 目标路径不能为空
    [[ -n "${target_path}" ]] || return 1
    # 在目标文件同目录下创建临时文件 (保证后续 mv 为同一文件系统内的原子 rename)
    tmp_path="$(mktemp "${target_path}.XXXXXX")" || return 1
    # 将标准输入写入临时文件, 失败则清理临时文件并返回
    if ! cat >"${tmp_path}"; then
        rm -f "${tmp_path}"
        return 1
    fi
    # 原子替换目标文件
    mv -f "${tmp_path}" "${target_path}" || return 1
    # 目标文件均为含密钥/口令的配置, 统一收紧为仅属主可读写
    chmod 600 "${target_path}"
}

# =============================================================================
# 函数名称: _gh_url
# 功能描述: 按需为 GitHub 系域名拼接加速前缀 (GH_PROXY 为空时原样返回)。
# 参数:
#   $1: 原始 URL
# 返回值: 直接打印改写后的 URL (恒返回 0)
# =============================================================================
function _gh_url() {
    local url="${1:-}"
    # 未配置代理或 URL 为空时原样返回
    if [[ -z "${GH_PROXY:-}" || -z "${url}" ]]; then
        printf '%s' "${url}"
        return 0
    fi
    # 安全加固: GH_PROXY 可经环境变量注入, 而本函数返回值会被拼进 service/nginx.sh 的
    # _error_detect → eval 命令串 (git clone $(_gh_url ...)), 故加白名单: 只接受
    # "scheme://host[:port][/path]" 形态, 拒绝空格与 shell 元字符 (' " $ ` ; & | ( ) < > 等)。
    # 非法时按"未配置代理"处理 (原样返回 URL) —— 既阻断注入, 又不中断调用方;
    # 告警走 stderr (stdout 是返回值, 不能污染), 且只提示一次避免刷屏。
    if [[ ! "${GH_PROXY}" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~:@/-]*)?$ ]]; then
        if [[ -z "${_GH_PROXY_WARNED:-}" ]]; then
            _GH_PROXY_WARNED=1
            printf 'GH_PROXY 值非法, 已忽略并按直连处理: %s\n' "${GH_PROXY}" >&2
        fi
        printf '%s' "${url}"
        return 0
    fi
    # 仅改写 GitHub 系域名; nginx.org / openssl.org / get.acme.sh 等保持原样
    case "${url}" in
    https://github.com/* | https://raw.githubusercontent.com/* | https://api.github.com/* | https://codeload.github.com/* | https://objects.githubusercontent.com/*)
        printf '%s/%s' "${GH_PROXY%/}" "${url}"
        ;;
    *)
        printf '%s' "${url}"
        ;;
    esac
}

# =============================================================================
# 函数名称: _resolve_public_ips
# 功能描述: 探测服务器公网 IPv4 / IPv6 地址, stdout 依次输出两行 (v4\nv6),
#           并缓存结果避免重复外网请求。分享链接、健康检查等消费方共用,
#           消除原先各自 curl、代理污染、空值静默、双栈判断不一致的问题。
# 设计要点:
#   - --noproxy '*' 绕过 http_proxy/https_proxy, 取到真实公网出口而非经代理回源;
#   - 结果缓存到文件级变量 _PUBLIC_IPV4/_PUBLIC_IPV6, 已探测则直接复用
#     (原 get_common_config 每个 inbound 都 curl, 慢且易被限流);
#   - 单项失败 (超时 / 主机无对应栈) 仅置空, 不中断调用方;
#   - 不做 IPv6 方括号包裹, 由调用方按场景决定 (分享链接需 [v6]:port)。
# 副作用: 写入 _PUBLIC_IPV4 / _PUBLIC_IPV6 / _PUBLIC_IP_PROBED (文件级)
# 返回值: 恒 0 (stdout 提供结果)
# =============================================================================
_PUBLIC_IPV4=""
_PUBLIC_IPV6=""
_PUBLIC_IP_PROBED=""

function _resolve_public_ips() {
    # 已探测过则直接回放缓存, 不再发起外网请求
    if [[ -n "${_PUBLIC_IP_PROBED}" ]]; then
        printf '%s\n%s\n' "${_PUBLIC_IPV4}" "${_PUBLIC_IPV6}"
        return 0
    fi
    _PUBLIC_IP_PROBED=1

    # --noproxy '*' 确保绕过任何出站代理, 拿真实公网地址
    _PUBLIC_IPV4="$(curl -fsSL --noproxy '*' --connect-timeout 5 --max-time 15 --retry 2 ipv4.icanhazip.com 2>/dev/null || true)"
    _PUBLIC_IPV6="$(curl -fsSL --noproxy '*' --connect-timeout 5 --max-time 15 --retry 2 ipv6.icanhazip.com 2>/dev/null || true)"
    # 去除可能的回车/空白, 防止污染分享链接或比较
    _PUBLIC_IPV4="$(printf '%s' "${_PUBLIC_IPV4}" | tr -d '[:space:]')"
    _PUBLIC_IPV6="$(printf '%s' "${_PUBLIC_IPV6}" | tr -d '[:space:]')"

    printf '%s\n%s\n' "${_PUBLIC_IPV4}" "${_PUBLIC_IPV6}"
}

# =============================================================================
# 函数名称: _preferred_remote_host
# 功能描述: 从已探测结果中挑选分享链接适用的远程主机地址。双栈主机优先 IPv4
#           (客户端兼容性最佳), 仅 IPv6 主机回退到 [IPv6] (链接需方括号包裹),
#           均无则返回空串 (保持原容错)。
# 前提: 纯函数 —— 只读全局 _PUBLIC_IPV4/_PUBLIC_IPV6, 自身不发起探测。
#       调用方必须先"直调" _resolve_public_ips (见其注释) 填充缓存。
# 参数: 无
# 返回值: 直接打印地址 (恒返回 0)
# =============================================================================
function _preferred_remote_host() {
    if [[ -n "${_PUBLIC_IPV4}" ]]; then
        printf '%s' "${_PUBLIC_IPV4}"
    elif [[ -n "${_PUBLIC_IPV6}" ]]; then
        printf '[%s]' "${_PUBLIC_IPV6}"
    fi
}

# =============================================================================
# 函数名称: _nginx_binary
# 功能描述: 本项目编译安装的 Nginx 可执行文件路径。
#           注: NGINX_PREFIX_DIR 由 core/handler.sh 以 readonly 定义, check.sh /
#           被单独 source 的夹具里没有它, 故用 :- 兜底, 保证函数随处可用。
# 参数: 无
# 返回值: 直接打印路径 (恒返回 0)
# =============================================================================
function _nginx_binary() {
    printf '%s' "${NGINX_PREFIX_DIR:-/usr/local/nginx}/sbin/nginx"
}

# =============================================================================
# 函数名称: is_local_nginx_installed
# 功能描述: 判断本机是否已安装「本项目编译版」Nginx。
#           本项目 Nginx 由 service/nginx.sh 编译安装, 需与发行版包管理器装的
#           nginx (无 Brotli 等模块) 区分对待 —— 后者落在发行版自己的路径下,
#           本路径命中即代表这是本项目编译版。
# 参数: 无
# 返回值: 0-已安装 1-未安装
#
# 注: 此前 handler.sh 与 nginx.sh 各有一份, 且**写成了两个不同的变量**:
#       handler.sh: [[ -x "${NGINX_PREFIX_DIR}/sbin/nginx" ]]
#       nginx.sh:   [[ -x "${NGINX_PATH}/sbin/nginx" ]]
#     两处的 NGINX_PATH 并非同一个东西 —— handler.sh:56 的 NGINX_PATH 是
#     "${SERVICE_DIR}/nginx.sh" (服务脚本文件), 而 nginx.sh:58 的 NGINX_PATH 是
#     "/usr/local/nginx" (安装目录)。当前两份恰好都解析到同一路径所以没出事,
#     但一旦有人按 handler.sh 的语义去改 nginx.sh, 判断就会静默反向。
#     合并后统一走 _nginx_binary, 变量只认 NGINX_PREFIX_DIR。
# =============================================================================
function is_local_nginx_installed() {
    [[ -x "$(_nginx_binary)" ]]
}

# =============================================================================
# 函数名称: _nginx_supports_http3
# 功能描述: 判断当前 Nginx 是否编译了 HTTP/3 支持 (--with-http_v3_module)。
#           用途: 站点模板里的 `listen ... quic` 在缺该模块时会让 nginx -t 直接报
#           `[emerg] invalid parameter "quic"`, 整个 Nginx 起不来 —— 所以写配置前
#           必须先探测能力, 不支持就把 quic 指令剥掉 (见 handler.sh:align_site_http3)。
#           注意: 模块存在只代表能解析 quic 指令; 真正握手还需 UDP/443 放行与
#           客户端支持, 那属于运行期检查 (见 check.sh 的 SNI 端口预检与体检)。
# 参数: 无
# 返回值: 0-支持 1-不支持或未安装
# =============================================================================
function _nginx_supports_http3() {
    local bin=''
    local out=''
    bin="$(_nginx_binary)"
    [[ -x "${bin}" ]] || return 1
    # nginx -V 把编译参数写到 stderr; 用变量承接而不是 grep -q,
    # 避免 grep 提前退出关闭管道把 nginx 打成 SIGPIPE(141)。
    out="$("${bin}" -V 2>&1 || true)"
    [[ "${out}" == *'with-http_v3_module'* ]]
}

# =============================================================================
# 函数名称: _ensure_nginx_user
# 功能描述: 确保存在专用非特权用户 nginx, 并把 Nginx worker 需要写入的目录
#           (/var/log/nginx) 归属给它。配合主配置 `user nginx;` 使用, 避免 worker
#           以 root 运行 (worker 一旦被攻破即等同主机沦陷)。
#           注: /dev/shm/nginx 的归属由 nginx.service 的 ExecStartPre 在每次启动时
#           接管 (chown nginx:nginx), 这里不必重复。
# 参数: 无
# 返回值: 0 (尽力而为, 创建失败也不阻断主流程)
# =============================================================================
function _ensure_nginx_user() {
    local u='nginx'
    if ! id -u "${u}" >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -d /var/empty "${u}" 2>/dev/null \
            || useradd -r -s /sbin/nologin "${u}" 2>/dev/null \
            || useradd -r "${u}" 2>/dev/null \
            || true
    fi
    if [[ -d /var/log/nginx ]]; then
        chown -R "${u}:${u}" /var/log/nginx 2>/dev/null || true
    fi
    return 0
}

# =============================================================================
# 函数名称: _ensure_xray_runtime_dirs
# 功能描述: 确保 Xray 的运行/日志目录 /var/log/xray 存在且权限收紧为 700 (仅 root 可读)。
#           Xray 以 root 运行且不自动创建父目录; access/error 日志写到该目录,
#           其中非 SNI 模式下会记录真实客户端 IP —— 收紧权限避免被其他本地用户读取。
# 参数: 无
# 返回值: 0 (尽力而为)
# =============================================================================
function _ensure_xray_runtime_dirs() {
    [[ -d /var/log/xray ]] || mkdir -p /var/log/xray 2>/dev/null || true
    chmod 700 /var/log/xray 2>/dev/null || true
    return 0
}

# =============================================================================
# 函数名称: _ensure_logrotate
# 功能描述: 安装日志轮转配置到 /etc/logrotate.d/xray-script-personal-use-only (幂等)。
#           背景: Nginx 站点日志与 Xray 访问日志默认只增不减, 长期运行的机器最终会把
#           磁盘写满; 体检只在单文件 >100MB 时告警, 属事后发现, 不能替代轮转。
#
#           设计取舍:
#             - 内容取自仓库模板 config/logrotate/xray-script-personal-use-only.conf, 不为"图省事"内联一份
#               —— 否则模板与脚本两份内容会漂移, 违背本仓库"单一来源"的既有约定。
#             - 落盘前逐字节比对: 内容一致时直接返回, 避免每次安装都刷新 mtime
#               (logrotate 的 dateext 按天归档, 与 mtime 无关, 但无谓写盘仍是噪音)。
#             - 仅在安装了 logrotate 本体时才写配置: 否则留着配置文件只会让 logrotate
#               报 "logrotate: command not found" 之类的噪音, 且用户无法生效。
#             - 复用 _atomic_write: 同目录临时文件 + 原子 rename, 避免写出半个文件。
#           非 Linux / 无 system 目录 (如 MSYS) 下静默跳过, 返回 1 供调用方提示。
# 参数:
#   $1: 模板路径 (可选; 默认 ${CONFIG_DIR}/logrotate/xray-script-personal-use-only.conf)
# 返回值: 0-已配置或已是最新 1-跳过 (无 logrotate / 无模板 / 无权限)
# =============================================================================
function _ensure_logrotate() {
    local tpl="${1:-${CONFIG_DIR}/logrotate/xray-script-personal-use-only.conf}"
    local dest='/etc/logrotate.d/xray-script-personal-use-only'

    # 没有 logrotate 本体就不写配置 (写了也不会被执行)
    command -v logrotate >/dev/null 2>&1 || return 1
    [[ -f "${tpl}" ]] || return 1
    [[ -d /etc/logrotate.d ]] || return 1

    # 已是最新则不动 (逐字节比对, 避免每次安装都刷新 mtime)
    if [[ -f "${dest}" ]] && cmp -s "${tpl}" "${dest}" 2>/dev/null; then
        return 0
    fi

    # 原子写 + 0644 (logrotate.d 下的配置必须是普通可读文件; _atomic_write 会强制 600,
    # 对 root-only 的 logrotate 无碍, 但显式放宽到 644 更符合该目录的惯例)
    if ! _atomic_write "${dest}" <"${tpl}"; then
        return 1
    fi
    chmod 644 "${dest}" 2>/dev/null || true
    return 0
}

# =============================================================================
# 以下为第二批下沉函数 (2026-09-19): 业务辅助函数
#
# 背景: 第一批只收敛了"共享头部"(严格模式/PATH/颜色/路径常量/i18n/_atomic_write),
#       业务辅助函数仍散落在各处重复定义 —— cmd_exists 4 份、_os/_os_full/_os_ver
#       各 3 份、print_info/warn/error 各 3 份、_download_verified 3 份。这些副本
#       当时逐字一致, 但没有任何机制阻止它们漂移; 尤其是 _download_verified ——
#       它是本项目取代 `curl xxx | bash` 的供应链防线 (体积/摘要/语法三重体检),
#       开三个口子意味着将来给其中一份补校验、另两份会静默保持裸奔。
#
# 唯一例外: install.sh 刻意保留自己的副本。它被单独下载到 ${HOME} 执行, 运行当时
#       仓库尚不存在, 必须保持单文件自包含 (见文件头注释)。因此它的同源函数也同步
#       修了同样的缺陷, 并在各自注释里标明了"与 core/_common.sh 保持同源"。
# =============================================================================

# =============================================================================
# 函数名称: cmd_exists
# 功能描述: 检查指定命令是否存在于当前 PATH (白名单 PATH, 见本文件顶部)。
# 参数:
#   $1: 命令名称
# 返回值: 0-存在 1-不存在/参数为空
# =============================================================================
function cmd_exists() {
    local cmd="${1:-}"
    [[ -n "${cmd}" ]] || return 1
    command -v -- "${cmd}" >/dev/null 2>&1
}

# =============================================================================
# 函数名称: is_enabled
# 功能描述: 判断一个"开关值"是否为开启状态, 供所有 `if 开关 ...` 判断统一使用。
#           接受的取值: 1 / true / yes / y / on (视为开启), 其余一律视为未开启。
# 参数:
#   $1: 待判断的值 (通常来自 `jq -r` 输出或用户输入, 可能是 1/0/Y/N/true/null/空串)
# 返回值: 0-开启 1-未开启
# 背景 (为什么必须有这个函数):
#   开关值普遍来自 `jq -r` 或用户交互输入, 而 `[[ ${flag} -eq 1 ]]` 这种写法是
#   **算术求值**: 遇到非数字字符串时, bash 会把它当成变量名去求值 —— 在全局
#   `set -u` 下直接以 "bash: Y: 未绑定的变量" / "bash: null: 未绑定的变量" 崩溃,
#   整个脚本随之中断 (实测确认)。两种触发路径都是真实场景:
#     1) jq -r 对缺失字段或显式 null 输出的是**字面字符串 "null"** (不是空串),
#        导入备份 / 手工编辑配置 / 跨版本迁移导致字段缺失时必然命中;
#     2) 交互输入默认给的是 "Y" / "N" (见 handler.sh 的 block-bt/block-cn/block-ad),
#        用户一旦选了 Y, 同款比较立即崩溃。
#   空串反而安全 (算术求值为 0), 所以这个坑只在"值非空且非数字"时爆发,
#   默认路径不易发现, 属于典型的潜伏缺陷。
#   统一走本函数即可同时覆盖数字开关与 Y/N 开关, 不再逐个打补丁。
# =============================================================================
function is_enabled() {
    local value="${1:-}"
    # ${var,,} 展开为小写后再匹配, 使 Y / Yes / TRUE 等写法都能被识别 (bash 4+)
    case "${value,,}" in
    1 | true | yes | y | on) return 0 ;;
    *) return 1 ;;
    esac
}

# =============================================================================
# 函数名称: print_info / print_warn / print_error
# 功能描述: 统一的日志输出三件套, 输出到 stderr 以免污染 `$(...)` 捕获的 stdout。
# 参数:
#   $*: 消息内容
# 返回值: print_info/print_warn 恒 0; print_error 打印后 exit 1 (不返回)
# 注: print_error 会终止调用方脚本, 与下沉前各副本语义完全一致。
# =============================================================================
function print_info() {
    printf "${GREEN}[%s] ${NC}%s\n" "$(_i18n '.title.info')" "$*" >&2
}

function print_warn() {
    printf "${YELLOW}[%s] ${NC}%s\n" "$(_i18n '.title.warn')" "$*" >&2
}

function print_error() {
    # $1=错误消息; $2=可选的可执行建议 (非空时以 [建议] 追加一行到 stderr)
    local msg="${1:-}" hint="${2:-}"
    printf "${RED}[%s] ${NC}%s\n" "$(_i18n '.title.error')" "${msg}" >&2
    if [[ -n "${hint}" ]]; then
        printf "${YELLOW}[%s] ${NC}%s\n" "$(_i18n '.title.hint')" "${hint}" >&2
    fi
    exit 1
}

# =============================================================================
# 函数名称: _os
# 功能描述: 检测当前操作系统的发行版名称。
# 参数: 无
# 返回值: 直接打印发行版 ID (debian/ubuntu/centos/...)
# =============================================================================
function _os() {
    local os=""

    # Debian/Ubuntu 系列
    if [[ -f "/etc/debian_version" ]]; then
        source /etc/os-release && os="${ID}"
        printf -- "%s" "${os}" && return
    fi

    # Red Hat/CentOS 系列
    if [[ -f "/etc/redhat-release" ]]; then
        os="centos"
        printf -- "%s" "${os}" && return
    fi
}

# =============================================================================
# 函数名称: _os_full
# 功能描述: 获取当前操作系统的完整发行版信息。
# 参数: 无
# 返回值: 直接打印完整版本信息
# =============================================================================
function _os_full() {
    if [[ -f /etc/redhat-release ]]; then
        awk '{print ($1,$3~/^[0-9]/?$3:$4)}' /etc/redhat-release && return
    fi

    if [[ -f /etc/os-release ]]; then
        awk -F'[= "]' '/PRETTY_NAME/{print $3,$4,$5}' /etc/os-release && return
    fi

    if [[ -f /etc/lsb-release ]]; then
        awk -F'[="]+' '/DESCRIPTION/{print $2}' /etc/lsb-release && return
    fi
}

# =============================================================================
# 函数名称: _os_ver
# 功能描述: 获取当前操作系统的主版本号。
# 参数: 无
# 返回值: 直接打印主版本号 (第一个点号前的部分)
# =============================================================================
function _os_ver() {
    local main_ver
    main_ver="$(echo "$(_os_full)" | grep -oE "[0-9.]+" || true)"
    printf -- "%s" "${main_ver%%.*}"
}

# =============================================================================
# 函数名称: _download_verified
# 功能描述: 取代 `curl xxx | bash` 的安全下载: 先把远程脚本落到 0600 临时文件,
#           通过【体积 / SHA256 摘要 / bash 语法】三重体检后才把路径交给调用方。
#           这是本项目唯一的第三方代码入口, 三个副本合并到此后只剩一个口子。
# 参数:
#   $1: 下载地址 (会经 _gh_url 按需加 GH 加速前缀)
#   $2: 期望的 SHA256 摘要 (可选; 省略则跳过摘要比对)
# 环境变量:
#   TMPFILE_DIR: 临时目录 (可选; 不可写时依次退回 ${SCRIPT_CONFIG_DIR} / ${TMPDIR} / /tmp)
# 返回值: stdout 打印已体检通过的本地文件路径; 任一环节失败返回 1 且清理临时文件
# =============================================================================
function _download_verified() {
    local url="${1:-}"            # 下载地址
    local expect_sha256="${2:-}"  # 期望摘要 (可选)
    local tmp_dir="${TMPFILE_DIR:-${SCRIPT_CONFIG_DIR}}"
    local tmp_file=''
    local got_sha256=''

    # 参数与目录体检: 目录不可用时退回系统临时目录
    [[ -n "${url}" ]] || return 1
    if [[ ! -d "${tmp_dir}" || ! -w "${tmp_dir}" ]]; then
        tmp_dir="${TMPDIR:-/tmp}"
    fi

    # 摘要缺失守卫 (2026-09-21 增设)
    # 这一步若在静默中被跳过, 就等价于 acme.sh 当年那个 P0: 只剩"体积≥512B + bash -n"
    # 两道弱校验, 而下载物随后会被执行。跳过摘要属于明确的降级选择 (即"跟随上游最新版"),
    # 必须在 stderr 上显性告知 —— 本函数的 stdout 只输出待用文件路径, 告警走 stderr 不会污染。
    if [[ -z "${expect_sha256}" ]]; then
        print_warn "$(_i18n '.common.download.no_sha256')"
        if [[ -n "${GH_PROXY:-}" ]]; then
            print_warn "$(_i18n '.common.download.via_proxy')"
        fi
    fi

    # 创建 0600 临时文件 (mktemp 默认权限即为仅属主可读写)
    tmp_file="$(mktemp "${tmp_dir%/}/.${SCRIPT_NAME}-dl.XXXXXXXX")" || return 1

    # 1) 下载: 失败 (HTTP 4xx/5xx、超时、断网) 即清理并返回
    if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 -o "${tmp_file}" "$(_gh_url "${url}")"; then
        rm -f "${tmp_file}"
        return 1
    fi

    # 2) 体积体检: 拦截空响应与错误页 (正常安装脚本远大于 512 字节)
    if [[ ! -s "${tmp_file}" ]] || [[ "$(wc -c <"${tmp_file}")" -lt 512 ]]; then
        rm -f "${tmp_file}"
        return 1
    fi

    # 3) 摘要体检: 给定期望摘要时比对 (忽略大小写)
    if [[ -n "${expect_sha256}" ]]; then
        got_sha256="$(sha256sum "${tmp_file}" | cut -d' ' -f1)"
        if [[ "${got_sha256,,}" != "${expect_sha256,,}" ]]; then
            rm -f "${tmp_file}"
            return 1
        fi
    fi

    # 4) 语法体检: 拦截非脚本内容与截断脚本
    if ! bash -n "${tmp_file}" 2>/dev/null; then
        rm -f "${tmp_file}"
        return 1
    fi

    printf '%s' "${tmp_file}"
    return 0
}

# =============================================================================
# 函数名称: _remove_site_conf
# 功能描述: 删除指定域名的 nginx 站点配置 (available + enabled 两处), 统一收口原本散落在
#           handler.sh / nginx.sh 的 7 处 "rm -f sites-available/...; rm -f sites-enabled/..."
#           重复对, 消除 DRY 隐患 (改一处漏一处的副本漂移)。幂等: 文件不存在时静默跳过。
# 参数:
#   $1: 站点域名 (site_name); 为空直接返回 0 (不报错)
# 目录解析 (兼容两套变量名):
#   - handler.sh 环境用 NGINX_CONFIG_DIR (${NGINX_PREFIX_DIR}/conf);
#   - nginx.sh 环境用 NGINX_PATH/conf (其 conf_dir 局部变量);
#   二者任一缺失时退回 /usr/local/nginx/conf, 确保删除路径与原调用点逐字符一致。
# =============================================================================
function _remove_site_conf() {
    local site_name="${1:-}"
    [[ -n "${site_name}" ]] || return 0
    local conf_dir="${NGINX_CONFIG_DIR:-${NGINX_PATH:-/usr/local/nginx}/conf}"
    rm -f "${conf_dir}/sites-available/${site_name}.conf"
    rm -f "${conf_dir}/sites-enabled/${site_name}.conf"
}
