#!/usr/bin/env bash
#
# Copyright (C) 2026 crudguy
#
# xray-script-personal-use-only:
#   https://github.com/crudguy/xray-script-personal-use-only
# =============================================================================
# 脚本名称: menu.sh
# 功能描述: 提供交互式菜单界面，用于 xray-script-personal-use-only 项目的主控制台。
#           显示各种配置选项、状态信息和操作菜单，支持多语言。
# 作者: crudguy
# 时间: 2026-09-19
# 版本: 1.0.0
# 依赖: bash, jq, sed, base64
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言、Xray 版本、配置标签等设置
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的菜单文本 (i18n 数据文件)
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

# 定义配置文件和相关目录的路径

# =============================================================================
# 函数名称: menu_language
# 功能描述: 显示语言选择菜单。
# 参数: 无
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function menu_language() {
    echo -e "${GREEN}1.${NC}中文"
    echo -e "${GREEN}2.${NC}English"
}

# =============================================================================
# 函数名称: menu_index
# 功能描述: 显示主菜单。
# 参数: 无 (直接使用全局变量 SCRIPT_CONFIG_PATH 和 I18N_MAP)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function menu_index() {
    # 从配置文件中读取脚本版本号
    local version
    version=$(jq -r '.version' "${SCRIPT_CONFIG_PATH}" || true)

    _menu_title "xray-script-personal-use-only"
    echo -e "Version      : ${GREEN}${version}${NC}"
    # 从 i18n 数据中读取描述信息
    echo -e "Description  : $(_i18n ".${CUR_FILE}.index.description")"

    _menu_title "$(_i18n ".${CUR_FILE}.index.installation")"
    echo -e "${GREEN}1.${NC} $(_i18n ".${CUR_FILE}.index.option1")"
    echo -e "${GREEN}2.${NC} $(_i18n ".${CUR_FILE}.index.option2")"
    echo -e "${GREEN}3.${NC} $(_i18n ".${CUR_FILE}.index.option3")"

    _menu_title "$(_i18n ".${CUR_FILE}.index.operation")"
    echo -e "${GREEN}4.${NC} $(_i18n ".${CUR_FILE}.index.option4")"
    echo -e "${GREEN}5.${NC} $(_i18n ".${CUR_FILE}.index.option5")"
    echo -e "${GREEN}6.${NC} $(_i18n ".${CUR_FILE}.index.option6")"

    _menu_title "$(_i18n ".${CUR_FILE}.index.configuration")"
    echo -e "${GREEN}7.${NC} $(_i18n ".${CUR_FILE}.index.option7")"
    echo -e "${GREEN}8.${NC} $(_i18n ".${CUR_FILE}.index.option8")"
    echo -e "${GREEN}9.${NC} $(_i18n ".${CUR_FILE}.index.option9")"

    # 诊断单列一节而不是塞进"配置管理": 体检是只读的,
    # 与"改配置"语义相反, 混在一起会让用户以为点它会改东西
    _menu_title "$(_i18n ".${CUR_FILE}.index.diagnostic")"
    echo -e "${GREEN}10.${NC} $(_i18n ".${CUR_FILE}.index.option10")"

    # 订阅与"分享链接"并列: 分享=单条链接/二维码, 订阅=聚合导入
    _menu_title "$(_i18n ".${CUR_FILE}.index.subscription")"
    echo -e "${GREEN}11.${NC} $(_i18n ".${CUR_FILE}.index.option11")"

    _menu_rule
    echo -e "${RED}0.${NC} $(_i18n ".${CUR_FILE}.index.option0")"
}

# =============================================================================
# 函数名称: menu_uninstall
# 功能描述: 显示卸载管理子菜单。让用户明确选择卸载对象 (Xray / Nginx),
#           避免把"卸载 Nginx"隐藏在主菜单第 3 项里造成误操作。
# 参数: 无 (直接使用全局变量 I18N_MAP)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function menu_uninstall() {
    _menu_title "$(_i18n ".${CUR_FILE}.uninstall.title")"
    echo -e "${GREEN}1.${NC} $(_i18n ".${CUR_FILE}.uninstall.option1")"
    echo -e "${GREEN}2.${NC} $(_i18n ".${CUR_FILE}.uninstall.option2")"

    _menu_rule
    echo -e "1. $(_i18n ".${CUR_FILE}.uninstall.info1")"
    echo -e "2. $(_i18n ".${CUR_FILE}.uninstall.info2")"
    echo -e "${RED}0.${NC} $(_i18n ".${CUR_FILE}.uninstall.option0")"
    _menu_rule
}

# =============================================================================
# 函数名称: menu_full_installation
# 功能描述: 显示完整安装选项菜单。
# 参数: 无 (直接使用全局变量 I18N_MAP)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function menu_full_installation() {
    _menu_title "$(_i18n ".${CUR_FILE}.full_installation.title")"
    echo -e "${GREEN}1.${NC} $(_i18n ".${CUR_FILE}.full_installation.option1")(${GREEN}$(_i18n ".${CUR_FILE}.status.default")${NC})"
    echo -e "${GREEN}2.${NC} $(_i18n ".${CUR_FILE}.full_installation.option2")"

    _menu_rule
    echo -e "1. $(_i18n ".${CUR_FILE}.full_installation.info1")"
    echo -e "2. $(_i18n ".${CUR_FILE}.full_installation.info2")"
    echo -e "${RED}0.${NC} $(_i18n ".${CUR_FILE}.full_installation.option0")"
    _menu_rule
}

# =============================================================================
# 函数名称: menu_xray
# 功能描述: 显示 Xray 版本选择菜单。
# 参数: 无 (直接使用全局变量 I18N_MAP)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function menu_xray() {
    _menu_title "$(_i18n ".${CUR_FILE}.xray_version.title")"
    echo -e "${GREEN}1.${NC} $(_i18n ".${CUR_FILE}.xray_version.option1")"
    echo -e "${GREEN}2.${NC} $(_i18n ".${CUR_FILE}.xray_version.option2")(${GREEN}$(_i18n ".${CUR_FILE}.status.default")${NC})"
    echo -e "${GREEN}3.${NC} $(_i18n ".${CUR_FILE}.xray_version.option3")"

    _menu_rule
    echo -e "1. $(_i18n ".${CUR_FILE}.xray_version.info1")"
    echo -e "2. $(_i18n ".${CUR_FILE}.xray_version.info2")"
    echo -e "3. $(_i18n ".${CUR_FILE}.xray_version.info3")"
    _menu_rule
}

# =============================================================================
# 函数名称: menu_xray_config
# 功能描述: 显示 Xray 协议配置菜单。
# 参数: 无 (直接使用全局变量 I18N_MAP)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function menu_xray_config() {
    _menu_title "$(_i18n ".${CUR_FILE}.protocol_config.title")"
    echo -e "${GREEN}1.${NC} $(_i18n ".${CUR_FILE}.protocol_config.option1")"
    echo -e "${GREEN}2.${NC} $(_i18n ".${CUR_FILE}.protocol_config.option2")(${GREEN}$(_i18n ".${CUR_FILE}.status.default")${NC})"
    echo -e "${GREEN}3.${NC} $(_i18n ".${CUR_FILE}.protocol_config.option3")"
    echo -e "${GREEN}4.${NC} $(_i18n ".${CUR_FILE}.protocol_config.option4")"
    echo -e "${GREEN}5.${NC} $(_i18n ".${CUR_FILE}.protocol_config.option5")"
    echo -e "${GREEN}6.${NC} $(_i18n ".${CUR_FILE}.protocol_config.option6")"

    _menu_rule
    echo -e "1. $(_i18n ".${CUR_FILE}.protocol_config.info1")"
    echo -e "2. $(_i18n ".${CUR_FILE}.protocol_config.info2")"
    echo -e "3. $(_i18n ".${CUR_FILE}.protocol_config.info3")"
    echo -e "3.1. $(_i18n ".${CUR_FILE}.protocol_config.info3_1")"
    echo -e "3.2. $(_i18n ".${CUR_FILE}.protocol_config.info3_2")"
    echo -e "3.3. $(_i18n ".${CUR_FILE}.protocol_config.info3_3")"
    echo -e "4. $(_i18n ".${CUR_FILE}.protocol_config.info4")"
    echo -e "5. $(_i18n ".${CUR_FILE}.protocol_config.info5")"
    echo -e "6. $(_i18n ".${CUR_FILE}.protocol_config.info6")"
    _menu_rule
}

# =============================================================================
# 函数名称: menu_web_config
# 功能描述: 显示 Web 服务器配置菜单。
# 参数: 无 (直接使用全局变量 I18N_MAP)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function menu_web_config() {
    _menu_title "$(_i18n ".${CUR_FILE}.web_config.title")"
    echo -e "${GREEN}1.${NC} $(_i18n ".${CUR_FILE}.web_config.option1")(${GREEN}$(_i18n ".${CUR_FILE}.status.default")${NC})"
    _menu_rule
}

# =============================================================================
# 函数名称: menu_ca_vendor
# 功能描述: 打印 CA 供应商选择菜单 (ZeroSSL / Let's Encrypt 两项) 及说明信息。
# 参数: 无
# 返回值: 恒 0
# =============================================================================
function menu_ca_vendor() {
    _menu_title "$(_i18n ".${CUR_FILE}.ca_vendor.title")"
    echo -e "${GREEN}1.${NC} $(_i18n ".${CUR_FILE}.ca_vendor.option1")(${GREEN}$(_i18n ".${CUR_FILE}.status.default")${NC})"
    echo -e "${GREEN}2.${NC} $(_i18n ".${CUR_FILE}.ca_vendor.option2")"
    _menu_rule
    echo -e "1. $(_i18n ".${CUR_FILE}.ca_vendor.info1")"
    echo -e "2. $(_i18n ".${CUR_FILE}.ca_vendor.info2")"
    _menu_rule
}

# =============================================================================
# 函数名称: menu_config
# 功能描述: 显示配置管理菜单。
# 参数: 无 (直接使用全局变量 I18N_MAP)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function menu_config() {
    _menu_title "$(_i18n ".${CUR_FILE}.config_management.title")"
    echo -e "${GREEN}1.${NC} $(_i18n ".${CUR_FILE}.config_management.option1")"
    echo -e "${GREEN}2.${NC} $(_i18n ".${CUR_FILE}.config_management.option2")"
    echo -e "${GREEN}3.${NC} $(_i18n ".${CUR_FILE}.config_management.option3")"
    echo -e "${GREEN}4.${NC} $(_i18n ".${CUR_FILE}.config_management.option4")"
    echo -e "${GREEN}5.${NC} $(_i18n ".${CUR_FILE}.config_management.option5")"
    echo -e "${GREEN}6.${NC} $(_i18n ".${CUR_FILE}.config_management.option6")"
    echo -e "${GREEN}7.${NC} $(_i18n ".${CUR_FILE}.config_management.option7")"
    echo -e "${GREEN}8.${NC} $(_i18n ".${CUR_FILE}.config_management.option8")"

    _menu_rule
    echo -e "1. $(_i18n ".${CUR_FILE}.config_management.info1")"
    echo -e "2. $(_i18n ".${CUR_FILE}.config_management.info2")"
    echo -e "3. $(_i18n ".${CUR_FILE}.config_management.info3")"
    echo -e "4. $(_i18n ".${CUR_FILE}.config_management.info4")"
    echo -e "5. $(_i18n ".${CUR_FILE}.config_management.info5")"
    echo -e "7. $(_i18n ".${CUR_FILE}.config_management.info6")"
    echo -e "8. $(_i18n ".${CUR_FILE}.config_management.info7")"
    _menu_rule
}

# =============================================================================
# 函数名称: menu_bbr
# 功能描述: 显示 BBR 与内核网络加速子菜单。
#           选项语义: 1 是"改"(幂等开启/修复), 2 是"看"(只读体检), 3/4 是两批
#           整机级优化 —— 单独成项而不并入 1, 因为它们的影响面远超 BBR 本身
#           (对所有进程/用户/服务生效), 不该在用户点"开启 BBR"时被顺手施加。
# 参数: 无 (直接使用全局变量 I18N_MAP)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function menu_bbr() {
    _menu_title "$(_i18n ".${CUR_FILE}.bbr.title")"
    echo -e "${GREEN}1.${NC} $(_i18n ".${CUR_FILE}.bbr.option1")"
    echo -e "${GREEN}2.${NC} $(_i18n ".${CUR_FILE}.bbr.option2")"
    echo -e "${GREEN}3.${NC} $(_i18n ".${CUR_FILE}.bbr.option3")"
    echo -e "${GREEN}4.${NC} $(_i18n ".${CUR_FILE}.bbr.option4")"

    _menu_rule
    echo -e "1. $(_i18n ".${CUR_FILE}.bbr.info1")"
    echo -e "2. $(_i18n ".${CUR_FILE}.bbr.info2")"
    echo -e "3. $(_i18n ".${CUR_FILE}.bbr.info3")"
    echo -e "4. $(_i18n ".${CUR_FILE}.bbr.info4")"
    echo -e "${RED}0.${NC} $(_i18n ".${CUR_FILE}.bbr.option0")"
    _menu_rule
}

# =============================================================================
# 函数名称: menu_route
# 功能描述: 显示路由规则管理菜单。
# 参数: 无 (直接使用全局变量 I18N_MAP)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function menu_route() {
    _menu_title "$(_i18n ".${CUR_FILE}.route_management.title")"
    echo -e "${GREEN}1.${NC} $(_i18n ".${CUR_FILE}.route_management.option1")"
    echo -e "${GREEN}2.${NC} $(_i18n ".${CUR_FILE}.route_management.option2")"
    echo -e "${GREEN}3.${NC} $(_i18n ".${CUR_FILE}.route_management.option3")"
    echo -e "${GREEN}4.${NC} $(_i18n ".${CUR_FILE}.route_management.option4")"
    echo -e "${GREEN}5.${NC} $(_i18n ".${CUR_FILE}.route_management.option5")"
    echo -e "${GREEN}6.${NC} $(_i18n ".${CUR_FILE}.route_management.option6")"

    _menu_rule
    # 选项 1 的说明分三行打印 (info1~info3, 均以序号 1. 呈现)
    echo -e "1. $(_i18n ".${CUR_FILE}.route_management.info1")"
    echo -e "1. $(_i18n ".${CUR_FILE}.route_management.info2")"
    echo -e "1. $(_i18n ".${CUR_FILE}.route_management.info3")"
    echo -e "2. $(_i18n ".${CUR_FILE}.route_management.info4")"
    echo -e "3. $(_i18n ".${CUR_FILE}.route_management.info5")"
    echo -e "4. $(_i18n ".${CUR_FILE}.route_management.info6")"
    echo -e "5. $(_i18n ".${CUR_FILE}.route_management.info7")"
    echo -e "6. $(_i18n ".${CUR_FILE}.route_management.info8")"
    _menu_rule
}

# =============================================================================
# 函数名称: menu_sni_config
# 功能描述: 显示 SNI 配置菜单。
# 参数: 无 (直接使用全局变量 I18N_MAP)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function menu_sni_config() {
    _menu_title "$(_i18n ".${CUR_FILE}.sni_config.title")"
    echo -e "${GREEN}1.${NC} $(_i18n ".${CUR_FILE}.sni_config.option1")"
    echo -e "${GREEN}2.${NC} $(_i18n ".${CUR_FILE}.sni_config.option2")"
    echo -e "${GREEN}3.${NC} $(_i18n ".${CUR_FILE}.sni_config.option3")"
    echo -e "${GREEN}4.${NC} $(_i18n ".${CUR_FILE}.sni_config.option4")"
    echo -e "${GREEN}5.${NC} $(_i18n ".${CUR_FILE}.sni_config.option5")"
    echo -e "${GREEN}6.${NC} $(_i18n ".${CUR_FILE}.sni_config.option6")"
    echo -e "${GREEN}7.${NC} $(_i18n ".${CUR_FILE}.sni_config.option7")"
    echo -e "${GREEN}8.${NC} $(_i18n ".${CUR_FILE}.sni_config.option8")"
    echo -e "${GREEN}9.${NC} $(_i18n ".${CUR_FILE}.sni_config.option9")"

    _menu_rule
    echo -e "1. $(_i18n ".${CUR_FILE}.sni_config.info1")"
    echo -e "2. $(_i18n ".${CUR_FILE}.sni_config.info2")"
    echo -e "7. $(_i18n ".${CUR_FILE}.sni_config.info3")"
    echo -e "8. $(_i18n ".${CUR_FILE}.sni_config.info4")"
    echo -e "9. $(_i18n ".${CUR_FILE}.sni_config.info5")"
    _menu_rule
}

# =============================================================================
# 函数名称: menu_custom_sites
# 功能描述: 打印自定义站点管理菜单 (列表 / 新增 / 修改 / 删除) 及说明信息。
# 参数: 无
# 返回值: 恒 0
# =============================================================================
function menu_custom_sites() {
    _menu_title "$(_i18n ".${CUR_FILE}.custom_sites.title")"
    echo -e "${GREEN}1.${NC} $(_i18n ".${CUR_FILE}.custom_sites.option1")"
    echo -e "${GREEN}2.${NC} $(_i18n ".${CUR_FILE}.custom_sites.option2")"
    echo -e "${GREEN}3.${NC} $(_i18n ".${CUR_FILE}.custom_sites.option3")"
    echo -e "${GREEN}4.${NC} $(_i18n ".${CUR_FILE}.custom_sites.option4")"

    _menu_rule
    echo -e "1. $(_i18n ".${CUR_FILE}.custom_sites.info1")"
    echo -e "2. $(_i18n ".${CUR_FILE}.custom_sites.info2")"
    echo -e "3. $(_i18n ".${CUR_FILE}.custom_sites.info3")"
    echo -e "4. $(_i18n ".${CUR_FILE}.custom_sites.info4")"
    _menu_rule
}

# =============================================================================
# 函数名称: menu_backup
# 功能描述: 显示配置备份与迁移子菜单 (导出 / 导入)。
#           导出与导入分成两个入口而非"一个键循环", 因为导入会覆盖生产配置,
#           必须在菜单层面就是一次独立的、需要确认的动作。
# 参数: 无 (直接使用全局变量 I18N_MAP)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function menu_backup() {
    _menu_title "$(_i18n ".${CUR_FILE}.backup.title")"
    echo -e "${GREEN}1.${NC} $(_i18n ".${CUR_FILE}.backup.option1")"
    echo -e "${GREEN}2.${NC} $(_i18n ".${CUR_FILE}.backup.option2")"

    _menu_rule
    echo -e "1. $(_i18n ".${CUR_FILE}.backup.info1")"
    echo -e "2. $(_i18n ".${CUR_FILE}.backup.info2")"
    echo -e "${RED}0.${NC} $(_i18n ".${CUR_FILE}.backup.option0")"
    _menu_rule
}

# =============================================================================
# 函数名称: _terminal_width
# 功能描述: 取当前终端宽度 (列数), 取不到时退回 80。
#           非 TTY 场景 (cron / 管道 / 重定向) 下 tput 与 COLUMNS 都不可靠,
#           故一律按 80 处理 —— 宁可显示完整 banner, 也不要误判成窄屏。
# 参数: 无
# 返回值: 打印列数 (恒为整数)
# =============================================================================
function _terminal_width() {
    local width=''
    # 只有 stderr 确实是终端时 tput 才有意义
    if [[ -t 2 ]] && cmd_exists 'tput'; then
        width="$(tput cols 2>/dev/null || true)"
    fi
    # tput 取不到再看 COLUMNS (bash 仅在交互式 shell 自动维护)
    [[ "${width}" =~ ^[0-9]+$ ]] || width="${COLUMNS:-}"
    [[ "${width}" =~ ^[0-9]+$ ]] || width=80
    printf '%s' "${width}"
}

# =============================================================================
# 函数名称: print_banner
# 功能描述: 随机打印一个 ASCII 艺术风格的 Banner (窄终端自动降级为单行标题)。
# 参数: 无
# 返回值: 无 (直接打印到标准输出)
# =============================================================================
function print_banner() {
    # 窄终端降级: 下面两段 ASCII art 宽约 70 列, 在手机 SSH / 分屏 / 窄窗口里会被
    # 折行成乱版, 反而盖住紧随其后的状态栏与菜单。宽度不足时改打一行紧凑标题。
    if (($(_terminal_width) < 80)); then
        echo -e "$(_i18n '.menu.banner_compact')"
        return 0
    fi

    # 生成一个 0 或 1 的随机数
    case $((RANDOM % 2)) in
    # 如果是 0，打印第一个 Banner (解码后)
    0)
        echo "IBtbMDsxOzM1Ozk1bV8bWzA7MTszMTs5MW1fG1swbSAgIBtbMDsxOzMyOzkybV9fG1swbSAgG1swOzE7MzQ7OTRtXxtbMG0gICAgG1swOzE7MzE7OTFtXxtbMG0gICAbWzA7MTszMjs5Mm1fG1swOzE7MzY7OTZtX18bWzA7MTszNDs5NG1fXxtbMDsxOzM1Ozk1bV9fG1swbSAgIBtbMDsxOzMzOzkzbV8bWzA7MTszMjs5Mm1fXxtbMDsxOzM2Ozk2bV9fG1swOzE7MzQ7OTRtX18bWzBtICAgG1swOzE7MzE7OTFtXxtbMDsxOzMzOzkzbV9fG1swOzE7MzI7OTJtX18bWzBtICAKIBtbMDsxOzMxOzkxbVwbWzBtIBtbMDsxOzMzOzkzbVwbWzBtIBtbMDsxOzMyOzkybS8bWzBtIBtbMDsxOzM2Ozk2bS8bWzBtIBtbMDsxOzM0Ozk0bXwbWzBtIBtbMDsxOzM1Ozk1bXwbWzBtICAbWzA7MTszMzs5M218G1swbSAbWzA7MTszMjs5Mm18G1swbSAbWzA7MTszNjs5Nm18XxtbMDsxOzM0Ozk0bV8bWzBtICAgG1swOzE7MzE7OTFtX18bWzA7MTszMzs5M218G1swbSAbWzA7MTszMjs5Mm18XxtbMDsxOzM2Ozk2bV8bWzBtICAgG1swOzE7MzU7OTVtX18bWzA7MTszMTs5MW18G1swbSAbWzA7MTszMzs5M218G1swbSAgG1swOzE7MzI7OTJtXxtbMDsxOzM2Ozk2bV8bWzBtIBtbMDsxOzM0Ozk0bVwbWzBtIAogIBtbMDsxOzMyOzkybVwbWzBtIBtbMDsxOzM2Ozk2bVYbWzBtIBtbMDsxOzM0Ozk0bS8bWzBtICAbWzA7MTszNTs5NW18G1swbSAbWzA7MTszMTs5MW18G1swOzE7MzM7OTNtX18bWzA7MTszMjs5Mm18G1swbSAbWzA7MTszNjs5Nm18G1swbSAgICAbWzA7MTszNTs5NW18G1swbSAbWzA7MTszMTs5MW18G1swbSAgICAgICAbWzA7MTszNDs5NG18G1swbSAbWzA7MTszNTs5NW18G1swbSAgICAbWzA7MTszMjs5Mm18G1swbSAbWzA7MTszNjs5Nm18XxtbMDsxOzM0Ozk0bV8pG1swbSAbWzA7MTszNTs5NW18G1swbQogICAbWzA7MTszNjs5Nm0+G1swbSAbWzA7MTszNDs5NG08G1swbSAgIBtbMDsxOzMxOzkxbXwbWzBtICAbWzA7MTszMjs5Mm1fXxtbMG0gIBtbMDsxOzM0Ozk0bXwbWzBtICAgIBtbMDsxOzMxOzkxbXwbWzBtIBtbMDsxOzMzOzkzbXwbWzBtICAgICAgIBtbMDsxOzM1Ozk1bXwbWzBtIBtbMDsxOzMxOzkxbXwbWzBtICAgIBtbMDsxOzM2Ozk2bXwbWzBtICAbWzA7MTszNDs5NG1fG1swOzE7MzU7OTVtX18bWzA7MTszMTs5MW0vG1swbSAKICAbWzA7MTszNDs5NG0vG1swbSAbWzA7MTszNTs5NW0uG1swbSAbWzA7MTszMTs5MW1cG1swbSAgG1swOzE7MzM7OTNtfBtbMG0gG1swOzE7MzI7OTJtfBtbMG0gIBtbMDsxOzM0Ozk0bXwbWzBtIBtbMDsxOzM1Ozk1bXwbWzBtICAgIBtbMDsxOzMzOzkzbXwbWzBtIBtbMDsxOzMyOzkybXwbWzBtICAgICAgIBtbMDsxOzMxOzkxbXwbWzBtIBtbMDsxOzMzOzkzbXwbWzBtICAgIBtbMDsxOzM0Ozk0bXwbWzBtIBtbMDsxOzM1Ozk1bXwbWzBtICAgICAKIBtbMDsxOzM0Ozk0bS8bWzA7MTszNTs5NW1fLxtbMG0gG1swOzE7MzE7OTFtXBtbMDsxOzMzOzkzbV9cG1swbSAbWzA7MTszMjs5Mm18G1swOzE7MzY7OTZtX3wbWzBtICAbWzA7MTszNTs5NW18XxtbMDsxOzMxOzkxbXwbWzBtICAgIBtbMDsxOzMyOzkybXwbWzA7MTszNjs5Nm1ffBtbMG0gICAgICAgG1swOzE7MzM7OTNtfBtbMDsxOzMyOzkybV98G1swbSAgICAbWzA7MTszNTs5NW18XxtbMDsxOzMxOzkxbXwbWzBtICAgICAKCkNvcHlyaWdodCAoQykgY3J1ZGd1eSB8IGh0dHBzOi8vZ2l0aHViLmNvbS9jcnVkZ3V5L3hyYXktb25la2V5Cgo=" | base64 --decode
        ;;
    # 如果是 1，打印第二个 Banner (解码后)
    1)
        echo "IBtbMDsxOzM0Ozk0bV9fG1swbSAgIBtbMDsxOzM0Ozk0bV9fG1swbSAgG1swOzE7MzQ7OTRtXxtbMG0gICAgG1swOzE7MzQ7OTRtXxtbMG0gICAbWzA7MzRtX19fX19fXxtbMG0gICAbWzA7MzRtX19fG1swOzM3bV9fX18bWzBtICAgG1swOzM3bV9fX19fG1swbSAgCiAbWzA7MTszNDs5NG1cG1swbSAbWzA7MTszNDs5NG1cG1swbSAbWzA7MTszNDs5NG0vG1swbSAbWzA7MTszNDs5NG0vG1swbSAbWzA7MzRtfBtbMG0gG1swOzM0bXwbWzBtICAbWzA7MzRtfBtbMG0gG1swOzM0bXwbWzBtIBtbMDszNG18X18bWzBtICAgG1swOzM3bV9ffBtbMG0gG1swOzM3bXxfXxtbMG0gICAbWzA7MzdtX198G1swbSAbWzA7MzdtfBtbMG0gIBtbMDsxOzMwOzkwbV9fG1swbSAbWzA7MTszMDs5MG1cG1swbSAKICAbWzA7MzRtXBtbMG0gG1swOzM0bVYbWzBtIBtbMDszNG0vG1swbSAgG1swOzM0bXwbWzBtIBtbMDszNG18X198G1swbSAbWzA7MzdtfBtbMG0gICAgG1swOzM3bXwbWzBtIBtbMDszN218G1swbSAgICAgICAbWzA7MzdtfBtbMG0gG1swOzE7MzA7OTBtfBtbMG0gICAgG1swOzE7MzA7OTBtfBtbMG0gG1swOzE7MzA7OTBtfF9fKRtbMG0gG1swOzE7MzA7OTBtfBtbMG0KICAgG1swOzM0bT4bWzBtIBtbMDszNG08G1swbSAgIBtbMDszN218G1swbSAgG1swOzM3bV9fG1swbSAgG1swOzM3bXwbWzBtICAgIBtbMDszN218G1swbSAbWzA7MzdtfBtbMG0gICAgICAgG1swOzE7MzA7OTBtfBtbMG0gG1swOzE7MzA7OTBtfBtbMG0gICAgG1swOzE7MzA7OTBtfBtbMG0gIBtbMDsxOzM0Ozk0bV9fXy8bWzBtIAogIBtbMDszN20vG1swbSAbWzA7MzdtLhtbMG0gG1swOzM3bVwbWzBtICAbWzA7MzdtfBtbMG0gG1swOzM3bXwbWzBtICAbWzA7MzdtfBtbMG0gG1swOzE7MzA7OTBtfBtbMG0gICAgG1swOzE7MzA7OTBtfBtbMG0gG1swOzE7MzA7OTBtfBtbMG0gICAgICAgG1swOzE7MzA7OTBtfBtbMG0gG1swOzE7MzQ7OTRtfBtbMG0gICAgG1swOzE7MzQ7OTRtfBtbMG0gG1swOzE7MzQ7OTRtfBtbMG0gICAgIAogG1swOzM3bS9fLxtbMG0gG1swOzM3bVxfXBtbMG0gG1swOzE7MzA7OTBtfF98G1swbSAgG1swOzE7MzA7OTBtfF98G1swbSAgICAbWzA7MTszMDs5MG18X3wbWzBtICAgICAgIBtbMDsxOzM0Ozk0bXxffBtbMG0gICAgG1swOzE7MzQ7OTRtfF8bWzA7MzRtfBtbMG0gICAgIAoKQ29weXJpZ2h0IChDKSBjcnVkZ3V5IHwgaHR0cHM6Ly9naXRodWIuY29tL2NydWRndXkveHJheS1vbmVrZXkKCg==" | base64 --decode
        ;;
    esac
}

# =============================================================================
# 函数名称: print_status
# 功能描述: 打印当前脚本配置的状态信息，包括 Xray 版本、配置标签和 WARP 状态。
# 参数: 无 (直接使用全局变量 SCRIPT_CONFIG_PATH 和 I18N_MAP)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function print_status() {
    # 一次性取出 Xray 版本 / 配置标签 / WARP 状态三个字段。
    # 原实现为 1 次 `jq '.'` + 3 次 `echo | jq -r`, 共 4 次 jq fork;
    # 现合并为单次 jq, 经 process substitution 逐行读入, 无额外子进程。
    # 配置文件缺失/非法时 jq 返回非 0 -> 三变量保持空串, 与原语义一致。
    local XRAY_VERSION='' CONFIG_TAG='' WARP_STATUS=''
    {
        IFS= read -r XRAY_VERSION || true
        IFS= read -r CONFIG_TAG || true
        IFS= read -r WARP_STATUS || true
    } < <(jq -r '[.xray.version, .xray.tag, .xray.warp] | .[]' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)

    # 从 i18n 数据中读取状态描述文本
    local not_installed
    not_installed=$(_i18n ".${CUR_FILE}.status.not_installed")
    local not_configured
    not_configured=$(_i18n ".${CUR_FILE}.status.not_configured")
    local enabled
    enabled=$(_i18n ".${CUR_FILE}.status.enabled")
    local disabled
    disabled=$(_i18n ".${CUR_FILE}.status.disabled")

    # 根据 Xray 版本是否存在，设置显示颜色和文本
    [[ ${XRAY_VERSION} ]] && XRAY_VERSION="${GREEN}${XRAY_VERSION}${NC}" || XRAY_VERSION="${RED}${not_installed}${NC}"
    # 根据配置标签是否存在，设置显示颜色和文本
    [[ ${CONFIG_TAG} ]] && CONFIG_TAG="${GREEN}${CONFIG_TAG}${NC}" || CONFIG_TAG="${RED}${not_configured}${NC}"
    # 根据 WARP 状态 (1 或 0)，设置显示颜色和文本
    # 修复: 原 `-eq 1` 在字段缺失/为 null 时会崩溃 —— jq -r 输出的是字面 "null",
    #       算术求值在 set -u 下报 "null: 未绑定的变量", 主菜单状态栏直接挂掉。
    #       导入备份 / 手工编辑配置 / 跨版本迁移都可能让 .xray.warp 缺失, 必须兜住。
    if is_enabled "${WARP_STATUS}"; then
        WARP_STATUS="${GREEN}${enabled}${NC}"
    else
        WARP_STATUS="${RED}${disabled}${NC}"
    fi

    # BBR 状态摘要: 只看"当前是否生效"。持久化文件是否落盘属于体检(v2 项)的
    # 内容, 主页面不展开 —— 否则每次渲染都得多读两个文件, 收益不成比例。
    local BBR_STATE=''
    if command -v sysctl >/dev/null 2>&1; then
        local _bbr_cc='' _bbr_qdisc=''
        _bbr_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
        _bbr_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
        if [[ "${_bbr_cc}" == 'bbr' && "${_bbr_qdisc}" == 'fq' ]]; then
            BBR_STATE="${GREEN}$(_i18n ".${CUR_FILE}.bbr.state_on")${NC}"
        else
            BBR_STATE="${RED}$(_i18n ".${CUR_FILE}.bbr.state_off")${NC}"
        fi
    else
        BBR_STATE="${RED}$(_i18n ".${CUR_FILE}.bbr.state_unknown")${NC}"
    fi

    _menu_rule
    echo -e "Xray       : ${XRAY_VERSION}"
    echo -e "CONFIG     : ${CONFIG_TAG}"
    echo -e "WARP Proxy : ${WARP_STATUS}"
    echo -e "BBR        : ${BBR_STATE}"
    _menu_rule
    echo
}

# =============================================================================
# 函数名称: get_choose
# 功能描述: 提示用户输入选择，并对输入进行基本验证和处理。
# 参数:
#   $1: 用于区分是否是语言选择菜单的标志 (例如 '--language')
# 返回值: 用户输入的选择数字 (通过 return 返回, 取值范围收敛到 0..255)
#         0 = 无效输入 / 未选择 (非法或超范围时额外向 stderr 打印提示)
# 注: 调用方 (main) 会把该值直接作为脚本退出码传出, 属于正常业务语义, 非"失败"。
# =============================================================================
function get_choose() {
    local i18n="${1:-}" # 获取参数
    local choose=''     # 用户输入 (显式初始化, 兼容 set -u; 原先裸 read 会污染全局)

    # 根据参数决定提示信息
    if [[ "$i18n" == '--language' ]]; then
        printf "请选择你的语言(默认: 中文): " >&2
    else
        # 从 i18n 数据中读取通用提示信息
        printf "${YELLOW}[%s] ${NC} %s: " "$(_i18n '.title.tip')" "$(_i18n ".${CUR_FILE}.choose")" >&2
    fi

    # 从标准输入读取用户输入 (Ctrl+D/EOF 时 read 返回非 0, 兜底为空串)
    read -r choose || choose=

    # 直接回车 (空输入) => 采用该菜单的默认项, 不再当作"输入无效"报警告。
    # 注: 默认项由调用方 case 的 `*)` 分支给出, 界面上以"(默认)"标注
    #     (如「1. 一键安装(默认)」); 此前空输入会被判为无效并打印
    #     "已按「退出/未选择」处理", 但调用方紧接着就走默认分支执行了安装 ——
    #     提示与实际行为相互矛盾(实测一键安装即触发)。这里统一返回 0 交由调用方决策。
    if [[ -z "${choose}" ]]; then
        return 0
    fi

    # 解析用户输入。
    # 注: 本函数的返回值就是"用户选择的菜单编号", 而进程退出码只有低 8 位有效 ——
    #     若直接 return 257 会被截断成 1, 用户误输入大数字将意外触发"一键安装"等危险操作。
    #     故这里统一收敛到 0..255: 非纯数字 / 超范围一律判为"无效输入"(返回 0, 等价于未选择)。
    local num=-1
    if [[ ${choose} =~ ^[0-9]+$ ]]; then
        # 去前导零 (例如 008 -> 8; 全 0 -> 空串), 纯 bash 实现, 不再 fork sed
        local stripped="${choose#"${choose%%[!0]*}"}"
        # 有效数字不超过 3 位 (<=999) 才做算术解析, 避免长数字串算术溢出
        if [[ ${#stripped} -le 3 ]]; then
            # 10# 前缀强制按十进制解析, 防止 "08"/"09" 被当成八进制报错
            num=$((10#${stripped:-0}))
        fi
    fi

    if ((num < 0 || num > 255)); then
        # 退出码已被"0 = 无效/未选择"占满, 无法再用退出码区分非法输入, 故用 stderr 明确提示
        if [[ "${i18n}" == '--language' ]]; then
            printf "${YELLOW}[Tip]${NC} 无效输入, 将使用默认语言 / Invalid input, falling back to default language\n" >&2
        else
            printf "${YELLOW}[%s]${NC} %s\n" "$(_i18n '.title.warn')" "$(_i18n ".${CUR_FILE}.choose_invalid")" >&2
        fi
        return 0
    fi
    # 显式输入字面 "0" 视作子菜单的 "0. 返回/取消" 项 (如「0. 返回主菜单」),
    # 与空回车(默认项)区分开: 空回车已在上方 return 0 (默认), 这里仅对"用户主动敲 0"生效。
    # 退出码 0 已被"默认/未选择"占用, 故把显式 0 映射到 255, 调用方据此识别为返回项。
    if [[ "${choose}" == "0" ]]; then
        return 255
    fi
    return "${num}"
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 根据传入的第一个参数决定要执行的操作。
#           2. 如果是语言选择，则显示语言菜单；否则加载 i18n 并显示相应菜单。
#           3. 显示指定的菜单或信息。
#           4. 除非是 banner 或 status，否则提示用户输入选择。
# 参数:
#   $@: 所有命令行参数
# 返回值: 无 (协调调用其他函数完成整个流程)
# =============================================================================
function main() {
    # 检查第一个参数是否为 --language，如果是则显示语言菜单
    if [[ "${1:-}" == "--language" ]]; then
        menu_language >&2
    else
        # 否则加载国际化数据
        load_i18n
    fi

    # 使用 case 语句根据第一个参数调用对应的菜单或信息显示函数
    case "${1:-}" in
    --index-full)
        # 主菜单"整屏"一次性完成: banner + 状态栏 + 主菜单 + 读取选择。
        # 背景: 主循环原本按 banner / status / index 各 fork 一次本脚本, 共 3 个子进程,
        #       每个子进程都要重新 load_i18n (解析 i18n JSON 建表), 实测约 325ms/往返,
        #       菜单切换有明显迟滞感。合并为单次 fork 后只需加载一次 i18n。
        #       渲染顺序与内容与原先三次调用**逐字一致** (UI 全部走 stderr)。
        print_banner >&2
        print_status >&2
        menu_index >&2
        # 已在此读取选择, 直接返回 —— 必须跳过下方的通用 get_choose, 否则会把
        # "读取一次选择"变成"读两次", 用户第一次输入被静默丢弃。
        local rc=0
        get_choose '--index' || rc=$?
        return "${rc}"
        ;;
    --index) menu_index >&2 ;;            # 显示主菜单
    --uninstall) menu_uninstall >&2 ;;    # 显示卸载管理子菜单
    --full) menu_full_installation >&2 ;; # 显示完整安装菜单
    --xray) menu_xray >&2 ;;              # 显示 Xray 版本菜单
    --config) menu_xray_config >&2 ;;     # 显示协议配置菜单
    --web) menu_web_config >&2 ;;         # 显示 Web 配置菜单
    --ca) menu_ca_vendor >&2 ;;
    --management) menu_config >&2 ;;      # 显示配置管理菜单
    --route) menu_route >&2 ;;            # 显示路由管理菜单
    --sni) menu_sni_config >&2 ;;         # 显示 SNI 配置菜单
    --custom-sites) menu_custom_sites >&2 ;;
    --backup) menu_backup >&2 ;;              # 显示配置备份与迁移菜单
    --bbr) menu_bbr >&2 ;;                    # 显示 BBR 与内核网络加速菜单
    --banner) print_banner >&2 ;;         # 显示 Banner
    --status) print_status >&2 ;;         # 显示状态信息
    esac

    # 如果不是显示 banner 或状态信息，则提示用户输入选择
    if [[ "${1:-}" != "--banner" && "${1:-}" != "--status" ]]; then
        get_choose "${1:-}"
    fi
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行。
# 注: main 的返回值就是"用户选择的菜单编号"(见 get_choose), 非 0 编号属于正常业务语义;
#     必须在此显式接住 (放在 || 右侧即进入"条件上下文", set -e 与 ERR trap 都不会误触发),
#     否则用户每选一个非 0 选项都会打印一条假的"[错误] 脚本意外失败"诊断。
OPTION=0
main "$@" || OPTION=$?
exit "${OPTION}"
