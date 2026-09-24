#!/usr/bin/env bash
# =============================================================================
# 测试名称: docker_removed_test.sh
# 测试目标: 锁定「Docker / cloudflare-warp 容器方案已彻底移除」, 并守住"该保留的
#           docker 用法不许被误删"这条反向边界。
#
# 背景: WARP 出站已从「Docker 容器 + socks 出站指向容器 40001」改为「Xray 原生
#   WireGuard 出站」(见 test/warp_wireguard_test.sh)。Docker 由此退出整个依赖链,
#   容器时代的产物一并删除:
#     service/docker.sh、config/cloudflare-warp/、test/docker_warp_test.sh、
#     handler.sh 的 exec_docker / handler_docker / DOCKER_PATH、
#     backup.sh 的 docker 成员与 --with-docker 开关、i18n 的 .docker 段。
#
#   这些一旦回流, 用户机器上会重新出现"装 Docker"这一步 (handler_docker 的
#   exec_docker '--install'), 而 WARP 早已不需要它 —— 正是本次要根除的东西。
#
# 反向守卫 (同样重要): 下列 docker 用法与 WARP 无关, 必须保留 ——
#   ci-local.sh 与 .github/workflows/shellcheck.yml 用 docker 跑 koalaman/shellcheck;
#   core/check.sh / test/target_presets_test.sh 里的 www.docker.com 是 Reality
#   target 探测样本站点。防止"清理"被过度执行。
#
# 依赖网络吗: 不。纯静态检查, 无需 jq 以外的外部命令 (jq 缺失时 T5 降级跳过)。
#
# 运行: bash test/docker_removed_test.sh
# =============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

# 断言: 路径不存在
assert_gone() {
    if [[ ! -e "$1" ]]; then ok "$2"; else bad "$2 (仍存在: $1)"; fi
}
# 断言: 文件不含该 ERE 模式
assert_absent() {
    if grep -qE -- "$2" "$1"; then bad "$3 (在 $1 命中 /$2/)"; else ok "$3"; fi
}
# 断言: 文件含该 ERE 模式
assert_present() {
    if grep -qE -- "$2" "$1"; then ok "$3"; else bad "$3 (在 $1 未命中 /$2/)"; fi
}

# ---------------------------------------------------------------------------
echo "== T1 容器时代的文件已移除 =="
# ---------------------------------------------------------------------------
assert_gone 'service/docker.sh'        'T1a service/docker.sh 已删除'
assert_gone 'config/cloudflare-warp'   'T1b config/cloudflare-warp/ 已删除'
assert_gone 'test/docker_warp_test.sh' 'T1c test/docker_warp_test.sh 已删除'

# ---------------------------------------------------------------------------
echo "== T2 core/handler.sh 不再有容器管理代码 =="
# ---------------------------------------------------------------------------
assert_absent 'core/handler.sh' '^function exec_docker\(\)'    'T2a exec_docker 已删除'
assert_absent 'core/handler.sh' '^function handler_docker\(\)' 'T2b handler_docker 已删除'
assert_absent 'core/handler.sh' '^readonly DOCKER_PATH='       'T2c DOCKER_PATH 常量已删除'
# handler_warp 必须还在 (证明清理没误伤 WARP 本体)
assert_present 'core/handler.sh' '^function handler_warp\(\)' 'T2d handler_warp 仍在'
assert_present 'core/handler.sh' '^function handler_reset_warp\(\)' 'T2e handler_reset_warp 仍在'

# ---------------------------------------------------------------------------
echo "== T3 全仓不再引用容器脚本 =="
# ---------------------------------------------------------------------------
# 注: --include 必须写在 `--` 之前 —— 放在其后会被当成文件名操作数, 该选项静默失效
# (上一版就因此把 CHANGELOG.md 也扫了进来)。本测试自身含该字面量 (用于断言), 需排除;
# .workbuddy 是沙箱临时区, 同样排除。
refs="$(grep -rl --include='*.sh' -- 'service/docker.sh' . 2>/dev/null \
    | grep -v '^\./\.workbuddy' | grep -v 'docker_removed_test\.sh' || true)"
if [[ -z "${refs}" ]]; then
    ok 'T3 无脚本引用 service/docker.sh'
else
    bad "T3 仍有引用: ${refs}"
fi

# ---------------------------------------------------------------------------
echo "== T4 tool/backup.sh 的 docker 成员与 --with-docker 开关已移除 =="
# ---------------------------------------------------------------------------
assert_absent 'tool/backup.sh' '^[[:space:]]*docker[[:space:]]*$' 'T4a 成员表不含 docker'
assert_absent 'tool/backup.sh' 'with_docker|with-docker'         'T4b 无 with_docker 残留'
assert_absent 'tool/backup.sh' 'DOCKER_DATA_DIR'                 'T4c 无 DOCKER_DATA_DIR 常量'
# 老归档里可能仍带 docker 成员, 未知成员的软跳过通道必须保留 (否则导入报错)
assert_present 'tool/backup.sh' 'unknown_member' 'T4d 未知成员软跳过仍在 (老归档兼容)'
# 成员表本身仍非空且仍含 script_config (导入侧强制要求)
assert_present 'tool/backup.sh' '^[[:space:]]*script_config[[:space:]]*$' 'T4e 成员表仍含 script_config'

# ---------------------------------------------------------------------------
echo "== T5 i18n 的 docker 段已移除 =="
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    for f in zh en; do
        if jq -e 'has("docker")' "i18n/${f}.json" >/dev/null 2>&1; then
            bad "T5(${f}) 仍有顶层 .docker 段"
        else
            ok "T5(${f}) 无顶层 .docker 段"
        fi
    done
else
    echo "  (jq 不可用, T5 的 has() 断言跳过)"
fi
for f in zh en; do
    n="$(grep -ci 'docker' "i18n/${f}.json" 2>/dev/null || true)"
    if [[ "${n:-0}" == '0' ]]; then
        ok "T5(${f}) 无 docker 字样"
    else
        bad "T5(${f}) 仍有 ${n} 处 docker 字样"
    fi
done

# ---------------------------------------------------------------------------
echo "== T6 反向守卫: 与 WARP 无关的 docker 用法必须保留 =="
# ---------------------------------------------------------------------------
assert_present 'ci-local.sh' 'docker run' 'T6a ci-local.sh 仍用 docker 跑 ShellCheck'
assert_present '.github/workflows/shellcheck.yml' 'docker run' 'T6b CI workflow 仍用 docker 跑 ShellCheck'
assert_present 'core/check.sh' 'www\.docker\.com' 'T6c target 探测样本 www.docker.com 仍在'

# ---------------------------------------------------------------------------
echo "== T7 install.sh 不涉及 docker =="
# ---------------------------------------------------------------------------
assert_absent 'install.sh' 'docker|Docker' 'T7 install.sh 无 docker 逻辑'

# ---------------------------------------------------------------------------
echo "== T8 WARP 功能未被误伤 (原生 wireguard 链路完整) =="
# ---------------------------------------------------------------------------
assert_present 'core/handler.sh' 'WARP_CREDENTIALS_PATH' 'T8a 凭据路径常量仍在'
assert_present 'core/handler.sh' 'protocol:[[:space:]]*"wireguard"' 'T8b 仍写 wireguard 出站'
# 注意: 不能简单断言"文件里没有 kcpSettings.seed" —— 反读兼容路径 (.inbounds[1]
#   .streamSettings.kcpSettings.seed, handler.sh 约 630 行) 与多处说明注释都含该字符串,
#   而它们是正确保留的。要锁的是"不再**写入** seed": 26.x 已移除该字段, 写回去会让
#   整份配置被拒 (finalmask 迁移时踩过的同类坑)。
assert_absent  'core/handler.sh' 'kcpSettings:[[:space:]]*\{[^}]*seed' 'T8c 不再往 kcpSettings 写 seed'

# ---------------------------------------------------------------------------
echo "==== docker_removed_test: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]]
