#!/usr/bin/env bash
# =============================================================================
# 测试名称: nginx_attach_inject_test.sh
# 测试目标: 锁定「接入既有 Nginx」的注入行为 —— 往一个**别人的** nginx.conf 里追加
#           受管 include, 且一个字节的现有配置都不能改动或丢失。
#
# 背景: 目标 nginx.conf 是生产文件。一旦注入写坏, 面板/站点会整体起不来。本用例用一份
#       真实的面板配置 (宝塔风格: `http` 与 `{` 分作两行、一级 stream 块自带 include、
#       http 块内有一个 listen 888 的 server) 当夹具, 逐条验证:
#         - main 上下文的 include 追加在文件末尾 (那时所有一级块已闭合);
#         - http 上下文的 include 插在 http 块开口之后;
#         - 原有行一条不少、顺序不变;
#         - 幂等 (第二次注入不改动文件, 靠受管标记);
#         - 注入前留原始备份, 且备份不被"已注入版"覆盖;
#         - 找不到 http 块时整体失败且**不留下半成品**。
#
# 覆盖:
#   S1 静态 —— 函数存在, 且判据/标记齐备 (受管标记、grep -qF 幂等、cp -p 备份、nginx -t 自检);
#   B1 行为 —— 注入结果: 两处 include 位置正确、原有内容零丢失;
#   B2 行为 —— 幂等: 二次注入内容逐字节不变;
#   B3 行为 —— 备份: 备份内容等于注入前原文;
#   B4 行为 —— 无 http 块时返回非 0 且文件未被改动;
#   NEG 负向 —— 去掉幂等判据后 B2 必须变红 (用 cmp 校验变异落地)。
#
# 运行: bash test/nginx_attach_inject_test.sh
# =============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s%s\n' "$1" "${2:+ ($2)}"; }
assert_eq() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got=$(printf '%q' "$2") want=$(printf '%q' "$3")"; fi
}
assert_contains() {
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing $(printf '%q' "$3")"; fi
}
assert_not_contains() {
    if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "unexpected $(printf '%q' "$3")"; fi
}

SB="$ROOT/.workbuddy/tmp/nginx_attach_inject.$$"
rm -rf "$SB" 2>/dev/null || true
mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

fn_of() { # $1=file $2=fn
    awk -v fn="$2" 'index($0, "function " fn "() {") == 1 { f=1 } f { print } f && /^}$/ { exit }' "$1"
}

# 受管标记: 从源码抽真实值, 不在测试里另抄一份 (抄的那份一旦与实现漂移, 断言就恒绿)
MARK="$(sed -n "s/^readonly NGINX_ATTACH_MARK='\\(.*\\)'\$/\\1/p" core/handler.sh | head -1 || true)"
assert_eq "S1: 抽到受管标记常量" "$([[ -n "${MARK}" ]] && printf 'yes' || printf 'no')" "yes"

FN="$(fn_of core/handler.sh nginx_attach_inject_includes)"
if [[ -z "${FN}" ]]; then
    bad "S1: 抽取 nginx_attach_inject_includes 为空"
    echo "==== nginx_attach_inject_test: PASS=$PASS FAIL=$FAIL ===="
    exit 1
fi

# ---------------------------------------------------------------------------
echo "[S1] 静态: 注入函数的关键判据"
# ---------------------------------------------------------------------------
assert_contains "S1: 幂等靠 grep -qF 标记" "$FN" 'grep -qF "${NGINX_ATTACH_MARK}"'
assert_contains "S1: 注入前备份用 cp -p" "$FN" 'cp -p "${conf}" "${bak}"'
assert_contains "S1: 写回保留原文件属性 (cat 而非 mv)" "$FN" 'cat "${new_conf}" > "${conf}"'
assert_contains "S1: 写完用目标 nginx 自检" "$FN" '"${bin}" -t'
assert_contains "S1: 自检失败即从备份还原" "$FN" 'cp -p "${bak}" "${conf}"'
assert_contains "S1: 未找到 http 块时整体失败" "$FN" 'exit 3'

# ---------------------------------------------------------------------------
# 夹具: 一份真实的面板型 nginx.conf (宝塔风格)
# ---------------------------------------------------------------------------
FIXDIR="$SB/conf"
mkdir -p "$FIXDIR"
CONF="$FIXDIR/nginx.conf"
cat > "$CONF" <<'NGINXCONF'
user  www www;
worker_processes auto;
error_log  /www/wwwlogs/nginx_error.log  crit;
pid        /www/server/nginx/logs/nginx.pid;
worker_rlimit_nofile 51200;

stream {
    log_format tcp_format '$time_local|$remote_addr|$protocol';
    access_log /www/wwwlogs/tcp-access.log tcp_format;
    include /www/server/panel/vhost/nginx/tcp/*.conf;
}

events
{
    use epoll;
    worker_connections 51200;
}

http
{
    include       mime.types;
    include proxy.conf;
    lua_package_path "/www/server/nginx/lib/lua/?.lua;;";
    default_type  application/octet-stream;
    client_max_body_size 50m;
    gzip on;
    gzip_types text/plain application/javascript text/css application/json;

    server
    {
        listen 888;
        server_name phpmyadmin;
        root  /www/server/phpmyadmin;
        location ~ /\.
        {
            deny all;
        }
    }
    include /www/server/panel/vhost/nginx/*.conf;
}
NGINXCONF
cp -p "$CONF" "$SB/orig.conf"

# ---------------------------------------------------------------------------
# runner: 注入真实函数体
# ---------------------------------------------------------------------------
RUNNER="$SB/runner.sh"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' "NGINX_CONFIG_DIR='${FIXDIR}'"
    printf '%s\n' '_i18n() { printf "%s" "$1"; }'
    printf '%s\n' '_i18n_sub() { printf "%s" "$1"; }'
    printf '%s\n' 'print_info() { printf "INFO %s\n" "$*" >&2; }'
    printf '%s\n' 'print_warn() { printf "WARN %s\n" "$*" >&2; }'
    # 指向不存在的二进制 -> 跳过 nginx -t 自检 (沙箱里没有 nginx)
    printf '%s\n' '_nginx_binary() { printf "%s" "/nonexistent/nginx"; }'
    printf '%s\n' "readonly NGINX_ATTACH_MARK='${MARK}'"
    printf '%s\n' "$FN"
    printf '%s\n' 'rc=0'
    printf '%s\n' 'nginx_attach_inject_includes "$1" || rc=$?'
    printf '%s\n' 'printf "RC=%s\n" "${rc}"'
} > "$RUNNER"

run_inject() { # $1=conf 路径 -> stdout 含 RC= 行; stderr 是报告
    bash "$RUNNER" "$1" 2>&1
}

# ---------------------------------------------------------------------------
echo "[B1] 行为: 注入结果与内容保全"
# ---------------------------------------------------------------------------
out1="$(run_inject "$CONF")"
assert_contains "B1: 首次注入成功 (RC=0)" "$out1" 'RC=0'

new_content="$(cat "$CONF")"
assert_contains "B1: main 上下文 include 已追加 (modules-enabled)" "$new_content" "include ${FIXDIR}/modules-enabled/*.conf;"
assert_contains "B1: http 上下文 include 已插入 (conf.d)" "$new_content" "include ${FIXDIR}/conf.d/*.conf;"
assert_contains "B1: http 上下文 include 已插入 (sites-enabled)" "$new_content" "include ${FIXDIR}/sites-enabled/*;"
assert_contains "B1: 标记同时出现在两处挂载点" "$new_content" "${MARK}"

# 原有配置一条不许少 —— 这是本特性最核心的安全性质
for needle in 'user  www www;' 'error_log  /www/wwwlogs/nginx_error.log  crit;' \
    'include /www/server/panel/vhost/nginx/tcp/*.conf;' 'listen 888;' \
    'include proxy.conf;' 'lua_package_path "/www/server/nginx/lib/lua/?.lua;;";' \
    'include /www/server/panel/vhost/nginx/*.conf;' 'gzip_types text/plain'; do
    assert_contains "B1: 原有行保全 -> ${needle}" "$new_content" "$needle"
done

# include 的**插入位置**要对: main 那条必须在 stream/events/http 三个块之后
line_last_http_close="$(grep -n '^}$' "$CONF" | tail -1 | cut -d: -f1)"
line_main_inc="$(grep -n "include ${FIXDIR}/modules-enabled" "$CONF" | tail -1 | cut -d: -f1)"
if [[ -n "${line_last_http_close}" && -n "${line_main_inc}" && "${line_main_inc}" -gt "${line_last_http_close}" ]]; then
    ok "B1: main 的 include 落在所有一级块闭合之后 (确实是 main 上下文)"
else
    bad "B1: main 的 include 位置不对" "inc=${line_main_inc:-空} last_close=${line_last_http_close:-空}"
fi
# http 的那些必须落在 http 块内部 (位于 http 开口之后、最后一个 } 之前)
line_http_open="$(grep -n '^http$' "$CONF" | head -1 | cut -d: -f1)"
line_http_cd="$(grep -n "include ${FIXDIR}/conf.d" "$CONF" | head -1 | cut -d: -f1)"
if [[ -n "${line_http_open}" && -n "${line_http_cd}" && "${line_http_cd}" -gt "${line_http_open}" && "${line_http_cd}" -lt "${line_last_http_close}" ]]; then
    ok "B1: http 的 include 落在 http 块内部"
else
    bad "B1: http 的 include 位置不对" "open=${line_http_open:-空} inc=${line_http_cd:-空} close=${line_last_http_close:-空}"
fi

# ---------------------------------------------------------------------------
echo "[B2] 行为: 幂等 (二次注入内容逐字节不变)"
# ---------------------------------------------------------------------------
cp -p "$CONF" "$SB/after_first.conf"
out2="$(run_inject "$CONF")"
assert_contains "B2: 二次注入仍成功返回" "$out2" 'RC=0'
assert_contains "B2: 二次注入走的是 already 分支" "$out2" '.handler.nginx.attach_already'
if cmp -s "$SB/after_first.conf" "$CONF"; then
    ok "B2: 二次注入未改动文件 (逐字节相同)"
else
    bad "B2: 二次注入改动了文件 (幂等失效)"
fi

# ---------------------------------------------------------------------------
echo "[B3] 行为: 备份"
# ---------------------------------------------------------------------------
BAK="${CONF}.xray-script.bak"
if [[ -f "$BAK" ]]; then
    ok "B3: 生成了原始配置备份"
    if cmp -s "$SB/orig.conf" "$BAK"; then
        ok "B3: 备份内容等于注入前原文"
    else
        bad "B3: 备份内容与原文不一致"
    fi
else
    bad "B3: 未生成备份文件"
fi

# ---------------------------------------------------------------------------
echo "[B4] 行为: 找不到 http 块时整体失败且不改动"
# ---------------------------------------------------------------------------
NOHTTP="$SB/nohttp/nginx.conf"
mkdir -p "$(dirname "$NOHTTP")"
# 只有 main 上下文, 没有任何 http 块
printf '%s\n' 'user www;' 'events' '{' '    worker_connections 512;' '}' > "$NOHTTP"
cp -p "$NOHTTP" "$SB/nohttp.orig"
out4="$(run_inject "$NOHTTP")"
assert_contains "B4: 无 http 块 -> 返回非 0" "$out4" 'RC=1'
assert_contains "B4: 无 http 块 -> 提示 no_http_block" "$out4" '.handler.nginx.attach_no_http_block'
if cmp -s "$SB/nohttp.orig" "$NOHTTP"; then
    ok "B4: 失败时目标文件未被改动 (不留半成品)"
else
    bad "B4: 失败时文件被改了 (留下半成品)"
fi
if [[ ! -e "${NOHTTP}.xray-script.new" ]]; then
    ok "B4: 失败时清理了临时文件"
else
    bad "B4: 失败时残留了 .new 临时文件"
fi

# ---------------------------------------------------------------------------
echo "[B5] 行为: Brotli 能力对齐 (外部 Nginx 大多没编这个第三方模块)"
# ---------------------------------------------------------------------------
# general.conf 被三份站点模板共同 include, 里面有 brotli 指令。目标 Nginx 若没编
# ngx_brotli, 照搬过去会让站点配置一加载就 unknown directive、整份配置被拒。
COMMON_SH="core/_common.sh"
assert_contains "S1: align_general_brotli 存在且按能力判定" \
    "$(fn_of core/handler.sh align_general_brotli)" '_nginx_supports_brotli'

make_fake_nginx() { # $1=prefix $2=configure arguments
    mkdir -p "$1/sbin"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'if [[ "${1:-}" == "-V" ]]; then'
        printf '%s\n' "    printf 'configure arguments: $2\n' >&2"
        printf '%s\n' 'fi'
        printf '%s\n' 'exit 0'
    } > "$1/sbin/nginx"
    chmod +x "$1/sbin/nginx"
}

make_general() { # $1=目标文件
    {
        printf '%s\n' '# 本项目提供的通用段'
        printf '%s\n' 'charset utf-8;'
        printf '%s\n' 'brotli            on;'
        printf '%s\n' 'brotli_comp_level 6;'
        printf '%s\n' 'brotli_types      text/plain text/css;'
        printf '%s\n' 'gzip on;'
    } > "$1"
}

run_align() { # $1=假 nginx 前缀 $2=general.conf 路径
    local b="$1" gen="$2" runner="$SB/runner_align.sh"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' '_i18n() { printf "%s" "$1"; }'
        printf '%s\n' '_i18n_sub() { printf "%s" "$1"; }'
        printf '%s\n' 'print_info() { printf "INFO %s\n" "$*" >&2; }'
        printf '%s\n' "_nginx_binary() { printf '%s' '${b}/sbin/nginx'; }"
        fn_of "$COMMON_SH" '_nginx_supports_brotli'
        fn_of core/handler.sh 'align_general_brotli'
        printf '%s\n' 'align_general_brotli "$1"'
    } > "$runner"
    bash "$runner" "$gen" 2>&1
}

GEN_NOBROTLI="$SB/gen-nobrotli/general.conf"
mkdir -p "$(dirname "$GEN_NOBROTLI")"
make_fake_nginx "$SB/nx-nobrotli" '--with-stream --with-http_v3_module'
make_general "$GEN_NOBROTLI"
run_align "$SB/nx-nobrotli" "$GEN_NOBROTLI" >/dev/null 2>&1 || true
gen_after="$(cat "$GEN_NOBROTLI")"
assert_not_contains "B5: 目标无 Brotli 时已剥掉 brotli 指令" "$gen_after" 'brotli            on;'
assert_not_contains "B5: 目标无 Brotli 时已剥掉 brotli_comp_level" "$gen_after" 'brotli_comp_level'
assert_contains "B5: 剥离后其余内容原样保留 (charset)" "$gen_after" 'charset utf-8;'
assert_contains "B5: 剥离后其余内容原样保留 (gzip)" "$gen_after" 'gzip on;'

GEN_BROTLI="$SB/gen-brotli/general.conf"
mkdir -p "$(dirname "$GEN_BROTLI")"
make_fake_nginx "$SB/nx-brotli" '--add-module=/src/ngx_brotli'
make_general "$GEN_BROTLI"
run_align "$SB/nx-brotli" "$GEN_BROTLI" >/dev/null 2>&1 || true
assert_contains "B5: 目标有 Brotli 时原样保留 (不误删)" "$(cat "$GEN_BROTLI")" 'brotli            on;'

# ---------------------------------------------------------------------------
echo "[NEG] 负向: 去掉幂等判据后 B2 必须变红"
# ---------------------------------------------------------------------------
sed 's|if grep -qF "${NGINX_ATTACH_MARK}" "${conf}"; then|if false; then|' core/handler.sh > "$SB/handler_neg.sh"
if cmp -s core/handler.sh "$SB/handler_neg.sh"; then
    bad "NEG: 变异未落地 (没匹配到幂等判据行)"
else
    ok "NEG: 变异已落地"
    NEG_RUNNER="$SB/runner_neg.sh"
    NEG_FIXDIR="$SB/negconf"
    mkdir -p "$NEG_FIXDIR"
    cp -p "$SB/orig.conf" "$NEG_FIXDIR/nginx.conf"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' "NGINX_CONFIG_DIR='${NEG_FIXDIR}'"
        printf '%s\n' '_i18n() { printf "%s" "$1"; }'
        printf '%s\n' '_i18n_sub() { printf "%s" "$1"; }'
        printf '%s\n' 'print_info() { :; }'
        printf '%s\n' 'print_warn() { :; }'
        printf '%s\n' '_nginx_binary() { printf "%s" "/nonexistent/nginx"; }'
        printf '%s\n' "readonly NGINX_ATTACH_MARK='${MARK}'"
        printf '%s\n' "$(fn_of "$SB/handler_neg.sh" nginx_attach_inject_includes)"
        printf '%s\n' 'rc=0'
        printf '%s\n' 'nginx_attach_inject_includes "$1" || rc=$?'
        printf '%s\n' 'printf "RC=%s\n" "${rc}"'
    } > "$NEG_RUNNER"
    bash "$NEG_RUNNER" "$NEG_FIXDIR/nginx.conf" >/dev/null 2>&1 || true
    cp -p "$NEG_FIXDIR/nginx.conf" "$SB/neg_after_first.conf"
    bash "$NEG_RUNNER" "$NEG_FIXDIR/nginx.conf" >/dev/null 2>&1 || true
    if cmp -s "$SB/neg_after_first.conf" "$NEG_FIXDIR/nginx.conf"; then
        bad "NEG: 破损版的二次注入仍未改动文件 —— 说明 B2 判据恒真, 测不出幂等失效"
    else
        ok "NEG: 破损版二次注入确实重复插入了 (B2 判据有效)"
    fi
fi

echo
echo "==== nginx_attach_inject_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
