#!/usr/bin/env bash
# _replace_in_file 功能回归测试 (纯 bash, 不依赖 jq / 框架)
# 锁定 P2-3 第二部分修复: 原 "sed -i 's|ph|val|g' file" 的两类隐患 ——
#   1) 替换值含定界符(|)或 & 时注入/破坏;
#   2) 搜索串来自变量且为空时 s|| 非法 sed 触发 ERR trap 中止。
# 同时验证搜索串中的正则元字符(如 .)按字面匹配。
set -Eeuo pipefail

PASS=0
FAIL=0

SRC="$(awk '/^function _replace_in_file\(\) \{/,/^}/' core/_common.sh)"
if [[ -z "$SRC" ]]; then
    echo "FATAL: 未能从 core/_common.sh 抽取 _replace_in_file"; exit 1
fi
eval "$SRC"

assert() {
    local desc="$1" got="$2" exp="$3"
    if [[ "$got" == "$exp" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc"
        echo "  got: [$got]"
        echo "  exp: [$exp]"
    fi
}

# 注: 必须带 /tmp 模板 —— 裸 mktemp 在 Windows/Git-Bash 下可能返回 "C:/..." 风格路径,
#     MSYS 无法解析, 且 set -e + trap 收尾 rm 失败会直接中止脚本。
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/xray-replfile.XXXXXX")"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT

# 1. 基础替换 + 元字符 . 按字面 (example.com)
f="$TMPD/a.conf"; printf '%s' 'server_name example.com; proxy=PROXY_TARGET; sock=unix:/dev/shm/nginx/custom_site.sock;' >"$f"
_replace_in_file "$f" "example.com" "real.com"
_replace_in_file "$f" "PROXY_TARGET" "http://1.2.3.4:8080"
_replace_in_file "$f" "unix:/dev/shm/nginx/custom_site.sock" "unix:/dev/shm/nginx/x.sock"
got="$(cat "$f")"
assert "basic-dot-literal" "$got" 'server_name real.com; proxy=http://1.2.3.4:8080; sock=unix:/dev/shm/nginx/x.sock;'

# 2. 替换值含定界符 | (原 sed 会破坏)
f="$TMPD/b.conf"; printf '%s' 'val=PLACE' >"$f"
_replace_in_file "$f" "PLACE" "a|b|c"
got="$(cat "$f")"
assert "pipe-val" "$got" 'val=a|b|c'

# 3. 替换值含 & (原 sed 会把 & 当整行匹配)
f="$TMPD/c.conf"; printf '%s' 'val=PLACE' >"$f"
_replace_in_file "$f" "PLACE" "x&y&z"
got="$(cat "$f")"
assert "amp-val" "$got" 'val=x&y&z'

# 4. 空替换值 (原 sed 合法, 这里也应正常清空)
f="$TMPD/d.conf"; printf '%s' 'keep=PLACE-end' >"$f"
_replace_in_file "$f" "PLACE" ""
got="$(cat "$f")"
assert "empty-repl" "$got" 'keep=-end'

# 5. 搜索串为空 -> 不崩溃, 内容不变 (原 sed s|| 会非法中止)
f="$TMPD/e.conf"; printf '%s' 'hello world' >"$f"
_replace_in_file "$f" "" "x" || true
got="$(cat "$f")"
assert "empty-search" "$got" 'hello world'

# 6. 搜索串不在文件中 -> 不变
f="$TMPD/f.conf"; printf '%s' 'hello world' >"$f"
_replace_in_file "$f" "NOPE" "x"
got="$(cat "$f")"
assert "no-match" "$got" 'hello world'

# 7. 多处出现全部替换 (g 语义)
f="$TMPD/g.conf"; printf '%s' 'X Y X Y X' >"$f"
_replace_in_file "$f" "X" "Z"
got="$(cat "$f")"
assert "global" "$got" 'Z Y Z Y Z'

# 8. 权限位保留 (仅当平台真正支持 Unix 权限时才断言; Windows/MSYS 不强制, 跳过)
f="$TMPD/h.conf"; printf '%s' 'data' >"$f"
chmod 640 "$f" 2>/dev/null || true
_before="$(stat -c '%a' "$f" 2>/dev/null || echo none)"
_replace_in_file "$f" "data" "data2"
if command -v stat >/dev/null 2>&1 && [[ "${_before}" == "640" ]]; then
    got="$(stat -c '%a' "$f")"
    assert "perms-kept" "$got" "640"
else
    PASS=$((PASS + 1))   # 平台不强制 Unix 权限 (如 Windows/MSYS), 跳过该断言 (目标 Linux 服务器支持)
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
