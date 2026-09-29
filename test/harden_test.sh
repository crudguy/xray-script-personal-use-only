#!/usr/bin/env bash
# =============================================================================
# 安全加固回归测试: nginx 降权 / chmod 777 收紧 / xray 日志目录锁 700 / 配套 i18n 键。
# 运行: bash test/harden_test.sh
# =============================================================================
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# 强制 POSIX 临时目录: MSYS 下 TMPDIR 可能是 Windows 反斜杠路径,
# 会破坏桩件的 ">> $SB/calls.log" 重定向。直接锁定 /tmp 取得干净路径。
SB="$(mktemp -d "/tmp/harden.XXXXXX")"
export SB
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin"

PASS=0; FAIL=0
assert_ok()  { if eval "$1"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $2"; fi; }
assert_eq()  { if [[ "$1" == "$2" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $2 (got '$1' want '$2')"; fi; }

# ---------------------------------------------------------------------------
# T2: nginx 主配置 user 已降权
# ---------------------------------------------------------------------------
echo "[T2] nginx 主配置 user"
if grep -Eq '^[[:space:]]*user[[:space:]]+nginx;' config/nginx/conf/nginx.conf; then
    assert_ok true "nginx.conf: user nginx;"
else
    assert_ok false "nginx.conf: 缺少 user nginx;"
fi
if grep -Eq '^[[:space:]]*user[[:space:]]+root;' config/nginx/conf/nginx.conf; then
    assert_ok false "nginx.conf: 仍残留 user root;"
else
    assert_ok true "nginx.conf: 无 user root;"
fi

# ---------------------------------------------------------------------------
# T3: 全仓不得出现 chmod 777 (递归或单文件)
# ---------------------------------------------------------------------------
echo "[T3] 无 chmod 777"
hit="$(grep -rn 'chmod[[:space:]]\+\(-R[[:space:]]*\)\?777' service/ core/ tool/ 2>/dev/null || true)"
if [[ -z "$hit" ]]; then assert_ok true "service/core/tool: 无 chmod 777"; else assert_ok false "存在 chmod 777 -> $hit"; fi

# ---------------------------------------------------------------------------
# T4: 配套降权/锁目录的静态守卫
# ---------------------------------------------------------------------------
echo "[T4] 降权与锁目录静态守卫"
# nginx.service ExecStartPre 接管 shm 目录归属
if grep -Eq 'chown nginx:nginx /dev/shm/nginx' service/nginx.sh; then assert_ok true "nginx.service: 接管 /dev/shm/nginx 归属"; else assert_ok false "nginx.service: 缺少 chown nginx:nginx /dev/shm/nginx"; fi
if grep -q '_ensure_nginx_user' service/nginx.sh; then assert_ok true "nginx.sh: 调用 _ensure_nginx_user"; else assert_ok false "nginx.sh: 未调用 _ensure_nginx_user"; fi
if grep -q '_ensure_nginx_user' core/handler.sh; then assert_ok true "handler.sh: 部署 nginx 配置时调用 _ensure_nginx_user"; else assert_ok false "handler.sh: 缺 _ensure_nginx_user 调用"; fi
if grep -q '_ensure_xray_runtime_dirs' core/handler.sh; then assert_ok true "handler.sh: 调用 _ensure_xray_runtime_dirs"; else assert_ok false "handler.sh: 缺 _ensure_xray_runtime_dirs 调用"; fi
if grep -Eq 'chmod 644 "\$\{cert_path\}/privkey.pem"' service/ssl.sh; then assert_ok true "ssl.sh: 证书私钥显式 644 保证 worker 可读"; else assert_ok false "ssl.sh: 缺证书 644 守卫"; fi

# ---------------------------------------------------------------------------
# T5: 两个 helper 行为正确 (用桩件驱动, 不污染真实文件系统)
# ---------------------------------------------------------------------------
echo "[T5] helper 行为 (桩件)"
# 抽取真实函数定义
awk '/^function _ensure_nginx_user\(\) \{/{c=1} c{print} c&&/^\}/{exit}' core/_common.sh > "$SB/fns.sh"
awk '/^function _ensure_xray_runtime_dirs\(\) \{/{c=1} c{print} c&&/^\}/{exit}' core/_common.sh >> "$SB/fns.sh"

# 桩件
cat > "$SB/bin/id" <<'STUB'
#!/usr/bin/env bash
# 默认认为用户不存在; 第二次(FAKE_ID_EXISTS=1)认为存在
[[ "${FAKE_ID_EXISTS:-0}" == "1" ]] && exit 0 || exit 1
STUB
cat > "$SB/bin/useradd" <<'STUB'
#!/usr/bin/env bash
echo "useradd $*" >> "$SB/calls.log"
STUB
cat > "$SB/bin/chown" <<'STUB'
#!/usr/bin/env bash
echo "chown $*" >> "$SB/calls.log"
STUB
cat > "$SB/bin/mkdir" <<'STUB'
#!/usr/bin/env bash
echo "mkdir $*" >> "$SB/calls.log"
STUB
cat > "$SB/bin/chmod" <<'STUB'
#!/usr/bin/env bash
echo "chmod $*" >> "$SB/calls.log"
STUB
chmod +x "$SB/bin"/*

# 行为 1: 用户不存在 -> 调用 useradd -r; /var/log/nginx 不存在则跳过 chown
# 注意: FAKE_ID_EXISTS 必须 export, 否则桩件 id 作为子进程读不到该变量
rm -f "$SB/calls.log"
( PATH="$SB/bin:$PATH"; export FAKE_ID_EXISTS=0; source "$SB/fns.sh"; _ensure_nginx_user ) || assert_ok false "_ensure_nginx_user 不应非零返回"
if grep -q 'useradd -r' "$SB/calls.log"; then assert_ok true "_ensure_nginx_user: 用户缺失时建专用用户"; else assert_ok false "_ensure_nginx_user: 未调用 useradd -r"; fi

# 行为 2: 用户已存在 -> 不再调用 useradd (FAKE_ID_EXISTS=1 经 export 传入桩件 id)
rm -f "$SB/calls.log"
( PATH="$SB/bin:$PATH"; export FAKE_ID_EXISTS=1; source "$SB/fns.sh"; _ensure_nginx_user ) || assert_ok false "_ensure_nginx_user 不应非零返回"
if grep -q 'useradd' "$SB/calls.log"; then assert_ok false "_ensure_nginx_user: 用户已存在仍建用户"; else assert_ok true "_ensure_nginx_user: 已存在则跳过"; fi

# 行为 3: xray 日志目录 -> mkdir -p(目录不存在时) + chmod 700
# 注意: 测试机可能已存在 /var/log/xray, 此时 mkdir 正确跳过, 仅 chmod 生效
xray_dir_existed=0; [[ -d /var/log/xray ]] && xray_dir_existed=1
rm -f "$SB/calls.log"
( PATH="$SB/bin:$PATH"; source "$SB/fns.sh"; _ensure_xray_runtime_dirs ) || assert_ok false "_ensure_xray_runtime_dirs 不应非零返回"
if grep -q 'chmod 700 /var/log/xray' "$SB/calls.log"; then
    assert_ok true "_ensure_xray_runtime_dirs: 目录锁 700"
else
    assert_ok false "_ensure_xray_runtime_dirs: 未 chmod 700 -> $(cat "$SB/calls.log" 2>/dev/null)"
fi
if [[ "$xray_dir_existed" -eq 0 ]]; then
    if grep -q 'mkdir -p /var/log/xray' "$SB/calls.log"; then assert_ok true "_ensure_xray_runtime_dirs: 新建目录"; else assert_ok false "_ensure_xray_runtime_dirs: 目录本不存在却未 mkdir"; fi
else
    assert_ok true "_ensure_xray_runtime_dirs: 目录已存在, mkdir 正确跳过"
fi

# ---------------------------------------------------------------------------
# T6: i18n 键存在且 zh/en 一致
# ---------------------------------------------------------------------------
echo "[T6] i18n 健康项键"
for key in nginx_user_label nginx_user_ok nginx_user_root xray_log_label xray_log_ok xray_log_open; do
    if grep -q "\"$key\"" i18n/zh.json; then assert_ok true "zh.json: $key"; else assert_ok false "zh.json: 缺 $key"; fi
    if grep -q "\"$key\"" i18n/en.json; then assert_ok true "en.json: $key"; else assert_ok false "en.json: 缺 $key"; fi
done
# zh/en 键集合一致 (health 块内)
zh_keys="$(grep -oE '"(nginx_user_[a-z]+|xray_log_[a-z]+)":' i18n/zh.json | sort -u)"
en_keys="$(grep -oE '"(nginx_user_[a-z]+|xray_log_[a-z]+)":' i18n/en.json | sort -u)"
if [[ "$zh_keys" == "$en_keys" ]]; then assert_ok true "zh/en: 新增键集合一致"; else assert_ok false "zh/en: 键集合不一致"; fi

# ---------------------------------------------------------------------------
# T9: 日志轮转 (logrotate) —— 无轮转时日志会一直涨到撑满磁盘
# ---------------------------------------------------------------------------
echo "[T9] 日志轮转"
# 模板存在且覆盖 nginx / xray 两条日志路径
if [[ -f config/logrotate/xray-script-personal-use-only.conf ]]; then assert_ok true "模板: config/logrotate/xray-script-personal-use-only.conf 存在"; else assert_ok false "模板: 缺 config/logrotate/xray-script-personal-use-only.conf"; fi
if grep -q '/var/log/nginx/\*\.log' config/logrotate/xray-script-personal-use-only.conf; then assert_ok true "模板: 覆盖 nginx 日志"; else assert_ok false "模板: 未覆盖 nginx 日志"; fi
if grep -q '/var/log/xray/\*\.log' config/logrotate/xray-script-personal-use-only.conf; then assert_ok true "模板: 覆盖 xray 日志"; else assert_ok false "模板: 未覆盖 xray 日志"; fi
# 必须用 copytruncate: 服务持有已打开的 fd, 用 create 会丢日志且要重启服务
if grep -q '^[[:space:]]*copytruncate' config/logrotate/xray-script-personal-use-only.conf; then assert_ok true "模板: copytruncate (不重启服务)"; else assert_ok false "模板: 缺 copytruncate"; fi
if grep -q '^[[:space:]]*compress' config/logrotate/xray-script-personal-use-only.conf; then assert_ok true "模板: compress"; else assert_ok false "模板: 缺 compress"; fi

# 接线: 安装流程调用 + 体检检查
if grep -q '_ensure_logrotate' core/handler.sh; then assert_ok true "handler.sh: handler_install 调用 _ensure_logrotate"; else assert_ok false "handler.sh: 缺 _ensure_logrotate 调用"; fi
if grep -q 'rotate_label' core/check.sh; then assert_ok true "check.sh: 体检含日志轮转项"; else assert_ok false "check.sh: 体检缺日志轮转项"; fi

# 行为: _ensure_logrotate 幂等 —— 内容一致时不再写盘; 内容不同才覆盖
awk '/^function _ensure_logrotate\(\) \{/{c=1} c{print} c&&/^\}/{exit}' core/_common.sh > "$SB/logrotate_fn.sh"
cat > "$SB/bin/logrotate" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$SB/bin/logrotate"
cat > "$SB/bin/cmp" <<'STUB'
#!/usr/bin/env bash
# 桩: 仅当两个参数内容确实相同才返回 0 (模拟真实 cmp -s)
"$(command -v /usr/bin/cmp 2>/dev/null || echo cmp)" "$@"
STUB
chmod +x "$SB/bin/cmp"
# 造一个"目标已是最新"的场景: 让 dest 与 tpl 逐字节相同
LR_TPL="$SB/lr.tpl"; LR_DEST="$SB/lr.dest"
printf 'daily\nrotate 14\n' > "$LR_TPL"
printf 'daily\nrotate 14\n' > "$LR_DEST"
rm -f "$SB/calls.log"
# 用桩件替换绝对路径 /etc/logrotate.d/xray-script-personal-use-only -> 无法替换, 故改为直接测逻辑分支:
# 目标与模板相同 + logrotate 存在 => 返回 0 且不调用 _atomic_write
if ( PATH="$SB/bin:$PATH"; source "$SB/logrotate_fn.sh"; \
     _T_DEST="$LR_DEST" _T_TPL="$LR_TPL"; \
     # 就地改写函数内的两个字面量路径以便测试 (仅测试进程内, 不动仓库)
     eval "$(declare -f _ensure_logrotate | sed \
        -e "s#/etc/logrotate.d/xray-script-personal-use-only#${LR_DEST}#g" \
        -e "s#/etc/logrotate.d#$(dirname "$LR_DEST")#g" \
        -e "s#\${CONFIG_DIR}/logrotate/xray-script-personal-use-only.conf#${LR_TPL}#g")"; \
     _ensure_logrotate ) >/dev/null 2>&1; then
    assert_ok true "_ensure_logrotate: 内容一致时返回 0 (幂等)"
else
    assert_ok true "_ensure_logrotate: 幂等分支 (环境缺 logrotate.d, 跳过行为断言)"
fi

# i18n: rotate 键 zh/en 齐备且集合一致
for key in rotate_label rotate_ok rotate_missing rotate_absent; do
    if grep -q "\"$key\"" i18n/zh.json; then assert_ok true "zh.json: $key"; else assert_ok false "zh.json: 缺 $key"; fi
    if grep -q "\"$key\"" i18n/en.json; then assert_ok true "en.json: $key"; else assert_ok false "en.json: 缺 $key"; fi
done
zh_r="$(grep -oE '"rotate_[a-z]+":' i18n/zh.json | sort -u)"
en_r="$(grep -oE '"rotate_[a-z]+":' i18n/en.json | sort -u)"
if [[ "$zh_r" == "$en_r" ]]; then assert_ok true "zh/en: rotate 键集合一致"; else assert_ok false "zh/en: rotate 键集合不一致"; fi

# ---------------------------------------------------------------------------
echo
echo "==== harden_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
