#!/bin/sh
# opsbox 运维工作台一键安装/升级/管理脚本
# 用法:
#   交互式菜单（安装/升级、改密码、启动、停止、重启）:
#     curl -fsSL https://raw.githubusercontent.com/qq928820655/opsbox/main/install.sh | sh
#   管理子命令（同样支持 curl | sh -s -- <动作>）:
#     sh install.sh status|start|stop|restart [all|ops|bridge|latency]
#   无终端管道模式（cron/自动化）按默认值全量安装
# 非交互参数:
#   sh install.sh --dir /opt/opsbox --password YOUR_TOKEN --with-bridge --with-latency
#   sh install.sh --ops-only --no-start --port 8002
# 升级与端口冲突:
#   目标目录已是同款应用 -> 自动升级并保留 .env（密码/端口沿用已有配置）
#   目标端口被其他应用占用 -> 交互询问：1)顺延可用端口(默认) 2)指定端口 3)停止占用者后使用
# 服务管理（安装后本机直用）:
#   sh /opt/opsbox/manage.sh

set -eu

REPO_OPS="qq928820655/opsbox"
REPO_BRIDGE="qq928820655/ai-terminal-bridge"
REPO_LATENCY="qq928820655/latency-test"
BRANCH_OPS="main"
BRIDGE_BRANCH="main"
LATENCY_BRANCH="master"

OPS_PORT=8002
BRIDGE_PORT=8790
LATENCY_PORT=8005
WITH_BRIDGE=1
WITH_LATENCY=1
DO_START=1
OPS_PASSWORD=""
TARGET=""
ON_CONFLICT="next"   # next=顺延可用端口 | stop=停止占用者后使用
INTERACTIVE=0
ACTION=""
SVC_WORD="all"
EXIST_INSTALLED=0

log()  { printf '\033[32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 参数解析（显式参数优先于已有配置与交互询问） ----------
SET_TARGET=0; SET_PASSWORD=0; SET_BRIDGE=0; SET_LATENCY=0; SET_START=0
SET_PORT=0; SET_BPORT=0; SET_LPORT=0
while [ $# -gt 0 ]; do
  case "$1" in
    status|start|stop|restart|menu)
      [ -n "$ACTION" ] && die "管理动作只能指定一个"
      ACTION="$1"; shift ;;
    all|ops|opsbox|bridge|ai-terminal-bridge|latency|latency-test)
      SVC_WORD="$1"; shift ;;
    --dir)          TARGET="$2"; SET_TARGET=1; shift 2 ;;
    --port)         OPS_PORT="$2"; SET_PORT=1; shift 2 ;;
    --password)     OPS_PASSWORD="$2"; SET_PASSWORD=1; shift 2 ;;
    --bridge-port)  BRIDGE_PORT="$2"; SET_BPORT=1; shift 2 ;;
    --latency-port) LATENCY_PORT="$2"; SET_LPORT=1; shift 2 ;;
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

# ---------- 目录定位与已有配置预读（先于一切交互） ----------
if [ "$SET_TARGET" = 0 ]; then
  for _p in /opt "$HOME" "$(pwd)"; do
    if [ -f "$_p/opsbox/.env" ]; then TARGET="$_p"; break; fi
  done
fi
[ -z "$TARGET" ] && { [ "$(id -u)" = 0 ] && TARGET=/opt/opsbox || TARGET="$HOME/opsbox"; }

read_env_var() { # 文件 变量 -> 值（空串表示无）
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2
}

if [ -f "$TARGET/opsbox/.env" ]; then
  EXIST_INSTALLED=1
  _v=$(read_env_var "$TARGET/opsbox/.env" OPS_PORT)
  [ -n "$_v" ] && [ "$SET_PORT" = 0 ] && OPS_PORT="$_v"
  _v=$(read_env_var "$TARGET/opsbox/.env" OPS_PASSWORD)
  [ -n "$_v" ] && [ "$SET_PASSWORD" = 0 ] && OPS_PASSWORD="$_v"
fi
_v=$(read_env_var "$TARGET/ai-terminal-bridge/.env" AITB_PORT)
[ -n "$_v" ] && [ "$SET_BPORT" = 0 ] && BRIDGE_PORT="$_v"
_v=$(read_env_var "$TARGET/latency-test/.env" LAT_PORT)
[ -n "$_v" ] && [ "$SET_LPORT" = 0 ] && LATENCY_PORT="$_v"

# ---------- 服务管理基础函数 ----------
dir_of() {
  case "$1" in
    opsbox)  echo "$TARGET/opsbox" ;;
    bridge)  echo "$TARGET/ai-terminal-bridge" ;;
    latency) echo "$TARGET/latency-test" ;;
  esac
}

mgmt_port() { # 组件 -> 从 .env 读端口，缺省回退
  _d=$(dir_of "$1"); _f="$_d/.env"; _key="OPS_PORT"; _def="8002"
  case "$1" in
    bridge)  _key="AITB_PORT"; _def="8790" ;;
    latency) _key="LAT_PORT";  _def="8005" ;;
  esac
  if [ -f "$_f" ]; then
    _v=$(grep "^$_key=" "$_f" 2>/dev/null | head -1 | cut -d= -f2)
    [ -n "$_v" ] && { echo "$_v"; return 0; }
  fi
  echo "$_def"
}

port_pids() { ss -tlnp 2>/dev/null | grep ":$1 " | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u; }

mgmt_stop_one() {
  _c="$1"; _d=$(dir_of "$_c"); _p=$(mgmt_port "$_c")
  if [ ! -d "$_d" ]; then warn "$_c 未安装（$_d）"; return 0; fi
  _pids=$(port_pids "$_p")
  if [ -n "$_pids" ]; then
    for _x in $_pids; do kill "$_x" 2>/dev/null || true; done
    sleep 1
    _pids=$(port_pids "$_p")
    if [ -n "$_pids" ]; then
      for _x in $_pids; do kill -9 "$_x" 2>/dev/null || true; done
      sleep 1
    fi
  fi
  if [ -n "$(port_pids "$_p")" ]; then
    warn "$_c 停止失败（端口 $_p 仍被占用）"
  else
    log "$_c 已停止（端口 $_p）"
  fi
}

mgmt_wait_http() { # 端口 -> 就绪返回 0
  _p="$1"; _i=0
  while [ $_i -lt 20 ]; do
    if command -v curl >/dev/null 2>&1; then
      curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$_p/" 2>/dev/null && return 0
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O /dev/null -T 2 "http://127.0.0.1:$_p/" 2>/dev/null && return 0
    else
      python3 -c "import socket;socket.create_connection(('127.0.0.1',$_p),2).close()" 2>/dev/null && return 0
    fi
    sleep 1; _i=$((_i + 1))
  done
  return 1
}

mgmt_start_one() {
  _c="$1"; _d=$(dir_of "$_c"); _p=$(mgmt_port "$_c")
  if [ ! -d "$_d" ]; then warn "$_c 未安装（$_d）"; return 0; fi
  if [ -n "$(port_pids "$_p")" ]; then
    log "$_c 已在运行（端口 $_p，PID $(port_pids "$_p" | tr '\n' ',' | sed 's/,$//')）"
    return 0
  fi
  case "$_c" in
    bridge)
      if command -v npm >/dev/null 2>&1; then
        ( cd "$_d" && AITB_PORT="$_p" setsid nohup npm start > server.log 2>&1 & )
      else
        warn "$_c 启动失败：node/npm 不可用"; return 0
      fi
      ;;
    opsbox)
      ( cd "$_d" && OPS_PORT="$_p" sh start.sh >/dev/null 2>&1 ) || true
      ;;
    latency)
      ( cd "$_d" && LAT_PORT="$_p" sh start.sh >/dev/null 2>&1 ) || true
      ;;
  esac
  if mgmt_wait_http "$_p"; then
    log "$_c 已启动（端口 $_p）-> http://127.0.0.1:$_p/"
    return 0
  else
    warn "$_c 启动后无响应，请查看日志: $_d/server.log"
    return 1
  fi
}

mgmt_status_one() {
  _c="$1"; _d=$(dir_of "$_c")
  if [ ! -d "$_d" ]; then
    printf '  %-8s 未安装    %s\n' "$_c" "$_d"
    return 0
  fi
  _p=$(mgmt_port "$_c")
  _pids=$(port_pids "$_p")
  if [ -n "$_pids" ]; then
    printf '  %-8s 运行中    端口 %-6s PID %-12s %s\n' "$_c" "$_p" "$(echo $_pids | tr '\n' ',' | sed 's/,$//')" "$_d"
  else
    printf '  %-8s 已停止    端口 %-6s %-12s %s\n' "$_c" "$_p" "-" "$_d"
  fi
}

mgmt_norm_svc() {
  case "$1" in
    all) echo "opsbox bridge latency" ;;
    ops|opsbox) echo opsbox ;;
    bridge|ai-terminal-bridge) echo bridge ;;
    latency|latency-test) echo latency ;;
    *) die "未知服务: $1（可用 all|ops|bridge|latency）" ;;
  esac
}

# ---------- 交互工具（curl|sh 时 stdin 是管道，读 /dev/tty） ----------
if [ -t 0 ]; then
  INTERACTIVE=1
elif [ -t 1 ] && (printf '' 2>/dev/null >/dev/tty) 2>/dev/null; then
  INTERACTIVE=1
fi

ask() { # ask 提示 默认值（直接回车取默认）
  _prompt="$1"; _def="$2"; _ans=""
  if [ "$INTERACTIVE" = 1 ]; then
    printf '%s（回车=%s）' "$_prompt" "$_def" 2>/dev/null >/dev/tty || true
    IFS= read -r _ans 2>/dev/null </dev/tty || _ans=""
  fi
  if [ -n "$_ans" ]; then printf '%s' "$_ans"; else printf '%s' "$_def"; fi
}

ask_yes() { # ask_yes 提示 默认(y/n)；0=是 1=否
  _prompt="$1"; _def="$2"; _ans=""
  if [ "$INTERACTIVE" = 1 ]; then
    case "$_def" in
      y|Y) _hint="[Y/n]" ;;
      *)   _hint="[y/N]" ;;
    esac
    printf '%s %s（回车=默认）' "$_prompt" "$_hint" 2>/dev/null >/dev/tty || true
    IFS= read -r _ans 2>/dev/null </dev/tty || _ans=""
  fi
  [ -z "$_ans" ] && _ans="$_def"
  case "$_ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

menu_read() { # menu_read 变量名（仅终端可用）
  if [ -t 0 ]; then
    IFS= read -r "$1"
  else
    IFS= read -r "$1" 2>/dev/null </dev/tty || { warn "当前无交互终端"; exit 1; }
  fi
}

gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 12
  else
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# ---------- 通用工具 ----------
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

rewrite_env_var() { # rewrite_env_var 文件 变量 值（安全替换，不支持多行值）
  _f="$1"; _k="$2"; _v="$3"
  [ -f "$_f" ] || return 0
  { grep -v "^$_k=" "$_f" 2>/dev/null || true; echo "$_k=$_v"; } > "$_f.t.$$"
  mv "$_f.t.$$" "$_f"
  chmod 600 "$_f" 2>/dev/null || true
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

stop_app() { # stop_app 类型 目录 端口（按端口精确停止）
  stop_port_pids "$3"
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

  if [ "$INTERACTIVE" = 1 ]; then
    {
      echo
      echo "  端口 $_want 已被占用：$CONFLICT_WHO"
      echo "    1) 顺延到下一个可用端口（默认）"
      echo "    2) 指定其他端口"
      echo "    3) 停止该应用并使用端口 $_want"
    } 2>/dev/null >/dev/tty || true
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
plan_install() { # plan_install 应用类型 目录 -> 全局 APP_MODE(install|upgrade)
  APP_MODE="install"
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

# ---------- 安装/升级主流程 ----------
do_install() {
  # ---- 交互询问（已有配置直接回车全部保留） ----
  if [ "$INTERACTIVE" = 1 ]; then
    log "开始安装/升级（已有配置直接回车即全部保留）"
    if [ "$SET_TARGET" = 0 ]; then
      TARGET=$(ask "安装目录" "$TARGET")
    fi
    if [ "$EXIST_INSTALLED" = 1 ]; then
      log "检测到已有安装：沿用当前密码/token（如需修改稍后用菜单[2]或 --password）"
    elif [ "$SET_PASSWORD" = 0 ]; then
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

  [ -z "$OPS_PASSWORD" ] && OPS_PASSWORD=$(gen_password)
  command -v python3 >/dev/null 2>&1 || die "需要 python3"
  command -v tar >/dev/null 2>&1 || die "需要 tar"
  mkdir -p "$TARGET"
  OPS_WAS=0; BR_WAS=0; LAT_WAS=0

  # ---- opsbox ----
  OPS_DIR="$TARGET/opsbox"
  plan_install opsbox "$OPS_DIR"
  OPS_MODE="$APP_MODE"
  if [ "$APP_MODE" = "upgrade" ]; then
    log "检测到 $OPS_DIR 已是 opsbox，执行更新/升级（保留 .env 等本机配置）"
    if [ -f "$OPS_DIR/.env" ]; then
      _env_port=$(grep '^OPS_PORT=' "$OPS_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2)
      if [ -n "$_env_port" ] && [ "$SET_PORT" = 0 ]; then
        OPS_PORT="$_env_port"
        log "沿用已有配置端口 $OPS_PORT"
      fi
      _env_pw=$(grep '^OPS_PASSWORD=' "$OPS_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2)
      if [ -n "$_env_pw" ] && [ "$SET_PASSWORD" = 0 ]; then
        OPS_PASSWORD="$_env_pw"
        log "沿用已有访问密码/token"
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
  chmod +x "$OPS_DIR"/start.sh "$OPS_DIR"/stop.sh 2>/dev/null || true
  if [ -f "$OPS_DIR/.env" ]; then
    sed -i "s/^OPS_PORT=.*/OPS_PORT=$OPS_PORT/" "$OPS_DIR/.env" 2>/dev/null || true
  fi
  if [ "$SET_PASSWORD" = 1 ] && [ -f "$OPS_DIR/.env" ]; then
    rewrite_env_var "$OPS_DIR/.env" OPS_PASSWORD "$OPS_PASSWORD"
    rewrite_env_var "$OPS_DIR/.env" AITB_TOKEN "$OPS_PASSWORD"
    rewrite_env_var "$TARGET/ai-terminal-bridge/.env" AITB_TOKEN "$OPS_PASSWORD"
    log "已按指定密码更新访问 token（含桥接同步）"
  fi

  # Python 依赖：fastapi+uvicorn+psutil+python-multipart（缺任一都会启动失败、预览无法访问）
  if ! python3 -c "import fastapi, uvicorn, psutil, multipart" >/dev/null 2>&1; then
    log "安装 Python 依赖（fastapi uvicorn[standard] psutil python-multipart）"
    _r=""
    [ -f "$OPS_DIR/requirements.txt" ] && _r="-r $OPS_DIR/requirements.txt"
    _pkgs="fastapi uvicorn[standard] psutil python-multipart"
    pip3 install $_r >/dev/null 2>&1 \
      || pip3 install --break-system-packages $_r >/dev/null 2>&1 \
      || pip3 install --user $_r >/dev/null 2>&1 \
      || pip3 install -i https://pypi.tuna.tsinghua.edu.cn/simple $_r >/dev/null 2>&1 \
      || true
    if ! python3 -c "import fastapi, uvicorn, psutil, multipart" >/dev/null 2>&1; then
      pip3 install $_pkgs >/dev/null 2>&1 \
        || pip3 install --break-system-packages $_pkgs >/dev/null 2>&1 \
        || pip3 install --user $_pkgs >/dev/null 2>&1 \
        || pip3 install -i https://pypi.tuna.tsinghua.edu.cn/simple $_pkgs >/dev/null 2>&1 \
        || die "Python 依赖安装失败，请手动执行: pip3 install fastapi 'uvicorn[standard]' psutil python-multipart"
    fi
    python3 -c "import fastapi, uvicorn, psutil, multipart" >/dev/null 2>&1 \
      || die "依赖安装后校验仍失败，请手动执行: pip3 install fastapi 'uvicorn[standard]' psutil python-multipart"
  fi

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

  # ---- ai-terminal-bridge ----
  if [ "$WITH_BRIDGE" = 1 ]; then
    BRIDGE_DIR="$TARGET/ai-terminal-bridge"
    plan_install bridge "$BRIDGE_DIR"
    if [ "$APP_MODE" = "upgrade" ]; then
      log "检测到 $BRIDGE_DIR 已是 ai-terminal-bridge，执行更新/升级"
      if [ -f "$BRIDGE_DIR/.env" ]; then
        _env_port=$(grep '^AITB_PORT=' "$BRIDGE_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2)
        if [ -n "$_env_port" ] && [ "$SET_BPORT" = 0 ]; then
          BRIDGE_PORT="$_env_port"
          log "沿用已有桥接端口 $BRIDGE_PORT"
        fi
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
      if [ -f "$BRIDGE_DIR/.env" ]; then
        sed -i "s/^AITB_PORT=.*/AITB_PORT=$BRIDGE_PORT/" "$BRIDGE_DIR/.env" 2>/dev/null || true
        rewrite_env_var "$BRIDGE_DIR/.env" AITB_TOKEN "$OPS_PASSWORD"
      fi
      if [ -f "$OPS_DIR/.env" ]; then
        sed -i "s|^AITB_URL=.*|AITB_URL=http://127.0.0.1:$BRIDGE_PORT|" "$OPS_DIR/.env" 2>/dev/null || true
      fi
    else
      warn "node/npm 不可用，跳过终端桥接（opsbox 菜单中该入口将不可用）"
      WITH_BRIDGE=0
    fi
  fi

  # ---- latency-test ----
  if [ "$WITH_LATENCY" = 1 ]; then
    LATENCY_DIR="$TARGET/latency-test"
    plan_install latency "$LATENCY_DIR"
    if [ "$APP_MODE" = "upgrade" ]; then
      log "检测到 $LATENCY_DIR 已是 latency-test，执行更新/升级"
      if [ -f "$LATENCY_DIR/.env" ]; then
        _env_port=$(grep '^LAT_PORT=' "$LATENCY_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2)
        if [ -n "$_env_port" ] && [ "$SET_LPORT" = 0 ]; then
          LATENCY_PORT="$_env_port"
          log "沿用已有探针端口 $LATENCY_PORT"
        fi
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
    chmod +x "$LATENCY_DIR"/start.sh "$LATENCY_DIR"/stop.sh 2>/dev/null || true
    if [ ! -f "$LATENCY_DIR/.env" ]; then
      echo "LAT_PORT=$LATENCY_PORT" > "$LATENCY_DIR/.env"
    fi
    if [ -f "$OPS_DIR/.env" ]; then
      sed -i "s|^LATENCY_URL=.*|LATENCY_URL=http://127.0.0.1:$LATENCY_PORT|" "$OPS_DIR/.env" 2>/dev/null || true
    fi
  fi

  # ---- 生成本机管理脚本 manage.sh ----
  cat > "$TARGET/manage.sh" <<'MEOF'
#!/bin/sh
# opsbox 全家桶服务管理
# 用法: sh manage.sh <status|start|stop|restart> [all|ops|bridge|latency]
#       直接执行 sh manage.sh 进入交互菜单
BASE="$(cd "$(dirname "$0")" && pwd)"
log()  { printf '\033[32m[manage]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[manage]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[manage]\033[0m %s\n' "$*" >&2; exit 1; }

dir_of() {
  case "$1" in
    opsbox)  echo "$BASE/opsbox" ;;
    bridge)  echo "$BASE/ai-terminal-bridge" ;;
    latency) echo "$BASE/latency-test" ;;
  esac
}

get_port() {
  _d=$(dir_of "$1"); _key="OPS_PORT"; _def="8002"
  case "$1" in
    bridge)  _key="AITB_PORT"; _def="8790" ;;
    latency) _key="LAT_PORT";  _def="8005" ;;
  esac
  _f="$_d/.env"
  if [ -f "$_f" ]; then
    _v=$(grep "^$_key=" "$_f" 2>/dev/null | head -1 | cut -d= -f2)
    [ -n "$_v" ] && { echo "$_v"; return 0; }
  fi
  echo "$_def"
}

port_pids() { ss -tlnp 2>/dev/null | grep ":$1 " | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u; }

stop_one() {
  _c="$1"; _d=$(dir_of "$_c"); _p=$(get_port "$_c")
  _pids=$(port_pids "$_p")
  [ -n "$_pids" ] && for _x in $_pids; do kill "$_x" 2>/dev/null; done
  sleep 1
  _pids=$(port_pids "$_p")
  [ -n "$_pids" ] && for _x in $_pids; do kill -9 "$_x" 2>/dev/null; done
  log "$_c 已停止（端口 $_p）"
}

start_one() {
  _c="$1"; _d=$(dir_of "$_c"); _p=$(get_port "$_c")
  if [ -n "$(port_pids "$_p")" ]; then
    log "$_c 已在运行（端口 $_p）"
    return 0
  fi
  case "$_c" in
    bridge)
      ( cd "$_d" && AITB_PORT="$_p" setsid nohup npm start > server.log 2>&1 & )
      ;;
    opsbox)
      ( cd "$_d" && OPS_PORT="$_p" sh start.sh >/dev/null 2>&1 )
      ;;
    latency)
      ( cd "$_d" && LAT_PORT="$_p" sh start.sh >/dev/null 2>&1 )
      ;;
  esac
  _i=0
  while [ $_i -lt 20 ]; do
    [ -n "$(port_pids "$_p")" ] && break
    sleep 1; _i=$((_i + 1))
  done
  if [ -n "$(port_pids "$_p")" ]; then
    log "$_c 已启动（端口 $_p）"
  else
    warn "$_c 启动失败，日志: $_d/server.log"
  fi
}

status_one() {
  _c="$1"; _d=$(dir_of "$_c"); _p=$(get_port "$_c")
  _pids=$(port_pids "$_p")
  if [ -n "$_pids" ]; then
    printf '  %-8s 运行中  端口 %-6s PID %s\n' "$_c" "$_p" "$(echo $_pids | tr '\n' ',' | sed 's/,$//')"
  else
    printf '  %-8s 已停止  端口 %s\n' "$_c" "$_p"
  fi
}

norm() {
  case "$1" in
    all) echo "opsbox bridge latency" ;;
    ops|opsbox) echo opsbox ;;
    bridge|ai-terminal-bridge) echo bridge ;;
    latency|latency-test) echo latency ;;
    *) die "未知服务: $1（可用 all|ops|bridge|latency）" ;;
  esac
}

do_action() {
  for _c in $(norm "$2"); do
    case "$1" in
      status)  status_one "$_c" ;;
      start)   start_one "$_c" ;;
      stop)    stop_one "$_c" ;;
      restart) stop_one "$_c"; start_one "$_c" ;;
    esac
  done
}

menu() {
  while :; do
    echo
    echo "========== opsbox 服务管理 =========="
    do_action status all
    echo "  1) 启动全部   2) 停止全部   3) 重启全部"
    echo "  4) 启动单个   5) 停止单个   6) 重启单个"
    echo "  0) 退出"
    printf '请选择: '
    if [ -t 0 ]; then
      IFS= read -r sel
    else
      IFS= read -r sel 2>/dev/null </dev/tty || IFS= read -r sel
    fi
    case "$sel" in
      1) do_action start all ;;
      2) do_action stop all ;;
      3) do_action restart all ;;
      4|5|6)
        printf '组件（opsbox/bridge/latency，回车=全部）: '
        if [ -t 0 ]; then IFS= read -r comp; else IFS= read -r comp 2>/dev/null </dev/tty || IFS= read -r comp; fi
        [ -z "$comp" ] && comp=all
        case "$sel" in 4) do_action start "$comp" ;; 5) do_action stop "$comp" ;; 6) do_action restart "$comp" ;; esac
        ;;
      0|q|Q) exit 0 ;;
    esac
  done
}

case "${1:-}" in
  status|start|stop|restart) do_action "$1" "${2:-all}" ;;
  "") menu ;;
  -h|--help|help) sed -n '2,5p' "$0" ;;
  *) die "未知命令: $1" ;;
esac
MEOF
  chmod +x "$TARGET/manage.sh"

  # ---- 启动 ----
  START_LAT=0; START_BR=0; START_OPS=0
  LAT_FAIL=0; BR_FAIL=0; OPS_FAIL=0
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
  if [ "$START_LAT" = 1 ]; then mgmt_start_one latency || LAT_FAIL=1; fi
  if [ "$START_BR" = 1 ]; then mgmt_start_one bridge || BR_FAIL=1; fi
  if [ "$START_OPS" = 1 ]; then mgmt_start_one opsbox || OPS_FAIL=1; fi

  # ---- 启动失败：回显日志尾部并整体失败，不打印成功汇总 ----
  if [ "$LAT_FAIL" = 1 ] || [ "$BR_FAIL" = 1 ] || [ "$OPS_FAIL" = 1 ]; then
    echo
    warn "部署未完成，以下组件启动失败："
    if [ "$LAT_FAIL" = 1 ]; then
      echo "----- latency-test 日志尾部（$TARGET/latency-test/server.log）-----"
      tail -n 20 "$TARGET/latency-test/server.log" 2>/dev/null || true
    fi
    if [ "$BR_FAIL" = 1 ]; then
      echo "----- ai-terminal-bridge 日志尾部（$TARGET/ai-terminal-bridge/server.log）-----"
      tail -n 20 "$TARGET/ai-terminal-bridge/server.log" 2>/dev/null || true
    fi
    if [ "$OPS_FAIL" = 1 ]; then
      echo "----- opsbox 日志尾部（$TARGET/opsbox/server.log）-----"
      tail -n 20 "$TARGET/opsbox/server.log" 2>/dev/null || true
    fi
    die "请按上方日志处理问题后重新执行本脚本（已有配置会保留）；手动启动: sh $TARGET/manage.sh start all"
  fi

  # ---- 汇总（端口/密码以 .env 实际生效值为准） ----
  if [ -f "$OPS_DIR/.env" ]; then
    _v=$(grep '^OPS_PORT=' "$OPS_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2);     [ -n "$_v" ] && OPS_PORT="$_v"
    _v=$(grep '^OPS_PASSWORD=' "$OPS_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2); [ -n "$_v" ] && OPS_PASSWORD="$_v"
  fi
  if [ -f "$TARGET/ai-terminal-bridge/.env" ]; then
    _v=$(grep '^AITB_PORT=' "$TARGET/ai-terminal-bridge/.env" 2>/dev/null | head -1 | cut -d= -f2); [ -n "$_v" ] && BRIDGE_PORT="$_v"
  fi
  if [ -f "$TARGET/latency-test/.env" ]; then
    _v=$(grep '^LAT_PORT=' "$TARGET/latency-test/.env" 2>/dev/null | head -1 | cut -d= -f2); [ -n "$_v" ] && LATENCY_PORT="$_v"
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
  if [ -d "$TARGET/ai-terminal-bridge" ]; then
    echo "  终端桥接 : http://127.0.0.1:$BRIDGE_PORT/  （已关联，opsbox 下拉菜单免登录跳转）"
  fi
  if [ -d "$TARGET/latency-test" ]; then
    echo "  链路探针 : http://127.0.0.1:$LATENCY_PORT/"
  fi
  echo "  目录     : $TARGET"
  echo "  配置     : $TARGET/opsbox/.env（改密码后重启服务生效）"
  echo "  服务管理 : sh $TARGET/manage.sh        （交互菜单：状态/启动/停止/重启）"
  echo "  平台预览 : 服务已监听端口 $OPS_PORT（MonkeyCode 等平台会自动生成 <端口>- 前缀的预览地址）"
  echo
  log "登录 opsbox 后，通过右上角下拉菜单直达已安装的上游应用。"
}

# ---------- 修改密码 ----------
change_password() {
  _new=""
  if [ "$INTERACTIVE" = 1 ]; then
    _new=$(ask "输入新的访问密码/token" "")
  fi
  [ -z "$_new" ] && { log "已取消（保持原密码）"; return 0; }
  OPS_PASSWORD="$_new"
  rewrite_env_var "$TARGET/opsbox/.env" OPS_PASSWORD "$_new"
  rewrite_env_var "$TARGET/opsbox/.env" AITB_TOKEN "$_new"
  rewrite_env_var "$TARGET/ai-terminal-bridge/.env" AITB_TOKEN "$_new"
  log "密码/token 已更新（opsbox 与桥接配置已同步）"
  for _c in opsbox bridge; do
    if [ -n "$(port_pids "$(mgmt_port "$_c")")" ]; then
      mgmt_stop_one "$_c"
      mgmt_start_one "$_c" || true
    fi
  done
}

# ---------- 交互式主菜单 ----------
main_menu() {
  while :; do
    echo
    echo "============ opsbox 运维全家桶 ============"
    if [ "$EXIST_INSTALLED" = 1 ]; then
      echo "  检测到已有安装: $TARGET（配置已自动读取）"
    fi
    for _c in opsbox bridge latency; do mgmt_status_one "$_c"; done
    echo "  1) 安装 / 升级（保留已有配置）"
    echo "  2) 修改访问密码/token"
    echo "  3) 启动全部    4) 停止全部    5) 重启全部"
    echo "  0) 退出"
    printf '请选择: '
    menu_read sel
    case "$sel" in
      1) do_install ;;
      2) change_password ;;
      3) for _c in opsbox bridge latency; do mgmt_start_one "$_c" || true; done ;;
      4) for _c in opsbox bridge latency; do mgmt_stop_one "$_c"; done ;;
      5) for _c in opsbox bridge latency; do mgmt_stop_one "$_c"; mgmt_start_one "$_c" || true; done ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选择: $sel" ;;
    esac
  done
}

# ---------- 入口 ----------
if [ -n "$ACTION" ]; then
  if [ "$ACTION" = "menu" ]; then
    main_menu
    exit 0
  fi
  for _c in $(mgmt_norm_svc "$SVC_WORD"); do
    case "$ACTION" in
      status)  mgmt_status_one "$_c" ;;
      start)   mgmt_start_one "$_c" ;;
      stop)    mgmt_stop_one "$_c" ;;
      restart) mgmt_stop_one "$_c"; mgmt_start_one "$_c" ;;
    esac
  done
  exit 0
fi

if [ "$INTERACTIVE" = 1 ]; then
  main_menu
else
  do_install
fi
