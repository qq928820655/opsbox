# opsbox 运维工作台

文件管理 + 资源监控一体化的运维面板（FastAPI 单服务，默认端口 8002），内置 PushPlus 资源预警，并通过下拉菜单接入终端桥接与链路探针。

## 功能

- **资源监控**：CPU / 内存（RSS 口径）/ 网络 / 磁盘 IO / 分区使用 / Top 进程，1 秒采样，默认首页
- **文件管理**：浏览、编辑、上传、下载、解压、搜索、批量操作
- **预警设置**：内存 RSS 或磁盘使用率超阈值时经 PushPlus 推送
- **内置应用入口**：下拉菜单直达终端桥接、链路探针与出片面板，共享登录态（bridge 免登录）

## 快速开始

```bash
cp .env.example .env    # 设置 OPS_PASSWORD
./start.sh              # 默认 8002
./stop.sh
```

浏览器打开 `http://127.0.0.1:8002/`，用 `.env` 里的密码登录。

## 配置

`.env`（或环境变量）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `OPS_PORT` | `8002` | 监听端口 |
| `OPS_PASSWORD` | 代码内默认值 | 登录密码 |
| `AITB_URL` | `http://127.0.0.1:8787` | 终端桥接内网地址 |
| `AITB_TOKEN` | 复用 `OPS_PASSWORD` | 调终端桥接管理接口的令牌 |
| `AITB_PUBLIC` | 空（按 Host 推导） | 终端桥接公网基址覆盖 |
| `LATENCY_URL` | `http://127.0.0.1:8005` | 链路探针内网地址 |
| `LATENCY_PUBLIC` | 空（按 Host 推导） | 链路探针公网基址覆盖 |
| `DOLA_URL` | `http://127.0.0.1:8004` | 出片面板（dola-pool）内网地址 |
| `DOLA_PUBLIC` | 空（按 Host 推导） | 出片面板公网基址覆盖 |

## 接口

文件：`/api/list` `read` `save` `mkdir` `touch` `delete` `rename` `copy` `move` `upload` `download` `preview` `unarchive` `search`

监控：`GET /api/stats`

预警：`GET|POST /api/alert/config`、`POST /api/alert/test`

内置应用跳转：`GET /api/launch/bridge`、`GET /api/launch/latency`

鉴权：同一密码登录，HMAC token；API 用 `X-Auth-Token` 头或 `?token=` 查询串。

## 接入的上游

本仓库内置接入三个独立应用（终端桥接、链路探针、出片面板），来源与版本登记见 [UPSTREAMS.md](UPSTREAMS.md)。

## 许可

MIT
