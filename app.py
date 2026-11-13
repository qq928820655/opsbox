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
import socket
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
DOLA_URL = (os.environ.get("DOLA_URL") or "http://127.0.0.1:8004").rstrip("/")
DOLA_PUBLIC = (os.environ.get("DOLA_PUBLIC") or "").rstrip("/")
# dola 出片面板管理密钥（释放浏览器等管理动作转发用；与面板 X-Admin-Key 同值）
DOLA_ADMIN_KEY = os.environ.get("DOLA_ADMIN_KEY") or "qq928820655"
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
            # is_dir 跟随符号链接：一个 `ln -s ../skills/animate animate` 就是
            # 目录，点进去应该能浏览。此前这里写成 isdir and not islink，把
            # 「链接指向目录」的条目一律降级成文件，前端于是按文件打开，而
            # /api/read 又用会跟随链接的 isdir 判成目录回 400——表现就是列表
            # 画成链接、点了提示「这是目录」却不跳转。
            is_link = os.path.islink(full)
            is_dir = os.path.isdir(full)
            entries.append({
                "name": name,
                "is_dir": is_dir,
                "is_link": is_link,
                # 悬空链接（目标不存在）既不进目录也读不到内容，单独标出来，
                # 免得前端点它时报一个「不存在」的通用错误。
                "broken_link": is_link and not os.path.exists(full),
                "size": 0 if is_dir else st.st_size,
                "mtime": int(st.st_mtime),
                "mode": __import__("stat").filemode(st.st_mode),
            })
        except (PermissionError, OSError):
            entries.append({"name": name, "is_dir": False, "is_link": False,
                            "broken_link": False,
                            "size": 0, "mtime": 0, "mode": "???", "error": True})
    entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
    return {"path": p, "entries": entries}


@app.get("/api/read")
async def api_read(request: Request, path: str):
    _auth(request)
    p = _abs(path)
    _check_exists(p)
    if os.path.isdir(p):
        # 用 200 + is_dir 而不是 400：编辑入口可能在别的路径上拿到一个目录
        # （符号链接、竞态改名），前端据此改成进目录，比弹一句「这是目录」
        # 然后什么都不做更有用。
        return {"path": p, "is_dir": True}
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
                            # 与 /api/list 同一套口径：is_dir 跟随链接（链接到
                            # 目录就是目录），但不顺着链接往下走，免得环。
                            is_link = e.is_symlink()
                            is_dir = e.is_dir()
                            results.append({
                                "path": e.path, "name": e.name,
                                "is_dir": is_dir,
                                "is_link": is_link,
                                "broken_link": is_link and not os.path.exists(e.path),
                                "size": 0 if is_dir else st.st_size,
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


def _dola_acct(cmdline):
    """从进程 cmdline 提取 dola 账号名（--user-data-dir=.../accounts/<账号>）。

    仅浏览器主进程携带 user-data-dir；对齐 dola-pool tools_api._top_procs 的
    chrome.<账号> 标注口径，便于在进程列表按内部账号识别与终止。"""
    for seg in cmdline or []:
        if seg.lstrip("-").startswith("user-data-dir="):
            base = seg.split("=", 1)[1].rstrip("/").split("/")[-1]
            return base or None
    return None


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
                created = True
            else:
                c["cpu"] = p.cpu_percent(interval=None)
                created = False
            c["info"] = p.info
            if created:
                try:
                    nm = (p.info.get("name") or "").lower()
                    acct = _dola_acct(p.cmdline())
                    if acct and "chrom" in nm:
                        c["info"]["name"] = f"chrome.{acct}"
                except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                    pass
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
    """推导内置应用的对外基址（A#133：不再回落 127.0.0.1）。

    优先级：
    1. 环境变量显式覆盖（AITB_PUBLIC/LATENCY_PUBLIC/DOLA_PUBLIC）；
    2. 预览环境 `8002-<id>.monkeycode-ai.live` 形态——把端口前缀换成目标端口；
    3. 任意域名/端口访问：沿用请求的协议 + 主机名，只把端口换成目标端口
       （用户实测：从非预览域名打开运维台时，按钮一律跳到 127.0.0.1，
       外网根本访问不到）；
    4. 仅在完全没有 Host 头（极少数本机探活）时才用 127.0.0.1。
    """
    if override:
        return override
    host_header = request.headers.get("host") or ""
    host = host_header.split(":")[0].strip()
    if not host:
        return f"http://127.0.0.1:{port}"
    prefix, sep, rest = host.partition("-")
    if sep and rest and prefix.isdigit():
        return f"https://{port}-{rest}"
    scheme = request.url.scheme or "http"
    # 本机回环地址按 http 处理（无 TLS）；其余域名保持请求协议
    if host in ("127.0.0.1", "localhost", "0.0.0.0"):
        return f"http://{host}:{port}"
    return f"{scheme}://{host}:{port}"


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


def _aitb_port() -> int:
    """本机个性化：bridge 实际端口从 AITB_URL 解析（上游硬编码 8787，本机部署在 8790）。"""
    try:
        p = urllib.parse.urlparse(AITB_URL).port
    except ValueError:
        p = None
    return p or 8787


@app.get("/api/launch/bridge")
async def launch_bridge(request: Request):
    _auth(request)
    base = _public_base(request, _aitb_port(), AITB_PUBLIC)
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


@app.get("/api/launch/dola")
async def launch_dola(request: Request):
    _auth(request)
    return {
        "ok": True,
        "url": f"{_public_base(request, 8004, DOLA_PUBLIC)}/panel",
        "name": "出片面板",
    }


# ---------- 目录占用扫描（移植自 dola-pool tools_api，资源监控个性化） ----------
# path -> {"ts","dirs","files","scanning","elapsed","error"}
_disk_scan_cache: dict = {}
_disk_scan_lock = threading.Lock()
# 扫描设置：auto=缓存到期后自动重扫；interval=自动重扫间隔（秒）。
# 持久化到 disk_scan_config.json，重启保留。
_disk_scan_cfg = {"auto": True, "interval": 600}
_disk_cfg_path = os.path.join(BASE_DIR, "disk_scan_config.json")


def _load_scan_cfg():
    try:
        with open(_disk_cfg_path, encoding="utf-8") as f:
            d = json.load(f)
        _disk_scan_cfg["auto"] = bool(d.get("auto", True))
        _disk_scan_cfg["interval"] = max(60, min(int(d.get("interval", 600)), 86400))
    except Exception:
        pass


def _save_scan_cfg():
    try:
        with open(_disk_cfg_path, "w", encoding="utf-8") as f:
            json.dump(_disk_scan_cfg, f)
    except Exception:
        pass


_load_scan_cfg()


def _scan_dir_sizes(path: str) -> dict:
    """扫描 path 下 depth-1 子目录与散文件的累计大小（字节数）。

    跳过符号链接与跨挂载点目录（du 语义），OSError 一律忽略。
    纯 Python 递归较慢（几万文件秒级~几十秒），只在后台线程里跑并缓存。
    """
    base_dev = os.stat(path).st_dev

    def tree_size(p: str) -> int:
        total = 0
        try:
            it = os.scandir(p)
        except OSError:
            return 0
        with it:
            for e in it:
                try:
                    if e.is_symlink():
                        continue
                    if e.is_dir(follow_symlinks=False):
                        if os.stat(e.path).st_dev != base_dev:
                            continue
                        total += tree_size(e.path)
                    elif e.is_file(follow_symlinks=False):
                        total += e.stat(follow_symlinks=False).st_size
                except OSError:
                    continue
        return total

    dirs = []
    loose_files = 0
    for name in os.listdir(path):
        full = os.path.join(path, name)
        try:
            st = os.lstat(full)
        except OSError:
            continue
        if os.path.islink(full):
            continue
        if os.path.isdir(full):
            if st.st_dev != base_dev:
                continue
            dirs.append({"name": name, "path": full, "size": tree_size(full)})
        elif os.path.isfile(full):
            loose_files += st.st_size
    dirs.sort(key=lambda d: d["size"], reverse=True)
    return {"dirs": dirs, "files": loose_files}


def _scan_dir_sizes_cached(path: str, force: bool = False) -> dict:
    """带缓存的目录占用扫描。

    auto 开启：缓存 interval 秒内直接返回，到期后下一次请求触发重扫；
    auto 关闭：缓存一直有效，点「重新扫描」才重扫；
    force=True：忽略缓存立即重扫（扫描进行中时仍返回 scanning 状态）。
    """
    now = time.time()
    with _disk_scan_lock:
        c = _disk_scan_cache.get(path)
        if c and c.get("scanning"):
            return {"path": path, "scanning": True, "dirs": [], "files": 0}
        if c and not force:
            if _disk_scan_cfg["auto"]:
                if now - c["ts"] < _disk_scan_cfg["interval"]:
                    return {**c, "cached": True}
            else:
                return {**c, "cached": True}
        _disk_scan_cache[path] = {"path": path, "ts": now, "scanning": True,
                                  "dirs": [], "files": 0, "error": ""}

    def _work():
        t0 = time.time()
        try:
            r = _scan_dir_sizes(path)
        except Exception as e:
            r = {"dirs": [], "files": 0, "error": str(e)[:200]}
        r.update({"path": path, "ts": time.time(), "scanning": False,
                  "elapsed": round(time.time() - t0, 1)})
        with _disk_scan_lock:
            _disk_scan_cache[path] = r

    threading.Thread(target=_work, daemon=True).start()
    return {"path": path, "scanning": True, "dirs": [], "files": 0}


@app.get("/api/disk/usage")
async def api_disk_usage(request: Request, path: str = "/", force: bool = False):
    """目录占用明细：depth-1 子目录大小排行（后台扫描 + 缓存）。

    缓存策略由 /api/disk/scan_config 控制（自动扫描开关 + 间隔）；
    force=1 忽略缓存立即重扫。返回 scanning=True 表示扫描进行中，前端轮询。
    """
    _auth(request)
    path = os.path.normpath(path)
    if not os.path.isdir(path):
        raise HTTPException(404, "目录不存在")
    return _scan_dir_sizes_cached(path, force=force)


class ScanCfgBody(BaseModel):
    auto: bool | None = None
    interval: int | None = None  # 秒；写入时夹到 60~86400


@app.get("/api/disk/scan_config")
async def api_disk_scan_config_get(request: Request):
    _auth(request)
    return {**_disk_scan_cfg}


@app.post("/api/disk/scan_config")
async def api_disk_scan_config_set(request: Request, body: ScanCfgBody):
    _auth(request)
    if body.auto is not None:
        _disk_scan_cfg["auto"] = bool(body.auto)
    if body.interval is not None:
        _disk_scan_cfg["interval"] = max(60, min(int(body.interval), 86400))
    _save_scan_cfg()
    return {"ok": True, **_disk_scan_cfg}


class KillBody(BaseModel):
    pid: int


@app.post("/api/kill")
async def api_kill(request: Request, body: KillBody):
    """终止进程：先 TERM 等 5s，仍在则 KILL。保护 init 与运维台自身。"""
    _auth(request)
    if body.pid in (1, os.getpid()):
        raise HTTPException(400, "拒绝终止该进程")
    try:
        pr = psutil.Process(body.pid)
    except psutil.NoSuchProcess:
        raise HTTPException(404, "进程不存在")
    try:
        pr.terminate()
        gone, _ = psutil.wait_procs([pr], timeout=5)
        if gone:
            return {"ok": True, "mode": "terminate"}
        pr.kill()
        return {"ok": True, "mode": "kill"}
    except psutil.AccessDenied:
        raise HTTPException(403, "无权限终止该进程")


@app.post("/api/dola/release_browsers")
async def api_dola_release_browsers(request: Request):
    """转发 dola 出片面板「释放全部空闲 Chromium」（管理动作在面板侧执行）。"""
    _auth(request)
    req = urllib.request.Request(
        f"{DOLA_URL}/api/admin/release_browsers", method="POST",
        headers={"X-Admin-Key": DOLA_ADMIN_KEY, "Content-Type": "application/json"},
        data=b"{}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
    except Exception as exc:
        raise HTTPException(502, f"dola 面板不可达或失败: {exc}")
    return {"ok": True, "dola": data}


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
        "net_ifs": _net_if_detail(),
        "top_cpu": top_cpu,
        "top_mem": top_mem,
    }


def _net_if_detail():
    """每网卡明细：IP / 启用状态 / 链路速率 / 收发累计（dola mon 个性化）。"""
    try:
        io = psutil.net_io_counters(pernic=True)
    except Exception:
        io = {}
    try:
        addrs = psutil.net_if_addrs()
    except Exception:
        addrs = {}
    try:
        st = psutil.net_if_stats()
    except Exception:
        st = {}
    out = []
    for name, counters in sorted(io.items()):
        addr = ""
        for a in addrs.get(name, []):
            if a.family == socket.AF_INET:
                addr = a.address
                break
        s = st.get(name)
        out.append({"name": name, "addr": addr,
                    "up": bool(s.isup) if s else None,
                    "speed": s.speed if s and s.speed and s.speed > 0 else 0,
                    "rx": counters.bytes_recv, "tx": counters.bytes_sent})
    return out


threading.Thread(target=_sample_loop, daemon=True).start()
threading.Thread(target=_alert_loop, daemon=True).start()
