#!/usr/bin/env bash
# =============================================================================
# test/ssl_test.sh — service/ssl.sh (acme.sh 证书管理) 行为测试
#
# 做法 (与 test/backup_test.sh 同源, 关键选型一致):
#   - 以**独立进程**调 ssl.sh 真实入口 (handler.sh 本就 `bash ssl.sh "$@"`),
#     不 source 抽函数库 —— 因 core/_common.sh 的 ERR trap 是 `exit "${rc}"`,
#     source 后落在宿主脚本上, 被测函数走失败路径会把整个测试脚本 exit 掉、
#     后续断言静默不执行 (现象是"输出到某处就断了", 极易误读成挂起)。
#   - 外部依赖 (acme.sh / nginx / systemctl) 用沙箱桩件替代, 可在无网络/无 root
#     的本机完整跑通签发全链路; 桩件放在 ~/bin (在 _common 的 PATH 白名单内),
#     acme.sh 桩放在 $HOME/.acme.sh (ssl.sh 写死调用此路径)。
#   - 只读路径常量 (NGINX_CONFIG_PATH / ACME_WEBROOT_PATH) 改写为沙箱路径,
#     避免测试把证书/配置写进真实 /usr/local/nginx。
#
# 覆盖范围:
#   T1  --help 冒烟 (rc=0 + 含 usage/命令列表)
#   T2  非法域名被拒 (../etc, a..b.com, *.example.com, example_com) -> rc!=0
#   T3  --status 无 --domain -> rc!=0
#   T4  normalize_ca_server 纯函数单测 (zerossl/letsencrypt/大小写/未知->zerossl/空)
#   T5  --issue 全链路桩跑 -> rc=0 + 证书文件落地 (privkey/fullchain 非空)
#   T6  静态守卫: DOMAIN_REGEX 定义且 --domain 已校验
#   T7  i18n: ssl.sh 引用的 .ssl.* 键在 zh.json 全部存在
#
# 说明: 本测试不验证真实 acme.sh 签发 (需网络/root/真实 CA), 那是环境集成层;
#       这里验证的是脚本自身的参数校验、路径安全、流程编排与 i18n 一致性。
# =============================================================================

set -u

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
SB="$(mktemp -d "/tmp/ssl-test.XXXXXX")"
trap 'trap - EXIT' EXIT
trap - EXIT

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

# --- 依赖前置检查 (区分"环境没配好" 与 "代码坏了") ---
for dep in bash jq; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "前置依赖缺失: ${dep} (请 PATH 加入 jq 垫片: export PATH=\"\$REPO/.workbuddy/tmp/jqshim:\$PATH\")"
        exit 3
    fi
done

# --- 沙箱搭建 ---
mkdir -p "${SB}/home/.xray-script-personal-use-only" "${SB}/home/bin" "${SB}/root/nginx/conf" "${SB}/root/nginx/sbin" "${SB}/root/www" "${SB}/home/.acme.sh"
mkdir -p "${SB}/core" "${SB}/service"
# ssl.sh 仅 source core/_common.sh, 不必复制整个 core (省时 + 隔离)
cp "${REPO}/core/_common.sh" "${SB}/core/"
# _common.sh 的 PATH 白名单把 ~/bin 放在 /usr/bin 之后, 且该 ~/bin 是字面量不会展开,
# 导致 ssl_test 放在 ${HOME}/bin 的 nginx/systemctl 桩件从未被命中 —— 真实(无 systemd)的
# systemctl 被优先调用, --issue 起停 nginx 在 CI/沙箱里必败。仅改沙箱副本: 把桩件目录
# 前置到白名单最前, 让桩件优于真实二进制生效 (不影响生产 PATH 语义)。
sed -i "s#^PATH=.*#PATH=\"${SB}/home/bin:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:/snap/bin\"#" "${SB}/core/_common.sh"
cp -r "${REPO}/i18n"         "${SB}/i18n"
cp "${REPO}/service/ssl.sh"  "${SB}/service/"

# 脚本主配置 (load_i18n 读 language)
printf '{"version":"vTEST","language":"zh","nginx":{"ca_server":"zerossl"}}\n' >"${SB}/home/.xray-script-personal-use-only/config.json"

# jq 垫片进 ~/bin (被测子进程 PATH 由 _common 覆盖为白名单, ~/bin 在内)
SHIM="${XRAY_TEST_SHIM:-${REPO}/.workbuddy/tmp/jqshim}"
if [[ -n "${SHIM}" && -x "${SHIM}/jq" ]]; then
    ln -sf "${SHIM}/jq" "${SB}/home/bin/jq"
fi

# 桩件: nginx / systemctl (走 ~/bin, 在 _common PATH 白名单内) —— 一律成功
cat >"${SB}/home/bin/nginx" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"${SB}/home/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${SB}/home/bin/nginx" "${SB}/home/bin/systemctl"

# 桩件: **目标那份** nginx 二进制 (${NGINX_PREFIX_DIR}/sbin/nginx) —— 校验/重载都落在它身上,
#   与 ~/bin/nginx 那个不同: 后者是"PATH 里的 nginx", 实现里已不再用它做校验。
cat >"${SB}/root/nginx/sbin/nginx" <<'STUB'
#!/usr/bin/env bash
printf 'TARGET_NGINX:%s\n' "$*" >>"$HOME/target_nginx.log"
exit 0
STUB
chmod +x "${SB}/root/nginx/sbin/nginx"

# 桩件: acme.sh (ssl.sh 写死调用 $HOME/.acme.sh/acme.sh)
# 解析 --key-file / --fullchain-file 并创建占位文件; 记下 --reloadcmd (它会被 acme.sh
# **持久化**进续期配置, 是"续期时能不能让 nginx 生效"的唯一依据, 必须能断言)。
cat >"${SB}/home/.acme.sh/acme.sh" <<'STUB'
#!/usr/bin/env bash
kf=''; ff=''; rc=''
while [ $# -gt 0 ]; do
  case "$1" in
    --key-file)       kf="$2"; shift 2;;
    --fullchain-file) ff="$2"; shift 2;;
    --reloadcmd)      rc="$2"; shift 2;;
    *) shift;;
  esac
done
[ -n "$rc" ] && printf '%s' "$rc" > "$HOME/reloadcmd.txt"
[ -n "$kf" ] && { mkdir -p "$(dirname "$kf")"; printf 'stub-key' > "$kf"; }
[ -n "$ff" ] && { mkdir -p "$(dirname "$ff")"; printf 'stub-fullchain' > "$ff"; }
exit 0
STUB
chmod +x "${SB}/home/.acme.sh/acme.sh"

# --- 目标前缀与常量改写 ---
# NGINX_CONFIG_PATH 现在**由 _nginx_target_prefix 派生**（预设环境变量 > 脚本配置的
# .nginx.prefix > 本项目固定前缀），故不再靠 sed 改写常量：直接预设 NGINX_PREFIX_DIR
# 即可把目标指到沙箱 —— 顺带把"派生是否真的生效"变成行为可验（证书落到沙箱路径才算过）。
FAKE_PREFIX="${SB}/root/nginx"
FAKE_NGINX="${FAKE_PREFIX}/conf"
FAKE_WEBROOT="${SB}/root/www"
patch_ssl() {
    local src="$1" dst="$2"
    local a2="readonly ACME_WEBROOT_PATH='/var/www/_zerossl'"
    # 反向守卫: 这个常量**不许**再写死 —— 写死就会在接入既有 Nginx 时把 ACME 挑战配置
    # 写到错的 nginx 上（甚至该文件根本不存在），HTTP-01 必然失败。
    if grep -qF "readonly NGINX_CONFIG_PATH='/usr/local/nginx/conf'" "${src}"; then
        echo "patch guard: NGINX_CONFIG_PATH 又变回写死常量了 (应由 _nginx_target_prefix 派生)"
        exit 2
    fi
    grep -qF '_nginx_target_prefix' "${src}" || { echo "patch guard: 未见 _nginx_target_prefix 派生"; exit 2; }
    grep -qF "${a2}" "${src}" || { echo "patch anchor2 missing"; exit 2; }
    sed -e "s|${a2}|readonly ACME_WEBROOT_PATH=\"${FAKE_WEBROOT}\"|" \
        "${src}" >"${dst}"
    grep -qE "^readonly ACME_WEBROOT_PATH=\"${FAKE_WEBROOT}\"" "${dst}" || { echo "patch2 verify fail"; exit 2; }
}
patch_ssl "${SB}/service/ssl.sh" "${SB}/service/ssl.sh.patched"

# 单元测副本: 去掉末尾 main "$@" (source 时不自动执行), 路径保持原值即可
sed -E '/^main "\$@"$/d' "${SB}/service/ssl.sh" >"${SB}/service/ssl.sh.unit"

# --- 调用封装: 独立进程跑真实入口 ---
ssl_run() {
    env -u CODEBUDDY_SESSION_ID -u CLAUDE_SESSION_ID \
        HOME="${SB}/home" PATH="${PATH}" NGINX_PREFIX_DIR="${FAKE_PREFIX}" \
        bash -c 'trap - ERR EXIT; exec bash "$@"' _ "${SB}/service/ssl.sh.patched" "$@"
}

echo "=== ssl.sh 行为测试 ==="

# T1 --help 冒烟 (rc=0 + 含命令列表与 --domain 选项; 不依赖具体语言文案)
ssl_run --help >"${SB}/t1.out" 2>&1; rc=$?
if [[ $rc -eq 0 ]] && grep -q '\-\-issue' "${SB}/t1.out" && grep -q '\-\-domain' "${SB}/t1.out"; then
    ok "T1 --help 冒烟 (rc=0 + 含命令列表与 --domain 选项)"
else
    bad "T1 --help 异常 (rc=$rc)"
fi

# T2 非法域名被拒
for d in '../etc' 'a..b.com' '*.example.com' 'example_com'; do
    ssl_run --issue --domain="$d" >"${SB}/t2.out" 2>&1; rc=$?
    if [[ $rc -ne 0 ]]; then
        ok "T2 非法域名被拒: $d"
    else
        bad "T2 非法域名未拒: $d"
    fi
done

# T3 --status 无 --domain 被拒
ssl_run --status >"${SB}/t3.out" 2>&1; rc=$?
if [[ $rc -ne 0 ]]; then
    ok "T3 --status 无域名被拒 (rc=$rc)"
else
    bad "T3 --status 无域名未拒"
fi

# T4 normalize_ca_server 纯函数单测
# 关键点: ssl.sh 用 $0 推导 _common.sh 路径, 直接 `source 单元副本` 会让 $0 变成
#   驱动脚本, 导致 "缺少 ../core/_common.sh"。故用 `bash -c 'source "$0"; ...' "$SRC"`
#   让 $0 指向被测脚本, _common 路径才能正确解析。
cat >"${SB}/run_unit_body.sh" <<'BODY'
#!/usr/bin/env bash
set -u
fail=0
check() {
  local inp="$1" exp="$2" got
  got="$(normalize_ca_server "$inp")"
  if [ "$got" != "$exp" ]; then echo "  FAIL normalize_ca_server('$inp') -> '$got' (exp '$exp')"; fail=1; else echo "  ok   normalize_ca_server('$inp') -> '$got'"; fi
}
check zerossl zerossl
check letsencrypt letsencrypt
check LetEncrypt zerossl
check ZEROSSL zerossl
check FOO zerossl
check '' zerossl
exit $fail
BODY
HOME="${SB}/home" bash -c 'source "$0"; trap - ERR; source "$1"' "${SB}/service/ssl.sh.unit" "${SB}/run_unit_body.sh" >"${SB}/t4.out" 2>&1; rc=$?
if [[ $rc -eq 0 ]]; then
    ok "T4 normalize_ca_server 单测全过"
else
    bad "T4 normalize_ca_server 单测失败"; sed 's/^/    /' "${SB}/t4.out"
fi

# T5 --issue 全链路桩跑 (预置占位 nginx.conf, 让备份/恢复分支走通)
printf 'user root;\n' >"${FAKE_NGINX}/nginx.conf"
ssl_run --issue --domain=valid.example.com --ca=zerossl >"${SB}/t5.out" 2>&1; rc=$?
cert_dir="${FAKE_NGINX}/certs/valid.example.com"
if [[ $rc -eq 0 ]] && [[ -s "${cert_dir}/privkey.pem" ]] && [[ -s "${cert_dir}/fullchain.pem" ]]; then
    ok "T5 --issue 全链路桩跑通过 + 证书落地 (privkey/fullchain 非空)"
else
    bad "T5 --issue 全链路失败 (rc=$rc)"; tail -20 "${SB}/t5.out" | sed 's/^/    /'
fi

# T5a 挑战配置改写的对象必须是**目标那份** conf (由预设前缀推出), 且跑完已原样还原。
#     若实现又写死本项目前缀, 改写会落到 /usr/local/nginx/conf (沙箱里不存在/不可写) ——
#     这一条与 T5 一起构成"路径派生真的生效"的行为证据。
if [[ "$(cat "${FAKE_NGINX}/nginx.conf")" == 'user root;' ]]; then
    ok "T5a 挑战配置改写落在目标前缀下, 且跑完已原样还原"
else
    bad "T5a 目标 nginx.conf 未还原 (内容: $(head -c 60 "${FAKE_NGINX}/nginx.conf" 2>/dev/null))"
fi

# T5b 配置校验必须用**目标二进制** (PATH 里的 nginx 未必是目标那份)
if grep -q 'TARGET_NGINX:-t' "${SB}/home/target_nginx.log" 2>/dev/null; then
    ok "T5b 配置校验用目标二进制 (-t), 未误用 PATH 里的 nginx"
else
    bad "T5b 未见对目标二进制的 -t 调用"
fi

# T5c acme.sh 的 --reloadcmd 会被**持久化**并由 cron 在任意环境执行, 故必须是
#     "目标二进制绝对路径 + -s reload", 且不得依赖 systemctl。
rc_cmd="$(cat "${SB}/home/reloadcmd.txt" 2>/dev/null || true)"
if [[ "${rc_cmd}" == "${FAKE_PREFIX}/sbin/nginx -t && ${FAKE_PREFIX}/sbin/nginx -s reload" ]]; then
    ok "T5c reloadcmd = 目标二进制绝对路径 + -s reload"
else
    bad "T5c reloadcmd 不符: '${rc_cmd}'"
fi
if [[ "${rc_cmd}" != *'systemctl'* ]]; then
    ok "T5c reloadcmd 不依赖 systemctl"
else
    bad "T5c reloadcmd 仍在用 systemctl (面板/手动编译的机器上续期不会生效)"
fi

# T6 静态守卫: DOMAIN_REGEX 单一来源 (_common.sh), ssl.sh 使用且不重复定义, check.sh 不重复定义
src_ok=1; use_ok=1; no_dup_ssl=1; no_dup_check=1
grep -qE '^readonly DOMAIN_REGEX=' "${SB}/core/_common.sh" && src_ok=0
grep -q '\[\[ "${DOMAIN}" =~ ${DOMAIN_REGEX} \]\]' "${SB}/service/ssl.sh" && use_ok=0
! grep -qE '^readonly DOMAIN_REGEX=' "${SB}/service/ssl.sh" && no_dup_ssl=0
! grep -qE '^readonly DOMAIN_REGEX=' "${REPO}/core/check.sh" && no_dup_check=0
if [[ $src_ok -eq 0 ]] && [[ $use_ok -eq 0 ]] && [[ $no_dup_ssl -eq 0 ]] && [[ $no_dup_check -eq 0 ]]; then
    ok "T6 DOMAIN_REGEX 单一来源(_common.sh)且 ssl.sh 使用 / 两处均无重复定义"
else
    bad "T6 DOMAIN_REGEX 守卫缺失 (src=$src_ok use=$use_ok noDupSsl=$no_dup_ssl noDupCheck=$no_dup_check)"
fi

# T6b 静态守卫: EMAIL_REGEX 单一来源 (_common.sh), ssl.sh / check.sh 均不重复定义且仍在使用
esrc_ok=1; eno_dup_ssl=1; eno_dup_check=1; euse_ssl=1; euse_check=1
grep -qE '^readonly EMAIL_REGEX=' "${SB}/core/_common.sh" && esrc_ok=0
! grep -qE '^readonly EMAIL_REGEX=' "${SB}/service/ssl.sh" && eno_dup_ssl=0
! grep -qE '^readonly EMAIL_REGEX=' "${REPO}/core/check.sh" && eno_dup_check=0
grep -q '=~ ${EMAIL_REGEX}' "${SB}/service/ssl.sh" && euse_ssl=0
grep -q '=~ $EMAIL_REGEX' "${REPO}/core/check.sh" && euse_check=0
if [[ $esrc_ok -eq 0 ]] && [[ $eno_dup_ssl -eq 0 ]] && [[ $eno_dup_check -eq 0 ]] && [[ $euse_ssl -eq 0 ]] && [[ $euse_check -eq 0 ]]; then
    ok "T6b EMAIL_REGEX 单一来源(_common.sh)且 ssl.sh/check.sh 无重复定义并仍使用"
else
    bad "T6b EMAIL_REGEX 守卫缺失 (src=$esrc_ok noDupSsl=$eno_dup_ssl noDupCheck=$eno_dup_check useSsl=$euse_ssl useCheck=$euse_check)"
fi

# T7 i18n: ssl.sh 引用的 .ssl.* 键在 zh.json 全部存在
keys="$(grep -oE '_i18n "\.\$\{CUR_FILE\}\.[a-zA-Z0-9._-]+"' "${SB}/service/ssl.sh" \
        | sed -E 's/_i18n "\.\$\{CUR_FILE\}\.//; s/"//' | sort -u)"
miss=0
for k in $keys; do
    if ! jq -e ".ssl.$k" "${REPO}/i18n/zh.json" >/dev/null 2>&1; then
        echo "    missing .ssl.$k"; miss=1
    fi
done
if [[ $miss -eq 0 ]]; then
    ok "T7 i18n: $(wc -w <<<"$keys") 个 .ssl.* 键在 zh.json 全部存在"
else
    bad "T7 i18n 缺键"
fi

echo
if [[ $fail -eq 0 ]]; then
    echo "结果: 全部通过 (rc=0)"
else
    echo "结果: 存在失败"
fi

# 清理
if [[ -z "${XRAY_TEST_KEEP:-}" ]]; then
    command rm -rf "${SB}"
fi
exit $fail
