#!/usr/bin/env bash
# =============================================================================
# 测试名称: menu_install_note_test.sh
# 测试目标: 锁定"装载管理"子菜单里那条澄清文案 (note1) 的存在与可读性。
#
# 为什么需要它: "仅安装/更新到底会不会顺手动我的运行配置" 是高频疑问, 答案只存在于
#   代码阅读者脑子里 —— 菜单文案若不写, 用户只能靠猜或翻 README。这条 note1 就是把这个
#   结论前置到决策点的界面契约。它属于"纯文案", 没有任何行为测试会因它消失而变红,
#   因此必须单独加静态守卫, 否则后续重构 menu_xray 时被顺手删掉也不会有人发现。
#
# 断言范围: (1) menu_xray 渲染函数确实引用了 .xray_version.note1;
#   (2) zh/en 两侧该键都存在且非空, 并各含关键语义词 (二进制 / binary);
#   (3) 真跑 menu.sh --xray 渲染, 中英双语输出里都能看到该文案 (端到端, 不只看源码);
#   (4) NEG 负向校验 —— 在副本里删掉渲染行后, 守卫判据必须变红 (证明它真能捕获)。
#
# 依赖: jq (缺则按项目约定 rc=3 SKIP), bash。
# =============================================================================
set -u

SB=".workbuddy/tmp/menu_install_note_sb"
rm -rf "$SB"; mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: 缺少依赖 jq"
    exit 3
fi

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1" >&2; }
# 传值式断言 (刻意不依赖 $?: 紧跟 [[ ]] 的 $? 会被 shellcheck 判 SC2319)
assert_eq() { # $1=名称 $2=期望 $3=实际
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (期望 [$2] 实际 [$3])"; fi
}
assert_contains() { # $1=名称 $2=整串 $3=子串
    case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1 (未含 [$3])" ;;
    esac
}

ZH='i18n/zh.json'
EN='i18n/en.json'
MENU='core/menu.sh'

# ---------------------------------------------------------------------------
# T1: menu_xray 的渲染函数体必须引用 .xray_version.note1
# ---------------------------------------------------------------------------
echo "[T1] menu_xray 引用 note1"
BODY="$(awk '$0 == "function menu_xray() {" {f=1} f {print} f && /^}/ {exit}' "$MENU")"
if [[ -z "$BODY" ]]; then
    bad "无法从 ${MENU} 抽取 menu_xray 函数体"
else
    ok "抽取到 menu_xray 函数体 ($(printf '%s\n' "$BODY" | wc -l | tr -d '[:space:]') 行)"
fi
assert_contains "menu_xray 引用 .xray_version.note1" "$BODY" 'xray_version.note1'
# 与既有的三条 info 同处一个菜单块 (确认没被挪到别的菜单里)
assert_contains "menu_xray 仍保留 info3 (未误替换)" "$BODY" 'xray_version.info3'

# ---------------------------------------------------------------------------
# T2: zh/en 的 note1 均非空, 且各含关键语义词
# ---------------------------------------------------------------------------
echo "[T2] zh/en note1 键完整且语义到位"
ZH_NOTE="$(jq -r '.menu.xray_version.note1 // empty' "$ZH")"
EN_NOTE="$(jq -r '.menu.xray_version.note1 // empty' "$EN")"
assert_eq "zh note1 非空" "yes" "$([[ -n "$ZH_NOTE" ]] && echo yes || echo no)"
assert_eq "en note1 非空" "yes" "$([[ -n "$EN_NOTE" ]] && echo yes || echo no)"
assert_contains "zh note1 点明只换二进制" "$ZH_NOTE" '二进制'
assert_contains "en note1 点明 binary only" "$EN_NOTE" 'binary'
# 读起来要能自洽: 一侧说"保留/不改动", 一侧说 kept as is
assert_contains "zh note1 点明运行配置保留" "$ZH_NOTE" '保留'
assert_contains "en note1 点明 config kept" "$EN_NOTE" 'kept as is'

# ---------------------------------------------------------------------------
# T3: 端到端 —— 真渲染 menu.sh --xray, 两种语言都能看到该文案
# ---------------------------------------------------------------------------
echo "[T3] 真渲染 menu.sh --xray (zh/en) 均含 note1"
render_menu() { # $1=lang -> stdout+stderr
    # 注: 必须拆成两条 local —— 同一句 `local a=1 b=${a}` 在 set -u 下 b 取值时 a 仍视为
    #     未绑定 (bash 会先一次性登记名字), 会打出"未绑定的变量"并让整段渲染 rc=1。
    local lang="$1"
    local home="${SB}/home_${lang}"
    mkdir -p "${home}/.xray-script-personal-use-only"
    printf '{"version":"vT","language":"%s"}\n' "$lang" >"${home}/.xray-script-personal-use-only/config.json"
    # </dev/null 让 get_choose 读到 EOF 立即退出, 避免守卫在 CI 上挂住
    timeout 20 env HOME="${home}" bash core/menu.sh --xray </dev/null 2>&1
}
ZH_OUT="$(render_menu zh)"; zh_rc=$?
EN_OUT="$(render_menu en)"; en_rc=$?

assert_eq "zh 渲染退出码 = 0" "0" "${zh_rc}"
assert_eq "en 渲染退出码 = 0" "0" "${en_rc}"
# 只取文案的无色前缀部分, 避免受 ANSI 包裹影响
assert_contains "zh 渲染输出含 note1 正文" "$ZH_OUT" '仅替换 xray 二进制'
assert_contains "en 渲染输出含 note1 正文" "$EN_OUT" 'Replaces the xray binary only'
# 顺带守住"文案没把原有 3 条 info 挤掉"
assert_contains "zh 渲染仍含 info3" "$ZH_OUT" '自选版可能存在配置不兼容问题'
assert_contains "en 渲染仍含 info3" "$EN_OUT" 'Custom versions may have config compatibility issues'

# ---------------------------------------------------------------------------
# T4: NEG 负向校验 —— 副本里删掉 note1 渲染行, 守卫判据必须变红
#   判据锚在"渲染函数里是否出现 note1"与"渲染输出里是否出现 note1 正文"这两条上,
#   所以只要真能改坏, T1/T3 的同类判据必然失败。
# ---------------------------------------------------------------------------
echo "[T4] NEG: 副本删掉渲染行后判据必须变红"
NEG="${SB}/neg"
mkdir -p "${NEG}/core" "${NEG}/i18n"
cp core/menu.sh core/_common.sh "${NEG}/core/"
cp i18n/zh.json i18n/en.json "${NEG}/i18n/"
# 标注: 只删渲染那一行, 保留 i18n 键 (模拟"键还在但界面不再展示"的最隐蔽失效形态)
sed -i '/xray_version\.note1/d' "${NEG}/core/menu.sh"

NEG_BODY="$(awk '$0 == "function menu_xray() {" {f=1} f {print} f && /^}/ {exit}' "${NEG}/core/menu.sh")"
if printf '%s\n' "$NEG_BODY" | grep -qF 'xray_version.note1'; then
    bad "NEG 未生效: 副本仍引用 note1 (T1 判据无法捕获删除)"
else
    ok "NEG 生效: 副本已不引用 note1 (T1 判据会红)"
fi
# 键还在 -> 证明 T2 的单点守不住这种失效, 必须靠 T1/T3
assert_eq "NEG: i18n 键仍在 (故 T2 守不住, 需 T1/T3)" "yes" \
    "$([[ -n "$(jq -r '.menu.xray_version.note1 // empty' "${NEG}/i18n/zh.json")" ]] && echo yes || echo no)"

NEG_HOME="${SB}/home_neg"
mkdir -p "${NEG_HOME}/.xray-script-personal-use-only"
printf '{"version":"vT","language":"zh"}\n' >"${NEG_HOME}/.xray-script-personal-use-only/config.json"
NEG_OUT="$(timeout 20 env HOME="${NEG_HOME}" bash "${NEG}/core/menu.sh" --xray </dev/null 2>&1)"
if printf '%s\n' "$NEG_OUT" | grep -qF '仅替换 xray 二进制'; then
    bad "NEG 未生效: 副本渲染输出仍含 note1 正文 (T3 判据无法捕获删除)"
else
    ok "NEG 生效: 副本渲染输出已无 note1 正文 (T3 判据会红)"
fi
# 副本菜单本身仍可用 (证明"变红"确实源于缺失文案, 而非整体崩掉造成的假红)
if printf '%s\n' "$NEG_OUT" | grep -qF '自选版可能存在配置不兼容问题'; then
    ok "NEG 副本菜单其余部分正常渲染 (红点是真的缺文案)"
else
    bad "NEG 副本菜单整体渲染异常, 变红不可信"
fi

echo "---"
echo "==== menu_install_note_test: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]]
