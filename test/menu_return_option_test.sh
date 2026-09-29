#!/usr/bin/env bash
# =============================================================================
# 菜单返回项一致性回归测试。
#
# 锁定: 每个"可导航"子菜单都必须
#   1. 在渲染函数里显示一行红色 "0. <返回文案>" (让用户看得见怎么退出);
#   2. 在 zh/en 两侧 i18n (menu.<块>.option0) 里都有对应键 (非空);
#   3. (P0) 原先把 `*` 当成"默认动作"的菜单 (xray 协议/版本/CA 厂商),
#      其 case 必须显式处理 255 (get_choose 把字面 0 映射为 255) 并返回,
#      不能让"按 0"触发某个默认安装/切换。
#
# 背景: 之前管理配置/路由/SNI/自定义站点等子菜单完全不显示返回项,
#       xray_config/xray 版本/CA 厂商更是把 `*` 当默认动作 —— 按 0 反而装了/切了。
# 运行: bash test/menu_return_option_test.sh
# =============================================================================
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

PASS=0; FAIL=0
ok() { if [[ $1 -eq 0 ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $2"; fi; }

# 可导航子菜单渲染函数 -> i18n 块名 (块在 menu.<块> 下, 见 _common.sh 的 CUR_FILE=文件名)
# (menu_web_config 是自动直通菜单, 不消费选择, 故意不列入)
declare -A MENUS=(
  [menu_config]=config_management
  [menu_route]=route_management
  [menu_sni_config]=sni_config
  [menu_custom_sites]=custom_sites
  [menu_xray_config]=protocol_config
  [menu_ca_vendor]=ca_vendor
  [menu_xray]=xray_version
)

# 取 menu_* 函数体
menu_block() {
  awk -v fn="$1" '$0 == "function " fn "() {" {f=1} f {print} f && /^}/ {exit}' core/menu.sh
}
# 取 processes_* 函数体
proc_block() {
  awk -v fn="$1" '$0 == "function " fn "() {" {f=1} f {print} f && /^}/ {exit}' core/main.sh
}

# jq 可用性 (缺则 SKIP, 与 i18n_parity_test 约定一致)
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: 缺少依赖 jq"
  exit 3
fi

# ---------------------------------------------------------------------------
# T1: 每个可导航子菜单都渲染红色 "0. 返回" 行, 且 zh/en 两侧 i18n 含非空 option0
# ---------------------------------------------------------------------------
echo "[T1] 子菜单均显示返回项且 i18n 双语键齐全"
for fn in "${!MENUS[@]}"; do
  blk="${MENUS[$fn]}"
  body="$(menu_block "$fn")"

  # 1) 渲染红色 0. 返回行
  if printf '%s\n' "$body" | grep -qE '\$\{RED\}0\.\$\{NC\}'; then
    ok 0 "$fn: 渲染了 0. 返回行"
  else
    ok 1 "$fn: 缺少 0. 返回行"
  fi

  # 2) zh/en 两侧都有非空 option0 (块在 menu.<块> 下)
  zh="$(jq -r --arg b "$blk" '.menu[$b].option0 // empty' i18n/zh.json)"
  en="$(jq -r --arg b "$blk" '.menu[$b].option0 // empty' i18n/en.json)"
  if [[ -n "$zh" && -n "$en" ]]; then
    ok 0 "$blk: zh/en 均有非空 option0"
  else
    ok 1 "$blk: zh='$zh' en='$en' (option0 缺失或空)"
  fi
done

# ---------------------------------------------------------------------------
# T2: P0 菜单 —— case 必须显式处理 255 并返回, 否则"按 0"会触发默认动作
# ---------------------------------------------------------------------------
echo "[T2] P0 菜单按 0 安全返回 (case 显式处理 255)"
for pfn in processes_xray_config processes_xray processes_ca_vendor; do
  pbody="$(proc_block "$pfn")"
  if printf '%s\n' "$pbody" | grep -qE '255\)[[:space:]]*return'; then
    ok 0 "$pfn: case 显式处理 255 并返回 (按 0 安全退出)"
  else
    ok 1 "$pfn: case 未显式处理 255, 按 0 可能触发默认动作"
  fi
done

echo
echo "==== menu_return_option_test: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]]
