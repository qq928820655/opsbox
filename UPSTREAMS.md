# 接入的上游来源登记

opsbox 自身是原创仓库（`qq928820655/opsbox`），但它通过下拉菜单**内置接入**了两个独立部署的上游应用。本文件登记这些上游的 git 来源，供后续更新与回溯使用。

## 一览

| 应用 | 上游 git 仓库 | 分支 | 接入端口 | 接入方式 |
|---|---|---|---|---|
| ai-terminal-bridge | https://github.com/qq928820655/ai-terminal-bridge.git | `main` | 8787 | 令牌签发 + 免登录跳转 |
| latency-test | https://github.com/qq928820655/latency-test.git | `master` | 8005 | 直接跳转 |

## 接入时的上游版本（2026-11-06）

| 应用 | commit | 提交日期 | 提交标题 |
|---|---|---|---|
| ai-terminal-bridge | `07387edf01fd1e33db6db137a5280c5c8a711b62` | 2026-11-06 | chore: 忽略本地 state 目录 |
| latency-test | `45105dd12fe03c920e3803df9f80ee23d1be7a88` | 2026-11-05 | feat: 浏览器端链路探针（RTT / 吞吐 / 流式到达节奏） |

> 上游升级后如接口行为发生变化，需要同步核对本文件的版本行与 `app.py` 中的接入实现。

## 接入契约

### ai-terminal-bridge（8787）

opsbox 依赖的 bridge 接口：

| 接口 | 用途 |
|---|---|
| `POST /api/tokens` | 用统一令牌申请跳转令牌（scopes 需含 `exec`/`session`/`admin`） |
| `POST /api/auth/login` | 前端用 `?token=` 换取会话（bridge 自带逻辑） |
| `GET /api/health` | 存活探测 |

opsbox 侧实现见 `app.py`：

- `_aitb_mint_token()`：向 bridge 申请 7 天有效期令牌，落盘缓存到 `bridge_token.json`
- `_public_base()`：按 Host 头把 `8002-xxx` 换算成 `8787-xxx`
- `GET /api/launch/bridge`：返回带令牌的免登录 URL

### latency-test（8005）

纯静态跳转，无接口依赖。opsbox 仅拼接公网地址：

- `GET /api/launch/latency` → `https://8005-<id>.monkeycode-ai.live/`

## 配置项

opsbox 通过环境变量定位上游，默认值即本机部署：

| 变量 | 默认 | 说明 |
|---|---|---|
| `AITB_URL` | `http://127.0.0.1:8787` | bridge 内网地址 |
| `AITB_TOKEN` | 复用 `OPS_PASSWORD` | 调 bridge 管理接口的统一令牌 |
| `AITB_PUBLIC` | 空（按 Host 推导） | bridge 公网基址覆盖 |
| `LATENCY_URL` | `http://127.0.0.1:8005` | 链路探针内网地址 |
| `LATENCY_PUBLIC` | 空（按 Host 推导） | 链路探针公网基址覆盖 |

## 更新上游时的检查清单

1. 在对应上游仓库拉取新版本并重启服务
2. 核对 `POST /api/tokens` 的请求/响应结构是否变化（bridge）
3. 核对 `?token=` 免登录流程是否仍可用（bridge 前端）
4. 更新本文件「接入时的上游版本」表
5. 在 ops 面板下拉菜单点一次两个入口，确认免登录跳转正常

## 相关文件

- `app.py`：接入实现（`/api/launch/bridge`、`/api/launch/latency`）
- `.env.example`：配置项模板
- `index.html`：下拉菜单入口
