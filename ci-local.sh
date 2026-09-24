#!/usr/bin/env bash
#
# 本地复现 CI —— 等价于 .github/workflows/shellcheck.yml 的门禁。
#
# CI 实际只有一个 job(shellcheck.yml), 跑 5 个实质 step:
#   1) bash -n 语法检查       2) 行尾 LF 守卫       3) ShellCheck 门禁(-S warning)
#   4) 行为测试 run_tests.sh   5) 存量债务棘轮(SC2155/SC2034/SC2154 只许下降)
# 本脚本把 1~5 全部搬下来, 且默认贴近 CI 的"非 root"条件。
#
# ShellCheck 的取用顺序与 CI 略有不同(CI 固定 docker 镜像):
#   第 3 阶段优先 docker(与 CI 同镜像同版本), 失败再回退本地二进制;
#   第 5 阶段优先本地二进制, 没有再回退 docker —— 棘轮只是"计数对账",
#   版本差异不会改变 SC2155/SC2034/SC2154 的判定, 故优先走无需拉镜像的路径。
#
# 用法:
#   bash ci-local.sh                  # 全量 (语法 + 行尾 + ShellCheck + 行为测试 + 棘轮)
#   bash ci-local.sh --no-shellcheck  # 跳过 ShellCheck 与棘轮(docker/二进制不可用或想省时间)
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

# 收集 shell 脚本清单 (供 ShellCheck 使用; 用数组避免 SC2046 单词拆分告警,
# 也顺带修了"文件名含空格"时命令替换会错误拆分的隐患)。
# ⚠️ 必须带上 --others: 只用 `git ls-files` 会**漏掉尚未 git add 的新文件**, 于是出现
#    "本地门禁全绿、提交后 CI 变红" —— CI 在 checkout 后所有文件都已跟踪, 一个不落。
#    2026-09-24 实测踩到: 新测试里的一条 SC2034 本地没报, 提交后才暴露。
#    --exclude-standard 让 .gitignore 覆盖的产物 (如 .workbuddy/tmp/*.sh) 仍被排除。
mapfile -t sh_files < <(git ls-files --cached --others --exclude-standard '*.sh')

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

# ---- [1/5] bash -n 语法检查 ----
echo; echo ">>> [1/5] bash -n 语法检查"
fail=0
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then
    printf '  ok   %s\n' "$f"
  else
    printf '  FAIL %s\n' "$f"
    fail=1
  fi
done < <(git ls-files --cached --others --exclude-standard '*.sh')
[ "$fail" -eq 0 ] && echo "语法检查通过 ✓" || { echo "语法检查失败"; exit 1; }

# ---- [2/5] 行尾守卫 (要求 LF) ----
echo; echo ">>> [2/5] 行尾守卫 (要求 LF)"
bad=0
while IFS= read -r f; do
  if grep -qU $'\r' "$f"; then
    echo "::error file=$f::含 CR (CRLF), 本仓库 *.sh 必须为 LF"
    bad=1
  fi
done < <(git ls-files --cached --others --exclude-standard '*.sh')
[ "$bad" -eq 0 ] && echo "全部 LF ✓" || { echo "行尾检查失败"; exit 1; }

# ---- [3/5] ShellCheck 门禁 ----
if [ "$NO_SHELLCHECK" -eq 1 ]; then
  echo; echo ">>> [3/5] ShellCheck 跳过 (--no-shellcheck)"
else
  echo; echo ">>> [3/5] ShellCheck 门禁 (-S warning)"
  # 与 CI 的差别: CI 固定 docker 镜像; 本地优先 docker, 但**必须区分两类非 0**:
  #   * ShellCheck 真发现  -> 输出含 gcc 格式诊断行 `file:line:col: severity:` , 门禁必须失败;
  #   * 工具自身失败        -> docker daemon 不可达 / 镜像拉不到 / 无 socket 权限,
  #                           实测退出码同样是 1。早期版本据 rc==1 直接 exit 1,
  #                           在"装了 docker CLI 但当前用户无权访问 socket"的机器上假红。
  # 故先取输出再判据, 只在真出诊断行时判失败, 否则降级回退。
  sc_backend='none'
  sc_rc=0
  sc_out=''
  if command -v docker >/dev/null 2>&1; then
    sc_backend='docker'
    echo "  使用 docker: koalaman/shellcheck:v0.10.0"
    sc_out="$(docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.10.0 \
      -S warning -f gcc "${sh_files[@]}" 2>&1)"
    sc_rc=$?
  elif command -v shellcheck >/dev/null 2>&1; then
    sc_backend='shellcheck'
    echo "  使用本地 shellcheck: $(command -v shellcheck)"
    sc_out="$(shellcheck -S warning -f gcc "${sh_files[@]}" 2>&1)"
    sc_rc=$?
  fi

  if [ "$sc_backend" = none ]; then
    echo "  未找到 docker / shellcheck 二进制, 跳过 ShellCheck (加 --no-shellcheck 可消除此提示)"
    echo "  想跑真 ShellCheck: brew install shellcheck 或 apt-get install shellcheck"
  elif printf '%s\n' "$sc_out" | grep -qE ':[0-9]+:[0-9]+: (error|warning|note):'; then
    printf '%s\n' "$sc_out"   # 原样透出诊断 (与 CI 的 gcc 格式一致)
    echo "ShellCheck 门禁未过 (见上)"; exit 1
  elif [ "$sc_rc" -ne 0 ]; then
    echo "  ⚠️ ShellCheck 未能执行 (rc=$sc_rc), 首几行输出:"
    printf '%s\n' "$sc_out" | sed -n '1,3p' | sed 's/^/     /'
    if [ "$sc_backend" = docker ] && command -v shellcheck >/dev/null 2>&1; then
      echo "     回退使用本地 shellcheck: $(command -v shellcheck)"
      shellcheck -S warning -f gcc "${sh_files[@]}"
      rc2=$?
      [ "$rc2" -ne 0 ] && exit "$rc2"
    else
      echo "     且无本地 shellcheck 二进制, 跳过 ShellCheck 门禁(离线/无 registry 访问)。"
      echo "     想跑真 ShellCheck: 联网拉取镜像, 或 brew/apt 安装 shellcheck。"
    fi
  else
    echo "ShellCheck 无告警 ✓"
  fi
fi

# ---- [4/5] 行为测试 ----
echo; echo ">>> [4/5] 行为测试 (test/run_tests.sh)"
if [ -n "$FILTER" ]; then
  bash test/run_tests.sh "$FILTER"
else
  bash test/run_tests.sh
fi
rc=$?
[ "$rc" -ne 0 ] && exit "$rc"

# ---- [5/5] 存量债务棘轮 (.shellcheckrc 例外只许下降) ----
# 与 CI 的 shellcheck.yml 末步等价: 用 --rcfile=/dev/null 忽略 .shellcheckrc,
# 统计被登记为例外的规则条数, 超过基线即失败。基线 = 0 (2026-09-17 清零), 只许降。
#
# 存在的意义: 第 3 阶段只看"当前 rcfile 下是否干净", 若有人往 .shellcheckrc 里加
# disable=, 第 3 阶段照样全绿 —— 棘轮是唯一会因此变红的门禁。
echo; echo ">>> [5/5] 存量债务棘轮 (SC2155/SC2034/SC2154 只许下降)"

# 棘轮判定器: stdin 收 ShellCheck 的原始 dump, 对三条登记规则逐条计数并打印结论行。
# 基线全部为 0 (2026-09-17 债务清零), 任一条 >0 即视为回潮。
# 返回: 0 = 三条均为 0; 1 = 至少一条回潮
# 抽成独立函数是为了可测 —— test/ci_local_ratchet_test.sh 直接喂 dump 文本驱动它,
# 不必真跑 shellcheck, 因此测试结果不随本机有无 shellcheck 而变化。
_ratchet_check() {
  local dump='' rule='' cur='' rc=0
  dump="$(cat)"
  for rule in SC2155 SC2034 SC2154; do
    # `|| true` 必须在 grep 之后: 该规则已清零时 grep 无匹配退出码为 1, 属正常状态而非错误
    cur=$( { printf '%s\n' "${dump}" | grep -o "\[${rule}\]" || true; } | wc -l | tr -d ' ')
    if [ "${cur}" -gt 0 ]; then
      printf '  FAIL %s 回潮 %s 处 (基线 0) —— 请改用根 .shellcheckrc 之外的修法, 或下调登记\n' "${rule}" "${cur}"
      rc=1
    else
      printf '  ok   %s 维持 0 处\n' "${rule}"
    fi
  done
  return "${rc}"
}

# 取回 shellcheck 的原始全量输出(含被 disable 的规则), 忽略退出码 —— 有告警是正常状态。
# 优先本地二进制(免拉镜像), 再回退 docker(与 CI 同镜像 koalaman/shellcheck:v0.10.0)。
ratchet_dump() {
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --rcfile=/dev/null -S warning -f gcc "${sh_files[@]}" 2>&1 || true
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.10.0 \
      --rcfile=/dev/null -S warning -f gcc "${sh_files[@]}" 2>&1 || true
  else
    return 1
  fi
}

if [ "$NO_SHELLCHECK" -eq 1 ]; then
  echo "  跳过 (--no-shellcheck)"
elif ! debt_txt="$(ratchet_dump)"; then
  echo "  未找到 shellcheck / docker, 跳过棘轮审计"
  echo "  注意: 跳过 = 本地少一道 CI 有的门禁, 结果仅供参照"
else
  # 护栏(与 CI 同): --rcfile 没被读到时会打印 "unable to read --rcfile" 并继续跑,
  # 此时统计的是"读过 .shellcheckrc"的结果, 棘轮会假绿。宁可显式失败。
  if printf '%s\n' "${debt_txt}" | grep -q 'unable to read --rcfile'; then
    echo "  FAIL --rcfile 未被读取, 棘轮计数不可信"
    printf '%s\n' "${debt_txt}" | sed 's/^/    /'
    exit 1
  fi
  # 落临时文件后再喂给判定器: 不用管道 / 进程替换 —— 管道右侧是子 shell, 判定器的
  # 退出码传不回来; 沙箱与部分 CI 环境也没有 /dev/fd 供 <(...) 使用。
  ratchet_tmp="$(mktemp "${TMPDIR:-/tmp}/.xray-ci-ratchet.XXXXXXXX")"
  printf '%s\n' "${debt_txt}" > "${ratchet_tmp}"
  if _ratchet_check < "${ratchet_tmp}"; then
    echo "存量债务棘轮通过 ✓"
  else
    rm -f "${ratchet_tmp}"
    echo "存量债务棘轮失败 (CI 会红)"; exit 1
  fi
  rm -f "${ratchet_tmp}"
fi

echo; echo "==================================================="
echo " 本地 CI 全部通过 ✓"
echo "==================================================="
