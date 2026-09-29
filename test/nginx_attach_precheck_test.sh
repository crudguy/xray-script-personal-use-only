#!/usr/bin/env bash
# =============================================================================
# 测试名称: nginx_attach_precheck_test.sh
# 测试目标: 锁定「Nginx 归属判定」与「SNI 安装前置预检」这两条边界 ——
#           它们是"机器上已有别的 Nginx"这一场景的全部安全网。
#
# 背景 (两个真实缺陷):
#   1) 归属判定与"目标前缀"耦合: is_local_nginx_installed 原先走 _nginx_binary(),
#      而后者跟随可被外部预设的 NGINX_PREFIX_DIR。一旦把目标指到 /www/server/nginx,
#      该函数就会把"外部 Nginx 存在"误读成"本项目版已就位", 接着 handler_nginx_config
#      会对它执行整份接管式部署 (mv 主配置 + cp -af 覆盖) —— 等于删掉人家原有的配置。
#      "是不是本项目编译的"只能由**固定前缀** NGINX_BUILTIN_PREFIX 回答。
#   2) 静默半成品: 本项目版未就位、系统上已有别的 Nginx 时, handler_nginx_install
#      段三打一句告警就 return 0, 而调用方继续跑 --xray-config / --restart / --share,
#      用户拿到一个连不上的分享链接 (Xray 在 unix socket 等, 443 上无人转发)。
#      现在由菜单层预检拦下, 并把目标那份的体检结果打出来。
#
# 覆盖:
#   S1 静态 —— 三个能力探测函数存在, 且判据子串正确 (brotli / with-stream +
#              with-stream_ssl_preread_module / with-http_v3_module);
#   S2 静态 —— NGINX_PREFIX_DIR 走 `: "${VAR:=默认}"` 且另有固定前缀常量;
#   S3 静态 —— is_local_nginx_installed 不再引用 _nginx_binary;
#   B1 行为 —— 假 nginx 二进制喂不同 -V: 三项能力判定必须与编译参数一致;
#   B2 行为 —— nginx_target_report 打出目标路径/归属/版本/三项能力, 且缺命脉时报 blocked;
#   B3 行为 —— nginx_detect_external_prefix 从 PATH 软链正确反推前缀, 形态陌生时失败;
#   B4 行为 —— handler_nginx_precheck 三种场景返回码 (本项目版就位=0 / 无 nginx=0 /
#              有外部 nginx=1 且已打印体检报告);
#   NEG 负向 —— 去掉命脉判据里的 with-stream_ssl_preread_module 后 B1 必须变红, 用 cmp 自证变异落地。
#
# 运行: bash test/nginx_attach_precheck_test.sh
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

SB="$ROOT/.workbuddy/tmp/nginx_attach.$$"
rm -rf "$SB" 2>/dev/null || true
mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

# 抽真实函数体。用 index()==1 而不是 `$0 == "function X() {"` —— 后者对带行尾注释的
# 定义行 (如 `function _nginx_supports_http3() { # $1=...`) 会静默抽不到, 得到空串。
fn_of() { # $1=file $2=fn
    awk -v fn="$2" 'index($0, "function " fn "() {") == 1 { f=1 } f { print } f && /^}$/ { exit }' "$1"
}

# 造一个只认 -V 的假 nginx 二进制; $2 = configure arguments 原文
make_fake_nginx() { # $1=prefix $2=features
    mkdir -p "$1/sbin" "$1/conf"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'if [[ "${1:-}" == "-V" ]]; then'
        printf '%s\n' '    printf "nginx version: nginx/1.29.4\n" >&2'
        printf '%s\n' "    printf 'configure arguments: $2\n' >&2"
        printf '%s\n' 'fi'
        printf '%s\n' 'exit 0'
    } > "$1/sbin/nginx"
    chmod +x "$1/sbin/nginx"
    # 同源校验要求 <prefix>/conf/nginx.conf 也存在 (二进制与配置在同一棵树里) ——
    # 这正是"面板装法/手动编译"与"发行版包/容器化"的分界判据。
    : > "$1/conf/nginx.conf"
}

FULL='--with-stream --with-stream_ssl_preread_module --with-http_v3_module --add-module=/src/ngx_brotli'
NOPREREAD='--with-http_v3_module --add-module=/src/ngx_brotli'

FAKE_FULL="$SB/nx-full"
FAKE_NOPRE="$SB/nx-nopre"
make_fake_nginx "$FAKE_FULL" "$FULL"
make_fake_nginx "$FAKE_NOPRE" "$NOPREREAD"
# 模拟"本项目版未就位": 固定前缀下不放任何二进制
BUILTIN_ABSENT="$SB/builtin-absent"
mkdir -p "$BUILTIN_ABSENT"

# ---------------------------------------------------------------------------
echo "[S1] 静态: 三个能力探测函数与判据子串"
# ---------------------------------------------------------------------------
COMMON="core/_common.sh"
for pair in '_nginx_supports_http3:with-http_v3_module' \
    '_nginx_supports_brotli:brotli' \
    '_nginx_supports_stream_preread:with-stream_ssl_preread_module'; do
    fname="${pair%%:*}"
    needle="${pair##*:}"
    body="$(fn_of "$COMMON" "$fname")"
    if [[ -n "$body" ]]; then
        ok "S1: 抽取到 ${fname}"
        assert_contains "S1: ${fname} 判据含 ${needle}" "$body" "$needle"
    else
        bad "S1: 抽取 ${fname} 为空"
    fi
done
# 命脉判据必须**两个参数都判** —— 只写了 --with-stream 却没写 preread 的构建依然不可用
pr_body="$(fn_of "$COMMON" '_nginx_supports_stream_preread')"
assert_contains "S1: 命脉判据同时要求 --with-stream" "$pr_body" "'with-stream'"
# 三个探测都必须支持显式传入二进制 (体检要能对准"外部那份")
assert_contains "S1: 探测支持显式传二进制参数" "$pr_body" '${1:-}'

# ---------------------------------------------------------------------------
echo "[S2] 静态: 目标前缀可配置 + 固定前缀常量"
# ---------------------------------------------------------------------------
# 按内容锚定而不是按行号 —— 这段逻辑上方的注释会随需求增删, 行号范围一改就静默跑偏
hdr="$(sed -n '/^readonly NGINX_BUILTIN_PREFIX=/,/^readonly NGINX_CONFIG_DIR=/p' core/handler.sh)"
assert_contains "S2: 定义了固定前缀常量" "$hdr" 'readonly NGINX_BUILTIN_PREFIX='
assert_contains "S2: 目标前缀经 _nginx_target_prefix 解析 (与体检同源)" "$hdr" '_nginx_target_prefix'
assert_not_contains "S2: 目标前缀不再被硬编码 readonly" "$hdr" 'readonly NGINX_PREFIX_DIR="/usr/local/nginx"'
# 解析序契约落在 helper 本体上 (handler 与 check 共用同一份, 各自不再复述)
tgt_body="$(fn_of "$COMMON" '_nginx_target_prefix')"
assert_contains "S2: 预设 NGINX_PREFIX_DIR 优先" "$tgt_body" '${NGINX_PREFIX_DIR:-}'
assert_contains "S2: 次选脚本配置的 .nginx.prefix" "$tgt_body" '.nginx.prefix'
assert_contains "S2: 最终兜底固定前缀" "$tgt_body" 'NGINX_BUILTIN_PREFIX'
assert_contains "S2: jq 字面 null 兜底" "$tgt_body" "'null'"
assert_contains "S2: 恒打印非空前缀" "$tgt_body" 'printf'

# ---------------------------------------------------------------------------
echo "[B0] 行为: _nginx_target_prefix (handler 与 check.sh 共用的解析序)"
# ---------------------------------------------------------------------------
# 契约: 预设环境变量 > 脚本配置 .nginx.prefix > 本项目固定前缀;
#       jq 缺字段(字面 null) / 配置损坏 / 配置不存在 都必须兜到固定前缀, 绝不返回空。
build_prefix_runner() { # $1=输出文件 $2=脚本配置路径 (空串 = 不设)
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' "NGINX_BUILTIN_PREFIX='/usr/local/nginx'"
        printf '%s\n' "SCRIPT_CONFIG_PATH='$2'"
        printf '%s\n' 'cmd_exists() { command -v "$1" >/dev/null 2>&1; }'
        fn_of "$COMMON" '_nginx_target_prefix'
        printf '%s\n' '_nginx_target_prefix'
    } >"$1"
}
PC="$SB/cfg"
mkdir -p "$PC"
printf '%s' '{"nginx":{"prefix":"/www/server/nginx"}}' >"$PC/attach.json"
printf '%s' '{"nginx":{}}' >"$PC/noprefix.json"
printf '%s' '{oops' >"$PC/broken.json"

build_prefix_runner "$SB/prefix_runner.sh" "$PC/attach.json"
assert_eq "B0: 读脚本配置的 .nginx.prefix (接入目标)" "$(bash "$SB/prefix_runner.sh" 2>/dev/null || true)" '/www/server/nginx'
assert_eq "B0: 预设环境变量优先于配置" \
    "$(NGINX_PREFIX_DIR='/opt/nginx' bash "$SB/prefix_runner.sh" 2>/dev/null || true)" '/opt/nginx'
build_prefix_runner "$SB/prefix_runner.sh" "$PC/noprefix.json"
assert_eq "B0: 配置缺该键 (jq 字面 null) -> 兜底固定前缀" "$(bash "$SB/prefix_runner.sh" 2>/dev/null || true)" '/usr/local/nginx'
build_prefix_runner "$SB/prefix_runner.sh" "$PC/broken.json"
assert_eq "B0: 配置损坏 -> 兜底固定前缀 (不返回空)" "$(bash "$SB/prefix_runner.sh" 2>/dev/null || true)" '/usr/local/nginx'
build_prefix_runner "$SB/prefix_runner.sh" ''
assert_eq "B0: 无脚本配置 -> 兜底固定前缀" "$(bash "$SB/prefix_runner.sh" 2>/dev/null || true)" '/usr/local/nginx'

# ---------------------------------------------------------------------------
echo "[S3] 静态: 归属判定与目标前缀解耦"
# ---------------------------------------------------------------------------
il_body="$(fn_of "$COMMON" '_is_local_nginx_installed')"
if [[ -z "$il_body" ]]; then il_body="$(fn_of "$COMMON" 'is_local_nginx_installed')"; fi
assert_contains "S3: 归属判定读固定前缀" "$il_body" 'NGINX_BUILTIN_PREFIX'
# 这条是本用例的立命之本: 一旦重新走 _nginx_binary(), 预设 NGINX_PREFIX_DIR 就会让
# 外部 Nginx 被误判成本项目版 -> 整份接管式部署 -> 删掉人家的 nginx.conf
assert_not_contains "S3: 归属判定不得走 _nginx_binary" "$il_body" '_nginx_binary'

# ---------------------------------------------------------------------------
# 行为 runner: 注入真实函数体 + 桩件
# ---------------------------------------------------------------------------
build_runner() { # $1=输出文件
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' 'NGINX_BUILTIN_PREFIX="${SB_BUILTIN:?}"'
        printf '%s\n' 'NGINX_PREFIX_DIR="${SB_PREFIX:?}"'
        printf '%s\n' '_i18n() { printf "%s" "$1"; }'
        # _i18n_sub 桩保留 key **与实参** —— 否则报告里的路径/归属/版本全被吞掉,
        # "确实打印了目标路径"这类断言就失去依据 (初版即因此假红)。
        printf '%s\n' '_i18n_sub() { local k="$1"; shift || true; printf "%s" "$k"; while [[ $# -ge 2 ]]; do printf " [%s=%s]" "$1" "$2"; shift 2 || true; done; }'
        printf '%s\n' 'print_info() { printf "INFO %s\n" "$*"; }'
        printf '%s\n' 'print_warn() { printf "WARN %s\n" "$*"; }'
        # 预检在能力合格时会把选定的接入目标写进脚本配置 (子进程改不了父环境, 只能落盘);
        # 这里桩成"写一份到 SC_LOG", 供断言"确实选定了哪一份"。
        printf '%s\n' 'SCRIPT_CONFIG="{}"'
        printf '%s\n' 'persist_script_config() { printf "%s" "${SCRIPT_CONFIG}" > "${SC_LOG:-/dev/null}"; }'
        fn_of "$COMMON" '_nginx_binary'
        fn_of "$COMMON" 'cmd_exists'
        fn_of "$COMMON" 'is_local_nginx_installed'
        fn_of "$COMMON" '_nginx_supports_http3'
        fn_of "$COMMON" '_nginx_supports_brotli'
        fn_of "$COMMON" '_nginx_supports_stream_preread'
        fn_of "$COMMON" '_has_containerized_nginx'
        fn_of 'core/handler.sh' 'nginx_detect_external_prefix'
        fn_of 'core/handler.sh' 'nginx_target_report'
        fn_of 'core/handler.sh' 'handler_nginx_precheck'
        printf '%s\n' 'case "${SCENARIO}" in'
        printf '%s\n' 'caps)'
        printf '%s\n' '    bin="${SB_PREFIX}/sbin/nginx"'
        for c in stream_preread http3 brotli; do
            printf '%s\n' "    if _nginx_supports_${c} \"\${bin}\"; then printf '${c}=0\n'; else printf '${c}=1\n'; fi"
        done
        printf '%s\n' '    ;;'
        printf '%s\n' 'detect)'
        printf '%s\n' '    p="$(nginx_detect_external_prefix)" && printf "prefix=%s\n" "${p}" || printf "prefix=<none>\n"'
        printf '%s\n' '    ;;'
        printf '%s\n' 'report)'
        printf '%s\n' '    nginx_target_report "${SB_PREFIX}"'
        printf '%s\n' '    ;;'
        printf '%s\n' 'precheck)'
        printf '%s\n' '    rc=0'
        printf '%s\n' '    handler_nginx_precheck || rc=$?'
        printf '%s\n' '    printf "RC=%s\n" "${rc}"'
        printf '%s\n' '    ;;'
        printf '%s\n' 'esac'
    } > "$1"
    printf '%s' "$1"
}
RUNNER="$SB/runner.sh"
build_runner "$RUNNER" >/dev/null

# 构造"这台机器上没有 nginx 命令"的 PATH。
# 为什么必须自己构造: runner 镜像 (ubuntu-24.04) **预装 nginx**(见
# .github/workflows/shellcheck.yml 里那段说明), 而本文件多处场景的前提正是"系统上没有
# nginx 命令"。直接继承环境 PATH 会让这些场景在 CI 上走成"有外部 nginx -> 形态不支持
# (RC=1)", 本地(无 nginx)却是绿的 —— 典型的环境敏感型假红, 且红得毫无线索。
# 做法上**不整目录剔除**: nginx 与 coreutils 可能同目录 (发行版装在 /usr/bin 的情形),
# 剔目录会连带隐藏 awk/grep/jq。改为把每个 PATH 目录"照抄"成软链农场, 只跳过 nginx 一项。
no_nginx_path() {
    local farm="$SB/path-no-nginx"
    rm -rf "$farm" 2>/dev/null || true
    mkdir -p "$farm"
    local out='' d entry name='' i=0 dst=''
    local -a dirs=()
    IFS=':' read -r -a dirs <<< "${PATH}"
    for d in "${dirs[@]}"; do
        [[ -n "${d}" && -d "${d}" ]] || continue
        i=$((i + 1))
        dst="${farm}/d${i}"
        mkdir -p "${dst}"
        for entry in "${d}"/*; do
            [[ -e "${entry}" ]] || continue
            name="${entry##*/}"
            if [[ "${name}" == 'nginx' ]]; then continue; fi
            ln -s "${entry}" "${dst}/${name}" 2>/dev/null || true
        done
        out="${out:+${out}:}${dst}"
    done
    printf '%s' "${out}"
}
NO_NGINX_PATH="$(no_nginx_path)"
# 自检: 前提不成立就当场报出来, 而不是让一批用例以"RC 不对"的含糊形式变红。
if PATH="${NO_NGINX_PATH}" command -v nginx >/dev/null 2>&1; then
    bad "环境预备: 剔除后的 PATH 仍能找到 nginx (用例前提不成立)"
else
    ok "环境预备: 已构造无 nginx 的 PATH (隔离 runner 预装的 nginx)"
fi
# 反向自检: 农场不能把常用命令一起弄丢 (否则失败原因会变成"工具缺失", 更难查)
_missing=''
for _t in bash awk grep sed cat ln jq; do
    PATH="${NO_NGINX_PATH}" command -v "${_t}" >/dev/null 2>&1 || _missing="${_missing}${_t} "
done
if [[ -z "${_missing}" ]]; then
    ok "环境预备: 农场保留了常用命令 (bash/awk/grep/sed/cat/ln/jq)"
else
    bad "环境预备: 农场丢了命令 (${_missing})"
fi

run_scn() { # $1=scenario $2=prefix $3=builtin $4=pathdir(可空)
    local scenario="$1" prefix="$2" builtin="$3" pathdir="${4:-}"
    # 基线一律用 NO_NGINX_PATH: 被测判据 (cmd_exists / nginx_detect_external_prefix)
    # 全走 PATH 解析, 基线一旦继承环境, 用例结果就由 runner 镜像装没装 nginx 决定。
    local path_override="${NO_NGINX_PATH}"
    if [[ -n "${pathdir}" ]]; then path_override="${pathdir}:${NO_NGINX_PATH}"; fi
    SCENARIO="${scenario}" SB_PREFIX="${prefix}" SB_BUILTIN="${builtin}" PATH="${path_override}" \
        bash "$RUNNER" 2>&1
}

# ---------------------------------------------------------------------------
echo "[B1] 行为: 三项能力判定与编译参数一致"
# ---------------------------------------------------------------------------
out_full="$(run_scn caps "$FAKE_FULL" "$BUILTIN_ABSENT")"
assert_contains "B1: 齐备构建 -> 命脉具备" "$out_full" 'stream_preread=0'
assert_contains "B1: 齐备构建 -> HTTP/3 具备" "$out_full" 'http3=0'
assert_contains "B1: 齐备构建 -> Brotli 具备" "$out_full" 'brotli=0'

out_nopre="$(run_scn caps "$FAKE_NOPRE" "$BUILTIN_ABSENT")"
assert_contains "B1: 缺命脉构建 -> 命脉判定为不具备" "$out_nopre" 'stream_preread=1'
assert_contains "B1: 缺命脉构建 -> HTTP/3 仍具备 (两项独立判)" "$out_nopre" 'http3=0'

# ---------------------------------------------------------------------------
echo "[B2] 行为: 体检报告内容与结论"
# ---------------------------------------------------------------------------
rep="$(run_scn report "$FAKE_FULL" "$BUILTIN_ABSENT")"
assert_contains "B2: 报告含目标二进制路径" "$rep" "${FAKE_FULL}/sbin/nginx"
assert_contains "B2: 报告含主配置路径" "$rep" "${FAKE_FULL}/conf/nginx.conf"
assert_contains "B2: 报告按固定前缀判定为" "$rep" '.handler.nginx.owner_foreign'
assert_contains "B2: 能力齐备时结论为可承载 SNI" "$rep" '.handler.nginx.verdict_ok'
assert_not_contains "B2: 能力齐备时不出 blocked" "$rep" '.handler.nginx.verdict_blocked'

rep_nopre="$(run_scn report "$FAKE_NOPRE" "$BUILTIN_ABSENT")"
assert_contains "B2: 缺命脉时给出 blocked 结论" "$rep_nopre" '.handler.nginx.verdict_blocked'

# ---------------------------------------------------------------------------
echo "[B3] 行为: 从 PATH 反推外部前缀"
# ---------------------------------------------------------------------------
PATHBIN="$SB/pathbin"
mkdir -p "$PATHBIN"
ln -sf "${FAKE_FULL}/sbin/nginx" "${PATHBIN}/nginx"
det="$(run_scn detect "$FAKE_FULL" "$BUILTIN_ABSENT" "$PATHBIN")"
assert_contains "B3: 软链形态可反推前缀" "$det" "prefix=${FAKE_FULL}"

det_miss="$(run_scn detect "$FAKE_FULL" "$BUILTIN_ABSENT")"
assert_contains "B3: PATH 里没有 nginx 时明确返回 none" "$det_miss" 'prefix=<none>'

# 发行版包安装的形态: 二进制在 /usr/sbin/nginx, 配置在 /etc/nginx —— 光按 <prefix>/sbin/nginx
# 反推会得到 prefix=/usr, 而 /usr/conf/nginx.conf 并不存在。同源校验必须把它挡下, 否则
# handler 会拿着一个错的 conf 目录去部署 (写进不相干的位置)。
RPMROOT="$SB/rpmroot"
mkdir -p "${RPMROOT}/usr/sbin" "${RPMROOT}/pathbin"
cp -p "${FAKE_FULL}/sbin/nginx" "${RPMROOT}/usr/sbin/nginx"
ln -sf "${RPMROOT}/usr/sbin/nginx" "${RPMROOT}/pathbin/nginx"
det_rpm="$(run_scn detect "$FAKE_FULL" "$BUILTIN_ABSENT" "${RPMROOT}/pathbin")"
assert_contains "B3: 发行版形态 (二进制与配置不同源) 被拒" "$det_rpm" 'prefix=<none>'

# ---------------------------------------------------------------------------
echo "[B4] 行为: 预检三场景返回码"
# ---------------------------------------------------------------------------
# 受控桩目录: "443 上什么都没有" —— ss 只回表头, docker 列表为空。凡断言"放行"的场景
# 都带上它, 否则"443 上有没有容器"就取决于宿主机 (CI runner 自带可用的 docker daemon),
# 又是一处环境敏感点。
NOCONTPB="$SB/nocont-path"
mkdir -p "$NOCONTPB"
cat > "${NOCONTPB}/ss" <<'FAKESS_CLEAN'
#!/usr/bin/env bash
printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
FAKESS_CLEAN
cat > "${NOCONTPB}/docker" <<'FAKEDOCKER_CLEAN'
#!/usr/bin/env bash
exit 0
FAKEDOCKER_CLEAN
chmod +x "${NOCONTPB}/ss" "${NOCONTPB}/docker"

# 场景一: 本项目版就位 -> 放行
BUILTIN_PRESENT="$SB/builtin-present"
make_fake_nginx "$BUILTIN_PRESENT" "$FULL"
pc1="$(run_scn precheck "$FAKE_FULL" "$BUILTIN_PRESENT")"
assert_contains "B4: 本项目版就位 -> RC=0" "$pc1" 'RC=0'

# 场景二: 系统上根本没有 nginx -> 放行 (后面会编译安装本项目版)
pc2="$(run_scn precheck "$FAKE_FULL" "$BUILTIN_ABSENT" "$NOCONTPB")"
assert_contains "B4: 系统无 nginx -> RC=0" "$pc2" 'RC=0'

# 场景三: 有外部 nginx 且能力合格 -> 选定它作为接入目标 (RC=0) 并持久化落盘
sc_log="$SB/sc.log"
: > "$sc_log"
pc3="$(SC_LOG="$sc_log" run_scn precheck "$FAKE_FULL" "$BUILTIN_ABSENT" "$PATHBIN")"
assert_contains "B4: 外部 nginx 能力合格 -> RC=0 (选定接入)" "$pc3" 'RC=0'
assert_contains "B4: 选定后打印目标路径" "$pc3" "${FAKE_FULL}/sbin/nginx"
assert_contains "B4: 选定后给出接入说明" "$pc3" '.handler.nginx.attach_selected'
assert_contains "B4: 接入目标已写入脚本配置 (供后续进程读回)" "$(cat "$sc_log")" "${FAKE_FULL}"

# 场景四: 有外部 nginx 但缺命脉能力 -> 拦下 (SNI 四层分流没有降级方案)
PATHBIN_NOPRE="$SB/pathbin-nopre"
mkdir -p "$PATHBIN_NOPRE"
ln -sf "${FAKE_NOPRE}/sbin/nginx" "${PATHBIN_NOPRE}/nginx"
pc4="$(run_scn precheck "$FAKE_NOPRE" "$BUILTIN_ABSENT" "$PATHBIN_NOPRE")"
assert_contains "B4: 缺命脉能力 -> RC=1 (拦下)" "$pc4" 'RC=1'
assert_contains "B4: 拦下时给出 blocked 结论" "$pc4" '.handler.nginx.verdict_blocked'
assert_contains "B4: 拦下时给出处置指引" "$pc4" '.handler.nginx.attach_pending'

# 场景五: 形态不支持 (发行版包 / 容器化面板) -> 拦下并说明支持的形态边界
pc5="$(run_scn precheck "$FAKE_NOPRE" "$BUILTIN_ABSENT" "${RPMROOT}/pathbin")"
assert_contains "B4: 形态不支持 -> RC=1 (拦下)" "$pc5" 'RC=1'
assert_contains "B4: 形态不支持 -> 说明支持的形态边界" "$pc5" '.handler.nginx.attach_unsupported_form'

# 场景六: 本机没有 nginx 命令, 但 443 被容器占着 (docker-proxy 形态) -> 必须与"真的没有
# nginx"区分开, 否则脚本会去编译安装第二套, 跟容器抢 443。
# 用假 ss 驱动真实判据 (PATH 前置), 不桩 _has_containerized_nginx 本身 —— 否则测的是桩。
CARTPB="$SB/cartpath"
mkdir -p "$CARTPB"
cat > "${CARTPB}/ss" <<'FAKESS'
#!/usr/bin/env bash
printf 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("docker-proxy",pid=1234,fd=4))\n'
FAKESS
# docker 同样桩掉: 判据②会问 docker 里有没有 nginx/openresty 容器, 不桩就取决于宿主机
cat > "${CARTPB}/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
exit 0
FAKEDOCKER
chmod +x "${CARTPB}/ss" "${CARTPB}/docker"

pc6="$(run_scn precheck "$FAKE_FULL" "$BUILTIN_ABSENT" "$CARTPB")"
assert_contains "B4: 443 被 docker-proxy 占用 -> RC=1 (拦下)" "$pc6" 'RC=1'
assert_contains "B4: 容器化场景给出专门说明" "$pc6" '.handler.nginx.attach_containerized'

# 反证: 同样没有 nginx 命令, 但 443 上没有容器 -> 必须放行 (让脚本正常去装本项目版)
pc7="$(run_scn precheck "$FAKE_FULL" "$BUILTIN_ABSENT" "$NOCONTPB")"
assert_contains "B4: 无容器占用时仍放行 (不误拦正常安装)" "$pc7" 'RC=0'

# NEG(环境): 把 nginx 混回基线 (等同"过滤失效") -> 场景二那条 RC=0 必须不再成立。
# 用来证明这份环境预备是有承重的: 哪天有人把基线改回继承环境, 本断言会当面指认。
LEAKPB="$SB/leak-nginx"
mkdir -p "$LEAKPB"
printf '#!/usr/bin/env bash\nexit 0\n' >"${LEAKPB}/nginx"
chmod +x "${LEAKPB}/nginx"
pc2_leak="$(run_scn precheck "$FAKE_FULL" "$BUILTIN_ABSENT" "$LEAKPB")"
assert_not_contains "NEG(环境): PATH 混入 nginx 时'系统无 nginx'判据确实会红" "$pc2_leak" 'RC=0'

# ---------------------------------------------------------------------------
echo "[NEG] 负向: 去掉命脉判据里的 preread 一半, 行为断言必须变红"
# ---------------------------------------------------------------------------
# 变异: 删掉判据行里 `&& "${out}" == *'with-stream_ssl_preread_module'*` 那一行 ——
# 于是"只编了 --with-stream 却没编 preread"的构建会被误判为具备命脉能力。
# 注: 判据行以 `]]` 结尾, 用它锚定; 只匹配模块名会把解释性注释也删掉。
awk '
    /with-stream_ssl_preread_module.*\]\]/ { next }
    { print }
' "$COMMON" > "$SB/common_neg.sh"
if cmp -s "$COMMON" "$SB/common_neg.sh"; then
    bad "NEG: 变异未落地 (没匹配到命脉判据那一行)"
else
    ok "NEG: 变异已落地"
    # 行为级自证: 用破损副本重建 runner, 缺命脉的那份假 nginx 必须被误判为"具备"
    # (即 stream_preread=0) —— 与 B1 的正向结论 (1) 相反, 证明 B1 判据不是恒真。
    # 注: build_runner 把生成的 runner 路径打到 stdout, 故直接把它接回 RUNNER;
    #     只重建文件而不换 RUNNER 的话, 跑的仍是原版, NEG 会假绿。
    RUNNER="$(COMMON="$SB/common_neg.sh" build_runner "$SB/runner_neg.sh")"
    neg_out="$(run_scn caps "$FAKE_NOPRE" "$BUILTIN_ABSENT")"
    RUNNER="$SB/runner.sh"
    assert_contains "NEG: 破损版把'缺命脉'误判为具备 (B1 判据非恒真)" "$neg_out" 'stream_preread=0'
fi

echo
echo "==== nginx_attach_precheck_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
