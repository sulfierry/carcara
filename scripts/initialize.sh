#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  Carcará Platform — Environment Initialization              ║
# ║  Validates dependencies, scaffolds structure, and reports   ║
# ║  system capabilities for on-premise LLM deployment.         ║
# ╚══════════════════════════════════════════════════════════════╝

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

pass()  { echo -e "  ${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC}  $1"; WARNINGS=$((WARNINGS + 1)); }
fail()  { echo -e "  ${RED}[FAIL]${NC}  $1"; ERRORS=$((ERRORS + 1)); }
info()  { echo -e "  ${CYAN}[INFO]${NC}  $1"; }
header(){ echo -e "\n${BLUE}${BOLD}▸ $1${NC}"; }

echo -e "${BOLD}${BLUE}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║         Carcará — Platform Initialization           ║"
echo "║   On-premise, privacy-first LLM platform for HPC   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ─────────────────────────────────────────────────────────────
header "1/6 — Docker Engine"
# ─────────────────────────────────────────────────────────────

if ! command -v docker &> /dev/null; then
    fail "Docker is not installed or not in PATH."
    echo -e "       Docker is the ${BOLD}absolute minimum requirement${NC} for Carcará."
    echo "       Install: https://docs.docker.com/get-docker/"
    echo ""
    echo -e "${RED}Cannot continue without Docker. Exiting.${NC}"
    exit 1
else
    DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    pass "Docker Engine v${DOCKER_VERSION}"
fi

# Check Docker daemon is running
if ! docker info &> /dev/null; then
    fail "Docker daemon is not running."
    echo "       Start Docker Desktop or run: sudo systemctl start docker"
    exit 1
else
    pass "Docker daemon is responsive."
fi

# ─────────────────────────────────────────────────────────────
header "2/6 — Docker Compose"
# ─────────────────────────────────────────────────────────────

COMPOSE_CMD=""
if docker compose version &> /dev/null; then
    COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "v2+")
    pass "Docker Compose ${COMPOSE_VERSION} (plugin)"
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    COMPOSE_VERSION=$(docker-compose version --short 2>/dev/null || echo "v1")
    pass "docker-compose ${COMPOSE_VERSION} (standalone)"
    COMPOSE_CMD="docker-compose"
else
    fail "Docker Compose is not installed."
    echo "       Install: https://docs.docker.com/compose/install/"
    exit 1
fi

# ─────────────────────────────────────────────────────────────
header "3/6 — System Capabilities"
# ─────────────────────────────────────────────────────────────

# Architecture
ARCH=$(uname -m)
OS=$(uname -s)
info "System: ${OS} ${ARCH}"

# Memory
if [[ "$OS" == "Darwin" ]]; then
    TOTAL_MEM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
elif [[ "$OS" == "Linux" ]]; then
    TOTAL_MEM_GB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1048576 ))
else
    TOTAL_MEM_GB=0
fi

if [[ $TOTAL_MEM_GB -ge 16 ]]; then
    pass "RAM: ${TOTAL_MEM_GB}GB (≥16GB recommended)"
elif [[ $TOTAL_MEM_GB -ge 8 ]]; then
    warn "RAM: ${TOTAL_MEM_GB}GB (16GB+ recommended for full local stack)"
else
    warn "RAM: ${TOTAL_MEM_GB}GB (may be insufficient for dev stack)"
fi

# Disk space
if [[ "$OS" == "Darwin" ]]; then
    FREE_DISK_GB=$(df -g . | awk 'NR==2{print $4}')
elif [[ "$OS" == "Linux" ]]; then
    FREE_DISK_GB=$(df -BG . | awk 'NR==2{print $4}' | tr -d 'G')
else
    FREE_DISK_GB=0
fi

if [[ $FREE_DISK_GB -ge 50 ]]; then
    pass "Disk: ${FREE_DISK_GB}GB free (≥50GB recommended)"
elif [[ $FREE_DISK_GB -ge 20 ]]; then
    warn "Disk: ${FREE_DISK_GB}GB free (50GB+ recommended)"
else
    warn "Disk: ${FREE_DISK_GB}GB free (may run out during image pulls)"
fi

# GPU detection (informational)
if command -v nvidia-smi &> /dev/null; then
    GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
    GPU_NAME=$(nvidia-smi -L 2>/dev/null | head -1 | sed 's/GPU 0: //;s/ (.*//')
    pass "GPU: ${GPU_COUNT}x ${GPU_NAME}"
else
    info "No NVIDIA GPU detected (OK for Tier 1 local dev — uses Ollama CPU)"
fi

# ─────────────────────────────────────────────────────────────
header "4/6 — Optional Tools"
# ─────────────────────────────────────────────────────────────

# Python
if command -v python3 &> /dev/null; then
    PY_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
    pass "Python ${PY_VERSION}"
else
    info "python3 not found — Docker fallback available"
fi

# curl
if command -v curl &> /dev/null; then
    pass "curl installed"
else
    info "curl not found — use: docker run --rm curlimages/curl:latest <url>"
fi

# make
if command -v make &> /dev/null; then
    pass "make installed"
else
    info "make not found — run scripts directly from scripts/"
fi

# jq
if command -v jq &> /dev/null; then
    pass "jq installed"
else
    info "jq not found — use: echo '{}' | docker run --rm -i ghcr.io/jqlang/jq:latest '.'"
fi

# git
if command -v git &> /dev/null; then
    pass "git installed"
else
    warn "git not found — version control unavailable"
fi

# ─────────────────────────────────────────────────────────────
header "5/6 — Project Structure"
# ─────────────────────────────────────────────────────────────

DIRS=(
    "configs/envs"
    "configs/models"
    "configs/deployments"
    "configs/base/nginx"
    "configs/base/grafana/dashboards"
    "containers"
    "slurm"
    "scripts"
    "services"
    "tests"
    "docs"
    "logs"
    "data/backups"
)

for dir in "${DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        info "Created $dir/"
    fi
done
pass "All project directories verified."

# Environment file scaffolding
if [ ! -f "configs/envs/development.env" ]; then
    if [ -f "configs/envs/development.env.example" ]; then
        cp configs/envs/development.env.example configs/envs/development.env
        pass "Created development.env from example"
    else
        touch configs/envs/development.env
        warn "No development.env.example found — created empty development.env"
    fi
else
    pass "configs/envs/development.env exists"
fi

# ─────────────────────────────────────────────────────────────
header "6/6 — Python Virtual Environment"
# ─────────────────────────────────────────────────────────────

if command -v python3 &> /dev/null; then
    if [ ! -d ".venv" ]; then
        python3 -m venv .venv
        pass "Virtual environment created at .venv/"
    else
        pass "Virtual environment exists at .venv/"
    fi

    source .venv/bin/activate
    pip install --upgrade pip > /dev/null 2>&1
    if [ -f "requirements.txt" ]; then
        pip install -r requirements.txt > /dev/null 2>&1
        pass "Python requirements installed"
    fi
else
    info "Skipped — python3 not available (Docker fallback active)"
fi

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${NC}"
if [ $ERRORS -gt 0 ]; then
    echo -e "${RED}${BOLD}  ✗ Initialization failed with ${ERRORS} error(s).${NC}"
    exit 1
elif [ $WARNINGS -gt 0 ]; then
    echo -e "${YELLOW}${BOLD}  ⚠ Initialization complete with ${WARNINGS} warning(s).${NC}"
else
    echo -e "${GREEN}${BOLD}  ✓ Initialization complete — all checks passed.${NC}"
fi
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "Next steps:"
echo "  1. Review configs/envs/development.env"
echo "  2. Run the Phase 1 workflow: agents/workflows/phase1-foundation.md"
echo ""
