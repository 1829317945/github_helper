# docker_setup.sh

这个脚本解决的核心需求是：

**"我想快速跑起来一个 GitHub 项目，但不想折腾环境"**

具体来说：

**环境污染问题** — 克隆一个项目，装了一堆 Node、Python、Go 依赖，用完不知道怎么清理干净。脚本把所有东西隔离在 Docker 里，用完一条命令全删。

**配置门槛问题** — 大多数项目需要自己写 Dockerfile，选基础镜像、写安装命令、配端口。不熟悉 Docker 的人光这一步就卡住了。脚本把这个过程自动化掉。

**端口冲突问题** — 本地已经跑着别的服务，新项目端口撞上了。脚本会自动检测占用情况，切换到可用端口。

**网络环境问题** — HTTPS 克隆被限制的环境下，自动切换 SSH 克隆。

**适用场景：**

- 看到一个有趣的开源项目想本地体验，但不想在机器上装一套完整运行环境
- 快速评估一个项目是否值得深入研究，跑起来看看再说
- 给别人演示项目，不依赖对方机器上装了什么
- 隔离运行不信任的代码，不污染宿主机

```bash
bash docker_setup.sh https://github.com/CorentinTh/it-tools --port 8888:80
```

---

## 特性

- **自动识别项目类型** — 检测 Node.js（npm / yarn / pnpm）、Python、Go、Rust、Ruby、PHP、CMake、Make，自动选择对应基础镜像
- **自动生成 Dockerfile** — 无需手动编写，依赖安装与代码分层，充分利用 Docker 构建缓存
- **自动检测端口** — 从 `package.json`、源码中的 `listen()` 调用推断，找不到则按语言给默认值
- **优先使用项目自带配置** — 若仓库包含 `Dockerfile` 或 `docker-compose.yml`，直接使用，不覆盖
- **环境变量交互配置** — 自动读取 `.env.example` / `.env.sample`，逐项询问赋值
- **SSH / HTTPS 双通道克隆** — 优先 SSH，失败后自动回退 HTTPS，适应不同网络环境
- **自动端口冲突检测** — 启动前扫描端口占用，自动切换到可用端口
- **完整清理机制** — `trap EXIT` 保证异常退出时临时目录和残留容器都被清理

---

## 快速开始

```bash
# 下载脚本
curl -O https://raw.githubusercontent.com/yourname/docker-setup/main/docker_setup.sh

# 运行一个 Node.js 项目
bash docker_setup.sh https://github.com/CorentinTh/it-tools --port 8888:80

# 运行一个 Python 项目
bash docker_setup.sh https://github.com/tiangolo/fastapi --port 8000:8000

# 运行完自动删除镜像
bash docker_setup.sh https://github.com/CorentinTh/it-tools --rm
```

---

## 选项

| 选项 | 说明 | 示例 |
|------|------|------|
| `--port HOST:CONTAINER` | 端口映射，可多次使用 | `--port 8080:3000` |
| `--env KEY=VALUE` | 注入环境变量，可多次使用 | `--env NODE_ENV=production` |
| `--keep` | 运行完保留镜像，不询问 | |
| `--rm` | 运行完删除镜像，不询问 | |
| `-h, --help` | 显示帮助 | |

---

## 支持的项目类型

| 类型 | 检测依据 | 基础镜像 | 默认端口 |
|------|----------|----------|----------|
| Node.js (pnpm) | `pnpm-lock.yaml` | `node:20-alpine` | 3000 |
| Node.js (yarn) | `yarn.lock` | `node:20-alpine` | 3000 |
| Node.js (npm) | `package.json` | `node:20-alpine` | 3000 |
| Python | `requirements.txt` / `pyproject.toml` / `setup.py` | `python:3.12-slim` | 8000 |
| Go | `go.mod` | `golang:1.22-alpine` | 8080 |
| Rust | `Cargo.toml` | `rust:1.78-slim` | — |
| Ruby | `Gemfile` | `ruby:3.3-alpine` | 4567 |
| PHP | `composer.json` | `php:8.3-cli-alpine` | 8080 |
| CMake | `CMakeLists.txt` | `ubuntu:24.04` | — |
| Make | `Makefile` | `ubuntu:24.04` | — |
| Java | `pom.xml` / `build.gradle` | `eclipse-temurin:21-jdk` | 8000 |
| 静态文件 | 其他 | `python:3.12-slim` | 8080 |

---

## 工作流程

```
输入 GitHub URL
      ↓
克隆仓库（SSH 优先，HTTPS 兜底）
      ↓
检测项目类型
      ↓
检测项目是否有 Dockerfile / docker-compose.yml
      ├─ 有 → 直接使用
      └─ 无 → 自动生成 Dockerfile
              ↓
           检测启动命令 & 端口
              ↓
           构建 Docker 镜像
      ↓
读取 .env.example（如有）→ 交互式配置环境变量
      ↓
自动检测可用端口，启动容器
      ↓
询问是否保留镜像 / --keep / --rm
```

---

## 常见问题

**Q: 页面打不开，浏览器显示连接拒绝**

检查容器是否真正启动，以及服务监听的端口是否与映射一致：
```bash
docker ps
docker logs <容器名>
```

**Q: Vite 项目启动后显示 `Network: use --host to expose`**

服务没有绑定到 `0.0.0.0`，需要在启动命令里加 `--host`：
```bash
docker run --rm -p 8888:5173 docker-setup/<项目名>:latest pnpm run dev -- --host
```

**Q: 项目有 nginx 托管（如 it-tools），实际端口是 80**

部分前端项目构建后由 nginx 托管，监听 80 端口而非开发服务器端口：
```bash
bash docker_setup.sh https://github.com/CorentinTh/it-tools --port 8888:80
```

**Q: npm 安装超时或 ECONNRESET**

网络不稳定导致，建议在 Dockerfile 里设置国内镜像源。在脚本的 `node-npm` 分支里将安装命令改为：
```bash
RUN npm config set registry https://registry.npmmirror.com && npm ci || npm install
```

**Q: cmake 项目缺少系统依赖（如 libncurses）**

cmake 项目的系统依赖因项目而异，脚本无法自动处理。目前需要手动在生成的 Dockerfile 里加入对应的 `apt-get install`。

**Q: 克隆失败：`Repository not found`**

- HTTPS 模式：检查仓库 URL 是否正确，仓库是否公开
- SSH 模式：确认 `~/.ssh/id_ed25519.pub` 已添加到 GitHub → Settings → SSH Keys

---

## 已知限制

- **多服务项目**：有 `docker-compose.yml` 的项目会尝试用 `docker compose up` 启动，但复杂依赖（数据库、Redis 等）可能需要额外配置
- **cmake 系统依赖**：无法自动检测和安装项目特定的系统库
- **私有仓库**：需要提前配置 SSH key 或 Personal Access Token
- **monorepo**：只检测根目录，子包不识别

---

## 清理

运行结束后脚本会询问是否删除镜像。若需手动清理所有构建内容：

```bash
# 停止所有容器
docker stop $(docker ps -q) 2>/dev/null

# 删除所有容器和镜像
docker system prune -af --volumes
```

---

## 依赖

- Docker 20.10+
- Git
- Python 3（用于解析 `package.json` 中的脚本字段）
- bash 4.0+（macOS 默认是 bash 3.x，建议 `brew install bash`）
