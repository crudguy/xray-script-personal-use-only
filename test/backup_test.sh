#!/usr/bin/env bash
#
# 用例: tool/backup.sh 的配置导出/导入 (管理配置→8 / --export-config / --import-config)
#
# 背景 (为什么固化成脚本): 本模块 789 行, 动的是"证书 + 配置"这类不可再生资产, 是用户
# 灾备/迁移的最后一道保险, 此前完全没有行为验证 —— 静态检查 (bash -n / shellcheck)
# 只能保证"语法与风格", 抓不到"回退点没生效""路径穿越被放行""私有权限被放宽"这类语义错误。
#
# 覆盖 (全部离线):
#   T1 导出            —— 产物存在 / 顶层只有 manifest.json + payload/ / manifest 标识与 schema
#   T2 manifest 成员表 —— 含 script_config; 源不存在的成员被跳过且不计入
#   T3 归档预检(安全)  —— 绝对路径 / ".." 穿越 / 顶层非法成员 三类均被拒绝 + 正常归档对照组
#   T4 导入(正常)      —— 还原后目标文件被实际改写, 且与归档载荷逐字节一致
#   T5 回退点          —— 导入前自动产出 pre-import-*.tar.gz
#   T6 未知成员        —— 成员表外的 id 被跳过告警, 且不落地
#   T7 静态守卫        —— 落点来自 _member_spec; 归档 0600 / 暂存 0700
#
# 做法: 在临时沙箱里复制 core/ + i18n/ + tool/ (保持"tool/ 与 core/ 平级"的相对布局,
#       因为 backup.sh 用 `$0` 推导自身目录, 再 `../core/_common.sh` 定位共享头部), 再用
#       sed 把 backup.sh 里两个 readonly 目标路径常量改写到沙箱内 (它们在真实机器上是
#       /usr/local/... , 测试机不可写)。随后 **以独立进程** 调用 backup.sh 的真实入口
#       main "$@" —— 这样就完整跑到了参数解析 + _do_export/_do_import 全链路。
#
#       注意沙箱必须在外层目录与 core/ 平级, 或至少在 shell 的 $0 视角下让 ../core 可达;
#       把 backup.sh 单独放到 /tmp 下跑会因为 `$0` 推出 /tmp/../core 而直接报"缺少
#       _common.sh"。同理, 本用例自身也必须放在仓库的 test/ 下执行。
#
#       为什么不在本进程内 source 抽出的函数库 (曾用过的手法):
#       实测在 Windows/MSYS + 宿主注入的 ERR/EXIT trap 下会挂起 (进程树里能看到
#       数层 bash 嵌套后卡死不动)。排查结论是 trap 继承与子 shell 交互在 MSYS 上不可靠,
#       且 source 方式下库函数里的 `exit 1` 会直接终止宿主测试脚本、把后面的断言静默吞掉
#       (表现出来不是"某条 FAIL", 而是"输出到这里就断了")。独立进程方式两个问题都消失。
#       踩坑记录见 .workbuddy/memory/2026-09-18.md。
#
# 依赖: bash, tar, gzip, jq, sha256sum。
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"

SB="$(mktemp -d "/tmp/xray-bktest.XXXXXX")"

# 注: 不注册 EXIT trap。本用例会起子进程, EXIT trap 在子 shell 里也会触发, 会把父 shell
# 仍在使用的沙箱删掉。改为末尾显式清理一次。
# 排查失败时: XRAY_TEST_KEEP=1 bash test/backup_test.sh
trap 'trap - EXIT' EXIT
trap - EXIT

fail=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
    printf '  FAIL %s\n' "$1"
    fail=1
}

# ---------------------------------------------------------------------------
# 0. 前置依赖: 本用例**自身**在顶层就用 jq 解析归档 manifest (不只是被测脚本里用),
#    而本机 (Windows/MSYS) 默认没有 jq, 靠 .workbuddy/tmp/jqshim 垫片进 PATH。
#    垫片没进 PATH 时, 顶层那些 jq 只会打出 "jq: command not found" 然后继续,
#    断言全部拿着空串静默 FAIL —— 看起来像被测代码坏了, 实际是环境没配好。
#    所以这里显式前置检查, 缺了就直接退出并给出正确命令。
# ---------------------------------------------------------------------------
for dep in bash tar gzip jq sha256sum; do
    if ! command -v "${dep}" >/dev/null 2>&1; then
        printf 'SKIP: 缺少依赖 %s\n' "${dep}" >&2
        printf '  本机 (MSYS) 需把 jq 垫片带进 PATH, 正确调用方式:\n' >&2
        printf '    PATH="$PWD/.workbuddy/tmp/jqshim:$PATH" \\\n' >&2
        printf '    XRAY_TEST_SHIM="$PWD/.workbuddy/tmp/jqshim" bash test/backup_test.sh\n' >&2
        exit 3
    fi
done

# Python 解释器: 下面两处要用 tarfile 精确构造"绝对路径成员"与".. 穿越"归档,
# GNU tar 造不出来。CI (ubuntu-latest) 只提供 python3, 本机可能是 python ——
# 不能写死命令名, 否则 `python: command not found` 会让脚本以 127 直接崩掉
# (set -e 下不是"某条 FAIL", 而是"输出到这里就断了")。两者都缺时交由调用方
# 走"构造失败跳过"分支, 而不是拖垮整个用例。
PY_BIN="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# 1. 沙箱: core/ + i18n/ + tool/ (tool 与 core 平级, 与仓库一致)
# ---------------------------------------------------------------------------
mkdir -p "${SB}/home/.xray-script-personal-use-only" "${SB}/root" "${SB}/out" "${SB}/tool"
cp -r "${REPO}/core" "${SB}/core"
cp -r "${REPO}/i18n" "${SB}/i18n"

FAKE_XRAY_CONF="${SB}/root/xray-config.json"
FAKE_NGINX_CONF_DIR="${SB}/root/nginx-conf"
mkdir -p "${FAKE_NGINX_CONF_DIR}"
printf '{"log":{"loglevel":"warning"},"inbounds":[]}\n' >"${FAKE_XRAY_CONF}"
printf 'worker_processes 1;\n' >"${FAKE_NGINX_CONF_DIR}/nginx.conf"

# 脚本主配置: _do_export 以它的存在为前提 (缺了会直接 _fail "请先完成安装"),
# load_i18n 也从它读 language。缺这一份整个用例都跑不起来。
printf '{"version":"vTEST","language":"zh","xray":{"tag":"Vision"}}\n' >"${SB}/home/.xray-script-personal-use-only/config.json"

# WARP 凭据 (原生 WireGuard 出站使用): 与 config.json 同目录。真实机器上未启用 WARP 时
# 该文件不存在, 备份成员 warp_credentials 会走"源缺失即跳过"分支, 故 T2 对两侧都做断言。
# 内容刻意用真实字段名 (private_key/peer_public_key/address), 与 handler.sh 的
# _warp_ensure_credentials 复用判据一致, 便于日后核对。
WARP_CRED_FILE="${SB}/home/.xray-script-personal-use-only/warp.json"
printf '{"private_key":"AAA","peer_public_key":"BBB","address":["172.16.0.2/32"],"reserved":[1,2,3]}\n' >"${WARP_CRED_FILE}"

# 把 backup.sh 拷进沙箱并把两个硬编码目标路径改写到沙箱内。
# 用锚点断言: 锚点没命中就 ABORT, 避免上游改了写法而测试静默"测了个假的"。
patch_backup() {
    local src="${REPO}/tool/backup.sh"
    local dst="${1}"
    local a1='readonly XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"'
    local a2='readonly NGINX_CONFIG_DIR="/usr/local/nginx/conf"'
    if ! grep -qF "${a1}" "${src}" || ! grep -qF "${a2}" "${src}"; then
        printf 'ABORT: backup.sh 里目标路径常量的锚点已变, 测试需同步更新\n' >&2
        printf '  期望锚点1: %s\n' "${a1}" >&2
        printf '  期望锚点2: %s\n' "${a2}" >&2
        exit 2
    fi
    sed \
        -e "s|${a1}|readonly XRAY_CONFIG_PATH=\"${FAKE_XRAY_CONF}\"|" \
        -e "s|${a2}|readonly NGINX_CONFIG_DIR=\"${FAKE_NGINX_CONF_DIR}\"|" \
        "${src}" >"${dst}"
    chmod +x "${dst}"
    # 写回后复核: 沙箱副本里那两行 readonly 必须已指向沙箱 (文件别处仍有同路径的注释,
    # 所以断言要落在 `readonly <VAR>=` 这一行上, 而不是裸字符串 grep)。
    if ! grep -qE "^readonly XRAY_CONFIG_PATH=\"${FAKE_XRAY_CONF}\"" "${dst}" ||
        ! grep -qE "^readonly NGINX_CONFIG_DIR=\"${FAKE_NGINX_CONF_DIR}\"" "${dst}"; then
        printf 'ABORT: 沙箱化改写未生效\n' >&2
        exit 2
    fi
}
patch_backup "${SB}/tool/backup.sh"

# ---------------------------------------------------------------------------
# 2. 以独立进程调用 backup.sh 的真实入口
# ---------------------------------------------------------------------------
# 清掉宿主注入的会话变量 (会激活 safe-bin 删除垫片), 并卸掉宿主可能继承的 trap。
#
# jq 垫片怎么进 PATH: _common.sh 会把 PATH **整体覆盖**为固定白名单 (/bin:/sbin:
# /usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:/snap/bin), 白名单外的目录
# (含本机的 .workbuddy/tmp/jqshim) 会被抹掉, 于是子进程里找不到 jq。白名单里唯一
# 可写的是 `~/bin`, 而本用例的 HOME 指向沙箱 —— 所以把垫片软链到 ${SB}/home/bin/jq。
if [[ -n "${XRAY_TEST_SHIM:-}" && -x "${XRAY_TEST_SHIM}/jq" ]]; then
    mkdir -p "${SB}/home/bin"
    ln -sf "${XRAY_TEST_SHIM}/jq" "${SB}/home/bin/jq"
fi

bk_run() {
    env -u CODEBUDDY_SESSION_ID -u CLAUDE_SESSION_ID \
        HOME="${SB}/home" \
        PATH="${PATH}" \
        bash -c 'trap - ERR EXIT; exec bash "$@"' _ "${SB}/tool/backup.sh" "$@"
}

# ---------------------------------------------------------------------------
# 3. T1/T2: 导出
# ---------------------------------------------------------------------------
ARCH="${SB}/out/backup.tar.gz"
if bk_run --export "${ARCH}" >"${SB}/export.log" 2>&1; then
    ok "T1 导出成功"
else
    bad "T1 导出失败"
    sed 's/^/  | /' "${SB}/export.log" | head -25
fi

if [[ -f "${ARCH}" ]]; then
    ok "T1 归档文件已生成"
else
    bad "T1 归档文件缺失: ${ARCH}"
fi

top="$(tar -tzf "${ARCH}" 2>/dev/null | awk -F/ '{print $1}' | sort -u | tr '\n' ' ')"
if [[ "${top}" == "manifest.json payload " ]]; then
    ok "T1 归档顶层只有 manifest.json + payload/"
else
    bad "T1 归档顶层异常: '${top}'"
fi

magic="$(tar -xzOf "${ARCH}" manifest.json 2>/dev/null | jq -r '.magic // empty')"
schema="$(tar -xzOf "${ARCH}" manifest.json 2>/dev/null | jq -r '.schema // empty')"
[[ "${magic}" == 'xray-script-personal-use-only-backup' ]] && ok "T2 manifest.magic 正确" || bad "T2 manifest.magic='${magic}'"
[[ "${schema}" == '1' ]] && ok "T2 manifest.schema=1" || bad "T2 manifest.schema='${schema}'"

if tar -xzOf "${ARCH}" manifest.json 2>/dev/null | jq -e 'any(.members[]?; .id == "script_config")' >/dev/null 2>&1; then
    ok "T2 manifest 含 script_config"
else
    bad "T2 manifest 缺 script_config"
fi

# 源存在 -> 收录; 源缺失 -> 跳过
has_a="$(tar -xzOf "${ARCH}" manifest.json 2>/dev/null | jq -r '[.members[]?.id] | any(. == "xray_config")')"
[[ "${has_a}" == 'true' ]] && ok "T2 源存在时成员被收录" || bad "T2 源存在却未收录 (got '${has_a}')"

rm -f "${FAKE_XRAY_CONF}"
bk_run --export "${SB}/out/b3.tar.gz" >/dev/null 2>&1 || true
has_b="$(tar -xzOf "${SB}/out/b3.tar.gz" manifest.json 2>/dev/null | jq -r '[.members[]?.id] | any(. == "xray_config")')"
[[ "${has_b}" == 'false' ]] && ok "T2 源缺失时成员被跳过" || bad "T2 源缺失却仍收录 (got '${has_b}')"
printf '{"log":{"loglevel":"warning"},"inbounds":[]}\n' >"${FAKE_XRAY_CONF}" # 复原

# WARP 凭据: 收录 / 载荷逐字节一致 / 缺失时跳过 (回归: 曾漏收, 迁移后"重置出口"退化为重新注册)
WARP_SRC_SHA="$(sha256sum "${WARP_CRED_FILE}" | cut -d' ' -f1)"
has_w="$(tar -xzOf "${ARCH}" manifest.json 2>/dev/null | jq -r '[.members[]?.id] | any(. == "warp_credentials")')"
[[ "${has_w}" == 'true' ]] && ok "T2 WARP 凭据被收录" || bad "T2 WARP 凭据未收录 (got '${has_w}')"
# 注: tar 取不出成员时 rc≠0, 这里必须 `|| true` 接住 —— 本用例是 set -Eeuo pipefail,
# 否则"载荷缺失"这种**正是要断言的情况**会让脚本就地终止, 后面的断言全部看不到。
w_pack_sha="$( { tar -xzOf "${ARCH}" payload/warp_credentials/warp.json 2>/dev/null || true; } | sha256sum | cut -d' ' -f1)"
[[ "${w_pack_sha}" == "${WARP_SRC_SHA}" ]] \
    && ok "T2 WARP 凭据载荷逐字节一致" || bad "T2 WARP 凭据载荷缺失/不一致 (got '${w_pack_sha}')"

rm -f "${WARP_CRED_FILE}"
bk_run --export "${SB}/out/b4.tar.gz" >/dev/null 2>&1 || true
has_w2="$(tar -xzOf "${SB}/out/b4.tar.gz" manifest.json 2>/dev/null | jq -r '[.members[]?.id] | any(. == "warp_credentials")')"
[[ "${has_w2}" == 'false' ]] && ok "T2 WARP 凭据缺失时被跳过" || bad "T2 WARP 凭据缺失却仍收录 (got '${has_w2}')"

# ---------------------------------------------------------------------------
# 4. T3: 归档安全预检 —— 三类恶意归档必须被拒
# ---------------------------------------------------------------------------
make_bad_archive() {
    local kind="$1" dest="$2" tmpd
    tmpd="$(mktemp -d "${SB}/bad.XXXXXX")"
    (
        cd "${tmpd}" || exit 1
        mkdir -p payload && echo x >payload/a
        case "${kind}" in
        abs)
            # 绝对路径成员: GNU tar 只在 -P (--absolute-names) 下才写绝对路径, 且
            # 解包时会**还原到该绝对路径** —— 所以这里必须用一个"解包也回不去仓库"的
            # 路径, 否则测试的恶意归档一旦被解包就会往 CWD (仓库根) 甩文件。
            # 早期版本用 `echo evil >"${tmpd}/evilfile"` + `tar -P`, 而 GNU tar 会把成员名
            # 记为 `${tmpd}/evilfile`, 解包落点即真实 /tmp/..., 交互式环境下曾把仓库根写脏。
            # 改为纯字符串成员名 (python tarfile 可精确控制), 不依赖 -P 也不碰任何真实路径。
            echo evil >"${tmpd}/evilfile"
            _make_abs_member_archive "${dest}" "${tmpd}/evilfile"
            ;;
        top)
            echo y >stranger.txt
            tar -czf "${dest}" payload stranger.txt 2>/dev/null
            ;;
        esac
    )
    command rm -rf "${tmpd}" 2>/dev/null || true
    [[ -f "${dest}" ]]
}

# 构造一个成员名为绝对路径的归档 (形如 "/abs/evil" 的 name, 不索引任何真实文件)。
# 用 python tarfile 直接写 name, 绕开 GNU tar 对绝对路径的 -P 依赖。
_make_abs_member_archive() {
    local dest="$1" src="$2" dest_win
    dest_win="$(cygpath -w -- "${dest}" 2>/dev/null || printf '%s' "${dest}")"
    if [[ -z "${PY_BIN:-}" ]]; then
        return 1
    fi
    "${PY_BIN}" - "${dest_win}" <<'PYEOF' 2>/dev/null
import sys, tarfile, io
dest = sys.argv[1]
with tarfile.open(dest, 'w:gz') as tf:
    data = b'evil\n'
    ti = tarfile.TarInfo('/abs-evil-marker/x')   # 纯绝对路径名, 不指向真实文件
    ti.size = len(data)
    tf.addfile(ti, io.BytesIO(data))
PYEOF
    [[ -f "${dest}" ]]
}

# dotdot 单独构造: GNU tar 会**拒绝**写出含 ".." 的成员名 (安全特性), 用 tar 命令造不出来。
# 但恶意归档完全可以用别的工具造出来 (python tarfile / bsdtar / 手工改字节), 所以这条
# 必须测。这里直接用 python 的 tarfile 写入一个名为 "payload/../evil" 的成员。
#
# 注: Windows 原生 python 不认 MSYS 的 /tmp/... 路径, 必须先用 cygpath 转成 Windows 路径
#     (非 MSYS 环境 cygpath 不存在, 此时原样传即可)。
make_dotdot_archive() {
    local dest="$1"
    local dest_win
    dest_win="$(cygpath -w -- "${dest}" 2>/dev/null || printf '%s' "${dest}")"
    if [[ -z "${PY_BIN:-}" ]]; then
        return 1
    fi
    "${PY_BIN}" - "${dest_win}" <<'PYEOF' 2>/dev/null
import sys, tarfile, io
dest = sys.argv[1]
with tarfile.open(dest, 'w:gz') as tf:
    data = b'evil\n'
    ti = tarfile.TarInfo('payload/../evil-dotdot')
    ti.size = len(data)
    tf.addfile(ti, io.BytesIO(data))
PYEOF
    [[ -f "${dest}" ]]
}

# 恶意归档走真实 --import 入口: 预检失败时 _do_import 会 exit 1, 进程非 0 即"被拒"。
# 同时要求日志里出现拒绝原因, 避免把"因别的原因崩了"误判成"安全预检生效"。
for kind in dotdot abs top; do
    dest="${SB}/out/bad-${kind}.tar.gz"
    # 构造失败 (无 python / tar 版本差异) 必须走下面的"跳过"分支, 不能在 set -e 下
    # 就地崩掉 —— 故统一用 `|| built=$?` 接住。
    if [[ "${kind}" == 'dotdot' ]]; then
        built=0
        make_dotdot_archive "${dest}" || built=$?
    else
        built=0
        make_bad_archive "${kind}" "${dest}" || built=$?
    fi
    if [[ "${built}" -eq 0 ]]; then
        rc=0
        bk_run --import "${dest}" --yes >"${SB}/bad-${kind}.log" 2>&1 || rc=$?
        # 必须同时满足两点才算"被安全预检拦下":
        #   1) 进程非 0 —— _do_import 的 _validate_archive 失败即 exit 1;
        #   2) 日志里出现安全预检的拒绝文案 —— 否则可能只是"因别的原因崩了", 那是假阳性。
        # 文案取自 i18n 的 backup.err.archive_unsafe / bad_dotdot / bad_abs / bad_member。
        if [[ "${rc}" -ne 0 ]] &&
            grep -qE '安全预检|拒绝导入|路径含|绝对路径|非预期条目' "${SB}/bad-${kind}.log"; then
            ok "T3 恶意归档被拒 (${kind})"
        elif [[ "${rc}" -ne 0 ]]; then
            bad "T3 恶意归档退出码非 0 但未见安全文案 (${kind})"
            sed 's/^/  | /' "${SB}/bad-${kind}.log" | head -8
        else
            bad "T3 恶意归档未被拒 (${kind})"
        fi
    else
        ok "T3 恶意归档 (${kind}) 构造失败, 跳过 (tar 版本差异)"
    fi
done

# 对照组: 正常归档必须能通过预检。
# 注: 这里**不额外跑一次完整 --import** —— MSYS 下起一个 backup.sh 进程约 9s, 完整
#     导入约 60s, 再多跑一次会让本用例的总时长翻倍。T4 本来就要跑一次正常导入, 它的
#     成功即"正常归档通过预检"的对照证据, 断言写在 T4 里即可。

# ---------------------------------------------------------------------------
# 5. T4/T5: 正常导入 + 回退点 (= T3 的正常归档对照组)
# ---------------------------------------------------------------------------
# 先把目标改成一个"可辨识"的内容, 再导入 ARCH —— 若还原生效, 内容必须变回去。
printf '{"log":{"loglevel":"error"},"inbounds":[{"port":1}]}\n' >"${FAKE_XRAY_CONF}"
BEFORE_HASH="$(sha256sum "${FAKE_XRAY_CONF}" | cut -d' ' -f1)"
# WARP 凭据此刻已缺失 (T2 段末删的), 正好等价于"迁移到新机器"的真实场景: 导入后应被还原。
rm -f "${WARP_CRED_FILE}"

rc=0
bk_run --import "${ARCH}" --yes >"${SB}/import.log" 2>&1 || rc=$?
if [[ "${rc}" -eq 0 ]]; then
    ok "T4 导入成功退出 (正常归档通过预检的对照组)"
else
    bad "T4 导入失败 (rc=${rc})"
    # 打印完整 import.log (不再 head 截断): 失败点通常在"停止服务"之后的
    # 还原/校验阶段, 截断会让人误判为停服出错。
    sed 's/^/  | /' "${SB}/import.log"
    echo "  | --- 环境探针 ---"
    echo "  | cp: $(cp --version 2>/dev/null | head -1)"
    echo "  | systemctl: $(command -v systemctl || echo MISSING)"
    echo "  | FAKE_XRAY_CONF sha: $(sha256sum "${FAKE_XRAY_CONF}" 2>/dev/null | cut -d' ' -f1)"
fi

AFTER_HASH="$(sha256sum "${FAKE_XRAY_CONF}" | cut -d' ' -f1)"
if [[ "${AFTER_HASH}" != "${BEFORE_HASH}" ]]; then
    ok "T4 目标文件被实际改写 (还原生效)"
else
    bad "T4 目标文件内容未变 (还原未生效)"
fi

want_hash="$(tar -xzOf "${ARCH}" "payload/xray_config/xray-config.json" 2>/dev/null | sha256sum | cut -d' ' -f1)"
if [[ -n "${want_hash}" && "${AFTER_HASH}" == "${want_hash}" ]]; then
    ok "T4 还原内容与归档载荷逐字节一致"
else
    bad "T4 还原内容与归档载荷不一致"
fi

# WARP 凭据回迁闭环: 导入前不存在, 导入后必须凭空出现且与导出时的内容逐字节一致
if [[ -f "${WARP_CRED_FILE}" ]] && [[ "$(sha256sum "${WARP_CRED_FILE}" | cut -d' ' -f1)" == "${WARP_SRC_SHA}" ]]; then
    ok "T4 WARP 凭据被还原且内容一致"
else
    bad "T4 WARP 凭据未还原/内容不一致"
fi

if ls "${SB}/home/.xray-script-personal-use-only/backup"/pre-import-*.tar.gz >/dev/null 2>&1; then
    ok "T5 导入前自动产出回退点"
else
    bad "T5 未找到 pre-import-*.tar.gz 回退点"
fi

# ---------------------------------------------------------------------------
# 6. T6: 未知成员被跳过
# ---------------------------------------------------------------------------
# 在正常归档基础上塞一个成员表外的 id, 并给出 payload —— 恢复时必须告警跳过, 且不落地。
UD="${SB}/ud"
mkdir -p "${UD}"
tar -xzf "${ARCH}" -C "${UD}" manifest.json payload
jq '.members += [{"id":"evil_unknown","kind":"file","files":1}]' "${UD}/manifest.json" >"${UD}/m.json"
mv "${UD}/m.json" "${UD}/manifest.json"
mkdir -p "${UD}/payload/evil_unknown" && echo pwned >"${UD}/payload/evil_unknown/x"
(cd "${UD}" && tar -czf "${SB}/out/unknown.tar.gz" manifest.json payload)

rc=0
bk_run --import "${SB}/out/unknown.tar.gz" --yes >"${SB}/unknown.log" 2>&1 || rc=$?
if grep -q 'evil_unknown' "${SB}/unknown.log"; then
    ok "T6 未知成员被跳过并告警"
else
    bad "T6 未知成员未被告警"
fi
if [[ ! -e "${SB}/root/evil_unknown" ]]; then
    ok "T6 未知成员未落地 (不采信归档内路径)"
else
    bad "T6 未知成员竟然落地了"
fi

# ---------------------------------------------------------------------------
# 7. T7: 静态守卫
# ---------------------------------------------------------------------------
grep -q 'function _member_spec' "${REPO}/tool/backup.sh" \
    && ok "T7 落点由 _member_spec 推导" || bad "T7 找不到 _member_spec"
grep -q 'chmod 600 "${out_path}"' "${REPO}/tool/backup.sh" \
    && ok "T7 归档收紧为 600" || bad "T7 归档未收紧为 600"
grep -q 'chmod 700 "${d}"' "${REPO}/tool/backup.sh" \
    && ok "T7 暂存目录收紧为 700" || bad "T7 暂存目录未收紧为 700"

if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
    ok "T7 归档权限断言跳过 (Windows 无 POSIX 权限位)"
else
    perm="$(stat -c '%a' "${ARCH}" 2>/dev/null || echo '')"
    [[ "${perm}" == '600' ]] && ok "T7 归档权限实测 600" || bad "T7 归档权限 '${perm}' != 600"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [[ "${fail}" -eq 0 ]]; then
    printf '结果: 全部通过\n'
else
    printf '结果: 失败\n'
fi

# 显式清理沙箱 (不用 EXIT trap, 见文件顶部说明)
if [[ "${XRAY_TEST_KEEP:-0}" == '1' ]]; then
    printf '(已保留沙箱: %s)\n' "${SB}"
else
    command rm -rf "${SB}" 2>/dev/null || true
fi
exit "${fail}"
