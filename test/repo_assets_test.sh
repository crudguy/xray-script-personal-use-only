#!/usr/bin/env bash
# =============================================================================
# 测试名称: repo_assets_test.sh
# 测试目标: 守住"仓库里必须真的存在那些被源码静态引用的资产"。
#
# 背景 (为什么需要这个用例):
#   源码里有大量"从仓库模板 cp/读一份出来用"的路径。这类引用一旦指向一个不存在
#   的文件, 问题不会在启动时报错, 而是等到用户点进那个菜单才炸 —— 且往往是
#   "破坏性路径": 例如变更域名的原顺序是「先删旧站点配置 -> 再 cp 模板」, 模板缺失
#   时旧配置已经删掉了, 用户拿到"站点消失"的现场。2026-09-26 的生产就绪度审计正是
#   靠人工翻找才发现 config/nginx/conf/sites-available/ 下三个站点模板**从未入库** ——
#   而 test/http3_test.sh 当时自己造了同名的夹具, 于是静态守卫一直是绿的。
#   这个用例把"引用 -> 资产"的关系变成可自动校验的断言, 不再依赖人工翻找。
#
# 锁定:
#   A  清单内资产逐个存在 (文件 / 目录);
#   B  源码静态引用双向核对: 正则从 core/ tool/ install.sh 里抽出所有
#      ${CONFIG_DIR|SERVICE_DIR|TOOL_DIR|I18N_DIR|SCRIPT_XRAY_DIR|CONFIG_XRAY_DIR|
#        PROJECT_ROOT}/… 形式的引用, 归一到仓库相对路径, 要求每一条都在清单里登记
#      —— 新增一处静态引用却忘了登记资产时会变红 (清单不会腐烂);
#   C  动态引用 (含 $ 或 *) 只允许落在"目录"上, 且该目录必须存在;
#   D  已知缺失 (PEND) 显式列名 + 必须写明原因: 缺失本身不判失败, 但会以 PEND 高亮
#      统计; 置 XRAY_ASSET_GUARD_STRICT=1 时 PEND 计入失败 (补好之后给 CI 用);
#   E  NEG: 对着"故意少一个文件"的假仓库跑同一套检查, 必须报出且只报出那一个缺失
#      —— 证明 A 段不是恒绿。
#
# 运行: bash test/repo_assets_test.sh
# =============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

PASS=0; FAIL=0; PEND=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
pend() { PEND=$((PEND+1)); printf '  PEND %s\n' "$1"; }
ck()   { # $1=名 $2=实测 $3=期望
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi
}

# ---------------------------------------------------------------------------
# 清单
# ---------------------------------------------------------------------------
# MANIFEST: 仓库必须存在的资产 (文件或目录), 每行 "路径<TAB>引用出处".
#           "引用出处"只作可读性用途, 但留空会被 B 段判红 (防止有人添加来路不明的条目)。
MANIFEST="$(
    cat <<'EOF'
config	${PROJECT_ROOT}/config (install.sh)
config.json	install.sh:678/739/839 版本号来源
config/xray	config/xray/${CONFIG_TAG}.json (handler.sh:1709)
config/logrotate/xray-script-personal-use-only.conf	_common.sh:787 logrotate 模板
config/nginx/conf	config/nginx/conf/* 整树同步 (handler.sh:4989)
config/nginx/conf/conf.d	ensure_nginx_support_files (handler.sh:890)
config/nginx/conf/nginxconfig.io	ensure_nginx_support_files (handler.sh:892)
config/nginx/conf/nginx.conf	nginx.conf 主配置模板
config/nginx/conf/nginxconfig.txt	nginx 配置片段说明
config/nginx/conf/modules-enabled/stream.conf	stream 模块装载模板
config/nginx/nginx.service	systemd 单元模板
core	${PROJECT_ROOT}/core (install.sh)
i18n	${I18N_DIR}/${lang}.json (_common.sh:349)
i18n/zh.json	简体中文文案
i18n/en.json	英文文案
install.sh	${PROJECT_ROOT}/install.sh 自更新
service	${PROJECT_ROOT}/service (install.sh)
service/nginx.sh	${SERVICE_DIR}/nginx.sh
service/ssl.sh	${SERVICE_DIR}/ssl.sh
tool	${PROJECT_ROOT}/tool (install.sh)
tool/backup.sh	${TOOL_DIR}/backup.sh (handler.sh:65)
tool/geodata.sh	${TOOL_DIR}/geodata.sh (handler.sh:64)
tool/traffic.sh	${TOOL_DIR}/traffic.sh (handler.sh:63)
config/xray/Fallback.json	Fallback 协议模板
config/xray/mKCP.json	mKCP 协议模板
config/xray/SNI.json	SNI 协议模板
config/xray/Trojan.json	Trojan 协议模板
config/xray/Vision.json	Vision 协议模板
config/xray/XHTTP.json	XHTTP 协议模板
EOF
)"

# TOLERATED: 允许缺失 —— 每条都必须写明**原因**, 原因留空视为 FAIL。
# 当前为空: 原先唯一登记的 config/nginx/conf/web 已伴随源码里那条失效的
# sync_missing_nginx_support_dir 调用一起删除 (2026-09-26), 不再需要容忍项。
TOLERATED="$(
    cat <<'EOF'
EOF
)"

# PENDING: 已知缺失且**必须补**的资产 (P0)。留空原因同样判 FAIL。
# 2026-09-26 生产就绪度审计发现: 三个站点模板从未入库, 于是"自定义站点"与"变更域名"
# 两个已在 README 宣称的功能必然失败 (后者还是破坏性路径)。
# 契约 (由 test/http3_test.sh T1/T2/T3 固化 + 两处渲染函数的占位符替换固化):
#   - 三者都有 `listen 443 quic` / `listen [::]:443 quic` / `Alt-Svc ... always` /
#     `server_name` / `ssl_certificate`;
#   - `quic reuseport` 只允许出现在主域名模板 (nginx 限制: 同一 listen 只许一次);
#   - domain/cdn 用占位符 `example.com` 与 `/yourpath`;
#   - custom-site 用 `example.com` / `unix:/dev/shm/nginx/custom_site.sock` / `PROXY_TARGET`。
PENDING="$(
    cat <<'EOF'
config/nginx/conf/sites-available	P0: 目录本身不存在, 上面三个模板无处安放
config/nginx/conf/sites-available/domain.example.com.conf	P0: _change_domain_render (handler.sh:4860) 直接 cp 它; 缺失时"变更域名"必然失败
config/nginx/conf/sites-available/cdn.example.com.conf	P0: 同上 (target_domain=cdn, 套 CDN 场景)
config/nginx/conf/sites-available/custom-site.example.com.conf	P0: render_custom_site_config (handler.sh:1000) 直接 cp 它; 缺失时"自定义站点"必然失败
EOF
)"

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
# 把清单 (路径<TAB>原因) 拆成两张表: 路径列表 / 路径->原因
manifest_paths() { printf '%s\n' "$MANIFEST" | awk -F'\t' 'NF && $1 != "" {print $1}'; }
reason_of() { # $1=路径 $2=清单全文
    printf '%s\n' "$2" | awk -F'\t' -v p="$1" '$1 == p {print $2}'
}

# 对给定仓库根跑一遍"资产是否齐备", 输出缺失的路径 (每行一个, 带 'file:' 或 'dir:' 前缀)。
# 刻意做成"可换根"的纯函数: NEG 段拿一个故意少文件的假仓库喂进来, 验证它不是恒绿。
missing_in() { # $1=仓库根 $2=允许缺失的路径(换行分隔)
    local root="$1" tolerated="$2" p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        printf '%s\n' "${tolerated}" | grep -Fxq "$p" && continue
        [[ -e "${root}/${p}" ]] || printf 'file:%s\n' "$p"
    done < <(manifest_paths)
}

# 从源码抽静态资产引用 -> 归一化 (两张表: 精确路径 / 目录)。
# 只抽非注释行; 变量前缀映射到仓库根; 含 $ 或 * 的段落按"动态"处理, 退化为它的静态前缀目录。
collect_refs() {
    grep -hnE '\$\{(CONFIG_DIR|SERVICE_DIR|TOOL_DIR|I18N_DIR|SCRIPT_XRAY_DIR|CONFIG_XRAY_DIR|PROJECT_ROOT)\}/' \
        core/*.sh tool/*.sh install.sh 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -oE '\$\{(CONFIG_DIR|SERVICE_DIR|TOOL_DIR|I18N_DIR|SCRIPT_XRAY_DIR|CONFIG_XRAY_DIR|PROJECT_ROOT)\}/[^"'"'"'[:space:]{}()|;&]*' \
    | sort -u
}

ref_to_path() { # $1=引用 -> 输出 "kind<TAB>仓库相对路径"
    local ref="$1" var rel base full kind
    var="$(printf '%s' "$ref" | sed -E 's/^\$\{([A-Z_]+)\}\/.*/\1/')"
    rel="$(printf '%s' "$ref" | sed -E 's/^\$\{[A-Z_]+\}\///')"
    case "${var}" in
        CONFIG_DIR)       base='config' ;;
        SERVICE_DIR)      base='service' ;;
        TOOL_DIR)         base='tool' ;;
        I18N_DIR)         base='i18n' ;;
        SCRIPT_XRAY_DIR)  base='config/xray' ;;
        CONFIG_XRAY_DIR)  base='config/xray' ;;
        PROJECT_ROOT)     base='' ;;
        *)                base='' ;;
    esac
    kind='file'
    case "${rel}" in
        *'$'*|*'*'*)
            # 动态段: 只保留静态前缀目录, 且降级为"目录必须存在"
            kind='dir'
            rel="${rel%%\$*}"
            rel="${rel%%\**}"
            rel="${rel%/}"
            ;;
    esac
    if [[ -z "${rel}" ]]; then
        full="${base}"
    elif [[ -z "${base}" ]]; then
        full="${rel}"
    else
        full="${base}/${rel}"
    fi
    printf '%s\t%s\n' "${kind}" "${full}"
}

# ---------------------------------------------------------------------------
# A  清单内资产逐个存在
# ---------------------------------------------------------------------------
echo "== A  清单内资产逐个存在 =="
TOLERATED_PATHS="$(printf '%s\n' "$TOLERATED" | awk -F'\t' 'NF && $1 != "" {print $1}')"
PENDING_PATHS="$(printf '%s\n' "$PENDING" | awk -F'\t' 'NF && $1 != "" {print $1}')"

A_MISS="$(missing_in "$ROOT" "$(printf '%s\n%s\n' "${TOLERATED_PATHS}" "${PENDING_PATHS}")")"
ck "A1 清单内资产全部存在 (缺: $(printf '%s' "${A_MISS}" | grep -c . || true) 项)" \
    "$(printf '%s' "${A_MISS}" | grep -c . || true)" "0"
if [[ -n "${A_MISS}" ]]; then
    printf '%s\n' "${A_MISS}" | sed 's/^/       -> /'
fi

# A2 清单每条都必须写明引用出处 (来路不明的条目不允许)
ck "A2 清单每条都写了引用出处" \
    "$(printf '%s\n' "$MANIFEST" | awk -F'\t' 'NF && $1 != "" && $2 == "" {print $1}' | grep -c . || true)" "0"
# A3 允许缺失/PEND 每条都必须写明原因
ck "A3 TOLERATED 每条都写了原因" \
    "$(printf '%s\n' "$TOLERATED" | awk -F'\t' 'NF && $1 != "" && $2 == "" {print $1}' | grep -c . || true)" "0"
ck "A4 PENDING 每条都写了原因" \
    "$(printf '%s\n' "$PENDING" | awk -F'\t' 'NF && $1 != "" && $2 == "" {print $1}' | grep -c . || true)" "0"

# ---------------------------------------------------------------------------
# B  源码静态引用双向核对
# ---------------------------------------------------------------------------
echo "== B  源码静态引用 -> 清单登记 =="
REGISTERED="$(printf '%s\n%s\n%s\n' "$(manifest_paths)" "${TOLERATED_PATHS}" "${PENDING_PATHS}" | awk 'NF' | sort -u)"
UNREGISTERED=0
UNREG_LIST=''
while IFS=$'\t' read -r kind path; do
    [[ -n "${path}" ]] || continue
    if ! printf '%s\n' "${REGISTERED}" | grep -Fxq "${path}"; then
        UNREGISTERED=$((UNREGISTERED+1))
        UNREG_LIST+="       -> ${kind} ${path}"$'\n'
    fi
done < <(collect_refs | while IFS= read -r r; do ref_to_path "$r"; done)

ck "B1 源码里的静态资产引用都已在清单登记" "${UNREGISTERED}" "0"
if [[ -n "${UNREG_LIST}" ]]; then printf '%s' "${UNREG_LIST}"; fi
# B2 反向自检: 抽取器本身必须真的抽到东西, 否则 B1 会因"空集合"而恒绿
ck "B2 NEG: 抽取器至少抽到 10 条引用 (防抽取正则失效导致恒绿)" \
    "$([[ "$(collect_refs | grep -c .)" -ge 10 ]] && echo yes)" "yes"

# ---------------------------------------------------------------------------
# C  动态引用的静态前缀目录必须存在
# ---------------------------------------------------------------------------
echo "== C  动态引用只能落在存在的目录上 =="
DYN_BAD=0
DYN_LIST=''
while IFS=$'\t' read -r kind path; do
    [[ "${kind}" == 'dir' ]] || continue
    [[ -n "${path}" ]] || continue
    printf '%s\n' "${TOLERATED_PATHS}" | grep -Fxq "${path}" && continue
    if printf '%s\n' "${PENDING_PATHS}" | grep -Fxq "${path}"; then continue; fi
    if [[ ! -d "${ROOT}/${path}" ]]; then
        DYN_BAD=$((DYN_BAD+1))
        DYN_LIST+="       -> ${path}"$'\n'
    fi
done < <(collect_refs | while IFS= read -r r; do ref_to_path "$r"; done)
ck "C1 动态引用的前缀目录都存在" "${DYN_BAD}" "0"
if [[ -n "${DYN_LIST}" ]]; then printf '%s' "${DYN_LIST}"; fi

# ---------------------------------------------------------------------------
# D  已知缺失 (PEND): 显式高亮, 可选严格模式
# ---------------------------------------------------------------------------
echo "== D  已知缺失 (PEND) =="
while IFS=$'\t' read -r p why; do
    [[ -n "${p}" ]] || continue
    if [[ -e "${ROOT}/${p}" ]]; then
        # 资产已经补上了, 却还挂在 PENDING 里 -> 清单该更新了 (提醒而非失败: 补资产的人
        # 未必就是维护清单的人, 不该让他的提交变红)
        pend "已补齐, 请从 PENDING 清单移走: ${p}"
    else
        pend "缺失: ${p} —— ${why}"
    fi
done <<< "$PENDING"
if [[ "${XRAY_ASSET_GUARD_STRICT:-0}" == '1' ]]; then
    ck "D1 严格模式: PEND 必须为 0" "${PEND}" "0"
else
    printf '  (置 XRAY_ASSET_GUARD_STRICT=1 可让 PEND 计入失败; 当前 PEND=%d)\n' "${PEND}"
fi

# ---------------------------------------------------------------------------
# E  NEG: 换一个"故意少一个文件"的假仓库, 检查器必须报出且只报出那一个
# ---------------------------------------------------------------------------
echo "== E  NEG: 检查器不是恒绿 =="
SB=".workbuddy/tmp/repo_assets_test.$$"
trap 'rm -rf "'"${SB}"'"' EXIT
FAKE="${SB}/fake-root"
mkdir -p "${FAKE}"
while IFS= read -r p; do
    [[ -n "${p}" ]] || continue
    [[ "${p}" == 'i18n/en.json' ]] && continue      # 故意漏掉这一个
    if [[ "${p}" == *.* ]]; then
        mkdir -p "${FAKE}/$(dirname "${p}")" && : >"${FAKE}/${p}"
    else
        mkdir -p "${FAKE}/${p}"
    fi
done < <(manifest_paths)
E_MISS="$(missing_in "${FAKE}" "$(printf '%s\n%s\n' "${TOLERATED_PATHS}" "${PENDING_PATHS}")")"
ck "E1 NEG: 漏掉 i18n/en.json 时恰好报出它" \
    "$(printf '%s' "${E_MISS}" | tr '\n' ' ' | sed 's/[[:space:]]*$//')" "file:i18n/en.json"

echo
printf 'PASS=%d FAIL=%d PEND=%d\n' "${PASS}" "${FAIL}" "${PEND}"
[[ "${FAIL}" -eq 0 ]] || exit 1
exit 0
