#!/bin/sh
# opsbox 运维工作台一键安装/升级脚本
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/qq928820655/opsbox/main/install.sh | sh
#   交互模式询问安装项与密码；管道模式(无终端)按默认值全量安装
# 非交互参数:
#   sh install.sh --dir /opt/opsbox --password YOUR_TOKEN --with-bridge --with-latency
#   sh install.sh --ops-only --no-start --port 8002
# 升级与端口冲突:
#   目标目录已是同款应用 -> 自动走更新/升级（保留 .env 等本机文件）
#   目标端口被其他应用占用 -> 交互询问：1)顺延可用端口 2)指定端口 3)停止占用者后使用
#                            非交互默认顺延，可用 --on-conflict stop 强制释放
#   sh install.sh --port 8002 --on-conflict stop

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
WITH_BRIDGE=1
WITH_LATENCY=1
DO_START=1
OPS_PASSWORD=""
TARGET=""
ON_CONFLICT="next"   # next=顺延可用端口 | stop=停止占用者后使用
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
    --on-conflict)  ON_CONFLICT="$2"; shift 2 ;;
    -h|--help)      sed -n '2,17p' "$0" 2>/dev/null || true; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done
case "$ON_CONFLICT" in
  next|stop) ;;
  *) die "--on-conflict 仅支持 next | stop" ;;
esac

# ---------- 交互判定（curl|sh 时 stdin 是管道，必须读 /dev/tty） ----------
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

ask_yes() { # ask_yes 提示 默认(y/n)；0=是 1=否
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
  log "opsbox 运维工作台一键安装/升级（文件管理 + 资源监控）"
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

# ---------- 基础依赖 ----------
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "需要 curl 或 wget"
command -v python3 >/dev/null 2>&1 || die "需要 python3"
command -v tar >/dev/null 2>&1 || die "需要 tar"

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  else
    wget -qO "$2" "$1"
  fi
}

fetch_extract() { # fetch_extract 仓库 分支 目标目录 显示分支名（保留旧实例 .env 等本机文件）
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

# ---------- 应用身份识别 ----------
detect_dir_kind() { # 目录 -> opsbox | bridge | latency | unknown
  _d="$1"
  if [ -f "$_d/app.py" ] && grep -q "opsbox 运维工作台" "$_d/app.py" 2>/dev/null; then
    echo opsbox
  elif [ -f "$_d/package.json" ] && grep -q '"ai-terminal-bridge"' "$_d/package.json" 2>/dev/null; then
    echo bridge
  elif [ -f "$_d/server.py" ] && grep -qi "latency.*throughput probe" "$_d/server.py" 2>/dev/null; then
    echo latency
  else
    echo unknown
  fi
}

port_pids()  { ss -tlnp 2>/dev/null | grep ":$1 " | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u; }
pid_cwd()    { readlink "/proc/$1/cwd" 2>/dev/null; }
pid_cmd()    { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }
pid_is_kind() { # 应用类型 PID -> 0=该类型的进程
  _c=$(pid_cmd "$2")
  case "$1" in
    opsbox)  case "$_c" in *uvicorn*app:app*|*app:app*uvicorn*) return 0 ;; *) return 1 ;; esac ;;
    bridge)  case "$_c" in *src/server.js*) return 0 ;; *) return 1 ;; esac ;;
    latency) case "$_c" in *server.py*) return 0 ;; *) return 1 ;; esac ;;
  esac
  return 1
}

next_free_port() { # 从指定端口+1 起找 100 个以内
  _p="$1"; _i=0
  while [ $_i -lt 100 ]; do
    _p=$((_p + 1))
    if ! ss -tln 2>/dev/null | grep -q ":$_p "; then
      echo "$_p"; return 0
    fi
    _i=$((_i + 1))
  done
  echo ""
}

stop_port_pids() { # 停掉占用端口的进程（TERM -> KILL）
  _pids=$(port_pids "$1")
  [ -z "$_pids" ] && return 0
  for _p in $_pids; do kill "$_p" 2>/dev/null || true; done
  sleep 1
  _pids=$(port_pids "$1")
  if [ -n "$_pids" ]; then
    for _p in $_pids; do kill -9 "$_p" 2>/dev/null || true; done
    sleep 1
  fi
}

stop_app() { # stop_app 类型 目录 端口（优先用项目自带 stop.sh）
  _kind="$1"; _dir="$2"; _port="$3"
  case "$_kind" in
    opsbox|latency)
      if [ -f "$_dir/stop.sh" ]; then
        ( cd "$_dir" && sh stop.sh >/dev/null 2>&1 ) || true
      fi
      ;;
  esac
  stop_port_pids "$_port"
}

# ---------- 端口解析：free / self(同目录同应用) / sameapp(同款应用其他目录) / foreign ----------
# 结果写入全局: RESOLVED_PORT, PORT_CLASS, CONFLICT_PORT, CONFLICT_PID, CONFLICT_WHO, STOPPED_OLD
resolve_port() { # resolve_port 应用类型 期望端口 目标目录
  _kind="$1"; _want="$2"; _dir="$3"
  RESOLVED_PORT="$_want"; PORT_CLASS="free"; CONFLICT_PORT=""
  CONFLICT_PID=""; CONFLICT_WHO=""; STOPPED_OLD=0
  _pids=$(port_pids "$_want")
  if [ -z "$_pids" ]; then
    return 0
  fi
  for _p in $_pids; do
    if [ "$(pid_cwd "$_p")" = "$_dir" ]; then
      # 同目录同应用：升级场景，直接视为占用（由调用方停止后原地升级）
      PORT_CLASS="self"; CONFLICT_PORT="$_want"
      CONFLICT_WHO="本目录实例（PID=$(echo "$_pids" | awk '{print $1}')）"
      return 0
    fi
  done
  for _p in $_pids; do
    if pid_is_kind "$_kind" "$_p"; then
      PORT_CLASS="sameapp"; CONFLICT_PID="$_p"
      CONFLICT_WHO="同款应用（cwd=$(pid_cwd "$_p" || echo 未知), PID=$_p）"
      break
    fi
  done
  if [ "$PORT_CLASS" != "sameapp" ]; then
    PORT_CLASS="foreign"
    CONFLICT_PID=$(echo "$_pids" | awk '{print $1}')
    CONFLICT_WHO="其他应用（PID=$CONFLICT_PID, cwd=$(pid_cwd "$CONFLICT_PID" || echo 未知), cmd=$(pid_cmd "$CONFLICT_PID" | cut -c1-80)）"
  fi
  CONFLICT_PORT="$_want"

  # ---- 冲突处理 ----
  if [ "$INTERACTIVE" = 1 ]; then
    {
      echo
      echo "  端口 $_want 已被占用：$CONFLICT_WHO"
      echo "    1) 顺延到下一个可用端口"
      echo "    2) 指定其他端口"
      echo "    3) 停止该应用并使用端口 $_want"
    } >/dev/tty 2>/dev/null || true
    _sel=$(ask "请选择" "1")
    case "$_sel" in
      2)
        _new=$(ask "请输入端口" "")
        while [ -n "$(port_pids "$_new")" ] || [ -z "$_new" ]; do
          warn "端口 $_new 不可用"
          _new=$(ask "请输入端口" "")
        done
        RESOLVED_PORT="$_new"
        ;;
      3)
        stop_port_pids "$_want"
        log "已停止端口 $_want 上的原应用"
        RESOLVED_PORT="$_want"; STOPPED_OLD=1
        ;;
      *)
        _nf=$(next_free_port "$_want")
        [ -z "$_nf" ] && die "端口 $_want 之后 100 个端口均被占用"
        warn "顺延端口: $_want -> $_nf（原应用保留运行）"
        RESOLVED_PORT="$_nf"
        ;;
    esac
  else
    if [ "$ON_CONFLICT" = "stop" ]; then
      warn "端口 $_want 被占用（$CONFLICT_WHO），--on-conflict=stop：停止后使用"
      stop_port_pids "$_want"
      RESOLVED_PORT="$_want"; STOPPED_OLD=1
    else
      _nf=$(next_free_port "$_want")
      [ -z "$_nf" ] && die "端口 $_want 之后 100 个端口均被占用"
      warn "端口 $_want 被占用（$CONFLICT_WHO），顺延到 $_nf，原应用保留运行（可用 --on-conflict stop 强制释放）"
      RESOLVED_PORT="$_nf"
    fi
  fi
  return 0
}

# ---------- 安装/升级判定 ----------
# 结果写入全局: APP_MODE(install|upgrade), WAS_RUNNING(0|1)
plan_install() { # plan_install 应用类型 目录
  APP_MODE="install"; WAS_RUNNING=0
  _kind="$1"; _dir="$2"
  if [ -d "$_dir" ]; then
    _k=$(detect_dir_kind "$_dir")
    if [ "$_k" = "$_kind" ]; then
      APP_MODE="upgrade"
    else
      mv "$_dir" "${_dir}.other.$$"
      warn "$_dir 已存在且是其他应用/未知内容（识别为 $_k），已移至 ${_dir}.other.$$"
    fi
  fi
  return 0
}

mkdir -p "$TARGET"
OPS_WAS=0; BR_WAS=0; LAT_WAS=0

# ---------- opsbox：安装或升级 ----------
OPS_DIR="$TARGET/opsbox"
plan_install opsbox "$OPS_DIR"
OPS_MODE="$APP_MODE"
if [ "$APP_MODE" = "upgrade" ]; then
  log "检测到 $OPS_DIR 已是 opsbox，执行更新/升级（保留 .env 等本机配置）"
  if [ -f "$OPS_DIR/.env" ]; then
    _env_port=$(grep '^OPS_PORT=' "$OPS_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2)
    if [ -n "$_env_port" ]; then
      OPS_PORT="$_env_port"
      log "沿用已有配置端口 $OPS_PORT"
    fi
  fi
fi
resolve_port opsbox "$OPS_PORT" "$OPS_DIR"
OPS_PORT="$RESOLVED_PORT"
if [ "$PORT_CLASS" = "self" ]; then
  OPS_WAS=1
  log "opsbox 正在运行（端口 $CONFLICT_PORT），升级前先停止"
  stop_app opsbox "$OPS_DIR" "$CONFLICT_PORT"
elif [ "$PORT_CLASS" = "sameapp" ] && [ "$STOPPED_OLD" = 0 ]; then
  log "端口 $CONFLICT_PORT 由另一目录的 opsbox 保留运行，本次安装使用端口 $OPS_PORT"
fi

log "安装 opsbox -> $OPS_DIR"
fetch_extract "$REPO_OPS" "$BRANCH_OPS" "$OPS_DIR" "$BRANCH_OPS"
chmod +x "$OPS_DIR"/opsbox/*.sh 2>/dev/null || true
if [ "$OPS_PORT" != "8002" ] && [ -f "$OPS_DIR/.env" ]; then
  sed -i "s/^OPS_PORT=.*/OPS_PORT=$OPS_PORT/" "$OPS_DIR/.env" 2>/dev/null || true
fi

# psutil
if ! python3 -c "import psutil" >/dev/null 2>&1; then
  log "安装 python 依赖 psutil"
  pip3 install psutil >/dev/null 2>&1 \
    || pip3 install --break-system-packages psutil >/dev/null 2>&1 \
    || pip3 install --user psutil >/dev/null 2>&1 \
    || die "psutil 安装失败，请手动执行: pip3 install psutil"
fi

# opsbox .env（首次安装写入；升级保留）
if [ -f "$OPS_DIR/.env" ]; then
  log "保留已有 opsbox/.env"
else
  cat > "$OPS_DIR/.env" <<EOF
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
  chmod 600 "$OPS_DIR/.env"
fi

# ---------- ai-terminal-bridge：安装或升级 ----------
if [ "$WITH_BRIDGE" = 1 ]; then
  BRIDGE_DIR="$TARGET/ai-terminal-bridge"
  plan_install bridge "$BRIDGE_DIR"
  if [ "$APP_MODE" = "upgrade" ]; then
    log "检测到 $BRIDGE_DIR 已是 ai-terminal-bridge，执行更新/升级"
    if [ -f "$BRIDGE_DIR/.env" ]; then
      _env_port=$(grep '^AITB_PORT=' "$BRIDGE_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2)
      [ -n "$_env_port" ] && BRIDGE_PORT="$_env_port" && log "沿用已有桥接端口 $BRIDGE_PORT"
    fi
  fi
  resolve_port bridge "$BRIDGE_PORT" "$BRIDGE_DIR"
  BRIDGE_PORT="$RESOLVED_PORT"
  if [ "$PORT_CLASS" = "self" ]; then
    BR_WAS=1
    log "桥接正在运行（端口 $CONFLICT_PORT），升级前先停止"
    stop_port_pids "$CONFLICT_PORT"
  elif [ "$PORT_CLASS" = "sameapp" ] && [ "$STOPPED_OLD" = 0 ]; then
    log "端口 $CONFLICT_PORT 由另一目录的 ai-terminal-bridge 保留运行，本次安装使用端口 $BRIDGE_PORT"
  fi
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
    log "安装 ai-terminal-bridge -> $BRIDGE_DIR"
    fetch_extract "$REPO_BRIDGE" "$BRIDGE_BRANCH" "$BRIDGE_DIR" "$BRIDGE_BRANCH"
    ( cd "$BRIDGE_DIR" && npm install --no-audit --no-fund >/dev/null 2>&1 ) \
      || warn "npm install 失败，请手动在 $BRIDGE_DIR 执行 npm install"
    if [ ! -f "$BRIDGE_DIR/.env" ]; then
      cat > "$BRIDGE_DIR/.env" <<EOF
AITB_HOST=0.0.0.0
AITB_PORT=$BRIDGE_PORT
AITB_TOKEN=$OPS_PASSWORD
AITB_CWD=$TARGET
AITB_CORS=*
EOF
      chmod 600 "$BRIDGE_DIR/.env"
    fi
    if [ -f "$BRIDGE_DIR/.env" ] && [ "$BRIDGE_PORT" != "8787" ]; then
      sed -i "s/^AITB_PORT=.*/AITB_PORT=$BRIDGE_PORT/" "$BRIDGE_DIR/.env" 2>/dev/null || true
    fi
  else
    warn "node/npm 不可用，跳过终端桥接（opsbox 菜单中该入口将不可用）"
    WITH_BRIDGE=0
  fi
fi

# ---------- latency-test：安装或升级 ----------
if [ "$WITH_LATENCY" = 1 ]; then
  LATENCY_DIR="$TARGET/latency-test"
  plan_install latency "$LATENCY_DIR"
  if [ "$APP_MODE" = "upgrade" ]; then
    log "检测到 $LATENCY_DIR 已是 latency-test，执行更新/升级"
    if [ -f "$LATENCY_DIR/.env" ]; then
      _env_port=$(grep '^LAT_PORT=' "$LATENCY_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2)
      [ -n "$_env_port" ] && LATENCY_PORT="$_env_port" && log "沿用已有探针端口 $LATENCY_PORT"
    fi
  fi
  resolve_port latency "$LATENCY_PORT" "$LATENCY_DIR"
  LATENCY_PORT="$RESOLVED_PORT"
  if [ "$PORT_CLASS" = "self" ]; then
    LAT_WAS=1
    log "latency-test 正在运行（端口 $CONFLICT_PORT），升级前先停止"
    stop_app latency "$LATENCY_DIR" "$CONFLICT_PORT"
  elif [ "$PORT_CLASS" = "sameapp" ] && [ "$STOPPED_OLD" = 0 ]; then
    log "端口 $CONFLICT_PORT 由另一目录的 latency-test 保留运行，本次安装使用端口 $LATENCY_PORT"
  fi
  log "安装 latency-test -> $LATENCY_DIR"
  fetch_extract "$REPO_LATENCY" "$LATENCY_BRANCH" "$LATENCY_DIR" "$LATENCY_BRANCH"
  chmod +x "$LATENCY_DIR"/*.sh 2>/dev/null || true
  if [ "$LATENCY_PORT" != "8005" ] && [ ! -f "$LATENCY_DIR/.env" ]; then
    echo "LAT_PORT=$LATENCY_PORT" > "$LATENCY_DIR/.env"
  fi
fi

# ---------- 启动（--no-start 时仅重启升级前已在运行的组件） ----------
START_LAT=0; START_BR=0; START_OPS=0
if [ "$DO_START" = 1 ]; then
  [ "$WITH_LATENCY" = 1 ] && START_LAT=1
  [ "$WITH_BRIDGE" = 1 ] && START_BR=1
  START_OPS=1
else
  if [ "$WITH_LATENCY" = 1 ] && [ "$LAT_WAS" = 1 ]; then
    START_LAT=1; log "latency-test 升级前在运行，更新后原样重启"
  fi
  if [ "$WITH_BRIDGE" = 1 ] && [ "$BR_WAS" = 1 ]; then
    START_BR=1; log "ai-terminal-bridge 升级前在运行，更新后原样重启"
  fi
  if [ "$OPS_WAS" = 1 ]; then
    START_OPS=1; log "opsbox 升级前在运行，更新后原样重启"
  fi
fi
if [ "$START_LAT" = 1 ]; then
  ( cd "$TARGET/latency-test" && sh start.sh >/dev/null 2>&1 ) || warn "latency-test 启动失败，日志: $TARGET/latency-test/server.log"
fi
if [ "$START_BR" = 1 ]; then
  ( cd "$TARGET/ai-terminal-bridge" && nohup npm start > server.log 2>&1 & ) || warn "ai-terminal-bridge 启动失败，日志: $TARGET/ai-terminal-bridge/server.log"
fi
if [ "$START_OPS" = 1 ]; then
  ( cd "$TARGET/opsbox" && sh start.sh >/dev/null 2>&1 ) || warn "opsbox 启动失败，日志: $TARGET/opsbox/server.log"
  sleep 2
fi

# ---------- 汇总 ----------
if [ -f "$OPS_DIR/.env" ]; then
  _env_pw=$(grep '^OPS_PASSWORD=' "$OPS_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2)
  [ -n "$_env_pw" ] && OPS_PASSWORD="$_env_pw"
fi
MAIN_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
[ -z "$MAIN_IP" ] && MAIN_IP=127.0.0.1
echo
log "完成！"
if [ "$OPS_MODE" = "upgrade" ]; then
  echo "  模式     : 更新/升级（本机配置已保留）"
else
  echo "  模式     : 全新安装"
fi
echo "  opsbox   : http://$MAIN_IP:$OPS_PORT/   密码/token: $OPS_PASSWORD"
if [ "$WITH_BRIDGE" = 1 ]; then
  echo "  终端桥接 : http://127.0.0.1:$BRIDGE_PORT/  （已关联，opsbox 下拉菜单免登录跳转）"
fi
if [ "$WITH_LATENCY" = 1 ]; then
  echo "  链路探针 : http://127.0.0.1:$LATENCY_PORT/"
fi
echo "  目录     : $TARGET"
echo "  配置     : $TARGET/opsbox/.env（改密码后执行 sh $TARGET/opsbox/restart.sh 生效）"
if [ "$START_OPS" = 0 ]; then
  echo "  未启动   : 手动执行 sh $TARGET/opsbox/start.sh"
fi
echo
log "登录 opsbox 后，通过右上角下拉菜单直达已安装的上游应用。"
