#!/usr/bin/env bash
#
# 本地复现 CI —— 等价于 .github/workflows/shellcheck.yml 的门禁。
#
# CI 实际只有一个 job(shellcheck.yml), 跑 5 个实质 step:
#   1) bash -n 语法检查       2) 行尾 LF 守卫       3) ShellCheck 门禁(-S warning)
#   4) 行为测试 run_tests.sh   5) 存量债务棘轮(审计, 仅 docker 可用时)
# 本脚本把 1~4 搬下来, 且默认贴近 CI 的"非 root"条件。
#
# 用法:
#   bash ci-local.sh                  # 全量 (语法 + 行尾 + ShellCheck[若可用] + 行为测试)
#   bash ci-local.sh --no-shellcheck  # 跳过 ShellCheck(docker 不可用 / 想省时间时)
#   bash ci-local.sh backup           # 只跑文件名含 "backup" 的行为测试
#
# ⚠️ 关键: CI 跑在 github runner 上, 它是**非 root** 用户; 本地若用 root 跑,
#    可能掩盖权限相关的差异, 导致"本地绿 / CI 红"对不上。
#    建议用你的普通登录账户执行 (macOS/Linux 桌面默认就是非 root):
#      bash ci-local.sh
#   若你当前是 root, 可降权跑:
#      sudo -u <普通用户名> bash ci-local.sh

set -uo pipefail   # 不放 -e: 行为测试自行管理成败, 由末尾 exit 决定

# ⚠️ 与 CI 对齐: shellcheck.yml 在 job 级固定 LC_ALL/LANG=C.UTF-8。
# menu_title_test 用 GNU `wc -L` 作为 CJK 双宽断言的独立基准, 该基准只在
# UTF-8 locale 下对中文返回 4 (C/POSIX 下返回 0); 若本地继承到 C/POSIX,
# 测试会静默跳过这套断言, 给出"假绿"且和 CI 对不上。这里显式固定, 让本地
# 复现忠实于 CI。主机若未装 C.UTF-8, glibc 会回退并发警告, 不影响其它检查。
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

ROOT="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
cd "$ROOT" || exit 1

# 收集被跟踪的 shell 脚本清单 (供 ShellCheck 使用; 用数组避免 SC2046 单词拆分告警,
# 也顺带修了"文件名含空格"时命令替换会错误拆分的隐患)
mapfile -t sh_files < <(git ls-files '*.sh')

NO_SHELLCHECK=0
FILTER=""
for a in "$@"; do
  case "$a" in
    --no-shellcheck) NO_SHELLCHECK=1 ;;
    --*) echo "未知选项: $a" >&2; exit 2 ;;
    *) FILTER="$a" ;;
  esac
done

echo "==================================================="
echo " 本地 CI 复现 — $(date '+%F %T %Z')"
echo " 当前 uid: $(id -u)  (0=root; CI runner 为非 root)"
echo " 过滤: ${FILTER:-无}   跳过ShellCheck: $([ "$NO_SHELLCHECK" -eq 1 ] && echo 是 || echo 否)"
echo "==================================================="

# ---- [1/4] bash -n 语法检查 ----
echo; echo ">>> [1/4] bash -n 语法检查"
fail=0
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then
    printf '  ok   %s\n' "$f"
  else
    printf '  FAIL %s\n' "$f"
    fail=1
  fi
done < <(git ls-files '*.sh')
[ "$fail" -eq 0 ] && echo "语法检查通过 ✓" || { echo "语法检查失败"; exit 1; }

# ---- [2/4] 行尾守卫 (要求 LF) ----
echo; echo ">>> [2/4] 行尾守卫 (要求 LF)"
bad=0
while IFS= read -r f; do
  if grep -qU $'\r' "$f"; then
    echo "::error file=$f::含 CR (CRLF), 本仓库 *.sh 必须为 LF"
    bad=1
  fi
done < <(git ls-files '*.sh')
[ "$bad" -eq 0 ] && echo "全部 LF ✓" || { echo "行尾检查失败"; exit 1; }

# ---- [3/4] ShellCheck 门禁 ----
if [ "$NO_SHELLCHECK" -eq 1 ]; then
  echo; echo ">>> [3/4] ShellCheck 跳过 (--no-shellcheck)"
else
  echo; echo ">>> [3/4] ShellCheck 门禁 (-S warning)"
  if command -v docker >/dev/null 2>&1; then
    echo "  使用 docker: koalaman/shellcheck:v0.10.0"
    if docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.10.0 \
      -S warning -f gcc "${sh_files[@]}"; then
      : # 门禁通过
    else
      rc=$?
      # rc==1 是 ShellCheck 真发现(门禁未过), 与 CI 一致, 必须失败;
      # 其余(125/126/127 等)是 docker 基础设施失败, 多为离线拉取镜像失败。
      # 本地复现应优雅降级而非中断整轮: 先回退本地 shellcheck, 再不行则跳过。
      if [ "$rc" -eq 1 ]; then
        exit 1
      fi
      echo "  ⚠️ docker 运行 ShellCheck 失败(rc=$rc), 多为离线无法拉取镜像。"
      if command -v shellcheck >/dev/null 2>&1; then
        echo "     回退使用本地 shellcheck: $(command -v shellcheck)"
        shellcheck -S warning -f gcc "${sh_files[@]}"
        rc2=$?
        [ "$rc2" -ne 0 ] && exit "$rc2"
      else
        echo "     且本地无 shellcheck 二进制, 跳过 ShellCheck 门禁(离线/无 registry 访问)。"
        echo "     想跑真 ShellCheck: 联网拉取镜像, 或 brew/apt 安装 shellcheck。"
      fi
    fi
  elif command -v shellcheck >/dev/null 2>&1; then
    echo "  使用本地 shellcheck: $(command -v shellcheck)"
    shellcheck -S warning -f gcc "${sh_files[@]}"
    rc=$?
    [ "$rc" -ne 0 ] && exit "$rc"
  else
    echo "  未找到 docker / shellcheck 二进制, 跳过 ShellCheck (加 --no-shellcheck 可消除此提示)"
    echo "  想跑真 ShellCheck: brew install shellcheck 或 apt-get install shellcheck"
  fi
fi

# ---- [4/4] 行为测试 ----
echo; echo ">>> [4/4] 行为测试 (test/run_tests.sh)"
if [ -n "$FILTER" ]; then
  bash test/run_tests.sh "$FILTER"
else
  bash test/run_tests.sh
fi
rc=$?
[ "$rc" -ne 0 ] && exit "$rc"

echo; echo "==================================================="
echo " 本地 CI 全部通过 ✓"
echo "==================================================="
