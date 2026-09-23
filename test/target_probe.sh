#!/usr/bin/env bash
# =============================================================================
# 脚本名称: target_probe.sh
# 功能描述: 手工校验 target (Reality 伪装目标) 是否满足脚本的硬条件 —— 逐个探测
#           DNS 解析 / 443 连通 / TLS 1.3 / X25519 密钥交换, 并给出分级结论。
#           不带参数时遍历 config.json 的 .target 全部预设; 也可直接给域名抽查。
#
# 用法:
#   bash test/target_probe.sh                    # 校验全部预设
#   bash test/target_probe.sh www.apple.com      # 校验指定域名
#
# 为什么不在 CI 里跑: 结论取决于**运行探测的那台机器**的网络。CI runner 与用户 VPS
#   的出网环境不同 (大陆网络还有 DNS 投毒与 SNI 阻断), 在 CI 上红/绿都不代表用户
#   的真实情况。故这是"改预设前手工跑一次"的工具, 不是门禁。
#
# 判定口径 (与 core/check.sh 的 check_domain_security 一一对应):
#   1. dig 能取到 A/AAAA 记录             -> resolve_domain
#   2. 能建立到 443 的 TCP 连接           -> test_tcp_connection
#   3. TLS 握手为 TLSv1.3                 -> get_tls_info + grep TLSv1.3
#   4. 密钥交换含 X25519                  -> get_tls_info + grep X25519
#   主列 (带 SNI) 是判定依据 —— Reality 真实链路上 dest 收到的是带 SNI 的
#   ClientHello, 所以带 SNI 的结论才贴近实际。带 SNI/不带 SNI 不一致时, 说明该
#   域名按 SNI 分流, 脚本旧的"不带 SNI"探测会误拒它。
#   每个 TLS 探测失败时自动重试一次: 单次失败常是国内网络的瞬时抖动, 重试仍失败
#   才算真不可用 (结论列会标 * 表示"重试后才通过", 提示该线路不太稳)。
#
# 依赖: bash, dig, openssl, timeout
# 退出码: 0 = 无 REJECT, 1 = 存在 REJECT
# =============================================================================
set -u

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)" || exit 1

# 探测一次 TLS, 输出分组信息(可能为空), 返回值: 0=TLS1.3+X25519 1=有 TLS1.3 无 X25519 2=无 TLS1.3
tls_probe() { # $1=host $2=sni|nosni
    local host="$1" mode="$2" info='' group=''
    if [[ "${mode}" == 'sni' ]]; then
        info="$(echo QUIT | timeout 10 stdbuf -oL openssl s_client -connect "${host}:443" -servername "${host}" -tls1_3 -alpn h2 2>&1 | tr -d '\0')"
    else
        info="$(echo QUIT | timeout 10 stdbuf -oL openssl s_client -connect "${host}:443" -tls1_3 -alpn h2 2>&1 | tr -d '\0')"
    fi
    group="$(printf '%s' "${info}" | grep -iE 'negotiated tls1.3 group|server temp key' | head -1 | sed 's/^[[:space:]]*//')"
    printf '%s' "${group}"
    if ! printf '%s' "${info}" | grep -q 'TLSv1.3'; then
        return 2
    fi
    printf '%s' "${info}" | grep -q 'X25519' || return 1
    return 0
}

# 带重试的一轮: 返回哨兵串 OK / OK_RETRY / NO_X25519 / NO_TLS13
tls_round() { # $1=host $2=sni|nosni
    local host="$1" mode="$2" rc=0
    tls_probe "${host}" "${mode}" >/dev/null 2>&1; rc=$?
    if ((rc == 0)); then
        printf 'OK'
        return 0
    fi
    # 失败重试一次: 国内网络瞬时抖动很常见, 单次失败不足以定罪
    tls_probe "${host}" "${mode}" >/dev/null 2>&1; rc=$?
    case "${rc}" in
    0) printf 'OK_RETRY' ;;
    1) printf 'NO_X25519' ;;
    *) printf 'NO_TLS13' ;;
    esac
    return 0
}

probe_one() {
    local host="$1"

    local dns='FAIL'
    if [[ -n "$(dig +short "${host}" 2>/dev/null)" || -n "$(dig +short AAAA "${host}" 2>/dev/null)" ]]; then
        dns='OK'
    fi

    local tcp='FAIL'
    timeout 5 bash -c "exec 3<>/dev/tcp/${host}/443" 2>/dev/null && tcp='OK'

    local group=''
    group="$(tls_probe "${host}" 'sni')" || true

    local tls_sni='' tls_nosni=''
    tls_sni="$(tls_round "${host}" 'sni')"
    tls_nosni="$(tls_round "${host}" 'nosni')"

    local verdict=''
    if [[ "${dns}" != 'OK' ]]; then
        verdict='NODNS'
    elif [[ "${tcp}" != 'OK' ]]; then
        verdict='OFFLINE'
    elif [[ "${tls_sni}" == 'NO_TLS13' ]]; then
        verdict='NOTLS13'
    elif [[ "${tls_sni}" == 'NO_X25519' ]]; then
        verdict='NOX25519'
    elif [[ "${tls_sni}" == 'OK_RETRY' ]]; then
        verdict='PASS'
    else
        verdict='PASS'
    fi

    printf '%-9s %-24s %-5s %-5s %-10s %-10s %s\n' \
        "${verdict}" "${host}" "${dns}" "${tcp}" "${tls_sni}" "${tls_nosni}" "${group:-未取得}"
}

main() {
    local -a hosts=()
    if (($# > 0)); then
        hosts=("$@")
    else
        local list=''
        list="$(jq -r '.target | keys[]' "${ROOT}/config.json" 2>/dev/null || true)"
        if [[ -z "${list}" ]]; then
            printf '无法从 %s 读取 .target 预设清单 (需要 jq)\n' "${ROOT}/config.json" >&2
            return 1
        fi
        read -r -a hosts <<<"$(printf '%s' "${list}" | tr '\n' ' ')"
    fi

    printf '%-9s %-24s %-5s %-5s %-10s %-10s %s\n' 'VERDICT' 'HOST' 'DNS' 'TCP' 'TLS1.3+SNI' 'TLS1.3(w/o)' 'GROUP(SNI)'
    local pass=0 reject=0 line='' verdict=''
    for h in "${hosts[@]}"; do
        line="$(probe_one "${h}")"
        printf '%s\n' "${line}"
        verdict="${line%% *}"
        if [[ "${verdict}" == 'PASS' ]]; then
            pass=$((pass + 1))
        else
            reject=$((reject + 1))
        fi
    done

    printf '\nPASS=%d REJECT=%d\n' "${pass}" "${reject}"
    printf '判定: PASS=四项全过; OFFLINE=443 不通; NODNS=解析失败; NOTLS13=无 TLS 1.3; NOX25519=TLS1.3 但无 X25519\n'
    printf '注: TLS1.3+SNI 列带 OK_RETRY 表示重试后才通过 —— 该线路不太稳, 换域名更稳妥\n'
    ((reject == 0))
}

main "$@"
