#!/usr/bin/env bash
# =============================================================================
#  docker_setup.sh — Docker 隔离版 GitHub 项目一键运行脚本
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}[→]${RESET} $*"; }
success() { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✗]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }
die()     { error "$*"; exit 1; }

REPO_URL=""
PORT_ARGS=()
ENV_ARGS=()
CLEANUP_MODE="ask"

show_help() {
  cat << EOF
${BOLD}用法:${RESET}  bash docker_setup.sh <GitHub仓库URL> [选项]

${BOLD}选项:${RESET}
  --port  HOST:CONTAINER   端口映射，可多次使用
  --env   KEY=VALUE        注入环境变量，可多次使用
  --keep                   运行完保留镜像，不询问
  --rm                     运行完删除镜像，不询问
  -h, --help               显示此帮助
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)   show_help ;;
    --port)      [[ -z "${2:-}" ]] && die "--port 需要参数"; PORT_ARGS+=("-p" "$2"); shift 2 ;;
    --env)       [[ -z "${2:-}" ]] && die "--env 需要参数";  ENV_ARGS+=("-e" "$2");  shift 2 ;;
    --keep)      CLEANUP_MODE="keep";   shift ;;
    --rm)        CLEANUP_MODE="remove"; shift ;;
    http*|git@*) REPO_URL="$1"; shift ;;
    *)           die "未知参数: $1，运行 --help 查看用法" ;;
  esac
done

[[ -z "$REPO_URL" ]] && {
  echo -e "${BOLD}用法:${RESET} bash docker_setup.sh <GitHub仓库URL> [选项]"
  exit 1
}

REPO_NAME=$(basename "$REPO_URL" .git \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9._-]/-/g')
IMAGE_TAG="docker-setup/${REPO_NAME}:latest"
CONTAINER_NAME="docker-setup-${REPO_NAME}-$$"
WORK_DIR=""

cleanup() {
  local exit_code=$?
  # 删除临时目录
  [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  # 停止并删除容器
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  # 只有异常退出才删除镜像
  if [[ $exit_code -ne 0 ]];then
    docker rmi "$IMAGE_TAG" >/dev/null 2>&1 || true
  fi
}
trap 'cleanup' EXIT INT TERM

# ─── 检查 Docker ──────────────────────────────────────────────────────────────
step "检查 Docker 环境"
command -v docker &>/dev/null || die "未检测到 Docker"
docker info &>/dev/null 2>&1  || die "Docker 守护进程未运行"
DOCKER_VER=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
success "Docker ${DOCKER_VER} 就绪"
# --- 修正后的克隆逻辑：防止认证弹窗 ---
step "克隆仓库"
WORK_DIR=$(mktemp -d)
TARGET_DIR="$WORK_DIR/repo"

# 1. 禁用 Git 终端交互提示 (核心：解决 image_2b3d13.png 中的问题)
export GIT_TERMINAL_PROMPT=0

# 2. 设置 SSH 参数：自动接受服务器指纹 (防止卡在 yes/no 确认)
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o BatchMode=yes"

# 3. 准备备选 URL
# 使用更健壮的正则表达式，确保转换成标准的 git@github.com:user/repo.git 格式
SSH_URL=$(echo "$REPO_URL" | sed -E 's|https://github.com/([^/]+)/([^/.]+)(\.git)?|git@github.com:\1/\2.git|')

info "正在尝试克隆项目..."
info "调试 - 原始 URL: $REPO_URL"
info "调试 - 转换后的 SSH URL: $SSH_URL"
# 4. 尝试顺序：SSH -> HTTPS
# 如果两个都失败，脚本会直接 die 并触发 cleanup，绝不卡死
if git clone --depth 1 "$SSH_URL" "$TARGET_DIR" ; then
    success "通过 SSH 克隆成功 (安全、无认证需求)"
elif git clone --depth 1 "$REPO_URL" "$TARGET_DIR" 2>/dev/null; then
    success "通过 HTTPS 克隆成功"
else
    # 这里如果失败，说明是彻底连不上或 GitHub 强制拒绝了
    error "克隆失败：GitHub 拒绝了匿名访问或网络不可达。"
    die "请检查 URL 是否正确或稍后再试。已执行清理。"
fi

cd "$TARGET_DIR" || die "无法进入克隆目录"
# 修复 Vite PWA 构建问题
sed -i 's/yarn build:app:docker/yarn build || true/' Dockerfile 2>/dev/null || true
# 检测 Dockerfile / Compose (最高优先级)
USE_EXISTING_DOCKERFILE=false
if [[ -f "docker-compose.yml" || -f "compose.yaml" ]];then
  success "检测到 docker-compose, 使用 compose 启动"
  if [[ -f "docker-compose.override.yml" ]];then
    info "检测到 override 配置, 将自动合并"
  fi
  if [[ -f ".env" ]];then
    info "检测到 .env 文件"
  fi
  step "启动 docker compose"
  docker compose up --build -d

  success "服务已启动"
  echo ""
  docker compose ps
  echo -e "${BOLD}${CYAN}-- 实时日志 -----------------------${RESET}"
# 使用更健壮的正则表达式，确保转换成标准的 git@github.com:user/repo.git 格式
SSH_URL=$(echo "$REPO_URL" | sed -E 's|https://github.com/([^/]+)/([^/.]+)(\.git)?|git@github.com:\1/\2.git|')  trap 'docker compose down -v >/dev/null 2>&1 || true' EXIT INT TERM
  docker compose logs -f
  exit 0
fi

if [[ -f "Dockerfile" ]];then
  success "检测到项目自带 Dockerfile, 优先使用"
  USE_EXISTING_DOCKERFILE=true
fi
RUN sed -i \
  -e 's/VitePWA(/VitePWA({ disable: true },/g' \
  -e 's/workbox: {/workbox: { maximumFileSizeToCacheInBytes: 5000000,/g' \
  vite.config.* 2>/dev/null || true
# ─── 检测项目类型 ─────────────────────────────────────────────────────────────
step "检测项目类型"

detect_project() {
  if [[ -f "package.json" ]]; then
    if   [[ -f "pnpm-lock.yaml" ]]; then echo "node-pnpm"
    elif [[ -f "yarn.lock"      ]]; then echo "node-yarn"
    else                                  echo "node-npm"
    fi
    return
  fi
  [[ -f "requirements.txt" || -f "pyproject.toml" || -f "setup.py" ]] && { echo "python"; return; }
  [[ -f "Cargo.toml"     ]] && { echo "rust";  return; }
  [[ -f "go.mod"         ]] && { echo "go";    return; }
  [[ -f "CMakeLists.txt" ]] && { echo "cmake"; return; }
  [[ -f "Gemfile"        ]] && { echo "ruby";  return; }
  [[ -f "composer.json"  ]] && { echo "php";   return; }
  [[ -f "Makefile"       ]] && { echo "make";  return; }
  [[ -f "pom.xml" || -f "build.gradle" ]] && { echo "java"; return;}
  echo "unknown"
}

PROJECT_TYPE=$(detect_project)
success "项目类型: ${BOLD}${PROJECT_TYPE}${RESET}"

# ─── 检测启动命令 ─────────────────────────────────────────────────────────────
detect_start_cmd() {
  case "$PROJECT_TYPE" in
    node-*)
      local tool="${PROJECT_TYPE#node-}"
      local dev start
      dev=$(python3 -c "
import json
try:
  d=json.load(open('package.json'))
  print(d.get('scripts',{}).get('dev',''))
except: pass
" 2>/dev/null || true)
      start=$(python3 -c "
import json
try:
  d=json.load(open('package.json'))
  print(d.get('scripts',{}).get('start',''))
except: pass
" 2>/dev/null || true)
      if [[ -n "$dev" ]];then
        echo "${tool} run preview || ${tool} run start || ${tool} run dev"
      elif [[ -n "$start" ]];then
        echo "${tool} run start"
      else 
        echo "${tool} start"
      fi
      ;;
    python)
      if [[ -f "manage.py" ]];then
        echo "python manage.py runserver 0.0.0.0:\$PORT"
        return 
      fi
      if grep -qi "fastapi" *.py 2>/dev/null;then
     
       for f in main.py app.py server.py; do
        [[ -f "$f" ]] && { echo "uvicorn ${f%.py}:app --host 0.0.0.0 --port \$PORT"; return; }
       done
      fi
      if grep -qi "flask" *.py 2>/dev/null;then
        for f in app.py main.py;do
          [[ -f "$f" ]] && { echo "flask run --host=0.0.0.0 --port=\$PORT"; return;}
        done
      fi
      for f in main.py app.py server.py;do
        [[ -f "$f" ]] && { echo "python $f";return;}
      done
      echo "python -m http.server \$PORT"
      echo "python main.py"
      ;;
    rust)    echo "./app" ;;
    go)      echo "./main" ;;
    cmake)   echo "./build/${REPO_NAME}" ;;
    ruby)    echo "bundle exec ruby app.rb" ;;
    php)     echo "php -S 0.0.0.0:8080 -t public" ;;
    make)    grep -q "^run:" Makefile 2>/dev/null && echo "make run" || echo "make" ;;
    unknown) echo "python3 -m http.server 8080" ;;
    *)       echo "echo '请手动指定启动命令'" ;;
  esac
}

START_CMD=$(detect_start_cmd)
info "检测到启动命令: ${BOLD}${START_CMD}${RESET}"

# ─── 选择基础镜像 ─────────────────────────────────────────────────────────────
pick_base_image() {
  case "$PROJECT_TYPE" in
    node-*)  echo "node:20-alpine" ;;
    python)  echo "python:3.12-slim" ;;
    rust)    echo "rust:1.78-slim" ;;
    go)      echo "golang:1.22-alpine" ;;
    cmake)   echo "ubuntu:24.04" ;;
    ruby)    echo "ruby:3.3-alpine" ;;
    php)     echo "php:8.3-cli-alpine" ;;
    make)    echo "ubuntu:24.04" ;;
    java)    echo "eclipse-temurin:21-jdk" ;;
    unknown) echo "python:3.12-slim" ;;
    *)       echo "ubuntu:24.04" ;;
  esac
}

BASE_IMAGE=$(pick_base_image)
info "基础镜像: ${BOLD}${BASE_IMAGE}${RESET}"

# ─── 检测端口 ─────────────────────────────────────────────────────────────────
detect_expose_port() {
  if [[ -f "package.json" ]]; then
    local p
    p=$(grep -oE '"PORT"[[:space:]]*:[[:space:]]*[0-9]+' package.json 2>/dev/null \
        | grep -oE '[0-9]+$' | head -1)
    [[ -n "$p" ]] && { echo "$p"; return; }
  fi
  local p
  p=$(grep -rE 'listen\(([0-9]{4,5})' --include="*.js" --include="*.ts" \
      --include="*.py" --include="*.rb" -h . 2>/dev/null \
      | grep -oE '[0-9]{4,5}' | head -1)
  [[ -n "$p" ]] && { echo "$p"; return; }
  case "$PROJECT_TYPE" in
    node-*)  echo "3000" ;;
    python)  echo "8000" ;;
    java)    echo "8000" ;;
    php)     echo "8080" ;;
    ruby)    echo "4567" ;;
    go)      echo "8080" ;;
    unknown) echo "8080" ;;
    *)       echo "" ;;
  esac
}

EXPOSE_PORT=$(detect_expose_port)
generate_cmd() {
  case "$PROJECT_TYPE" in

    node-*)
      cat << 'EOF'
CMD sh -c "\
  (npm run build || yarn build) >/dev/null 2>&1 || echo 'build failed'; \
  (npm run preview || yarn preview) \
  || (npm run start || yarn start) \
  || (npm run dev -- --host 0.0.0.0 --port $PORT || yarn dev --host 0.0.0.0 --port $PORT) \
"
EOF
      ;;

    python)
      echo "CMD sh -c \"$START_CMD\""
      ;;
make|cmake)
cat << 'EOF'
CMD ["sh","-c","echo '🔧 构建完成，开始查找可执行文件...'; \
for f in httpd server main app a.out; do \
  if [ -f \"$f\" ]; then \
    chmod +x \"$f\" 2>/dev/null || true; \
    echo \"🚀 运行: ./$f\"; \
    exec ./$f $PORT || exec ./$f; \
  fi; \
done; \
EXEC=$(file * 2>/dev/null | grep ELF | awk -F: '{print $1}' | head -1); \
if [ -n \"$EXEC\" ]; then \
  chmod +x \"$EXEC\" 2>/dev/null || true; \
  echo \"🚀 运行: ./$EXEC\"; \
  exec ./$EXEC $PORT || exec ./$EXEC; \
fi; \
echo '⚠️ 未找到，尝试 gcc 编译...'; \
gcc *.c -o app 2>/dev/null || true; \
if [ -f app ]; then \
  chmod +x app; \
  echo '🚀 运行: ./app'; \
  exec ./app $PORT || exec ./app; \
fi; \
echo '❌ 未找到任何可执行文件'; \
exit 1"]
EOF
;;
    

    go)
      echo 'CMD ["./main"]'
      ;;

    rust)
      echo 'CMD ["./target/release/app"]'
      ;;

    java)
      echo 'CMD ["java","-jar","target/app.jar"]'
      ;;

    *)
      echo 'CMD ["sh"]'
      ;;
  esac
}

# ─── 生成 Dockerfile ──────────────────────────────────────────────────────────
step "生成 Dockerfile"

generate_dockerfile() {
  cat > .dockerignore << 'EOF'
node_modules
.git
dist
build
.env
*.log
__pycache__
*.pyc
target
vendor
EOF

  cat > Dockerfile << DEOF
FROM ${BASE_IMAGE}
WORKDIR /app
ENV HOST=0.0.0.0
ENV PORT=${EXPOSE_PORT:-3000}
DEOF

  case "$PROJECT_TYPE" in
    node-pnpm)
      cat >> Dockerfile << 'DEOF'
COPY package.json pnpm-lock.yaml ./
RUN npm install -g pnpm && pnpm install --frozen-lockfile
RUN sed -i \
  -e 's/VitePWA(/VitePWA({ disable: true },/g' \
  -e 's/workbox: {/workbox: { maximumFileSizeToCacheInBytes: 5000000,/g' \
  vite.config.* 2>/dev/null || true
COPY . .
DEOF
      ;;
    node-yarn)
      cat >> Dockerfile << 'DEOF'
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile
RUN sed -i 's/VitePWA(/VitePWA({ disable: true },/' vite.config.* 2>/dev/null || true
COPY . .
DEOF
      ;;
    node-npm)
      cat >> Dockerfile << 'DEOF'
COPY package.json package-lock.json* ./
RUN npm ci || npm install
RUN npm run build 2>/dev/null || true
RUN sed -i 's/VitePWA(/VitePWA({ disable: true },/' vite.config.* 2>/dev/null || true
COPY . .
DEOF
      ;;
    python)
      cat >> Dockerfile << 'DEOF'
COPY requirements.txt* pyproject.toml* setup.py* ./
RUN pip install --no-cache-dir -r requirements.txt 2>/dev/null || \
    pip install --no-cache-dir -e . 2>/dev/null || \
    pip install --no-cache-dir . 2>/dev/null || \
    pip install --no-cache-dir flask fastapi uvicorn django  2>/dev/null || true
COPY . .
DEOF
      ;;
    rust)
      cat >> Dockerfile << 'DEOF'
COPY Cargo.toml Cargo.lock* ./
RUN mkdir -p src && echo "fn main(){}" > src/main.rs && cargo build --release && rm -rf src
COPY . .
RUN cargo build --release
DEOF
      ;;
    go)
      cat >> Dockerfile << 'DEOF'
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN go build -o main .
DEOF
      ;;
    cmake)
      cat >> Dockerfile << 'DEOF'
RUN apt-get update -qq && apt-get install -y cmake build-essential -qq
COPY . .
RUN mkdir -p build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j"$(nproc)"
DEOF
      ;;
    ruby)
      cat >> Dockerfile << 'DEOF'
COPY Gemfile Gemfile.lock* ./
RUN bundle install
COPY . .
DEOF
      ;;
    php)
      cat >> Dockerfile << 'DEOF'
COPY composer.json composer.lock* ./
RUN composer install --no-interaction 2>/dev/null || true
COPY . .
DEOF
      ;;
    make)
      cat >> Dockerfile << 'DEOF'
RUN apt-get update -qq && apt-get install -y build-essential -qq
COPY . .
RUN make || true && \
    (ls -l || true) && \
    (gcc *.c -o app 2>/dev/null || true)
DEOF
      ;;
    java)
      cat >> Dockerfile << 'DEOF'
COPY . .
RUN ./mvnw package -DskipTests || mvn package -DskipTests || true
CMD sh -c "java -jar target/*.jar"
DEOF
      ;;
    *)
      cat >> Dockerfile << 'DEOF'
COPY . .
DEOF
      ;;
  esac
generate_cmd >> Dockerfile
 
}
if [[ "$USE_EXISTING_DOCKERFILE" == "true" ]];then
  info "使用项目原生 Dockerfile"
else
generate_dockerfile
fi

success "Dockerfile 生成完成"

echo ""
echo -e "${BOLD}${CYAN}── 生成的 Dockerfile ──${RESET}"
cat -n Dockerfile | sed 's/^/  /'
echo ""

# ─── 构建镜像 ─────────────────────────────────────────────────────────────────
step "构建 Docker 镜像"
info "镜像标签: ${IMAGE_TAG}"

docker build \
  --tag "$IMAGE_TAG" \
  --label "docker-setup.repo=${REPO_URL}" \
  --label "docker-setup.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  . \
  || die "镜像构建失败"

success "镜像构建完成: ${IMAGE_TAG}"

# ─── 处理 .env 文件 ───────────────────────────────────────────────────────────
step "检查环境变量配置"

for tmpl in .env.example .env.sample .env.template; do
  if [[ -f "$tmpl" ]]; then
    warn "检测到 ${tmpl}，请为以下变量提供值（留空使用默认）："
    while IFS= read -r line; do
      [[ "$line" =~ ^#.*$ || ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
      key="${line%%=*}"
      default="${line#*=}"
      echo -ne "  ${YELLOW}${key}${RESET}${default:+（默认: ${default}）}: "
      read -r val
      [[ -n "$val" ]] && ENV_ARGS+=("-e" "${key}=${val}")
    done < "$tmpl"
    break
  fi
done

# ─── 运行容器 ─────────────────────────────────────────────────────────────────
step "启动容器"
FINAL_PORT=""
for p in "$EXPOSE_PORT" 3000 5173 8000 8080 5000; do
  [[ -z "$p" ]] && continue
  if ! lsof -i:$p >/dev/null 2>&1;then
    FINAL_PORT=$p
    break
  fi
done
[[ -z "$FINAL_PORT" ]] && FINAL_PORT=$(shuf -i 20000-40000 -n 1)

PORT_ARGS=("-p" "${FINAL_PORT}:${FINAL_PORT}")
ENV_ARGS+=("-e" "PORT=${FINAL_PORT}")
RUN_CMD=(docker run -d --name "$CONTAINER_NAME" -e HOST=0.0.0.0) 
[[ ${#PORT_ARGS[@]} -gt 0 ]] && RUN_CMD+=("${PORT_ARGS[@]}")
[[ ${#ENV_ARGS[@]}  -gt 0 ]] && RUN_CMD+=("${ENV_ARGS[@]}")
RUN_CMD+=(--rm "$IMAGE_TAG")

info "执行: ${RUN_CMD[*]}"

if [[ ${#PORT_ARGS[@]} -gt 0 ]]; then
  HOST_PORT=$(echo "${PORT_ARGS[1]}" | cut -d: -f1)
  info "访问地址: http://localhost:${HOST_PORT}"
elif [[ -n "$EXPOSE_PORT" ]]; then
  info "访问地址: http://localhost:${FINAL_PORT}"
fi

echo ""
echo -e "${BOLD}${CYAN}── 容器输出 ──────────────────────────────────────────${RESET}"

EXIT_CODE=0
"${RUN_CMD[@]}" || EXIT_CODE=$?

echo -e "${BOLD}${CYAN}── 容器已退出（退出码: ${EXIT_CODE}）──────────────────${RESET}"

# ─── 清理 ─────────────────────────────────────────────────────────────────────
step "清理"

do_cleanup() {
  local exit_code=$?

  info "删除镜像 ${IMAGE_TAG}..."
  docker rmi "$IMAGE_TAG" --force 2>/dev/null && success "镜像已删除"
  docker image prune -f &>/dev/null && success "悬空层已清理"
  success "环境已完全清除"
}

do_keep() {
  success "镜像已保留: ${IMAGE_TAG}"
  echo ""
  echo -e "  下次直接运行:"
  if [[ ${#PORT_ARGS[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}docker run --rm ${PORT_ARGS[*]} ${IMAGE_TAG}${RESET}"
  else
    echo -e "  ${BOLD}docker run --rm ${IMAGE_TAG}${RESET}"
  fi
  echo -e "\n  手动删除镜像:"
  echo -e "  ${BOLD}docker rmi ${IMAGE_TAG}${RESET}"
}

case "$CLEANUP_MODE" in
  remove) do_cleanup ;;
  keep)   do_keep ;;
  ask)
    echo ""
    echo -e "${BOLD}是否删除 Docker 镜像？${RESET}"
    echo -e "  ${GREEN}y${RESET} — 删除，零残留"
    echo -e "  ${YELLOW}n${RESET} — 保留，下次秒启动"
    echo -ne "请选择 [y/N]: "
    read -r choice
    case "${choice,,}" in
      y|yes) do_cleanup ;;
      *)     do_keep ;;
    esac
    ;;
esac

echo ""
echo -e "${BOLD}${GREEN}完成！${RESET}"
