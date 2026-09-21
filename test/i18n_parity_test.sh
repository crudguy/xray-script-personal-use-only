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

SB="test/.tmp/i18n_parity_sb"
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

echo "==== i18n_parity_test: PASS=$pass FAIL=$fail ===="
rm -rf "$SB"
[[ $fail -eq 0 ]]
