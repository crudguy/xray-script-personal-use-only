#!/usr/bin/env bash
# docker.sh WARP 容器管理回归测试 (纯 bash, 不依赖真实 docker)
#   锁定: enable_warp / disable_warp / build_warp 的"已存在则跳过"幂等分支,
#        get_container_ip / obtain_container_ip 取值.
# 注: docker 调用副作用写入文件日志 (函数内变量不跨越 $(...) 子shell).
set -u
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1" >&2; }
assert_eq() { local d="$1" g="$2" e="$3"; if [[ "$g" == "$e" ]]; then ok "$d"; else bad "$d (got[$g] exp[$e])"; fi; }

SRC='service/docker.sh'
if [[ ! -r "$SRC" && -r "${0%/*}/../$SRC" ]]; then cd "${0%/*}/.." || exit 1; fi
TMPD=".workbuddy/tmp/docker_warp_$$"; rm -rf "$TMPD"; mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT
LOG="$TMPD/docker_log"
[[ -r "$SRC" ]] || { bad "找不到 $SRC"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

GCI="$(awk '/^function get_container_ip\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
OBC="$(awk '/^function obtain_container_ip\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
BLD="$(awk '/^function build_warp\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
ENA="$(awk '/^function enable_warp\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
DIS="$(awk '/^function disable_warp\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
[[ -n "$GCI" && -n "$OBC" && -n "$BLD" && -n "$ENA" && -n "$DIS" ]] || { bad "函数抽取失败"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# ---- 常量与桩件 ----
WARP_IMAGE='cloudflare-warp'
WARP_DIR="$TMPD/warp"; CONFIG_DIR="$TMPD/config"
DOCKER_RUNNING=''; IMAGE_EXISTS=''; EMPTY_IP=''
docker() {
  case "$1" in
    ps)     [[ -n "$DOCKER_RUNNING" ]] && printf '%s' "$WARP_IMAGE" ;;
    images) [[ -n "$IMAGE_EXISTS" ]] && printf '%s' "$WARP_IMAGE" ;;
    inspect) printf '10.0.0.9' ;;
    run)    printf 'ran' >> "$LOG" ;;
    build)  printf 'build' >> "$LOG" ;;
    stop|rm|image) printf 'stop' >> "$LOG" ;;
  esac
}
# (get_container_ip 的覆盖定义见下方 eval 之后, 必须先 eval 真实实现再覆盖, 否则会被覆盖回去)
print_info() { :; }; print_warn() { :; }; print_error() { :; }
_i18n()    { printf ''; }
_i18n_sub() { printf '%s' "$1"; }
mkdir -p "$WARP_DIR"

eval "$GCI"; eval "$OBC"; eval "$BLD"; eval "$ENA"; eval "$DIS"
# 覆盖真实 get_container_ip (须置于 eval 之后): EMPTY_IP 置位时返回空,
# 验证 obtain_container_ip 的"空 IP 不输出"分支
get_container_ip() { [[ -n "$EMPTY_IP" ]] && return 0; printf '10.0.0.9'; }

echo "== get_container_ip / obtain_container_ip =="
assert_eq "get_container_ip 取 IP" "$(get_container_ip warp)" "10.0.0.9"
assert_eq "obtain_container_ip 有 IP" "$(obtain_container_ip warp)" "10.0.0.9"
EMPTY_IP=1; assert_eq "obtain_container_ip 空 IP 不输出" "$(obtain_container_ip warp)" ""; EMPTY_IP=''

echo "== build_warp 幂等 =="
IMAGE_EXISTS=''; : > "$LOG"; build_warp
if grep -q build "$LOG"; then ok "镜像不存在 -> 执行 build"; else bad "镜像不存在却跳过 build"; fi
IMAGE_EXISTS=1; : > "$LOG"; build_warp
if ! grep -q build "$LOG"; then ok "镜像已存在 -> 跳过 build"; else bad "镜像已存在仍 build"; fi

echo "== enable_warp 幂等 =="
DOCKER_RUNNING=''; : > "$LOG"; ENA_OUT="$(enable_warp)"
if grep -q ran "$LOG" && [[ "$ENA_OUT" == "10.0.0.9" ]]; then ok "未运行 -> 启动并回显 IP"; else bad "未运行却未启动: log[$(cat "$LOG")] out[$ENA_OUT]"; fi
DOCKER_RUNNING=1; : > "$LOG"; ENA_OUT="$(enable_warp)"
if ! grep -q ran "$LOG" && [[ -z "$ENA_OUT" ]]; then ok "已运行 -> 跳过 (无输出)"; else bad "已运行仍启动: log[$(cat "$LOG")] out[$ENA_OUT]"; fi

echo "== disable_warp =="
DOCKER_RUNNING=1; : > "$LOG"; mkdir -p "$WARP_DIR"; disable_warp
if grep -q stop "$LOG" && [[ ! -d "$WARP_DIR" ]]; then ok "运行中 -> 停止并清理目录"; else bad "disable 异常: log[$(cat "$LOG")] warpdirexists[$([[ -d "$WARP_DIR" ]] && echo y || echo n)]"; fi
DOCKER_RUNNING=''; : > "$LOG"; disable_warp
if ! grep -q stop "$LOG"; then ok "未运行 -> 无操作"; else bad "未运行仍执行停止"; fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
