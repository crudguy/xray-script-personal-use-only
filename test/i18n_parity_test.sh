#!/usr/bin/env bash
# =============================================================================
# 测试名称: i18n_parity_test.sh
# 测试目标: 锁定 zh / en 双语的叶子键集合必须完全一致。
#
# 为什么需要它: 双语最容易出的不是"翻译错了", 而是"只在某一侧加了键" —— 这种漂移
#   在运行时不会报错, 只会让用户撞上空白或原文键名。此前 zh/en 各 699 个键、双向差集
#   为空的结论, 是靠一次性手工脚本比对得来的, 跑完就丢, 无法防住未来新增文案。
#   unknown_option_test.sh 的 T5/T7 只能守单点的 unknown_option, 防不住整侧缺失。
#
# 方法: 用 jq 把 JSON 展平成"叶子键路径"列表 (点号连接), sort -u 后用 comm 求双向差集。
#   注: 仓库里存在本身就带点号的扁平键名 (如 backup 段的 "err.archive_unsafe"), 展平后
#   会被当成路径分隔符; 但两侧用的是同一套展平规则, 差集判定不受影响。
#
# 依赖: jq, sort, comm (Linux CI 均自带)。缺 jq 时按本项目约定以 rc=3 SKIP。
#   Windows/MSYS 下 jq 不在 PATH 时, 用 XRAY_TEST_SHIM=<jq 所在目录> 指路。
# =============================================================================
set -u

SB=".workbuddy/tmp/i18n_parity_sb"
rm -rf "$SB"; mkdir -p "$SB"
# EXIT trap: 断言失败提前退出时也要收掉沙箱, 否则多次运行会不断累积残留目录
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

if [[ -n "${XRAY_TEST_SHIM:-}" && -d "${XRAY_TEST_SHIM}" ]]; then
    export PATH="${XRAY_TEST_SHIM}:${PATH}"
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: 缺少依赖 jq"
    exit 3
fi

ZH='i18n/zh.json'
EN='i18n/en.json'

pass=0; fail=0
ok() { if [[ $1 -eq 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }

# 展平: 输出全部叶子键的点号路径, 排序去重
flatten() { jq -r '[paths(scalars)] | map(join(".")) | .[]' "$1" | sort -u; }

if [[ ! -f "${ZH}" || ! -f "${EN}" ]]; then
    echo "[FAIL T0] 找不到语言文件: ${ZH} / ${EN}"
    echo "==== i18n_parity_test: PASS=0 FAIL=1 ===="
    exit 1
fi

flatten "${ZH}" > "$SB/zh.keys"
flatten "${EN}" > "$SB/en.keys"

n_zh="$(wc -l < "$SB/zh.keys" | tr -d '[:space:]')"
n_en="$(wc -l < "$SB/en.keys" | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
# T1 双语叶子键集合完全一致 (任一方向都不允许有差集)
# ---------------------------------------------------------------------------
only_zh="$(comm -23 "$SB/zh.keys" "$SB/en.keys")"
only_en="$(comm -13 "$SB/zh.keys" "$SB/en.keys")"

if [[ -z "${only_zh}" && -z "${only_en}" ]]; then
    ok 0 && echo "[T1] zh/en 键集合一致 (${n_zh} 个键)"
else
    ok 1 && echo "[FAIL T1] zh/en 键集合不一致 (zh=${n_zh} en=${n_en})"
    if [[ -n "${only_zh}" ]]; then
        echo "      仅中文有 (英文漏译):"
        printf '%s\n' "${only_zh}" | sed 's/^/        - /' | head -n 20
    fi
    if [[ -n "${only_en}" ]]; then
        echo "      仅英文有 (中文漏译):"
        printf '%s\n' "${only_en}" | sed 's/^/        - /' | head -n 20
    fi
fi

# ---------------------------------------------------------------------------
# T2 不允许空文案: 值为空串的键等同于缺失 (运行时会渲染成空白)
# ---------------------------------------------------------------------------
# 注: 这里必须是 `paths(scalars) as $p`(逐条路径绑定), 不能写成 `[paths(scalars)] as $p`
#     —— 后者绑的是"路径的数组", getpath($p) 匹配不到任何节点, T2 会恒绿失效。
empty_zh="$(jq -r 'paths(scalars) as $p | select(getpath($p) == "") | $p | join(".")' "${ZH}" 2>/dev/null || true)"
empty_en="$(jq -r 'paths(scalars) as $p | select(getpath($p) == "") | $p | join(".")' "${EN}" 2>/dev/null || true)"

if [[ -z "${empty_zh}" && -z "${empty_en}" ]]; then
    ok 0 && echo "[T2] zh/en 均无空文案键"
else
    ok 1 && echo "[FAIL T2] 存在空文案键"
    [[ -n "${empty_zh}" ]] && printf '%s\n' "${empty_zh}" | sed 's/^/        zh - /' | head -n 20
    [[ -n "${empty_en}" ]] && printf '%s\n' "${empty_en}" | sed 's/^/        en - /' | head -n 20
fi

# ---------------------------------------------------------------------------
# T3 键的数量规模守卫: 防止某次改动把整侧语言文件清空却仍"一致" (两边都空也算一致)
# ---------------------------------------------------------------------------
if [[ "${n_zh}" -ge 500 && "${n_en}" -ge 500 ]]; then
    ok 0 && echo "[T3] 键规模正常 (${n_zh} / ${n_en}, 阈值 500)"
else
    ok 1 && echo "[FAIL T3] 键规模异常偏小 (zh=${n_zh} en=${n_en}), 疑似语言文件被清空或截断"
fi

# ---------------------------------------------------------------------------
# T4/T5 代码侧引用核对 (T1-T3 只比对两份语言文件之间, 看不见"代码引用的键"这一侧)
# ---------------------------------------------------------------------------
# 为什么需要: _i18n 查表落空时**恒返回 0 且打印空串** —— 不报错、不留日志。键名写错
#   或漏加的结果, 只是用户看到一行没有内容的提示/警告。2026-09-26 复审把全部引用
#   与 zh.keys 求差, 才发现 service/nginx.sh 引用的
#   nginx.update.backup_skipped 两语言都缺 (Nginx 升级时旧二进制不存在的那条
#   降级告警渲染成空白)。这类漂移 T1/T2/T3 全看不见。
#
# 口径 (抽取器与判定见下):
#   - 只扫产品代码 core/ service/ tool/, **不扫 test/** —— 测试里有刻意取不存在的
#     键来验证兜底行为的用例, 纳入会产生假红;
#   - 键里的 ${CUR_FILE} 按该文件 basename(去扩展名、去前导下划线) 展开, 与
#     _common.sh 的 readonly CUR_FILE 同口径;
#   - 含 ${...} 的键是动态后缀, 只取静态前缀并要求前缀下至少有一个真键;
#   - 形如 .$key 的纯变量键静态不可判, 跳过 (read.sh 的 read.* 走这条, 由
#     param_map 的 field 驱动);
#   - 跳过注释行。
SRC_FILES=()
for f in core/*.sh service/*.sh tool/*.sh; do [[ -f "$f" ]] && SRC_FILES+=("$f"); done

refs="$SB/refs"
: > "$refs"
for f in "${SRC_FILES[@]}"; do
    cur="$(basename "$f")"; cur="${cur%%.*}"; cur="${cur#_}"
    grep -v '^[[:space:]]*#' "$f" \
        | grep -oE "_i18n(_sub|_raw|_array)?[[:space:]]+[\"'][.][^\"']*[\"']" \
        | sed -E "s/^_i18n(_sub|_raw|_array)?[[:space:]]+//; s/^[\"']//; s/[\"']\$//" \
        | while IFS= read -r raw; do
            [[ -n "$raw" ]] || continue
            raw="${raw#.}"
            raw="${raw//'${CUR_FILE}'/$cur}"
            if [[ "$raw" == *'${'* ]]; then
                pre="${raw%%\$\{*}"; pre="${pre%.}"
                [[ -n "$pre" ]] && printf 'P\t%s\n' "$pre" >> "$refs"
            elif [[ "$raw" == *'$'* ]]; then
                : # 纯变量键, 静态不可判
            else
                printf 'F\t%s\n' "$raw" >> "$refs"
            fi
        done
done

# 输出 refs 里"在语言文件中找不到"的完整键; 供 T4 与 T4c 负向自检共用
check_refs() {
    local rf="$1" k=''
    while IFS= read -r k; do
        [[ -n "$k" ]] || continue
        grep -Fxq -- "$k" "$SB/zh.keys" || printf '%s\n' "$k"
    done < <(awk -F'\t' '$1=="F"{print $2}' "$rf" | sort -u)
}

n_full="$(awk -F'\t' '$1=="F"' "$refs" | sort -u | wc -l | tr -d '[:space:]')"
n_pref="$(awk -F'\t' '$1=="P"' "$refs" | sort -u | wc -l | tr -d '[:space:]')"

miss="$(check_refs "$refs")"
if [[ -z "${miss}" ]]; then
    ok 0 && echo "[T4] 代码引用的 ${n_full} 个键全部存在 (动态前缀式 ${n_pref} 个)"
else
    ok 1 && echo "[FAIL T4] 代码引用了语言文件中不存在的键 (运行期将渲染成空串):"
    printf '%s\n' "${miss}" | sed 's/^/        - /' | head -n 20
fi

# T4b 抽取器有效性自检: 正则写坏时集合为空 -> 缺检查恒绿, 必须先卡住
if [[ "${n_full}" -ge 500 ]]; then
    ok 0 && echo "[T4b] 抽取器有效性自检通过 (${n_full} >= 500)"
else
    ok 1 && echo "[FAIL T4b] 抽到的键数异常偏少 (${n_full}), 抽取正则可能已失效"
fi

# T4c 负向自检: 注入一个必然不存在的键, 检查器必须恰好报出它
printf 'F\tzzz.definitely.not.a.real.key\n' > "$SB/neg.refs"
neg="$(check_refs "$SB/neg.refs")"
if [[ "${neg}" == 'zzz.definitely.not.a.real.key' ]]; then
    ok 0 && echo "[T4c] 负向自检通过 (不存在的键被正确报出)"
else
    ok 1 && echo "[FAIL T4c] 负向自检失败 —— 检查器对不存在的键无反应, T4 可能是恒绿"
fi

# ---------------------------------------------------------------------------
# T5 _i18n_sub 的占位符名必须出现在该键的文案里
# ---------------------------------------------------------------------------
# 为什么需要: 占位符是"字符串字面量替换"而不是变量插值 —— 名子写错 (或文案侧漏写
#   ${x}) 不会报错, 只是把名子原样留在输出里。约定形态: _i18n_sub <key> <ph> <val> …,
#   其中 key 与 ph 一律用**单引号**(或 key 用双引号、ph 用单引号), val 一律用双引号。
#   故判定: 切到 _i18n_sub 之后, 第一个引号串是 key, 其余**单引号**串是占位符名,
#   双引号串一律是值 (形如 "${bad}") 必须排除 —— 二者字面形态相同, 只能靠引号区分。
#   (2026-09-26 初版正是把值当成了占位符名, 34 个调用报出 27 条假红。)
kv="$SB/zh.kv"
jq -r 'paths(scalars) as $p | [(($p | map(tostring) | join("."))), (getpath($p) | tostring)] | @tsv' \
    "${ZH}" > "$kv"

ph_bad=''
for f in "${SRC_FILES[@]}"; do
    cur="$(basename "$f")"; cur="${cur%%.*}"; cur="${cur#_}"
    while IFS= read -r line; do
        [[ "${line}" == *_i18n_sub* ]] || continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        after="${line#*_i18n_sub}"
        toks=()
        while IFS= read -r t; do [[ -n "$t" ]] && toks+=("$t"); done \
            < <(printf '%s' "${after}" | grep -oE "'[^']*'|\"[^\"]*\"" || true)
        [[ ${#toks[@]} -ge 2 ]] || continue
        key="${toks[0]}"; key="${key:1:${#key}-2}"
        [[ "${key}" == .* ]] || continue
        key="${key#.}"; key="${key//'${CUR_FILE}'/$cur}"
        [[ "${key}" == *'$'* ]] && continue
        text="$(awk -F'\t' -v k="${key}" '$1==k{print $2; exit}' "$kv")"
        # 键本身不存在由 T4 负责; 此处只检查"键存在时占位符是否落在文案里"
        [[ -n "${text}" ]] || continue
        for t in "${toks[@]:1}"; do
            [[ "${t}" == "'"* ]] || continue   # 双引号 = 值参数
            ph="${t:1:${#t}-2}"
            [[ -n "${ph}" ]] || continue
            [[ "${text}" == *"${ph}"* ]] || ph_bad+="${key} 缺 [${ph}]"$'\n'
        done
    done < "$f"
done

if [[ -z "${ph_bad}" ]]; then
    ok 0 && echo "[T5] _i18n_sub 占位符与文案一致"
else
    ok 1 && echo "[FAIL T5] 占位符名未出现在对应文案中 (会原样渲染在输出里):"
    printf '%s' "${ph_bad}" | sed 's/^/        - /' | head -n 20
fi

# ---------------------------------------------------------------------------
# T6 面向用户的输出不得硬编码中文
# ---------------------------------------------------------------------------
# 为什么需要: 走 print_* 却直接写中文字面量, 和键缺失一样**两边都不报错** —— CI 不会红,
#   只是 `--lang=en` 的用户看到一行中文。2026-09-26 复审发现 6 处 (service/nginx.sh 的
#   OpenSSL 目录名异常 / brotli ref 非法两条告警, tool/backup.sh 的 [restore-fail] 四连),
#   全部由"人工逐眼看"才发现。这条断言把"靠人记得检查"变成机器判据。
#
# 判据 (逐行):
#   ① 跳过整行注释、剥掉行尾注释 —— 注释写中文是合法的说明手段;
#   ② 只看**输出型**语句 (echo / printf / read -p / print_*);
#   ③ 剩下的中文必须命中下列豁免之一, 否则判 FAIL:
#      E1 本文件 `source ..._common.sh` 之前的行 —— i18n 尚未加载, 查表必然落空;
#      E2 trap 语句 —— 可能在 i18n 加载完成前就被触发;
#      E3 `_common.sh` 自身 —— 它就是 bootstrap, 不存在更早的 provider;
#      E4 白名单里显式登记的少量既有硬编码 (语言选择菜单 / install.sh 自包含的帮助)。
#      **注意 E4 是挂账不是"没有问题"**: 往里加一条必须同时给出理由。
#
# 中文检测为什么按字节: locale 判据不可靠 —— 本仓库 CI 上 LANG 是 zh_CN.UTF-8, 但
#   `grep '[一-龥]'` 会报 "Invalid collation character"。故统一在 **C locale 下按 UTF-8
#   字节**判定: CJK 基本区 U+4E00–U+9FFF 编码为 E4–E9 开头的三字节序列。这样做还有个
#   附带好处: 绿色对勾 (`✓`, U+2713 → E2 开头) 这类非汉字符号不会被误判成中文。
CJK_RE=$'[\xe4-\xe9][\x80-\xbf][\x80-\xbf]'

T6_FILES=()
for f in core/*.sh service/*.sh tool/*.sh install.sh; do [[ -f "$f" ]] && T6_FILES+=("$f"); done

# 白名单 「basename|子串」—— 子串需是稳定的字面片段, 不要写可能整段改写的话。
# 现有条目各自的理由:
#   menu.sh 三条 = **语言选择菜单本身**: 此时语言还没选出来, 查表无从下手, 且必须在
#                  屏幕上同时呈现"中文/English"两种字样才能让人选;
#   install.sh 七条 = 安装器**不 source _common.sh**、自带一份 I18N_DATA, 且 --help /
#                   GH_PROXY 校验发生在语言数据可用之前的参数解析早期。
wl="$SB/wl"
cat >"$wl" <<'WL_EOF'
menu.sh|${NC}中文
menu.sh|请选择你的语言
menu.sh|无效输入, 将使用默认语言
install.sh|用法: bash install.sh
install.sh|交互式安装 / 首次部署
install.sh|指定界面语言
install.sh|仅检查并安装依赖
install.sh|强制刷新到远端最新提交
install.sh|显示本帮助
install.sh|GH_PROXY 值非法
WL_EOF

# 扫描一个文件, 打印未命中任何豁免的硬编码中文输出行 "<file>:<lineno>: <内容>"
# 年度维护说明: 新增白名单走上面的 $wl; 绝不要放宽下面任何一条判据来"让它变绿"。
t6_scan() {
    local f="$1" line='' code='' base='' src_line='' lineno=0
    base="$(basename "$f")"
    src_line="$(grep -n 'source .*_common\.sh' "$f" 2>/dev/null | head -n 1 | cut -d: -f1)"
    [[ -n "${src_line}" ]] || src_line=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue          # 整行注释
        code="${line%%[[:space:]]#*}"                          # 剥行尾注释: "<空白>#" 起算
        printf '%s' "${code}" | LC_ALL=C grep -qE "${CJK_RE}" || continue
        printf '%s' "${code}" | grep -qE '\b(echo|printf|read)\b|print_(info|warn|error|pass|step|title)' || continue
        [[ "${base}" == '_common.sh' ]] && continue            # E3 bootstrap
        printf '%s' "${code}" | grep -qE '^[[:space:]]*trap' && continue    # E2 信号陷阱
        [[ "${src_line}" -gt 0 && "${lineno}" -lt "${src_line}" ]] && continue  # E1 i18n 未加载
        awk -F'|' -v b="${base}" -v c="${code}" \
            '$1==b && index(c,$2)>0 {found=1} END {exit !found}' "$wl" && continue  # E4 白名单
        printf '%s:%s: %s\n' "$f" "${lineno}" "$(printf '%s' "${code}" | sed 's/^[[:space:]]*//')"
    done <"$f"
}

t6_bad=''
for f in "${T6_FILES[@]}"; do
    t6_bad+="$(t6_scan "$f")"
done

if [[ -z "${t6_bad}" ]]; then
    ok 0 && echo "[T6] 面向用户的输出无未登记的硬编码中文 (扫描 ${#T6_FILES[@]} 个文件)"
else
    ok 1 && echo "[FAIL T6] 存在绕过 i18n 的硬编码中文输出 (--lang=en 时仍会显示中文):"
    printf '%s' "${t6_bad}" | sed 's/^/        - /' | head -n 20
    printf '        (共 %s 条; 确属必须硬编码的, 在 T6 白名单显式登记并写明理由)\n' \
        "$(printf '%s\n' "${t6_bad}" | grep -c '' | tr -d '[:space:]')"
fi

# T6b 抽取器有效性自检: 字节式中文正则万一失效, T6 会变成恒绿 —— 必须先自证能检出,
#   且能正确放行 `✓` 这类非汉字的 UTF-8 符号。
cjk_pos='' cjk_neg=''
printf '%s' '中文 abc' | LC_ALL=C grep -qE "${CJK_RE}" && cjk_pos=1
printf '%s' '✓ done' | LC_ALL=C grep -qE "${CJK_RE}" || cjk_neg=1
if [[ -n "${cjk_pos}" && -n "${cjk_neg}" ]]; then
    ok 0 && echo "[T6b] 字节式判据自检通过 (检出中文 且 不误判 ✓ 符号)"
else
    ok 1 && echo "[FAIL T6b] 中文检测判据失效 (正=${cjk_pos:-0} 负=${cjk_neg:-0}), T6 结果不可信"
fi

# T6c 负向自检: 在一行真实的输出语句里塞一句中文, 扫描器必须把它报出来
t6_neg_file="$SB/neg_t6.sh"
{
    echo '#!/usr/bin/env bash'
    echo 'function _common_loaded() { :; }'
    echo 'print_info "这是一句没有走 i18n 的中文提示"'
} >"${t6_neg_file}"
t6_neg="$(t6_scan "${t6_neg_file}")"
if printf '%s' "${t6_neg}" | grep -q '这是一句没有走 i18n 的中文提示'; then
    ok 0 && echo "[T6c] 负向自检通过 (注入的中文输出被正确报出)"
else
    ok 1 && echo "[FAIL T6c] 负向自检失败 —— 注入的中文输出未被报出, T6 可能是恒绿"
fi

echo "==== i18n_parity_test: PASS=$pass FAIL=$fail ===="
rm -rf "$SB"
[[ $fail -eq 0 ]]
