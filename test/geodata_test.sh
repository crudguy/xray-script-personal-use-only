#!/usr/bin/env bash
# geodata.sh download_verified 回归测试 (纯 bash, 不依赖真实 curl/sha256sum)
#   锁定: SHA256 比对通过才原子就位; 不一致/缺失摘要/下载失败均清理并返回 1,
#        且绝不破坏已存在的目标文件.
set -u
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1" >&2; }

SRC='tool/geodata.sh'
if [[ ! -r "$SRC" && -r "${0%/*}/../$SRC" ]]; then cd "${0%/*}/.." || exit 1; fi
TMPD=".workbuddy/tmp/geodata_$$"; rm -rf "$TMPD"; mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT
[[ -r "$SRC" ]] || { bad "找不到 $SRC"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

DV="$(awk '/^download_verified\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC")"
[[ -n "$DV" ]] || { bad "抽取 download_verified 失败"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

WANT_SUM=''; GOT_SUM=''; CURL_FAIL=''
curl() {
  if [[ "$CURL_FAIL" == "1" ]]; then return 1; fi
  local out=''
  while [[ $# -gt 0 ]]; do
    case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
  done
  if [[ "$out" == *.sha256sum ]]; then
    printf '%s  %s\n' "$WANT_SUM" "$(basename "$out" .sha256sum)" > "$out"
  else
    printf 'DATA' > "$out"
  fi
}
sha256sum() { printf '%s  %s\n' "$GOT_SUM" "$1"; }

eval "$DV"

echo "== download_verified SHA256 比对 =="
# 成功: 摘要一致
WANT_SUM='abc123'; GOT_SUM='abc123'; CURL_FAIL=''
rm -f "$TMPD/dst" "$TMPD/dst.new" "$TMPD/dst.sha256sum"
download_verified "https://x/geo.dat" "$TMPD/dst"; rc=$?
if [[ $rc -eq 0 && -f "$TMPD/dst" && "$(cat "$TMPD/dst")" == "DATA" && ! -f "$TMPD/dst.new" ]]; then
  ok "摘要一致 -> 原子就位 dst, 无残留 .new"
else
  bad "成功场景异常 rc=$rc dst[$([[ -f "$TMPD/dst" ]] && echo y || echo n)] new[$([[ -f "$TMPD/dst.new" ]] && echo y || echo n)]"
fi

# 失败: 摘要不一致
WANT_SUM='aaa'; GOT_SUM='bbb'; CURL_FAIL=''
rm -f "$TMPD/dst2" "$TMPD/dst2.new" "$TMPD/dst2.sha256sum"
download_verified "https://x/geo.dat" "$TMPD/dst2"; rc=$?
if [[ $rc -eq 1 && ! -f "$TMPD/dst2" && ! -f "$TMPD/dst2.new" ]]; then
  ok "摘要不一致 -> 返回1且不创建 dst/.new"
else
  bad "不一致场景异常 rc=$rc dst2[$([[ -f "$TMPD/dst2" ]] && echo y || echo n)] new[$([[ -f "$TMPD/dst2.new" ]] && echo y || echo n)]"
fi

# 失败: 摘要文件缺失 (空 want_sum)
WANT_SUM=''; GOT_SUM='zzz'; CURL_FAIL=''
rm -f "$TMPD/dst3" "$TMPD/dst3.new" "$TMPD/dst3.sha256sum"
download_verified "https://x/geo.dat" "$TMPD/dst3"; rc=$?
if [[ $rc -eq 1 ]]; then ok "摘要为空 -> 返回1"; else bad "空摘要应返回1 rc=$rc"; fi

# 失败: 下载中断
WANT_SUM='abc123'; GOT_SUM='abc123'; CURL_FAIL=1
rm -f "$TMPD/dst4" "$TMPD/dst4.new" "$TMPD/dst4.sha256sum"
download_verified "https://x/geo.dat" "$TMPD/dst4"; rc=$?
if [[ $rc -eq 1 ]]; then ok "下载失败 -> 返回1"; else bad "下载失败应返回1 rc=$rc"; fi

# 安全: 失败时已存在的 dst 不被破坏
WANT_SUM='aaa'; GOT_SUM='bbb'; CURL_FAIL=''
printf 'ORIGINAL' > "$TMPD/dst5"
rm -f "$TMPD/dst5.new" "$TMPD/dst5.sha256sum"
download_verified "https://x/geo.dat" "$TMPD/dst5"; rc=$?
if [[ $rc -eq 1 && "$(cat "$TMPD/dst5")" == "ORIGINAL" ]]; then
  ok "失败时原 dst 保留未破坏"
else
  bad "失败时原 dst 被破坏 rc=$rc content[$(cat "$TMPD/dst5" 2>/dev/null)]"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
