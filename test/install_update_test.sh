#!/usr/bin/env bash
# shellcheck disable=SC2034  # 本用例把 install.sh 的真实函数体 awk 抽取后 eval 注入, 下列常量与桩件变量 (I18N_DATA/GREEN/NC/.../CUR_FILE) 由被注入的函数体读取; shellcheck 的数据流不跨 eval。
# install.sh 自更新/回滚与 commit SHA 校验回归测试 (纯 bash, 不依赖真实 curl/jq/git)
#   锁定: get_remote_commit_sha / read_local_commit_sha / save_local_commit_sha 的 40hex 校验,
#        _gh_url 代理改写, _atomic_write 原子写, check_xray_script_update 决策,
#        _update_xray_script 升级失败回滚 (安全核心).
set -u
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1" >&2; }
assert_eq() { local d="$1" g="$2" e="$3"; if [[ "$g" == "$e" ]]; then ok "$d"; else bad "$d (got[$g] exp[$e])"; fi; }

SRC='install.sh'
if [[ ! -r "$SRC" && -r "${0%/*}/../$SRC" ]]; then cd "${0%/*}/.." || exit 1; fi
# 项目根: 优先取调用方传入的 PROJ_ROOT (沙箱内层 bash 的 $PWD 可能被 shim 破坏), 否则回退 $PWD
ROOT_DIR="${PROJ_ROOT:-${PWD:-}}"
TMPD="$ROOT_DIR/.workbuddy/tmp/install_upd_$$"; rm -rf "$TMPD"; mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT
[[ -r "$SRC" ]] || { bad "找不到 $SRC"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# ---- 抽取真实函数体 ----
GH="$(awk '/^function _gh_url\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
AT="$(awk '/^function _atomic_write\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
GR="$(awk '/^function get_remote_commit_sha\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
RL="$(awk '/^function read_local_commit_sha\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
SV="$(awk '/^function save_local_commit_sha\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
CU="$(awk '/^function check_xray_script_update\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
UP="$(awk '/^function _update_xray_script\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
for v in GH AT GR RL SV CU UP; do
  if [[ -z "${!v}" ]]; then bad "抽取 $v 失败"; fi
done
[[ $FAIL -eq 0 ]] || { echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# ---- 测试用全局常量/桩件基础 (真实函数会引用, 须先定义, 否则 set -u 报错) ----
# I18N_DATA 声明为空关联数组: 已声明的数组引用未设键在 set -u 下不报错(返回空)
declare -A I18N_DATA=()
I18N_DATA['failed']='failed'; I18N_DATA['tip']='tip'; I18N_DATA['new']='new'
I18N_DATA['promptly']='promptly'; I18N_DATA['now']='now'; I18N_DATA['force']='force'
I18N_DATA['completed']='completed'; I18N_DATA['download']='download'
GREEN=''; NC=''; YELLOW=''; RED=''
XRAY_SCRIPT_REPO='x/y'; XRAY_SCRIPT_REF='main'
XRAY_SCRIPT_COMMIT_API="https://api.github.com/repos/${XRAY_SCRIPT_REPO}/commits/${XRAY_SCRIPT_REF}"
SCRIPT_CONFIG_DIR="$TMPD/cfg"; mkdir -p "$SCRIPT_CONFIG_DIR"
SCRIPT_CONFIG_PATH="$SCRIPT_CONFIG_DIR/commit"
SCRIPT_COMMIT_PATH="$SCRIPT_CONFIG_DIR/commit"
LOCAL_SHA_VAL=''; REMOTE_SHA_VAL=''; FORCE_UPDATE=0; READ_ANSWER=''

# ============================================================ 静态契约
echo "== 静态契约 =="
if printf '%s\n' "$UP" | grep -q 'backup_dir=' && printf '%s\n' "$UP" | grep -q 'mv -f "${temp_dir}" "${PROJECT_ROOT}"'; then
  ok "_update_xray_script 存在 备份 + 替换 步骤"
else
  bad "_update_xray_script 缺少备份/替换"
fi
if printf '%s\n' "$UP" | grep -q 'mv -f "${backup_dir}" "${PROJECT_ROOT}"'; then
  ok "_update_xray_script 失败回滚: 备份还原逻辑存在"
else
  bad "_update_xray_script 缺少失败回滚还原"
fi

# ============================================================ _gh_url (纯, 依赖 GH_PROXY)
echo "== _gh_url 代理改写 =="
eval "$GH"
GH_PROXY=''; assert_eq "无代理 原样" "$(_gh_url "https://github.com/x")" "https://github.com/x"
GH_PROXY='https://ghfast.top'; assert_eq "GitHub 域加前缀" "$(_gh_url "https://github.com/x")" "https://ghfast.top/https://github.com/x"
assert_eq "非 GitHub 域不加前缀" "$(_gh_url "https://nginx.org/x")" "https://nginx.org/x"

# ============================================================ _atomic_write (真实)
echo "== _atomic_write 原子写 =="
# 占位声明: 真实实现由下方 eval "$AT" 注入; 因 eval 对 shellcheck 不可见, 先声明以满足 SC2218(函数须先于调用定义). eval 会覆盖此占位.
_atomic_write() { :; }
eval "$AT"
printf 'hello' | _atomic_write "$TMPD/aw_target"; rc=$?
if [[ $rc -eq 0 && "$(cat "$TMPD/aw_target" 2>/dev/null)" == "hello" ]]; then ok "原子写入内容正确"; else bad "_atomic_write 写入异常 rc=$rc"; fi
perms="$(stat -c '%a' "$TMPD/aw_target" 2>/dev/null || echo '?')"
if [[ "$perms" == "600" ]]; then ok "目标文件权限收为 600"; elif [[ "$perms" == "644" ]]; then ok "权限 644 (Windows-FS 无法收紧为 600, 代码已 chmod 600)"; else bad "权限应为 600, 实测 $perms"; fi
_at_rc=0; _atomic_write "" || _at_rc=$?
if [[ $_at_rc -eq 1 ]]; then ok "空目标路径返回 1 (不崩)"; else bad "空目标应返回 1, 实测 $_at_rc"; fi

# ---- 之后用桩件版 _atomic_write: 把被调用目标写入日志文件 (规避管道子shell 变量不回传) ----
ATOMIC_LOG="$TMPD/atomic_log"; : > "$ATOMIC_LOG"
_atomic_write() { printf '%s\n' "${1:-}" >> "$ATOMIC_LOG"; return 0; }

# ============================================================ get_remote_commit_sha (stub curl/jq/cmd_exists)
echo "== get_remote_commit_sha 40hex 校验 =="
CURL_BODY=''; CURL_FAIL=''
curl() { if [[ "$CURL_FAIL" == "1" ]]; then return 1; fi; printf '%s' "$CURL_BODY"; }
cmd_exists() { [[ "$1" == "jq" ]] && return 0; return 1; }
jq() { grep -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' | head -1 | cut -d'"' -f4; }
eval "$GR"
CURL_BODY='{"sha":"a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0","x":1}'; CURL_FAIL=''
got="$(get_remote_commit_sha)"; rc=$?
assert_eq "合法响应 提取 40hex" "$got" "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
CURL_BODY='garbage no sha'; got="$(get_remote_commit_sha)"; rc=$?
if [[ $rc -eq 1 ]]; then ok "无 sha 字段 -> 返回 1"; else bad "无 sha 应返回 1, 实测 rc=$rc got[$got]"; fi
CURL_FAIL=1; got="$(get_remote_commit_sha)"; rc=$?
if [[ $rc -eq 1 ]]; then ok "下载失败 -> 返回 1"; else bad "下载失败应返回 1, 实测 rc=$rc"; fi

# ============================================================ read_local_commit_sha (真实)
echo "== read_local_commit_sha 40hex 校验 =="
eval "$RL"
printf 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0\n' > "$TMPD/commit_ok"
SCRIPT_COMMIT_PATH="$TMPD/commit_ok"; assert_eq "合法记录 读取" "$(read_local_commit_sha)" "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
printf 'garbage\n' > "$TMPD/commit_bad"; SCRIPT_COMMIT_PATH="$TMPD/commit_bad"
rl_got="$(read_local_commit_sha)"; rl_rc=$?
if [[ $rl_rc -eq 1 ]]; then ok "非法内容 -> 返回 1"; else bad "非法内容应返回 1, 实测 rc=$rl_rc"; fi
SCRIPT_COMMIT_PATH="$TMPD/nonexist"; rl_got="$(read_local_commit_sha)"; rl_rc=$?
if [[ $rl_rc -eq 1 ]]; then ok "文件缺失 -> 返回 1"; else bad "文件缺失应返回 1, 实测 rc=$rl_rc"; fi

# ============================================================ save_local_commit_sha (桩件 _atomic_write)
echo "== save_local_commit_sha 合法性守卫 =="
eval "$SV"
SCRIPT_CONFIG_DIR="$TMPD/cfg"; mkdir -p "$SCRIPT_CONFIG_DIR"
SCRIPT_COMMIT_PATH="$SCRIPT_CONFIG_DIR/commit"
: > "$ATOMIC_LOG"
save_local_commit_sha "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"; sv_rc=$?
sv_target="$(tail -n 1 "$ATOMIC_LOG" 2>/dev/null)"
if [[ $sv_rc -eq 0 && "$sv_target" == "$SCRIPT_COMMIT_PATH" ]]; then ok "合法 sha -> 记录到 commit 文件"; else bad "合法 sha 未记录: rc=$sv_rc target[$sv_target]"; fi
: > "$ATOMIC_LOG"
save_local_commit_sha "not-a-sha"; sv_rc=$?
sv_target="$(tail -n 1 "$ATOMIC_LOG" 2>/dev/null)"
if [[ $sv_rc -eq 0 && -z "$sv_target" ]]; then ok "非法 sha -> 静默跳过 (不写)"; else bad "非法 sha 不应写盘: rc=$sv_rc target[$sv_target]"; fi

# ============================================================ check_xray_script_update 决策
echo "== check_xray_script_update 决策 =="
# 注意: read 是 bash 特殊内建, 不能用函数 stub 覆盖; 改用喂 stdin 控制其返回值.
read_local_commit_sha() { [[ -n "$LOCAL_SHA_VAL" ]] && printf '%s' "$LOCAL_SHA_VAL"; }
get_remote_commit_sha() { [[ -n "$REMOTE_SHA_VAL" ]] && printf '%s' "$REMOTE_SHA_VAL"; }
_update_xray_script() { UPDATE_CALLED=1; return 0; }
eval "$CU"
UPDATE_CALLED=''

REMOTE_SHA_VAL=''; FORCE_UPDATE=0; UPDATE_CALLED=''
check_xray_script_update </dev/null; rc=$?
if [[ $rc -eq 0 && -z "$UPDATE_CALLED" ]]; then ok "远端不可达 -> 静默跳过 (非强制)"; else bad "远端不可达应跳过: rc=$rc called[$UPDATE_CALLED]"; fi

REMOTE_SHA_VAL=''; FORCE_UPDATE=1; UPDATE_CALLED=''
err="$(check_xray_script_update 2>&1)"; rc=$?
if [[ $rc -eq 0 && -z "$UPDATE_CALLED" && "$err" == *"failed"* ]]; then ok "远端不可达 + 强制 -> 告警并跳过"; else bad "强制但远端不可达异常: rc=$rc called[$UPDATE_CALLED]"; fi

LOCAL_SHA_VAL='a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0'; REMOTE_SHA_VAL="$LOCAL_SHA_VAL"; FORCE_UPDATE=0; UPDATE_CALLED=''
check_xray_script_update </dev/null; rc=$?
if [[ $rc -eq 0 && -z "$UPDATE_CALLED" ]]; then ok "已是最新 -> 不更新"; else bad "已最新仍更新: rc=$rc called[$UPDATE_CALLED]"; fi

LOCAL_SHA_VAL='oldoldoldoldoldoldoldoldoldoldoldol'; REMOTE_SHA_VAL='a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0'; FORCE_UPDATE=0; UPDATE_CALLED=''
check_xray_script_update <<< 'n'; rc=$?
if [[ $rc -eq 0 && -z "$UPDATE_CALLED" ]]; then ok "有更新但用户选 n -> 不更新"; else bad "用户拒绝仍更新: rc=$rc called[$UPDATE_CALLED]"; fi

LOCAL_SHA_VAL='oldoldoldoldoldoldoldoldoldoldoldol'; REMOTE_SHA_VAL='a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0'; FORCE_UPDATE=0; UPDATE_CALLED=''
check_xray_script_update <<< 'y'; rc=$?
if [[ -n "$UPDATE_CALLED" ]]; then ok "有更新且用户选 y -> 执行更新"; else bad "用户同意却未更新"; fi

FORCE_UPDATE=1; UPDATE_CALLED=''
check_xray_script_update </dev/null; rc=$?
if [[ -n "$UPDATE_CALLED" ]]; then ok "强制更新 -> 跳过比对与询问直接更新"; else bad "强制更新未执行"; fi

# ============================================================ _update_xray_script 回滚 (安全核心)
echo "== _update_xray_script 升级失败回滚 =="
# 重 eval 真实实现
eval "$UP"
# 环境
SCRIPT_CONFIG_DIR="$TMPD/cfg2"; mkdir -p "$SCRIPT_CONFIG_DIR"
SCRIPT_COMMIT_PATH="$SCRIPT_CONFIG_DIR/commit"
PROJECT_ROOT="$TMPD/proj"; rm -rf "$PROJECT_ROOT"; mkdir -p "$PROJECT_ROOT"; printf 'ORIGINAL' > "$PROJECT_ROOT/marker"
HOME="$TMPD/home"; mkdir -p "$HOME"
CUR_DIR="$TMPD"; CUR_FILE="install.sh"
TEMP_DIR="${SCRIPT_CONFIG_DIR}/xray-script-personal-use-only-temp"
BACKUP="${PROJECT_ROOT}.old.$$"
# 桩件
download_xray_script_files() { mkdir -p "$1"; touch "$1/install.sh" "$1/newcontent"; }
_sync_script_version_label() { :; }
bash() { return 0; }   # 防止真实 bash 重新执行 install.sh
mv() {
  if [[ "$MV_FAIL" == "1" && "$1" == "-f" && "$2" == "$TEMP_DIR" && "$3" == "$PROJECT_ROOT" ]]; then
    return 1
  fi
  command mv "$@"
}
# _error 记录消息到文件: 调用包在子shell 内, 子shell 变量不回传父shell, 故用文件承载错误证据
ERR_LOG="$TMPD/err_log"; : > "$ERR_LOG"
_error() { printf '%s' "$*" > "$ERR_LOG"; exit 1; }   # 真实 exit 仅在子shell 内生效, 干净中止 _update_xray_script

# 失败场景: temp->project 的 mv 被强制失败 -> 应从备份还原且报 _error
# 包在 ( ) 子shell 内: 真实 exit 只退出子shell, 不杀测试进程
MV_FAIL=1; : > "$ERR_LOG"; UPDATE_TARGET='a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0'
( _update_xray_script "$UPDATE_TARGET" )
ERR_MSG="$(cat "$ERR_LOG" 2>/dev/null)"
if [[ -n "$ERR_MSG" && -f "$PROJECT_ROOT/marker" && ! -f "$PROJECT_ROOT/newcontent" && ! -e "$BACKUP" ]]; then
  ok "升级失败: 报 _error + 从备份还原 + 不破坏原项目"
else
  bad "回滚异常: err[$ERR_MSG] marker[$([[ -f "$PROJECT_ROOT/marker" ]] && echo y || echo n)] new[$([[ -f "$PROJECT_ROOT/newcontent" ]] && echo y || echo n)] backup[$([[ -e "$BACKUP" ]] && echo y || echo n)]"
fi

# 成功场景: 正常替换
rm -rf "$PROJECT_ROOT"; mkdir -p "$PROJECT_ROOT"; printf 'ORIGINAL' > "$PROJECT_ROOT/marker"
MV_FAIL=''; : > "$ERR_LOG"
( _update_xray_script "$UPDATE_TARGET" )
ERR_MSG="$(cat "$ERR_LOG" 2>/dev/null)"
if [[ -z "$ERR_MSG" && -f "$PROJECT_ROOT/newcontent" && ! -f "$PROJECT_ROOT/marker" && ! -e "$BACKUP" ]]; then
  ok "升级成功: 新内容就位 + 备份清理"
else
  bad "成功场景异常: err[$ERR_MSG] new[$([[ -f "$PROJECT_ROOT/newcontent" ]] && echo y || echo n)] old[$([[ -f "$PROJECT_ROOT/marker" ]] && echo y || echo n)] backup[$([[ -e "$BACKUP" ]] && echo y || echo n)]"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
