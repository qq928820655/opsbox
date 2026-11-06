"""opsbox 运维工作台 = 文件管理 + 资源监控（filebrowser + resmon 合并版，端口 8002）。

文件 API：/api/list read save mkdir touch delete rename copy move upload
         download preview unarchive search
监控 API：/api/stats（后台 1s 采样线程：CPU/内存/网络/磁盘IO/Top进程/分区）
预警 API：/api/alert/config（读写配置）、/api/alert/test（测试推送）
         后台线程按间隔检测 RSS 内存占比与磁盘使用率，超阈值经 pushplus 推送。
鉴权：同一密码登录，HMAC token（复用原 filebrowser .secret，旧 token 继续有效）。
"""
import hashlib
import hmac
import json
import mimetypes
import os
import platform
import secrets
import shutil
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections import deque
from pathlib import Path

import psutil
from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PASSWORD = (os.environ.get("OPS_PASSWORD") or os.environ.get("FB_PASSWORD")
            or os.environ.get("RM_PASSWORD") or "qq928820655")
# 运维工作台内置应用（统一登录：复用 OPS_PASSWORD 作为 bridge 管理令牌）
AITB_URL = (os.environ.get("AITB_URL") or "http://127.0.0.1:8787").rstrip("/")
AITB_TOKEN = os.environ.get("AITB_TOKEN") or PASSWORD
LATENCY_URL = (os.environ.get("LATENCY_URL") or "http://127.0.0.1:8005").rstrip("/")
AITB_PUBLIC = (os.environ.get("AITB_PUBLIC") or "").rstrip("/")
LATENCY_PUBLIC = (os.environ.get("LATENCY_PUBLIC") or "").rstrip("/")
MAX_EDIT = 5 * 1024 * 1024
MAX_ARCHIVES = 4 * 1024 * 1024 * 1024
TOKEN_TTL = 7 * 24 * 3600
HIST_MAX = 900

SECRET_FILE = os.path.join(BASE_DIR, ".secret")


def _secret() -> bytes:
    try:
        with open(SECRET_FILE, "rb") as f:
            return f.read()
    except FileNotFoundError:
        s = secrets.token_bytes(32)
        with open(SECRET_FILE, "wb") as f:
            f.write(s)
        os.chmod(SECRET_FILE, 0o600)
        return s


SECRET = _secret()
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

# ===== 预警配置 =====
ALERT_FILE = os.path.join(BASE_DIR, "alert_config.json")
ALERT_DEFAULTS = {
    "enabled": False,
    "machine_name": "",
    "preview_url": "",
    "pushplus_token": "",
    "mem_threshold": 85,
    "disk_threshold": 90,
    "cooldown_min": 30,
    "check_interval_s": 60,
}
_alert_last = {"mem": 0.0, "disk": 0.0}   # 上次成功推送时间戳，用于冷却


def _alert_load() -> dict:
    cfg = dict(ALERT_DEFAULTS)
    try:
        with open(ALERT_FILE, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            cfg.update({k: v for k, v in data.items() if k in ALERT_DEFAULTS})
    except (OSError, ValueError):
        pass
    return cfg


def _alert_save(cfg: dict) -> dict:
    merged = dict(ALERT_DEFAULTS)
    merged.update({k: cfg[k] for k in ALERT_DEFAULTS if k in cfg})
    tmp = ALERT_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(merged, f, ensure_ascii=False, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, ALERT_FILE)
    return merged


def _default_machine_name() -> str:
    try:
        return platform.node() or "unknown"
    except Exception:
        return "unknown"


def _pushplus_send(token: str, title: str, content: str) -> tuple[bool, str]:
    """调用 pushplus 推送。返回 (成功, 说明)。"""
    if not token:
        return False, "未配置 pushplus token"
    payload = urllib.parse.urlencode({
        "token": token,
        "title": title,
        "content": content,
        "template": "html",
    }).encode("utf-8")
    req = urllib.request.Request(
        "https://www.pushplus.plus/send",
        data=payload,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode("utf-8", "replace")
        try:
            data = json.loads(body)
        except ValueError:
            return False, f"响应无法解析: {body[:200]}"
        code = data.get("code")
        if code == 200:
            return True, "ok"
        return False, f"pushplus 返回 code={code} msg={data.get('msg')}"
    except urllib.error.HTTPError as exc:
        return False, f"HTTP {exc.code}"
    except Exception as exc:
        return False, f"{type(exc).__name__}: {exc}"


def _fmt_bytes(n: float) -> str:
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024
    return f"{n:.1f} TB"


def _build_alert_content(kind: str, value: float, threshold: float, cfg: dict,
                         extra: str = "") -> tuple[str, str]:
    name = (cfg.get("machine_name") or "").strip() or _default_machine_name()
    url = (cfg.get("preview_url") or "").strip() or "-"
    label = "内存" if kind == "mem" else "磁盘"
    title = f"[预警] {name} {label}使用率 {value:.1f}%"
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    rows = [
        ("机器名称", name),
        ("预警事项", f"{label}使用率达到阈值"),
        ("当前值", f"{value:.1f}%"),
        ("触发阈值", f"{threshold:.1f}%"),
        ("预览地址", url),
        ("检测时间", now),
    ]
    if extra:
        rows.append(("详情", extra))
    body = "".join(
        f"<tr><td style='padding:4px 10px;color:#666;white-space:nowrap'>{k}</td>"
        f"<td style='padding:4px 10px'>{v}</td></tr>"
        for k, v in rows
    )
    content = (
        f"<div style='font-family:sans-serif'>"
        f"<h3 style='margin:0 0 8px'>{title}</h3>"
        f"<table style='border-collapse:collapse'>{body}</table>"
        f"</div>"
    )
    return title, content


def _disk_max() -> tuple[float, str]:
    best_pct, best_desc = 0.0, ""
    for d in _disks():
        if d["pct"] > best_pct:
            best_pct = float(d["pct"])
            best_desc = f"{d['mount']} ({d['dev']}) {_fmt_bytes(d['used'])} / {_fmt_bytes(d['total'])}"
    return best_pct, best_desc


def _alert_loop():
    while True:
        cfg = _alert_load()
        interval = max(10, int(cfg.get("check_interval_s") or 60))
        if cfg.get("enabled") and cfg.get("pushplus_token"):
            cooldown = max(1, int(cfg.get("cooldown_min") or 30)) * 60
            now = time.time()
            try:
                mem = _mem()
                mem_pct = float(mem.get("pct") or 0.0)
                mem_thr = float(cfg.get("mem_threshold") or 85)
                if mem_pct >= mem_thr and now - _alert_last["mem"] >= cooldown:
                    extra = (f"已用 {_fmt_bytes(mem['used'])} / {_fmt_bytes(mem['total'])}"
                             f"（RSS 合计）")
                    title, content = _build_alert_content("mem", mem_pct, mem_thr, cfg, extra)
                    ok, msg = _pushplus_send(cfg["pushplus_token"], title, content)
                    if ok:
                        _alert_last["mem"] = now
                    print(f"[alert] mem push {'ok' if ok else 'fail: ' + msg}", flush=True)
            except Exception as exc:
                print(f"[alert] mem check error: {exc}", flush=True)
            try:
                disk_pct, disk_desc = _disk_max()
                disk_thr = float(cfg.get("disk_threshold") or 90)
                if disk_pct >= disk_thr and now - _alert_last["disk"] >= cooldown:
                    title, content = _build_alert_content("disk", disk_pct, disk_thr, cfg, disk_desc)
                    ok, msg = _pushplus_send(cfg["pushplus_token"], title, content)
                    if ok:
                        _alert_last["disk"] = now
                    print(f"[alert] disk push {'ok' if ok else 'fail: ' + msg}", flush=True)
            except Exception as exc:
                print(f"[alert] disk check error: {exc}", flush=True)
        time.sleep(interval)

# ===== 鉴权 =====


class LoginBody(BaseModel):
    password: str = ""


class PathBody(BaseModel):
    path: str


class SaveBody(BaseModel):
    path: str
    content: str
    encoding: str = "utf-8"


class DeleteBody(BaseModel):
    paths: list[str]


class RenameBody(BaseModel):
    path: str
    new_name: str


class TransferBody(BaseModel):
    srcs: list[str]
    dest: str


class UnarchiveBody(BaseModel):
    path: str
    dest: str = ""


class SearchBody(BaseModel):
    dir: str
    q: str
    limit: int = 300


def _make_token() -> str:
    exp = str(int(time.time()) + TOKEN_TTL)
    sig = hmac.new(SECRET, exp.encode(), hashlib.sha256).hexdigest()
    return f"{exp}.{sig}"


def _auth(request: Request):
    token = request.headers.get("x-auth-token") or request.query_params.get("token")
    if not token or "." not in token:
        raise HTTPException(401, "未登录")
    exp, sig = token.split(".", 1)
    if not exp.isdigit() or int(exp) < time.time():
        raise HTTPException(401, "登录已过期")
    good = hmac.new(SECRET, exp.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, good):
        raise HTTPException(401, "凭证无效")


_failures: list = []


@app.post("/api/login")
async def login(body: LoginBody):
    now = time.time()
    global _failures
    _failures = [t for t in _failures if now - t < 60]
    if len(_failures) >= 10:
        raise HTTPException(429, "尝试过于频繁，请稍后再试")
    if hmac.compare_digest(body.password.encode(), PASSWORD.encode()):
        _failures.clear()
        return {"token": _make_token()}
    _failures.append(now)
    time.sleep(1.0)
    raise HTTPException(401, "密码错误")


@app.get("/")
async def index():
    with open(os.path.join(BASE_DIR, "index.html"), encoding="utf-8") as f:
        return HTMLResponse(f.read())


# ===== 文件管理 =====


def _abs(p: str) -> str:
    if not p or not p.strip():
        raise HTTPException(400, "路径为空")
    return os.path.realpath(os.path.abspath(p))


def _check_exists(p: str):
    if not os.path.exists(p):
        raise HTTPException(404, f"不存在: {p}")


def _fail(msg: str):
    raise HTTPException(400, msg)


@app.get("/api/list")
async def api_list(request: Request, path: str = "/"):
    _auth(request)
    p = _abs(path)
    _check_exists(p)
    if not os.path.isdir(p):
        _fail(f"不是目录: {p}")
    entries = []
    try:
        names = os.listdir(p)
    except PermissionError:
        raise HTTPException(403, f"权限不足: {p}")
    for name in names:
        full = os.path.join(p, name)
        try:
            st = os.lstat(full)
            entries.append({
                "name": name,
                "is_dir": os.path.isdir(full) and not os.path.islink(full),
                "is_link": os.path.islink(full),
                "size": 0 if os.path.isdir(full) else st.st_size,
                "mtime": int(st.st_mtime),
                "mode": __import__("stat").filemode(st.st_mode),
            })
        except (PermissionError, OSError):
            entries.append({"name": name, "is_dir": False, "is_link": False,
                            "size": 0, "mtime": 0, "mode": "???", "error": True})
    entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
    return {"path": p, "entries": entries}


@app.get("/api/read")
async def api_read(request: Request, path: str):
    _auth(request)
    p = _abs(path)
    _check_exists(p)
    if os.path.isdir(p):
        _fail("这是目录")
    st = os.stat(p)
    if st.st_size > MAX_EDIT:
        return {"path": p, "binary": True, "too_big": True, "size": st.st_size}
    with open(p, "rb") as f:
        data = f.read(MAX_EDIT + 1)
    if b"\0" in data[:8192]:
        return {"path": p, "binary": True, "size": st.st_size}
    for enc in ("utf-8", "gbk", "latin-1"):
        try:
            text = data.decode(enc)
            return {"path": p, "binary": False, "content": text,
                    "encoding": enc, "size": st.st_size, "mtime": int(st.st_mtime)}
        except (UnicodeDecodeError, ValueError):
            continue
    return {"path": p, "binary": True, "size": st.st_size}


@app.post("/api/save")
async def api_save(request: Request, body: SaveBody):
    _auth(request)
    p = _abs(body.path)
    _check_exists(os.path.dirname(p))
    if body.encoding not in ("utf-8", "gbk", "latin-1"):
        _fail("不支持的编码")
    tmp = p + ".fbtmp"
    with open(tmp, "wb") as f:
        f.write(body.content.encode(body.encoding, errors="replace"))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)
    return {"ok": True, "path": p, "size": os.path.getsize(p)}


@app.post("/api/mkdir")
async def api_mkdir(request: Request, body: PathBody):
    _auth(request)
    p = _abs(body.path)
    if os.path.exists(p):
        _fail("已存在")
    os.makedirs(p)
    return {"ok": True, "path": p}


@app.post("/api/touch")
async def api_touch(request: Request, body: PathBody):
    _auth(request)
    p = _abs(body.path)
    if os.path.exists(p):
        _fail("已存在")
    Path(p).touch()
    return {"ok": True, "path": p}


@app.post("/api/delete")
async def api_delete(request: Request, body: DeleteBody):
    _auth(request)
    if not body.paths:
        _fail("未选择")
    done, errors = [], []
    for raw in body.paths:
        p = _abs(raw)
        if p == "/":
            errors.append({"path": raw, "error": "拒绝删除根目录"})
            continue
        try:
            if os.path.isdir(p) and not os.path.islink(p):
                shutil.rmtree(p)
            else:
                os.remove(p)
            done.append(p)
        except Exception as e:
            errors.append({"path": raw, "error": str(e)})
    return {"ok": len(errors) == 0, "deleted": done, "errors": errors}


@app.post("/api/rename")
async def api_rename(request: Request, body: RenameBody):
    _auth(request)
    p = _abs(body.path)
    _check_exists(p)
    new_name = body.new_name.strip()
    if not new_name or "/" in new_name or new_name in (".", ".."):
        _fail("非法名称")
    np = os.path.join(os.path.dirname(p), new_name)
    if os.path.exists(np):
        _fail("目标已存在")
    os.rename(p, np)
    return {"ok": True, "path": np}


def _unique_dest(dest_dir: str, name: str) -> str:
    target = os.path.join(dest_dir, name)
    if not os.path.exists(target):
        return target
    base, ext = os.path.splitext(name)
    i = 1
    while os.path.exists(os.path.join(dest_dir, f"{base}({i}){ext}")):
        i += 1
    return os.path.join(dest_dir, f"{base}({i}){ext}")


@app.post("/api/copy")
async def api_copy(request: Request, body: TransferBody):
    _auth(request)
    dest = _abs(body.dest)
    if not os.path.isdir(dest):
        _fail(f"目标目录不存在: {dest}")
    done, errors = [], []
    for raw in body.srcs:
        src = _abs(raw)
        _check_exists(src)
        if src == dest or dest.startswith(src + os.sep):
            errors.append({"path": raw, "error": "不能复制到自身内部"})
            continue
        target = _unique_dest(dest, os.path.basename(src))
        try:
            if os.path.isdir(src) and not os.path.islink(src):
                shutil.copytree(src, target, symlinks=True)
            else:
                shutil.copy2(src, target, follow_symlinks=False)
            done.append(target)
        except Exception as e:
            errors.append({"path": raw, "error": str(e)})
    return {"ok": len(errors) == 0, "copied": done, "errors": errors}


@app.post("/api/move")
async def api_move(request: Request, body: TransferBody):
    _auth(request)
    dest = _abs(body.dest)
    if not os.path.isdir(dest):
        _fail(f"目标目录不存在: {dest}")
    done, errors = [], []
    for raw in body.srcs:
        src = _abs(raw)
        _check_exists(src)
        if src == dest or dest.startswith(src + os.sep):
            errors.append({"path": raw, "error": "不能移动到自身内部"})
            continue
        target = _unique_dest(dest, os.path.basename(src))
        try:
            shutil.move(src, target)
            done.append(target)
        except Exception as e:
            errors.append({"path": raw, "error": str(e)})
    return {"ok": len(errors) == 0, "moved": done, "errors": errors}


@app.post("/api/upload")
async def api_upload(request: Request, dest: str = Form(...), file: UploadFile = File(...)):
    _auth(request)
    d = _abs(dest)
    if not os.path.isdir(d):
        _fail(f"目标目录不存在: {d}")
    target = _unique_dest(d, os.path.basename(file.filename or "upload.bin"))
    size = 0
    with open(target, "wb") as out:
        while chunk := await file.read(1024 * 1024):
            out.write(chunk)
            size += len(chunk)
    return {"ok": True, "path": target, "size": size}


@app.get("/api/download")
async def api_download(request: Request, path: str, background: BackgroundTasks):
    _auth(request)
    p = _abs(path)
    _check_exists(p)
    if os.path.isfile(p):
        return FileResponse(p, filename=os.path.basename(p))
    if not os.path.isdir(p):
        _fail("不支持的对象类型")
    tmp = tempfile.mktemp(prefix="fb-dl-", suffix=".zip", dir="/tmp/opencode")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, _dirs, files in os.walk(p):
            for fn in files:
                full = os.path.join(root, fn)
                zf.write(full, os.path.relpath(full, os.path.dirname(p)))
    background.add_task(os.remove, tmp)
    return FileResponse(tmp, filename=os.path.basename(p) + ".zip")


@app.get("/api/preview")
async def api_preview(request: Request, path: str):
    _auth(request)
    p = _abs(path)
    _check_exists(p)
    mime, _ = mimetypes.guess_type(p)
    if not mime or not mime.startswith(("image/", "video/", "audio/", "application/pdf")):
        _fail("不支持的预览类型")
    return FileResponse(p, media_type=mime)


ARCHIVE_SUFFIXES = (".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz")


@app.post("/api/unarchive")
async def api_unarchive(request: Request, body: UnarchiveBody):
    _auth(request)
    p = _abs(body.path)
    _check_exists(p)
    lower = p.lower()
    if not lower.endswith(ARCHIVE_SUFFIXES):
        _fail("不支持的压缩格式")
    dest = _abs(body.dest) if body.dest else os.path.join(
        os.path.dirname(p), os.path.basename(p).split(".")[0] or "extracted")
    os.makedirs(dest, exist_ok=True)
    try:
        if lower.endswith(".zip"):
            with zipfile.ZipFile(p) as zf:
                for m in zf.namelist():
                    t = os.path.realpath(os.path.join(dest, m))
                    if not t.startswith(dest + os.sep) and t != dest:
                        _fail("压缩包含不安全路径")
                zf.extractall(dest)
        else:
            with tarfile.open(p) as tf:
                for m in tf.getmembers():
                    t = os.path.realpath(os.path.join(dest, m.name))
                    if not t.startswith(dest + os.sep) and t != dest:
                        _fail("压缩包含不安全路径")
                tf.extractall(dest)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(500, f"解压失败: {e}")
    return {"ok": True, "dest": dest}


SKIP_DIRS = {"/proc", "/sys", "/dev", "/run"}


@app.post("/api/search")
async def api_search(request: Request, body: SearchBody):
    _auth(request)
    root = _abs(body.dir)
    _check_exists(root)
    q = body.q.strip().lower()
    if not q:
        _fail("关键词为空")
    limit = max(1, min(body.limit, 1000))
    deadline = time.time() + 4.0
    results = []

    def walk(d):
        if len(results) >= limit or time.time() > deadline:
            return
        try:
            with os.scandir(d) as it:
                for e in it:
                    if len(results) >= limit or time.time() > deadline:
                        return
                    if q in e.name.lower():
                        try:
                            st = e.stat(follow_symlinks=False)
                            results.append({
                                "path": e.path, "name": e.name,
                                "is_dir": e.is_dir(follow_symlinks=False),
                                "size": 0 if e.is_dir(follow_symlinks=False) else st.st_size,
                                "mtime": int(st.st_mtime)})
                        except OSError:
                            pass
                    if e.is_dir(follow_symlinks=False):
                        if e.path not in SKIP_DIRS and not e.path.startswith(tuple(s + "/" for s in SKIP_DIRS)):
                            walk(e.path)
        except (PermissionError, OSError):
            pass

    walk(root)
    return {"ok": True, "results": results, "truncated": len(results) >= limit}


# ===== 资源监控（原 resmon 合并）=====

hist = deque(maxlen=HIST_MAX)
hist_lock = threading.Lock()
_proc_cache: dict = {}


def _proc_mem_bytes() -> int:
    total = 0
    for p in psutil.process_iter():
        try:
            total += p.memory_full_info().pss
        except Exception:
            try:
                total += p.memory_info().rss
            except Exception:
                pass
    return total


def _mem():
    vm = psutil.virtual_memory()
    sm = psutil.swap_memory()
    used = _proc_mem_bytes()
    return {
        "total": vm.total, "used": used,
        "avail": max(0, vm.total - used),
        "os_avail": vm.available,
        "pct": round(used / vm.total * 100, 1) if vm.total else 0.0,
        "swap_total": sm.total, "swap_used": sm.used, "swap_pct": sm.percent,
    }


def _sample_procs():
    alive = set()
    for p in psutil.process_iter(["pid", "name", "username", "memory_percent", "status"]):
        try:
            alive.add(p.pid)
            c = _proc_cache.get(p.pid)
            if c is None:
                c = {"proc": p, "cpu": 0.0}
                _proc_cache[p.pid] = c
                p.cpu_percent(interval=None)
            else:
                c["cpu"] = p.cpu_percent(interval=None)
            c["info"] = p.info
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            pass
    for pid in [k for k in _proc_cache if k not in alive]:
        _proc_cache.pop(pid, None)


def _sample_loop():
    psutil.cpu_percent(interval=None, percpu=True)
    net = psutil.net_io_counters()
    disk = psutil.disk_io_counters()
    last = (time.time(), net, disk)
    while True:
        time.sleep(1.0)
        now = time.time()
        net = psutil.net_io_counters()
        disk = psutil.disk_io_counters()
        dt = now - last[0]
        s = {
            "ts": int(now),
            "cpu": psutil.cpu_percent(interval=None),
            "cores": psutil.cpu_percent(interval=None, percpu=True),
            "load": [round(x, 2) for x in os.getloadavg()],
            "mem": _mem(),
            "net_recv": max(0.0, (net.bytes_recv - last[1].bytes_recv) / dt) if net and last[1] else 0.0,
            "net_sent": max(0.0, (net.bytes_sent - last[1].bytes_sent) / dt) if net and last[1] else 0.0,
            "net_total_recv": net.bytes_recv if net else 0,
            "net_total_sent": net.bytes_sent if net else 0,
            "disk_read": max(0.0, (disk.read_bytes - last[2].read_bytes) / dt) if disk and last[2] else 0.0,
            "disk_write": max(0.0, (disk.write_bytes - last[2].write_bytes) / dt) if disk and last[2] else 0.0,
        }
        last = (now, net, disk)
        with hist_lock:
            hist.append(s)
        _sample_procs()


def _top_procs(n=20):
    by_cpu, by_mem = [], []
    for c in _proc_cache.values():
        info = c.get("info") or {}
        item = {
            "pid": info.get("pid"),
            "name": info.get("name") or "?",
            "user": info.get("username") or "?",
            "cpu": round(c.get("cpu", 0.0), 1),
            "mem": round(info.get("memory_percent") or 0.0, 1),
            "rss": 0,
            "status": info.get("status") or "",
        }
        try:
            item["rss"] = c["proc"].memory_info().rss
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
        by_cpu.append(item)
        by_mem.append(item)
    by_cpu.sort(key=lambda x: -x["cpu"])
    by_mem.sort(key=lambda x: -x["mem"])
    return by_cpu[:n], by_mem[:n]


def _disks():
    out = []
    for part in psutil.disk_partitions(all=False):
        if part.fstype in ("squashfs", "tmpfs", "devtmpfs", "overlay", "iso9660"):
            continue
        try:
            u = psutil.disk_usage(part.mountpoint)
            out.append({"mount": part.mountpoint, "dev": part.device,
                        "total": u.total, "used": u.used, "free": u.free,
                        "pct": u.percent})
        except (PermissionError, OSError):
            continue
    out.sort(key=lambda x: x["mount"])
    return out


def _cpu_model():
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if "model name" in line:
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or "unknown"


class AlertConfigBody(BaseModel):
    enabled: bool = False
    machine_name: str = ""
    preview_url: str = ""
    pushplus_token: str = ""
    mem_threshold: float = 85
    disk_threshold: float = 90
    cooldown_min: int = 30
    check_interval_s: int = 60


def _mask_token(tok: str) -> str:
    tok = str(tok or "")
    if len(tok) <= 8:
        return "*" * len(tok)
    return tok[:4] + "*" * (len(tok) - 8) + tok[-4:]


def _public_base(request: Request, port: int, override: str) -> str:
    """推导内置应用的公网基址。

    预览环境的域名形如 `8002-<id>.monkeycode-ai.live`，端口是主机名前缀，
    把前缀换成目标端口即可得到同域的其他预览地址；非该形态时回落到本机地址。
    """
    if override:
        return override
    host = (request.headers.get("host") or "").split(":")[0].strip()
    prefix, sep, rest = host.partition("-")
    if sep and rest and prefix.isdigit():
        return f"https://{port}-{rest}"
    return f"http://127.0.0.1:{port}"


BRIDGE_TOKEN_FILE = os.path.join(BASE_DIR, "bridge_token.json")
BRIDGE_TOKEN_TTL_MS = 7 * 24 * 3600 * 1000


def _bridge_cached_token() -> str:
    """读取缓存的跳转令牌；过期或缺失返回空串。"""
    try:
        with open(BRIDGE_TOKEN_FILE, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return ""
    tok = str(data.get("token") or "")
    exp = int(data.get("expires_at") or 0)
    if tok and exp > time.time() + 300:
        return tok
    return ""


def _bridge_store_token(tok: str) -> None:
    tmp = BRIDGE_TOKEN_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"token": tok, "expires_at": int(time.time() + BRIDGE_TOKEN_TTL_MS / 1000)},
                  f, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, BRIDGE_TOKEN_FILE)


def _aitb_mint_token() -> str:
    """取得用于免登录跳转的令牌：优先复用缓存，失效时再向 bridge 申请。

    令牌有效期 7 天并落盘缓存，避免每次点击都新建一个短时效令牌把
    bridge 的令牌列表刷满。
    """
    cached = _bridge_cached_token()
    if cached:
        return cached
    payload = json.dumps({
        "name": "ops-launch",
        "ttlMs": BRIDGE_TOKEN_TTL_MS,
        "scopes": ["exec", "session", "admin"],
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{AITB_URL}/api/tokens",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {AITB_TOKEN}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=8) as resp:
        data = json.loads(resp.read().decode("utf-8", "replace"))
    tok = ((data or {}).get("token") or {}).get("token") or ""
    if not tok:
        raise RuntimeError("bridge 未返回令牌")
    _bridge_store_token(tok)
    return tok


@app.get("/api/launch/bridge")
async def launch_bridge(request: Request):
    _auth(request)
    base = _public_base(request, 8787, AITB_PUBLIC)
    try:
        tok = _aitb_mint_token()
    except Exception as exc:
        # 申请失败时退回统一令牌，保证仍能进入（只是 URL 里会带主令牌）
        print(f"[launch] bridge token mint failed: {exc}", flush=True)
        tok = AITB_TOKEN
    return {
        "ok": True,
        "url": f"{base}/?token={urllib.parse.quote(tok)}",
        "name": "终端桥接",
    }


@app.get("/api/launch/latency")
async def launch_latency(request: Request):
    _auth(request)
    return {
        "ok": True,
        "url": f"{_public_base(request, 8005, LATENCY_PUBLIC)}/",
        "name": "链路探针",
    }


@app.get("/api/alert/config")
async def alert_config_get(request: Request):
    _auth(request)
    cfg = _alert_load()
    out = dict(cfg)
    out["pushplus_token"] = _mask_token(cfg.get("pushplus_token") or "")
    out["has_token"] = bool(cfg.get("pushplus_token"))
    out["default_machine_name"] = _default_machine_name()
    out["last_push"] = {"mem": _alert_last["mem"], "disk": _alert_last["disk"]}
    return out


@app.post("/api/alert/config")
async def alert_config_set(body: AlertConfigBody, request: Request):
    _auth(request)
    cur = _alert_load()
    incoming = body.model_dump()
    tok = str(incoming.get("pushplus_token") or "").strip()
    if "*" in tok or not tok:
        incoming["pushplus_token"] = cur.get("pushplus_token") or ""
    incoming["mem_threshold"] = min(99.0, max(1.0, float(incoming.get("mem_threshold") or 85)))
    incoming["disk_threshold"] = min(99.0, max(1.0, float(incoming.get("disk_threshold") or 90)))
    incoming["cooldown_min"] = min(1440, max(1, int(incoming.get("cooldown_min") or 30)))
    incoming["check_interval_s"] = min(3600, max(10, int(incoming.get("check_interval_s") or 60)))
    saved = _alert_save(incoming)
    out = dict(saved)
    out["pushplus_token"] = _mask_token(saved.get("pushplus_token") or "")
    out["has_token"] = bool(saved.get("pushplus_token"))
    return {"ok": True, "config": out}


@app.post("/api/alert/test")
async def alert_test(request: Request):
    _auth(request)
    cfg = _alert_load()
    if not cfg.get("pushplus_token"):
        raise HTTPException(400, "请先保存 pushplus token")
    mem = _mem()
    disk_pct, disk_desc = _disk_max()
    detail = (f"内存 {mem['pct']:.1f}% ({_fmt_bytes(mem['used'])} / {_fmt_bytes(mem['total'])})"
              f"；磁盘最高 {disk_pct:.1f}% {disk_desc}")
    title, content = _build_alert_content(
        "mem", float(mem["pct"]), float(cfg.get("mem_threshold") or 85), cfg,
        "这是一条测试消息。" + detail)
    ok, msg = _pushplus_send(cfg["pushplus_token"], title, content)
    if not ok:
        raise HTTPException(502, f"推送失败: {msg}")
    return {"ok": True, "message": "测试消息已发送"}


@app.get("/api/stats")
async def stats(request: Request):
    _auth(request)
    with hist_lock:
        snap = list(hist)
    cur = snap[-1] if snap else None
    top_cpu, top_mem = _top_procs()
    nconn = -1
    try:
        nconn = len(psutil.net_connections(kind="inet"))
    except Exception:
        pass
    return {
        "sys": {
            "hostname": platform.node(),
            "platform": f"{platform.system()} {platform.release()}",
            "python": platform.python_version(),
            "boot": int(psutil.boot_time()),
            "uptime": int(time.time() - psutil.boot_time()),
            "cpu_count": psutil.cpu_count(logical=True),
            "cpu_model": _cpu_model(),
            "nconn": nconn,
        },
        "cur": cur,
        "hist": {
            "ts": [s["ts"] for s in snap],
            "cpu": [s["cpu"] for s in snap],
            "mem": [s["mem"]["pct"] for s in snap],
            "net_recv": [round(s["net_recv"]) for s in snap],
            "net_sent": [round(s["net_sent"]) for s in snap],
            "disk_read": [round(s["disk_read"]) for s in snap],
            "disk_write": [round(s["disk_write"]) for s in snap],
        },
        "disks": _disks(),
        "top_cpu": top_cpu,
        "top_mem": top_mem,
    }


threading.Thread(target=_sample_loop, daemon=True).start()
threading.Thread(target=_alert_loop, daemon=True).start()
