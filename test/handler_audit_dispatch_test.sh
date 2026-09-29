#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_audit_dispatch_test.sh
# 测试目标: dispatch 层审计留痕收口 (_audit_dispatch) 的行为回归与静态契约 ——
#           "改配置类写操作必须留痕、臂内已留痕/只读查询不重复记录、审计失败不阻断主流程"。
#
# 为什么需要本测试:
#   1) 该改动的价值全在**覆盖面**上: 各臂里散落的 _audit_log 只覆盖 49 臂中的一部分,
#      而 routing / xray-config / change-domain / warp / sniff-route-only 这些改配置
#      动作全为零留痕 —— "前天那台机器的分流规则是谁改的"事后无法回答。若 _audit_dispatch
#      的调用被误删或名单被写成"全排除", 表面无任何报错 (审计是静默的旁路), 只能靠测试锁住。
#   2) 调用点必须在 main 的 option **分派 case 之前**: 放到 case 之后, 那些直接
#      _error/exit 的失败路径就记不到 —— 而这正是审计最想看到的记录。位置是顺序属性,
#      静态断言比行为断言更能锁住它。
#   3) 排除名单是手工维护的, 最容易腐化: 写错一个字符 (--purgee) 会让那一项静默回到
#      "会被记录", 更糟的是名单里出现已更名的选项时无从察觉。故双向锁:
#        - 名单里的每一项都必须真的存在于 main 的 case 中 (防拼写错/防名单残留);
#        - 关键写操作一个都不许进名单 (防"图省事全排除", 那等于没做这个改动)。
#   4) 审计是旁路: 任何写入失败都不能让主流程失败 —— 否则 audit.log 所在盘写满会让
#      "卸载 Xray"这种救命操作直接卡死。故单独锁"不可写路径下仍返回 0"。
#
# 锁定不变量:
#   T1 抽取     —— _audit_dispatch / _audit_log / main 真实函数体可抽出
#   T2 调用点   —— main 内有 _audit_dispatch "${option}" "$*" 且位于分派 case 之前
#   T3 名单闭合 —— 排除名单每一项都存在于 main 的 case 中
#   T4 名单不越界 —— 关键写操作 option 均不在排除名单里
#   T5 写操作留痕 —— --routing 等产出审计记录 (动作名去 -- 前缀)
#   T6 detail   —— 其余参数拼成的细节随记录一起落盘
#   T7 不重复   —— 臂内已留痕 / 只读查询 一律不产出记录
#   T8 未知参数 —— 传错的参数也会留痕 (cron 里写错 --health 可被追查); 空 option 不记录
#   T9 恒 0     —— 审计落盘不可达时仍返回 0, 不阻断主流程
#   T10 静态守卫负向校验 —— 删调用点 / 名单写错 / 全排除替代实现 / 调用点后置, 四种改坏都要被抓到
#
# 实现: 从 core/handler.sh 抽真实函数体 eval 注入 (不另写实现, 避免漂移); 排除名单与
#   main 的 case 也从源码里解析出来比对 —— 测试里不写死名单, 否则名单一改测试就假绿。
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$REPO"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1 (期望 [$3] 实际 [$2])"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1 (未包含 [$3]，实际 [$2])"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1 (不应包含 [$3]，实际 [$2])"; fi; }
assert_count() { # $1=说明 $2=期望次数 $3=文本 $4=模式 (整行精确匹配)
    local n
    n="$(printf '%s\n' "$3" | grep -cxF -- "$4" || true)"
    assert_eq "$1" "${n}" "$2"
}

SB="$REPO/.workbuddy/tmp/handler_audit.$$"
rm -rf "$SB" 2>/dev/null || true
mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

extract_fn() { # $1=文件 $2=函数名
    awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' "$1"
}

HANDLER='core/handler.sh'
dispatch_fn="$(extract_fn "$HANDLER" _audit_dispatch)"
audit_fn="$(extract_fn "$HANDLER" _audit_log)"
main_fn="$(extract_fn "$HANDLER" main)"
[[ -n "$dispatch_fn" ]] || bad "T1a: 抽取 _audit_dispatch 失败"
[[ -n "$audit_fn" ]] || bad "T1b: 抽取 _audit_log 失败"
[[ -n "$main_fn" ]] || bad "T1c: 抽取 main 失败"
if [[ "$FAIL" -gt 0 ]]; then echo "==== handler_audit_dispatch_test: PASS=$PASS FAIL=$FAIL ===="; exit 1; fi

# ---------------------------------------------------------------------------
# 静态解析: 从源码里取"排除名单"与"main 分派 case 支持的 option"两个集合。
#   名单 = _audit_dispatch 内 case..esac 之间的 --xxx 字面量;
#   option = main 内 case..esac 之间以 `    --` 开头的 pattern (注释行以 `#` 开头, 天然排除)。
# 不写死名单/选项 —— 否则名单一改测试就假绿。
# ---------------------------------------------------------------------------
case_block() { # $1 = 函数体文本; 输出其 case..esac 之间的行
    printf '%s\n' "$1" | sed -n '/^    case "\${option}" in$/,/^    esac$/p'
}
opt_list() { # 从 case 块里取 option 字面量 (sort -u)
    grep -oE '\-\-[a-z][a-z-]*' | sort -u
}
skip_opts="$(case_block "${dispatch_fn}" | opt_list)"
main_opts="$(case_block "${main_fn}" | grep -E '^    --[a-z]' | grep -oE '^    --[a-z-]+' | sed 's/^    //' | sort -u)"
[[ -n "${skip_opts}" ]] || bad "T0a: 未解析出排除名单 (源码结构变了?)"
[[ -n "${main_opts}" ]] || bad "T0b: 未解析出 main 的 option 集合 (源码结构变了?)"

# 关键写操作 —— 这些必须留在"会被记录"的一侧。
#   不含 --install/--restart (臂内已自行留痕, 属允许排除项), 只列零留痕的改配置动作。
KEY_WRITE_OPTS=(--routing --xray-config --change-domain --change-port
    --warp --reset-warp --sniff-route-only --custom-sites
    --geodata-cron --nginx-cron --remove-certificate --script-config
    --version --nginx-update --web --ca-server)

# ---------------------------------------------------------------------------
# 静态契约检查 (可对任意副本运行, 供负向校验复用)。
#   返回 0 = 通过; 非 0 时把问题描述打到 stdout。
# ---------------------------------------------------------------------------
static_check() {
    local f="$1"
    local rc=0
    local d_fn m_fn call_line case_line s_opts m_opts o
    d_fn="$(extract_fn "$f" _audit_dispatch)"
    m_fn="$(extract_fn "$f" main)"
    # (1) 调用点存在
    call_line="$(grep -nF '_audit_dispatch "${option}"' "$f" | head -1 | cut -d: -f1 || true)"
    if [[ -z "${call_line}" ]]; then
        echo "缺少 _audit_dispatch 调用"
        rc=1
    fi
    # (2) 调用点在分派 case 之前 (main 那个 case 在文件更靠后处, 故取最后一个匹配)
    case_line="$(grep -nF 'case "${option}" in' "$f" | tail -1 | cut -d: -f1 || true)"
    if [[ -n "${call_line}" && -n "${case_line}" && "${call_line}" -ge "${case_line}" ]]; then
        echo "调用点(${call_line}) 未早于分派 case(${case_line})"
        rc=1
    fi
    # (3) 名单里的每一项都必须真在 main 的 case 中 (名单项均为无空格 token, 可安全分词)
    s_opts="$(case_block "${d_fn}" | opt_list)"
    m_opts="$(case_block "${m_fn}" | grep -E '^    --[a-z]' | grep -oE '^    --[a-z-]+' | sed 's/^    //' | sort -u)"
    # shellcheck disable=SC2086  # 名单项均无空格, 分词遍历是刻意的
    for o in ${s_opts}; do
        if [[ "$(printf '%s\n' "${m_opts}" | grep -cxF -- "${o}" || true)" == '0' ]]; then
            echo "排除名单含 main 中不存在的 option: ${o}"
            rc=1
        fi
    done
    # (4) 关键写操作不得被排除
    for o in "${KEY_WRITE_OPTS[@]}"; do
        if [[ "$(printf '%s\n' "${s_opts}" | grep -cxF -- "${o}" || true)" != '0' ]]; then
            echo "关键写操作被误列入排除名单: ${o}"
            rc=1
        fi
    done
    return "${rc}"
}

# ---- T2/T3/T4: 对真实源码跑静态检查 ----
if static_check "$HANDLER" >"${SB}/static.out" 2>&1; then
    ok
else
    bad "T2/T3/T4: 静态契约检查未通过 -> $(cat "${SB}/static.out")"
fi
assert_contains "T2 调用点为事前留痕 (main 内有调用)" "${main_fn}" '_audit_dispatch "${option}" "$*"'
assert_count "T3a 排除名单已解析出 --purge" "1" "${skip_opts}" "--purge"
assert_count "T3b 排除名单不含 --routing (关键写操作)" "0" "${skip_opts}" "--routing"
assert_count "T3c 排除名单不含 --xray-config (关键写操作)" "0" "${skip_opts}" "--xray-config"

# ---------------------------------------------------------------------------
# 行为驱动: 命令替换自带子 shell, eval 注入的函数与桩件不污染本进程。
#   AUDIT_FILE -> 审计落盘路径 (经 _audit_log 真实现写入)
#   结果经 stdout 回传: 第一行 RC=<退出码>, 其后为审计文件内容
# ---------------------------------------------------------------------------
run_dispatch() { # $1=option $2=detail
    local _rc=0
    # 下面两个变量只被 eval 注入的 _audit_log 读取 —— shellcheck 的数据流不跨 eval, 会报
    # SC2034 (appears unused), 故逐行抑制 (必须紧贴被报的**赋值行**); 且**不能**加 export
    # (会污染子进程环境)。
    # shellcheck disable=SC2034
    local SCRIPT_CONFIG_DIR="${AUDIT_DIR:-${SB}}"
    # 真源码里 AUDIT_LOG_PATH 是 readonly 常量 (由 SCRIPT_CONFIG_DIR 拼出); 这里直接指向
    # 用例文件 —— 不 eval 那行 readonly, 否则多个用例无法各自改写路径。
    # shellcheck disable=SC2034
    AUDIT_LOG_PATH="${AUDIT_FILE}"
    eval "${audit_fn}"
    eval "${dispatch_fn}"
    _audit_dispatch "$1" "${2:-}" || _rc=$?
    printf 'RC=%s\n' "${_rc}"
    cat "${AUDIT_FILE}" 2>/dev/null || true
}

drive() { # $1=option $2=detail $3=结果文件名(基础名)
    local f="${SB}/$3.log"
    : >"$f"
    AUDIT_FILE="${f}" run_dispatch "$1" "${2:-}"
}

# T5: 改配置类写操作 -> 留痕
out="$(drive '--routing' 'block domain' routing)"
assert_contains "T5a --routing 产出审计记录" "${out}" '| routing'
assert_not_contains "T5b 记录里的动作名不带 -- 前缀" "${out}" '| --routing'
assert_contains "T5c 记录含时间戳与用户字段" "${out}" '| user='
# T6: detail 一并落盘 (审计要能回答"改成什么了")
assert_contains "T6a detail 随记录落盘" "${out}" '| routing | block domain'
out="$(drive '--change-port' '443' change_port)"
assert_contains "T6b --change-port 的端口进 detail" "${out}" '| change-port | 443'
out="$(drive '--xray-config' '' xray_config)"
assert_contains "T7a 无 detail 时仍记录动作" "${out}" '| xray-config'
assert_not_contains "T7b 无 detail 时不出现空分隔" "${out}" '| xray-config |'

# T7: 臂内已留痕 / 只读查询 -> 不重复记录 (审计文件应保持空, 只回传 RC=0)
for pair in '--purge:' '--start:' '--stop:' '--restart:' '--install:release' \
    '--export-config:' '--import-config:/tmp/a.tar.gz' '--bbr:' '--net-tune:' \
    '--nofile-limit:' '--share:--save' '--traffic:' '--sni-ports:'; do
    opt="${pair%%:*}"
    detail="${pair#*:}"
    out="$(drive "${opt}" "${detail}" "skip_${opt#--}")"
    assert_eq "T7c ${opt} 不在 dispatch 层重复记录" "${out}" 'RC=0'
done

# T8: 未知/传错的参数也留痕 (cron 里把 --health 写成 --heath 可追查)
out="$(drive '--heath' '' heath)"
assert_contains "T8a 未知参数同样留痕" "${out}" '| heath'

# T8b: 空 option 不记录 (异常调用兜底)
out="$(drive '' '' empty)"
assert_eq "T8b 空 option 不产出记录" "${out}" 'RC=0'

# T9: 审计落盘不可达 -> 仍返回 0, 不阻断主流程
BAD_DIR='/proc/self/fake-audit-dir'
out="$(AUDIT_DIR="${BAD_DIR}" AUDIT_FILE="${BAD_DIR}/audit.log" run_dispatch '--routing' 'block ip')"
assert_contains "T9a 不可写路径下仍返回 0" "${out}" 'RC=0'
# T9b: 且**不许**往 stderr 喷报错 —— 审计是旁路, 配置目录不可写时那行 "没有那个文件或目录"
#      会插进用户屏幕上的分享链接/二维码中间。坑: bash 的重定向失败报错走的是**当时的**
#      stderr, 直接写在命令上的 `2>/dev/null` 罩不住 (必须用 `{ ...; } 2>/dev/null` 包一层)。
err="$(AUDIT_DIR="${BAD_DIR}" AUDIT_FILE="${BAD_DIR}/audit.log" run_dispatch '--routing' 'block ip' 2>&1 >/dev/null || true)"
assert_eq "T9b 不可写路径下不往 stderr 喷报错" "${err}" ''

# ---------------------------------------------------------------------------
# T10: 静态守卫的负向校验 —— 把副本改坏, 确认检查真的变红。
#   用 cp + 原地改写, 不碰 git checkout (工作区可能有未提交改动)。
# ---------------------------------------------------------------------------
neg_check() { # $1=改坏后的文件 $2=说明 ; 返回 0 = 确实被抓到
    local f="$1" what="$2" out=''
    if out="$(static_check "$f" 2>&1)"; then
        bad "T10 负向校验失败: ${what} 未被静态检查捕获"
        return 1
    fi
    ok
    return 0
}

# NEG1: 删掉调用点 (最容易被误删的一行)
cp "$HANDLER" "${SB}/neg1.sh"
sed -i '/_audit_dispatch "\${option}"/d' "${SB}/neg1.sh"
neg_check "${SB}/neg1.sh" '删掉 _audit_dispatch 调用'

# NEG2: 名单写错一个字符 (--purge -> --purgee)
cp "$HANDLER" "${SB}/neg2.sh"
sed -i 's/    --purge | --start/    --purgee | --start/' "${SB}/neg2.sh"
neg_check "${SB}/neg2.sh" '排除名单拼写错 (--purgee)'

# NEG3: 关键写操作被误列入排除名单 (把 --routing 塞进 --purge 那一行)
cp "$HANDLER" "${SB}/neg3.sh"
sed -i 's/    --purge | --start/    --purge | --routing | --start/' "${SB}/neg3.sh"
neg_check "${SB}/neg3.sh" '关键写操作 --routing 被排除'

# NEG4: 调用点挪到分派 case 之后 (事后再记 -> 直接 exit 的失败路径记不到)
cp "$HANDLER" "${SB}/neg4.sh"
sed -i '/_audit_dispatch "\${option}"/d' "${SB}/neg4.sh"
printf '%s\n' '    _audit_dispatch "${option}" "$*"' >>"${SB}/neg4.sh"
neg_check "${SB}/neg4.sh" '调用点被挪到分派 case 之后'

echo "==== handler_audit_dispatch_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
