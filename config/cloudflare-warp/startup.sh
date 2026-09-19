#!/usr/bin/env bash
# Cloudflare WARP 容器启动脚本
# 已注册 (存在 reg.json): 把容器暴露的 40001 转发到 WARP 本地代理 40000, 并常驻运行 warp-svc;
# 未注册: 拉起守护进程完成首次注册 (registration new / mode proxy / connect), 成功后退出,
#         由容器重启策略重新进入"已注册"分支。

if [ -f /var/lib/cloudflare-warp/reg.json ]; then
    # 已注册: 转发代理端口并启动常驻服务
    echo "Forwarding 0.0.0.0:40001 to 127.0.0.1:40000"
    socat TCP-LISTEN:40001,reuseaddr,fork TCP:127.0.0.1:40000 &
    echo "Starting Cloudflare WARP"
    warp-svc
else
    # 未注册: 首次注册后退出, 由容器重启接管
    echo "Cloudflare WARP not registered, try start a daemon and register it."
    warp-svc >&/dev/null &
    sleep 5
    echo "Registering Cloudflare WARP"
    warp-cli --accept-tos registration new
    echo "Setting Cloudflare WARP mode to proxy"
    warp-cli --accept-tos mode proxy
    echo "Connecting Cloudflare WARP"
    warp-cli --accept-tos connect
    echo "Done, killing daemon and exiting. This container should work after restart."
    exit 1
fi
