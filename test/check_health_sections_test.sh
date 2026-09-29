#!/usr/bin/env bash
# =============================================================================
# 测试名称: check_health_sections_test.sh
# 测试目标: check.sh 五个体检分区的**首次回归覆盖**。
#
# 为什么需要本测试: 2026-09-26 复审量化发现, check.sh 的 11 个 _health_* / helpers 里
#   有 5 个在 test/ 下**一次都没被提及** —— 改坏了不会有任何用例变红:
#     _health_deps    (check.sh:2059) 必需/可选命令清单, 缺了哪项走 fail / 哪项走 warn
#     _health_nginx   (check.sh:2173) nginx 存在性 -> 单元/存活/配置语法/H3 模块/worker 用户
#     _health_ports   (check.sh:2238) 443 归属必须与模式一致; UDP/443 与防火墙放行
#     _health_system  (check.sh:1985) OS / 内核 / 内存 (读 /etc/os-release 与 /proc/meminfo)
#     _health_script  (check.sh:2493) 脚本配置 + 日志体积 + 轮转 + 订阅新鲜度
#   此前"54 条 handler 臂全覆盖"的口径**不含 check.sh** —— 体检报告是用户判断"要不要修"
#   的唯一依据, 判错方向更糟: 该 fail 的报了 pass (漏报)、顺序退化少查一段也一样看不出来。
#
# 方法与硬约定:
#   - 抽**真实函数体**注入 (awk 从 core/check.sh 截出 function 定义), 不另写实现;
#   - 外部依赖全用桩件替换 (cmd_exists / systemctl / ss / 防火墙探测 / 体积与人可读单位),
#     真实保留的部分只有 jq 与 cat —— fixture 落给它俩, 保证路径是真的;
#   - 每个分区至少一条正向断言 + 一条**负向变异** (改坏 check.sh 后该断言必须变红),
#     并且变异要先 diff 自证"真的落地", 避免假 NEG;
#   - 全过程只读: 不写系统路径, 不拉起服务, 所有写操作都在 $SB 沙箱内。
#
# 依赖: jq (缺则按本项目约定 rc=3 SKIP)。
# =============================================================================
set -u

SB=".workbuddy/tmp/check_health_sections_sb"
rm -rf "$SB"; mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

if [[ -n "${XRAY_TEST_SHIM:-}" && -d "${XRAY_TEST_SHIM}" ]]; then
    export PATH="${XRAY_TEST_SHIM}:${PATH}"
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: 缺少依赖 jq"
    exit 3
fi

CHECK_SRC="core/check.sh"
if [[ ! -f "${CHECK_SRC}" ]]; then
    echo "[FAIL T0] 找不到被测文件: ${CHECK_SRC}"
    echo "==== check_health_sections_test: PASS=0 FAIL=1 ===="
    exit 1
fi

N_PASS=0; N_FAIL=0
ok() { if [[ $1 -eq 0 ]]; then N_PASS=$((N_PASS + 1)); else N_FAIL=$((N_FAIL + 1)); fi; }
bad() { ok 1 && echo "[FAIL $1] $2"; }
good() { ok 0 && echo "[$1] $2"; }

# --- 记录桩: 分区函数唯一的对外输出是两个助手, 全部记录下来供断言比对 -------------
SECTIONS=()
ITEMS=()
_health_section() { SECTIONS+=("$1"); }
_health_item() { ITEMS+=("$1|$2"); }

_i18n() { local k="${1:-}"; printf '<%s>' "${k##*.}"; }
cmd_exists() { [[ -n "${HAS[$1]:-}" ]]; }
_file_bytes() { printf '%s' "${BYTES[$1]:-}"; }
_human_size() { printf '%sB' "$1"; }
_nginx_supports_http3() { [[ "${H3}" -eq 1 ]]; }
get_listening_process_by_port() { printf '%s' "${LP_TCP[$1]:-}"; }
get_listening_process_by_udp_port() { printf '%s' "${LP_UDP[$1]:-}"; }
check_firewall_port_open() { return "${FW_RC:-2}"; }
systemctl() {
    case "${*}" in
    'cat nginx') [[ "${UNIT_NGINX}" -eq 1 ]] ;;
    'is-active nginx') printf '%s' "${ACTIVE_NGINX}" ;;
    esac
}
# _common.sh 的两个 nginx 判据 (check.sh 通过 source 拿到, 本用例只抽分区函数体 -> 必须补桩):
#   _nginx_is_running   —— "目标二进制真身是否在跑", 由 NGX_RUNNING 控制
#   _nginx_init_script  —— SysV 启动脚本路径 (空 = 没有), 由 NGX_INIT 控制
_nginx_is_running() { [[ "${NGX_RUNNING:-0}" -eq 1 ]]; }
_nginx_init_script() { printf '%s' "${NGX_INIT:-}"; }
# 目标前缀解析 (inject 会 eval 声明块里的 `ngx_prefix="$(_nginx_target_prefix)"`, 必须补桩)
_nginx_target_prefix() { printf '%s' "${NGX_PREFIX_STUB:-$SB/ngx}"; }
uname() { printf '%s' "${KVER}"; }
# df 桩: 返回一个 POSIX -Pk 形态的两行文本, 让磁盘那一段走"有数据"分支
df() {
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    printf 'overlay 104857600 52428800 %s 51%% /\n' "${DF_AVAIL:-52428800}"
}
# 假 nginx 二进制: nginx -t 的退出码由该假脚本自己决定 (它跑在子进程里,
#   测试进程里的变量传不进去, 故每次改行为都要整体重写这个脚本)
set_nginx_test_rc() {
    printf '#!/usr/bin/env bash\nexit %s\n' "$1" >"$SB/ngx/sbin/nginx"
    chmod +x "$SB/ngx/sbin/nginx"
}

# ---------------------------------------------------------------------------
# 注入器: 从给定源文件抽出 check_health_report 的变量声明 + 五个分区的真实函数体
# ---------------------------------------------------------------------------
# 为什么要连变量声明一起抽: 五个分区函数本来定义在 check_health_report() **内部**,
#   它们用到的 os_release / mem_warn_kb / disk_warn_kb / sub_count … 都是外层函数的
#   `local`。逐函数注入时外层没了, 手工补变量清单既会漏、又会随 check.sh 演进漂移
#   (漏一个的代价是 set -u 直接炸)。故这里把那段声明块一并抽出、去掉 local 关键字
#   后 eval —— check.sh 新增变量时本用例自动跟上。
# $1 = 源码路径 (可以是变异副本); 抽到空 = 抽取正则失效, 直接判 FAIL (避免恒绿)
inject() {
    local src="$1" fn='' body='' decls=''
    # 只抽"变量赋值行", 跳过块内的打印/分支语句 —— 那段里夹着带 ${GREEN} 的输出,
    #   整段 eval 会因为颜色变量未定义而在 set -u 下炸掉。
    decls="$(awk '
        /^    # ---------- 常量与阈值 ----------/ { flag = 1; next }
        /^function _health_system/ { flag = 0 }
        flag {
            line = $0
            sub(/^[ \t]*local /, "", line)
            if (line ~ /^[A-Za-z_][A-Za-z0-9_]*=/) print line
        }
    ' "$src")"
    if [[ -z "${decls}" ]]; then
        printf '抽取失败: 变量声明块 (源文件: %s)\n' "$src" >&2
        return 1
    fi
    # 声明里会引用 SCRIPT_CONFIG_DIR / PROJECT_ROOT, 必须先给值再 eval
    : "${SCRIPT_CONFIG_DIR:=$SB/cfgdir}" "${PROJECT_ROOT:=$SB/root}"
    eval "$decls" || return 1
    for fn in _health_system _health_deps _health_nginx _health_ports _health_script; do
        body="$(awk -v fn="$fn" '
            $0 ~ "^function " fn "\\(\\)" { flag = 1 }
            flag { print }
            flag && /^}/ { exit }
        ' "$src")"
        if [[ -z "${body}" ]]; then
            printf '抽取失败: %s (源文件: %s)\n' "$fn" "$src" >&2
            return 1
        fi
        eval "$body" || return 1
    done
}

# 每轮场景前的状态重置。两个注意点:
#   ① 这里**不重复声明**分区函数用到的业务变量 (os_name / mem_total_kb / sub_count …) ——
#      它们由 inject 从 check_health_report 的声明块自动抽出。手工列清单会随 check.sh
#      演进漂移, 漏一个就是 set -u 中途炸掉。
#   ② 下面这些是被**动态 eval 的真实函数体**读取的, shellcheck 静态看不见,
#      故逐个 `# shellcheck disable=SC2034`(项目约定: 不许用文件头级 disable)。
init_state() {
    SECTIONS=(); ITEMS=()
    declare -gA HAS BYTES LP_TCP LP_UDP
    HAS=(); BYTES=(); LP_TCP=(); LP_UDP=()
    # 桩件控制变量 (本文件内直接使用, 不需要 disable)
    H3=1; FW_RC=2; UNIT_NGINX=0; ACTIVE_NGINX='inactive'; KVER='6.12.0-test'
    NGX_RUNNING=0; NGX_INIT=''
    # shellcheck disable=SC2034
    CUR_FILE='check'
    # shellcheck disable=SC2034
    os_release="$SB/os-release"
    # shellcheck disable=SC2034
    meminfo="$SB/meminfo"
    # shellcheck disable=SC2034
    mem_warn_kb=1048576
    # shellcheck disable=SC2034
    SCRIPT_CONFIG_DIR="$SB/cfgdir"
    # shellcheck disable=SC2034
    PROJECT_ROOT="$SB/root"
    # shellcheck disable=SC2034
    SCRIPT_CONFIG_PATH="$SB/script_config.json"
    # shellcheck disable=SC2034
    ngx_prefix="$SB/ngx"
    # shellcheck disable=SC2034
    ngx_config_dir="$SB/ngx/conf"
    # shellcheck disable=SC2034
    audit_log="$SB/audit.log"
    # shellcheck disable=SC2034
    xray_access_log="$SB/access.log"
}

# 统计某个等级的 item 条数
count_level() {
    local want="$1" n=0 it=''
    for it in "${ITEMS[@]}"; do [[ "${it%%|*}" == "$want" ]] && n=$((n + 1)); done
    printf '%s' "$n"
}
has_item() { # has_item <level> <消息子串>
    local want="$1" pat="$2" it=''
    for it in "${ITEMS[@]}"; do
        [[ "${it%%|*}" == "$want" ]] || continue
        [[ "${it#*|}" == *"$pat"* ]] && return 0
    done
    return 1
}
dump_items() { local it=''; for it in "${ITEMS[@]}"; do printf '        %s\n' "$it"; done; }

# fixture: 假的 nginx 二进制 (-t 的行为由 NGX_TEST_RC 控制) + 一份脚本配置
mkdir -p "$SB/ngx/sbin" "$SB/ngx/conf" "$SB/cfgdir" "$SB/root"
set_nginx_test_rc 0
cat >"$SB/os-release" <<'EOF'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
VERSION_ID="13"
EOF
cat >"$SB/meminfo" <<'EOF'
MemTotal:       8192000 kB
MemAvailable:   4096000 kB
EOF

# ============================================================================
# 场景 1: _health_deps —— 必需清单缺失必须 FAIL, 可选清单缺失只 WARN
# ============================================================================
run_deps() {
    local src="$1"
    inject "$src" || return 2
    init_state
    HAS[jq]=1; HAS[curl]=1; HAS[openssl]=1     # 必需: 齐
    HAS[dig]=1; HAS[ss]=1; HAS[sysctl]=1; HAS[lsmod]=1; HAS[stat]=1
    HAS[unzip]=1; HAS[tar]=1; HAS[base64]=1; HAS[flock]=1; HAS[qrencode]=1
    _health_deps || return 2
    [[ $(count_level 'pass') -eq 2 && $(count_level 'fail') -eq 0 && $(count_level 'warn') -eq 0 ]] || return 1
    return 0
}
run_deps_missing_req() {
    local src="$1"
    inject "$src" || return 2
    init_state
    HAS[jq]=''; HAS[curl]=1; HAS[openssl]=1     # 缺 jq = 必需项缺失
    _health_deps || return 2
    has_item 'fail' 'jq' || return 1
    has_item 'pass' '<deps_req_label>' && return 1   # 必需项缺失时不得再报 pass
    return 0
}

# 场景: 依赖齐备 -> 必需/可选各一条 pass
inject "$CHECK_SRC"; init_state
for c in jq curl openssl dig ss sysctl lsmod stat unzip tar base64 flock qrencode; do HAS[$c]=1; done
_health_deps
if [[ $(count_level 'pass') -eq 2 ]]; then
    good "T1" "_health_deps: 依赖齐备 -> 2 条 pass, 无 fail/warn"
else
    bad "T1" "_health_deps: 依赖齐备却不是 2 条 pass"; dump_items
fi

inject "$CHECK_SRC"; init_state; HAS[openssl]=''
_health_deps
if has_item 'fail' 'openssl'; then
    good "T2" "_health_deps: 缺必需项 openssl -> fail 且点名"
else
    bad "T2" "_health_deps: 缺必需项 openssl 未判 fail"; dump_items
fi

inject "$CHECK_SRC"; init_state; HAS[qrencode]=''
_health_deps
if has_item 'warn' 'qrencode' && ! has_item 'fail' 'qrencode'; then
    good "T3" "_health_deps: 缺可选项 qrencode -> warn (不升级为 fail)"
else
    bad "T3" "_health_deps: 缺可选项的分级不正确"; dump_items
fi

# ============================================================================
# 场景 2: _health_nginx —— 未安装必须整段 skip; 装了要逐项体检
# ============================================================================
# nginx 压根没装: ngx_prefix / ngx_config_dir 都指向不存在的目录, 且无 systemctl
inject "$CHECK_SRC"; init_state
ngx_prefix="$SB/absent"; ngx_config_dir="$SB/absent/conf"; ngx_present=0; has_systemctl=0
_health_nginx
if [[ $(count_level 'skip') -eq 1 && ${#ITEMS[@]} -eq 1 ]]; then
    good "T4" "_health_nginx: 未安装 -> 恰好 1 条 skip, 不多查一项"
else
    bad "T4" "_health_nginx: 未安装时的 skip 行为不符"; dump_items
fi

inject "$CHECK_SRC"; init_state; set_nginx_test_rc 0
ngx_present=1; has_systemctl=1; UNIT_NGINX=1; ACTIVE_NGINX='active'
_health_nginx
if has_item 'pass' '<svc_unit_label>' && has_item 'pass' '<nginx_test_label>' \
    && has_item 'pass' '<h3_module_label>' && [[ $(count_level 'fail') -eq 0 ]]; then
    good "T5" "_health_nginx: 健康实例 -> 单元/语法/H3 三查全 pass"
else
    bad "T5" "_health_nginx: 健康实例未得全 pass"; dump_items
fi

inject "$CHECK_SRC"; init_state; set_nginx_test_rc 1
ngx_present=1; has_systemctl=1; UNIT_NGINX=1; ACTIVE_NGINX='active'
_health_nginx
if has_item 'fail' '<nginx_test_bad>'; then
    good "T6" "_health_nginx: nginx -t 失败 -> fail 且标明配置语法问题"
else
    bad "T6" "_health_nginx: nginx -t 失败未判 fail"; dump_items
fi

# T7 无 systemd 单元但有 SysV 启动脚本 —— 面板/手动编译的常态, 不该报"单元缺失"
inject "$CHECK_SRC"; init_state; set_nginx_test_rc 0
ngx_present=1; has_systemctl=1; UNIT_NGINX=0; ACTIVE_NGINX='inactive'
NGX_INIT='/etc/init.d/nginx'; NGX_RUNNING=1
_health_nginx
if has_item 'pass' '<svc_unit_initd>' && has_item 'pass' '<svc_active_running>' \
    && ! has_item 'warn' '<svc_unit_missing>'; then
    good "T7" "_health_nginx: init.d 托管 + 目标进程在跑 -> 单元与运行态均 pass"
else
    bad "T7" "_health_nginx: init.d 托管的 Nginx 被误报为异常"; dump_items
fi

# T8 systemd 说 inactive 但目标进程确实在跑 —— 生成式 unit 的典型假阴性
inject "$CHECK_SRC"; init_state; set_nginx_test_rc 0
ngx_present=1; has_systemctl=1; UNIT_NGINX=1; ACTIVE_NGINX='inactive'
NGX_INIT=''; NGX_RUNNING=1
_health_nginx
if has_item 'pass' '<svc_active_running>' && ! has_item 'warn' '<svc_active_label>'; then
    good "T8" "_health_nginx: is-active 答 inactive 但进程在跑 -> 判运行 (不误报未运行)"
else
    bad "T8" "_health_nginx: 生成式 unit 的 inactive 仍被当成未运行"; dump_items
fi

# T9 静态: 体检侧的目标前缀必须走共享解析函数, 不得写死 (解析序契约本身在
#   nginx_attach_precheck_test 的 S2 里对着 helper 本体断言, 这里只管"有没有接上")
if grep -q '_nginx_target_prefix' "$CHECK_SRC" \
    && grep -q 'ngx_config_dir="${ngx_prefix}/conf"' "$CHECK_SRC" \
    && ! grep -q "ngx_prefix='/usr/local/nginx'" "$CHECK_SRC" \
    && ! grep -q "cert_dir='/usr/local/nginx" "$CHECK_SRC"; then
    good "T9" "_health_nginx: 目标前缀走共享解析 (写死会让接入模式体检整段失真)"
else
    bad "T9" "_health_nginx: 目标前缀仍是硬编码"
fi

# ============================================================================
# 场景 3: _health_ports —— 443 归属必须与模式一致; SNI 下才查 UDP/443
# ============================================================================
inject "$CHECK_SRC"; init_state
printf '{"nginx":{"domain":"example.com"}}' >"$SB/script_config.json"
sni_mode=1; LP_TCP[443]='users:(("nginx",pid=1,fd=6))'; LP_TCP[80]='users:(("nginx",pid=1,fd=7))'; FW_RC=0
_health_ports
if has_item 'pass' '<port_expect_ok>' && has_item 'warn' '<h3_udp_absent>'; then
    good "T7" "_health_ports: SNI + 443 归 nginx -> pass; UDP 未监听 -> warn"
else
    bad "T7" "_health_ports: SNI 模式下的归属/UDP 判定不符"; dump_items
fi

inject "$CHECK_SRC"; init_state
printf '{"nginx":{}}' >"$SB/script_config.json"
sni_mode=0; LP_TCP[443]='users:(("xray",pid=1,fd=6))'
_health_ports
if has_item 'pass' '<port_expect_ok>' && has_item 'skip' '<h3_mode_skip>'; then
    good "T8" "_health_ports: 直连 + 443 归 xray -> pass; H3 检查整段 skip"
else
    bad "T8" "_health_ports: 直连模式判定不符"; dump_items
fi

inject "$CHECK_SRC"; init_state
printf '{"nginx":{"domain":"example.com"}}' >"$SB/script_config.json"
sni_mode=1; LP_TCP[443]='users:(("xray",pid=1,fd=6))'
_health_ports
if has_item 'warn' '<port_mismatch>'; then
    good "T9" "_health_ports: SNI 模式却归 xray -> warn 归属不符"
else
    bad "T9" "_health_ports: 归属错配未告警"; dump_items
fi

# ============================================================================
# 场景 4: _health_system —— OS/内核/内存三查, 内存不足走 warn
# ============================================================================
inject "$CHECK_SRC"; init_state
_health_system
if has_item 'pass' 'Debian GNU/Linux 13 (trixie)' && has_item 'pass' "$KVER"; then
    good "T10" "_health_system: 读到 OS 与内核版本并判 pass"
else
    bad "T10" "_health_system: OS/内核未正确上报"; dump_items
fi

inject "$CHECK_SRC"; init_state
cat >"$SB/meminfo" <<'EOF'
MemTotal:       8192000 kB
MemAvailable:      2048 kB
EOF
_health_system
if has_item 'warn' '<mem_low>'; then
    good "T11" "_health_system: 可用内存低于阈值 -> warn 内存偏低"
else
    bad "T11" "_health_system: 内存偏低未告警"; dump_items
fi
cat >"$SB/meminfo" <<'EOF'
MemTotal:       8192000 kB
MemAvailable:   4096000 kB
EOF

# ============================================================================
# 场景 5: _health_script —— 配置缺失/损坏 -> fail; 日志超限 -> warn
# ============================================================================
inject "$CHECK_SRC"; init_state
SCRIPT_CONFIG_PATH="$SB/nonexistent.json"
HAS[jq]=1; HAS[logrotate]=''
_health_script
if has_item 'fail' '<script_conf_missing>'; then
    good "T12" "_health_script: 主配置不存在 -> fail"
else
    bad "T12" "_health_script: 主配置缺失未判 fail"; dump_items
fi

inject "$CHECK_SRC"; init_state
printf '{ this is not json' >"$SB/script_config.json"
SCRIPT_CONFIG_PATH="$SB/script_config.json"
HAS[jq]=1; HAS[logrotate]=''
_health_script
if has_item 'fail' '<script_conf_bad>'; then
    good "T13" "_health_script: 主配置 JSON 损坏 -> fail"
else
    bad "T13" "_health_script: 配置损坏未判 fail"; dump_items
fi

inject "$CHECK_SRC"; init_state
printf '{"version":"v2026-09-26","path":"%s","xray":{"tag":"sni"}}' "$PROJECT_ROOT" >"$SB/script_config.json"
SCRIPT_CONFIG_PATH="$SB/script_config.json"
HAS[jq]=1; HAS[logrotate]=''
BYTES["$SB/audit.log"]=2048; BYTES["$SB/access.log"]=99999999999
_health_script
if has_item 'pass' '<xray_conf_ok>' && has_item 'warn' '<log_large>'; then
    good "T14" "_health_script: 配置 OK + 访问日志超限 -> 配置 pass / 日志 warn"
else
    bad "T14" "_health_script: 配置与日志分级不符"; dump_items
fi

inject "$CHECK_SRC"; init_state
printf '{"version":"v1","path":"/somewhere/else","xray":{"tag":"sni"}}' >"$SB/script_config.json"
SCRIPT_CONFIG_PATH="$SB/script_config.json"
HAS[jq]=1; HAS[logrotate]=''
_health_script
if has_item 'warn' '<script_path_mismatch>'; then
    good "T15" "_health_script: 配置里的 path 与运行目录不一致 -> warn"
else
    bad "T15" "_health_script: path 不一致未告警"; dump_items
fi

# ============================================================================
# 负向自检: 每个分区改坏一处判据, 对应的正向断言必须变红
# ============================================================================
# 下面四个 probe 与上面的正向断言**同源**, 只是把"调用 + 判定"收成可以换源码重跑的形式。
# 约定: probe 在原始代码下必须返回 0; 喂变异副本后必须返回非 0 —— 后者不成立即为假绿。
_probe_pre() { inject "$1" || return 2; init_state; }

_nginx_absent_probe() {
    _probe_pre "$1" || return $?
    # ngx_prefix 必须指向不存在的位置: init_state 的默认 fixture 里放着假 nginx,
    # 不换掉的话 ngx_present 会被判定为 1, 走不到 skip 分支
    # shellcheck disable=SC2034
    ngx_prefix="$SB/absent"
    # shellcheck disable=SC2034
    ngx_config_dir="$SB/absent/conf"
    # shellcheck disable=SC2034
    ngx_present=0
    # shellcheck disable=SC2034
    has_systemctl=0
    _health_nginx || return 2
    [[ $(count_level 'skip') -eq 1 && ${#ITEMS[@]} -eq 1 ]] || return 1
    return 0
}
# T8 的同源 probe: 目标进程确实在跑, 但 systemd 说 inactive (生成式 unit 的假阴性)
_nginx_running_probe() {
    _probe_pre "$1" || return $?
    # shellcheck disable=SC2034
    ngx_present=1
    # shellcheck disable=SC2034
    has_systemctl=1
    # shellcheck disable=SC2034
    UNIT_NGINX=1
    # shellcheck disable=SC2034
    ACTIVE_NGINX='inactive'
    # shellcheck disable=SC2034
    NGX_RUNNING=1
    _health_nginx || return 2
    has_item 'pass' '<svc_active_running>' || return 1
    return 0
}
_ports_expect_probe() {
    _probe_pre "$1" || return $?
    printf '{"nginx":{"domain":"example.com"}}' >"$SB/script_config.json"
    # shellcheck disable=SC2034
    sni_mode=1
    LP_TCP[443]='users:(("nginx",pid=1,fd=6))'
    _health_ports || return 2
    has_item 'pass' '<port_expect_ok>' || return 1
    return 0
}
_system_mem_probe() {
    _probe_pre "$1" || return $?
    cat >"$SB/meminfo" <<'EOF'
MemTotal:       8192000 kB
MemAvailable:      2048 kB
EOF
    _health_system || return 2
    has_item 'warn' '<mem_low>' || return 1
    return 0
}
_script_missing_probe() {
    _probe_pre "$1" || return $?
    # shellcheck disable=SC2034
    SCRIPT_CONFIG_PATH="$SB/nonexistent.json"
    HAS[jq]=1
    _health_script || return 2
    has_item 'fail' '<script_conf_missing>' || return 1
    return 0
}

neg_run() { # neg_run <label> <sed> <probe>
    local label="$1" sedexpr="$2" fn="$3" mut="$SB/mut.sh" rc=0 rc2=0
    "$fn" "$CHECK_SRC"; rc=$?
    if [[ ${rc} -ne 0 ]]; then
        bad "${label}" "负向自检前置失败: ${fn} 在**原始代码**下就没通过 (rc=${rc}), 断言本身有问题"
        return
    fi
    cp -f "$CHECK_SRC" "$mut"
    sed -i "${sedexpr}" "$mut"
    if diff -q "$CHECK_SRC" "$mut" >/dev/null; then
        bad "${label}" "变异未落地 —— sed 没匹配到任何内容, NEG 无意义"
        return
    fi
    "$fn" "$mut"; rc2=$?
    if [[ ${rc2} -eq 0 ]]; then
        bad "${label}" "判据失效: 代码被改坏 (${sedexpr}) 后 ${fn} 仍然通过 —— 断言可能是恒绿"
    else
        good "${label}" "负向自检通过 (改坏判据后 ${fn} 确实变红)"
    fi
}

neg_run "N1" 's/for tmp in jq curl openssl;/for tmp in xyzzy curl openssl;/' run_deps_missing_req
neg_run "N2" 's|if \[\[ "${ngx_present}" -eq 0 \]\]; then|if false; then|' _nginx_absent_probe
neg_run "N3" "s|expect_name='nginx'|expect_name='zzz'|" _ports_expect_probe
neg_run "N4" 's/MemAvailable:\*)/MemXXX:\*)/' _system_mem_probe
neg_run "N5" 's|if \[\[ ! -f "${SCRIPT_CONFIG_PATH}" \]\]; then|if false; then|' _script_missing_probe
# N6: 把"按目标进程真身判运行态"这条拿掉 (退回只看 systemd) -> T8 必须变红
neg_run "N6" 's|if \[\[ "${ngx_running}" -eq 1 \]\]; then|if false; then|' _nginx_running_probe

echo "==== check_health_sections_test: PASS=$N_PASS FAIL=$N_FAIL ===="
rm -rf "$SB"
[[ $N_FAIL -eq 0 ]]
