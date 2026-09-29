#!/usr/bin/env bash
# =============================================================================
# test/cli_service_test.sh — 非交互服务参数 (--start/--stop/--restart/--share) 转发守卫
#
# 背景: handler.sh 早已实现 4 个服务运维动作 (handler_start/stop/restart/share),
#   但公开入口此前没把它们透传下去 —— install.sh 的 DIRECT_ARGS 收集清单 与 main.sh 的
#   _cmd case 都缺这 4 个参数, 导致 `bash ... --start` 会落回交互菜单。本测试静态锁定
#   转发链三处落点, 防止回退:
#     1) install.sh 的 DIRECT_ARGS 收集清单须含 4 参;
#     2) main.sh 的 _cmd case 须有 4 个分支转发给 exec_handler;
#     3) handler.sh 须保留 4 个 case 分支 (底层能力, 防误删)。
#
# 纯静态 + grep, 不依赖 jq, CI/沙箱均可跑。
# =============================================================================
set -u

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
INSTALL="$REPO/install.sh"
MAIN="$REPO/core/main.sh"
HANDLER="$REPO/core/handler.sh"

for f in "$INSTALL" "$MAIN" "$HANDLER"; do
    [[ -f "$f" ]] || { echo "前置文件缺失: $f"; exit 3; }
done

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

echo "=== 非交互服务参数转发守卫测试 ==="

# 1) install.sh 的 DIRECT_ARGS 收集清单须包含 4 个参数
echo "-- install.sh DIRECT_ARGS 收集清单 --"
for p in --start --stop --restart --share; do
    # 参数后要么是 " |"(中间项) 要么是 ")"(末项), 两者都算被收集
    grep -Eq -- "$p([[:space:]]*\\||[[:space:]]*\\))" "$INSTALL" \
        && ok "install.sh 收集: $p" \
        || bad "install.sh 未收集: $p"
done

# 2) main.sh 的 _cmd case 须有 4 个分支转发到 exec_handler
echo "-- main.sh _cmd 分支 --"
grep -Eq "^    --start) exec_handler '--start' ;;"   "$MAIN" && ok "main.sh 分支: --start"    || bad "main.sh 缺 --start 分支"
grep -Eq "^    --stop) exec_handler '--stop' ;;"     "$MAIN" && ok "main.sh 分支: --stop"      || bad "main.sh 缺 --stop 分支"
grep -Eq "^    --restart) exec_handler '--restart' ;;" "$MAIN" && ok "main.sh 分支: --restart" || bad "main.sh 缺 --restart 分支"
grep -Fq  "exec_handler '--share'"                  "$MAIN" && ok "main.sh 分支: --share(透传)" || bad "main.sh 缺 --share 分支"

# 3) handler.sh 须保留 4 个 case 分支 (底层能力, 防误删)
echo "-- handler.sh case 分支 --"
grep -Eq "^    --start) handler_start ;;"   "$HANDLER" && ok "handler.sh 分支: --start"     || bad "handler.sh 缺 --start"
grep -Eq "^    --stop) handler_stop ;;"     "$HANDLER" && ok "handler.sh 分支: --stop"       || bad "handler.sh 缺 --stop"
grep -Eq "^    --restart) handler_restart ;;" "$HANDLER" && ok "handler.sh 分支: --restart" || bad "handler.sh 缺 --restart"
grep -Fq  "handler_share \"\$@\""           "$HANDLER" && ok "handler.sh 分支: --share"     || bad "handler.sh 缺 --share"

echo
if [[ $fail -eq 0 ]]; then echo "结果: 全部通过 (rc=0)"; else echo "结果: 存在失败"; fi
exit $fail
