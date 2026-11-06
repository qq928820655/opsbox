#!/bin/sh
# opsbox 运维工作台一键安装脚本
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/qq928820655/opsbox/main/install.sh | sh
#   交互模式下会询问安装项与密码；管道模式(无终端)按默认值全量安装
# 也可带参数非交互安装（显式指定的参数不会再次询问）:
#   sh install.sh --dir /opt/opsbox --password YOUR_TOKEN --with-bridge --with-latency
#   sh install.sh --ops-only --no-start --port 8002

set -eu

REPO_OPS="qq928820655/opsbox"
REPO_BRIDGE="qq928820655/ai-terminal-bridge"
REPO_LATENCY="qq928820655/latency-test"
BRANCH_OPS="main"
BRIDGE_BRANCH="main"
LATENCY_BRANCH="master"

OPS_PORT=8002
BRIDGE_PORT=8787
LATENCY_PORT=8005
WITH_BRIDGE=1      # 默认安装上游并关联
WITH_LATENCY=1
DO_START=1
OPS_PASSWORD=""    # 为空则随机生成
TARGET=""          # 为空则按身份选择 /opt/opsbox 或 ~/opsbox
INTERACTIVE=0

log()  { printf '\033[32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 参数解析（显式参数优先于交互询问） ----------
SET_TARGET=0; SET_PASSWORD=0; SET_BRIDGE=0; SET_LATENCY=0; SET_START=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)          TARGET="$2"; SET_TARGET=1; shift 2 ;;
    --port)         OPS_PORT="$2"; shift 2 ;;
    --password)     OPS_PASSWORD="$2"; SET_PASSWORD=1; shift 2 ;;
    --bridge-port)  BRIDGE_PORT="$2"; shift 2 ;;
    --latency-port) LATENCY_PORT="$2"; shift 2 ;;
    --with-bridge)  WITH_BRIDGE=1; SET_BRIDGE=1; shift ;;
    --no-bridge)    WITH_BRIDGE=0; SET_BRIDGE=1; shift ;;
    --with-latency) WITH_LATENCY=1; SET_LATENCY=1; shift ;;
    --no-latency)   WITH_LATENCY=0; SET_LATENCY=1; shift ;;
    --ops-only)     WITH_BRIDGE=0; WITH_LATENCY=0; SET_BRIDGE=1; SET_LATENCY=1; shift ;;
    --start)        DO_START=1; SET_START=1; shift ;;
    --no-start)     DO_START=0; SET_START=1; shift ;;
    -h|--help)      sed -n '2,10p' "$0" 2>/dev/null || true; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

# ---------- 交互判定（curl|sh 时 stdin 是管道，必须读 /dev/tty） ----------
# /dev/tty 需真实可写才进入交互，沙箱/容器里静默回退默认值
if [ -t 0 ]; then
  INTERACTIVE=1
elif [ -t 1 ] && (printf '' >/dev/tty) 2>/dev/null; then
  INTERACTIVE=1
fi

ask() { # ask 提示 默认值
  _prompt="$1"; _def="$2"; _ans=""
  if [ "$INTERACTIVE" = 1 ]; then
    printf '%s [%s] ' "$_prompt" "$_def" >/dev/tty 2>/dev/null || true
    IFS= read -r _ans </dev/tty 2>/dev/null || _ans=""
  fi
  if [ -n "$_ans" ]; then printf '%s' "$_ans"; else printf '%s' "$_def"; fi
}

ask_yes() { # ask_yes 提示 默认(y/n)；返回 0=是 1=否
  _ans=$(ask "$1" "$2")
  if [ -z "$_ans" ]; then _ans="$2"; fi
  case "$_ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 12
  else
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

if [ "$INTERACTIVE" = 1 ]; then
  log "opsbox 运维工作台一键安装（文件管理 + 资源监控）"
  if [ "$SET_TARGET" = 0 ]; then
    _def_dir="/opt/opsbox"; [ "$(id -u)" != 0 ] && _def_dir="$HOME/opsbox"
    TARGET=$(ask "安装目录" "$_def_dir")
  fi
  if [ "$SET_PASSWORD" = 0 ]; then
    OPS_PASSWORD=$(ask "访问密码/令牌（opsbox 与桥接共用，即关联 token）" "$(gen_password)")
  fi
  if [ "$SET_BRIDGE" = 0 ]; then
    ask_yes "是否安装终端桥接 ai-terminal-bridge（端口 $BRIDGE_PORT，Web 终端）并自动关联？" "y" && WITH_BRIDGE=1 || WITH_BRIDGE=0
  fi
  if [ "$SET_LATENCY" = 0 ]; then
    ask_yes "是否安装链路探针 latency-test（端口 $LATENCY_PORT）？" "y" && WITH_LATENCY=1 || WITH_LATENCY=0
  fi
  if [ "$SET_START" = 0 ]; then
    ask_yes "安装完成后立即启动服务？" "y" && DO_START=1 || DO_START=0
  fi
fi

[ -z "$TARGET" ] && { [ "$(id -u)" = 0 ] && TARGET=/opt/opsbox || TARGET="$HOME/opsbox"; }
[ -z "$OPS_PASSWORD" ] && OPS_PASSWORD=$(gen_password)

# ---------- 依赖检查 ----------
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "需要 curl 或 wget"
command -v python3 >/dev/null 2>&1 || die "需要 python3"
command -v tar >/dev/null 2>&1 || die "需要 tar"

fetch() { # fetch URL 输出文件
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  else
    wget -qO "$2" "$1"
  fi
}

# fetch_extract 仓库 分支 目标目录 显示分支名（含旧实例 .env 等本机文件迁移）
fetch_extract() {
  _repo="$1"; _branch="$2"; _dest="$3"; _show="$4"
  _tmp="$TARGET/.tgz.$$"
  mkdir -p "$_dest.new"
  log "下载 $_repo@$_show -> $_dest.new"
  fetch "https://github.com/$_repo/archive/refs/heads/$_branch.tar.gz" "$_tmp"
  tar -xzf "$_tmp" -C "$_dest.new" --strip-components=1
  rm -f "$_tmp"
  if [ -d "$_dest" ]; then
    for _keep in .env .secret bridge_token.json alert_config.json; do
      if [ -f "$_dest/$_keep" ]; then cp -f "$_dest/$_keep" "$_dest.new/$_keep"; fi
    done
    rm -rf "$_dest"
  fi
  mv "$_dest.new" "$_dest"
}

# ---------- 安装 opsbox ----------
log "安装 opsbox -> $TARGET/opsbox"
fetch_extract "$REPO_OPS" "$BRANCH_OPS" "$TARGET/opsbox" "$BRANCH_OPS"
chmod +x "$TARGET"/opsbox/*.sh 2>/dev/null || true

# psutil（opsbox 运行依赖）
if ! python3 -c "import psutil" >/dev/null 2>&1; then
  log "安装 python 依赖 psutil"
  pip3 install psutil >/dev/null 2>&1 \
    || pip3 install --break-system-packages psutil >/dev/null 2>&1 \
    || pip3 install --user psutil >/dev/null 2>&1 \
    || die "psutil 安装失败，请手动执行: pip3 install psutil"
fi

# opsbox .env（上游关联配置在此落盘）
if [ -f "$TARGET/opsbox/.env" ]; then
  warn "保留已有 $TARGET/opsbox/.env（如需改密码请编辑后 restart）"
else
  cat > "$TARGET/opsbox/.env" <<EOF
OPS_PORT=$OPS_PORT
OPS_PASSWORD=$OPS_PASSWORD

# 上游关联：终端桥接（免登录跳转依赖 AITB_TOKEN 与 bridge 的 bootstrap 令牌一致）
AITB_URL=http://127.0.0.1:$BRIDGE_PORT
AITB_TOKEN=$OPS_PASSWORD
AITB_PUBLIC=

# 上游关联：链路探针
LATENCY_URL=http://127.0.0.1:$LATENCY_PORT
LATENCY_PUBLIC=
EOF
  chmod 600 "$TARGET/opsbox/.env"
fi

# ---------- 安装 ai-terminal-bridge ----------
if [ "$WITH_BRIDGE" = 1 ]; then
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    warn "未检测到 node/npm，尝试通过系统包管理器安装"
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y nodejs npm >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y nodejs npm >/dev/null 2>&1 || true
    fi
  fi
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    log "安装 ai-terminal-bridge -> $TARGET/ai-terminal-bridge"
    fetch_extract "$REPO_BRIDGE" "$BRIDGE_BRANCH" "$TARGET/ai-terminal-bridge" "$BRIDGE_BRANCH"
    ( cd "$TARGET/ai-terminal-bridge" && npm install --no-audit --no-fund >/dev/null 2>&1 ) \
      || warn "npm install 失败，请手动在 $TARGET/ai-terminal-bridge 执行 npm install"
    if [ ! -f "$TARGET/ai-terminal-bridge/.env" ]; then
      cat > "$TARGET/ai-terminal-bridge/.env" <<EOF
AITB_HOST=0.0.0.0
AITB_PORT=$BRIDGE_PORT
AITB_TOKEN=$OPS_PASSWORD
AITB_CWD=$TARGET
AITB_CORS=*
EOF
      chmod 600 "$TARGET/ai-terminal-bridge/.env"
    fi
  else
    warn "node/npm 不可用，跳过终端桥接（opsbox 菜单中该入口将不可用）"
    WITH_BRIDGE=0
  fi
fi

# ---------- 安装 latency-test ----------
if [ "$WITH_LATENCY" = 1 ]; then
  log "安装 latency-test -> $TARGET/latency-test"
  fetch_extract "$REPO_LATENCY" "$LATENCY_BRANCH" "$TARGET/latency-test" "$LATENCY_BRANCH"
  chmod +x "$TARGET"/latency-test/*.sh 2>/dev/null || true
fi

# ---------- 启动 ----------
if [ "$DO_START" = 1 ]; then
  if [ "$WITH_LATENCY" = 1 ]; then
    ( cd "$TARGET/latency-test" && sh start.sh >/dev/null 2>&1 ) || warn "latency-test 启动失败，日志: $TARGET/latency-test/server.log"
  fi
  if [ "$WITH_BRIDGE" = 1 ]; then
    ( cd "$TARGET/ai-terminal-bridge" && nohup npm start > server.log 2>&1 & ) || warn "ai-terminal-bridge 启动失败，日志: $TARGET/ai-terminal-bridge/server.log"
  fi
  ( cd "$TARGET/opsbox" && sh start.sh >/dev/null 2>&1 ) || warn "opsbox 启动失败，日志: $TARGET/opsbox/server.log"
  sleep 2
fi

# ---------- 汇总 ----------
MAIN_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
[ -z "$MAIN_IP" ] && MAIN_IP=127.0.0.1
echo
log "安装完成！"
echo "  opsbox   : http://$MAIN_IP:$OPS_PORT/   密码/token: $OPS_PASSWORD"
if [ "$WITH_BRIDGE" = 1 ]; then
  echo "  终端桥接 : http://127.0.0.1:$BRIDGE_PORT/  （已关联，opsbox 下拉菜单免登录跳转）"
fi
if [ "$WITH_LATENCY" = 1 ]; then
  echo "  链路探针 : http://127.0.0.1:$LATENCY_PORT/"
fi
echo "  目录     : $TARGET"
echo "  配置     : $TARGET/opsbox/.env（改密码后执行 sh $TARGET/opsbox/restart.sh 生效）"
if [ "$DO_START" = 0 ]; then
  echo "  未启动   : 手动执行 sh $TARGET/opsbox/start.sh"
fi
echo
log "登录 opsbox 后，通过右上角下拉菜单直达已安装的上游应用。"
