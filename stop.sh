#!/bin/bash
PORT="${OPS_PORT:-8002}"
PIDS=$(ss -tlnp 2>/dev/null | grep ":${PORT} " | grep -oP 'pid=\K[0-9]+' | sort -u)
if [ -n "$PIDS" ]; then kill $PIDS && echo "已停止: $PIDS"; else echo "端口 ${PORT} 无进程"; fi
