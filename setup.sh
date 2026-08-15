#!/bin/bash

# ==========================================
# Akari's Dotfile Optimized Installer 🚀
# ==========================================
# v5.6: Sudo KeepAlive Decoupling & Deadlock Elimination
set -euo pipefail
START_TIME=$(date +%s)

# ==========================================
# ⚙️ User Feature Selection (大型服务开关)
# ==========================================
# 默认全选 (true)。若某台机器不需要某项服务，直接改为 false 即可跳过！
ENABLE_ZRAM=true             # ⚡ zram 内存压缩引擎 (0 磁盘磨损，杜绝 OOM)
ZRAM_SIZE="ram * 2"          # ⚡ zram 大小配置: 支持 "ram * 2", "ram * 0.5", "ram", "2048" 等
ZRAM_ALGORITHM="zstd"        # ⚡ 压缩算法: "zstd" (最高压缩比), "lzo-rle" (极低 CPU 占用)

ENABLE_NEOVIM=true           # Neovim (最新二进制 /usr/local/bin/nvim)
ENABLE_NVCHAD=true           # NvChad 开箱即用配置 (~/.config/nvim)
ENABLE_TMUX=true             # Tmux + 插件管理器 (TPM) + 状态恢复
ENABLE_ZSH=true              # Zsh + Oh My Zsh + Powerlevel10k + 5大插件
ENABLE_DOCKER=true           # Docker CE + CLI + Compose Plugin

# ==========================================
# 📦 APT 软件包管理列表 (可自由增删/注释)
# ==========================================
# 所有系统工具与扩展软件统一在此数组中管理：
APT_PACKAGES=(
    "htop"
    "btop"                   # 极简轻量、颜值与性能双登顶的 C++ 监控神器
    "ncdu"
    "p7zip-full"
    "python-is-python3"
    "systemd-zram-generator" # 官方 systemd 原生 zram 自动生成器
    "fastfetch"              # 若旧版 Ubuntu 无 fastfetch 会自动智能回退为 neofetch
    # "podman"
    # "ripgrep"
    # "fd-find"
)

# ==========================================
# Helper Functions
# ==========================================
log() {
    echo -e "\033[32m[$(date +%T)] $1\033[0m"
}

warn() {
    echo -e "\033[33m[WARN] $1\033[0m"
}

err() {
    echo -e "\033[31m[ERROR] $1\033[0m" >&2
}

# Timer wrapper
measure() {
    local NAME="$1"
    local START=$(date +%s)
    shift
    "$@"
    local END=$(date +%s)
    log "⏱️  [$NAME] took $((END - START))s"
}

# Store keepalive PID separately so it is NOT blocked in wait loops
SUDO_KEEPALIVE_PID=""

# Store worker task PIDs (Neovim, TPM, NvChad) to wait for them later & clean them up on interrupt
declare -a BG_PIDS=()

# Graceful cleanup on interrupt (Ctrl+C / SIGTERM)
cleanup() {
    echo ""
    warn "🛑 Interrupted by user! Terminating all background processes..."
    for pid in "${BG_PIDS[@]}"; do
        kill -9 "$pid" 2>/dev/null || true
    done
    if [ -n "$SUDO_KEEPALIVE_PID" ]; then
        kill -9 "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    exit 130
}
trap cleanup INT TERM

# Sudo check and background keepalive (using -n to avoid interactive password prompt)
if [ "$EUID" -ne 0 ]; then
    if sudo -n true 2>/dev/null; then
        # Keep-alive sudo in background while script runs (tracked in SUDO_KEEPALIVE_PID)
        ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null ) &
        SUDO_KEEPALIVE_PID=$!
    fi
else
    warn "Running as root is not recommended. Consider running as normal user with sudo."
fi

# ==========================================
# PHASE 1: Background Tasks (No Dependencies)
# ==========================================

# Detect architecture (Neovim v0.10+ uses new naming)
ARCH=$(uname -m)
case $ARCH in
    x86_64)  NVIM_ARCH="nvim-linux-x86_64" ;;
    aarch64) NVIM_ARCH="nvim-linux-arm64" ;;
    *)       err "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# JOB 1: Neovim Install (with fallback URL)
if [ "$ENABLE_NEOVIM" = "true" ]; then
    (
        START_NVIM=$(date +%s)
        log "☁️ [BG-1] Downloading Neovim ($NVIM_ARCH)..."
        
        # Primary: Latest release
        NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/${NVIM_ARCH}.tar.gz"
        
        if ! curl -fsSL "$NVIM_URL" -o /tmp/nvim.tar.gz 2>/dev/null; then
            # Fallback: Stable release (v0.10.4)
            warn "[BG-1] Latest failed, trying v0.10.4..."
            NVIM_URL="https://github.com/neovim/neovim/releases/download/v0.10.4/${NVIM_ARCH}.tar.gz"
            if ! curl -fsSL "$NVIM_URL" -o /tmp/nvim.tar.gz; then
                err "[BG-1] Neovim download failed completely."
                exit 1
            fi
        fi
        
        sudo rm -rf /opt/nvim /opt/nvim-linux64 /opt/${NVIM_ARCH}
        sudo tar -C /opt -xzf /tmp/nvim.tar.gz
        rm -f /tmp/nvim.tar.gz
        
        # Create symlink for PATH accessibility
        sudo ln -sf /opt/${NVIM_ARCH}/bin/nvim /usr/local/bin/nvim
        
        END_NVIM=$(date +%s)
        log "✅ [BG-1] Neovim installed in $((END_NVIM - START_NVIM))s"
    ) &
    BG_PIDS+=($!)
else
    log "⏭️ [BG-1] Neovim disabled in config (skipping)."
fi

# JOB 2: Tmux Plugin Manager (independent, doesn't need OMZ)
if [ "$ENABLE_TMUX" = "true" ]; then
    (
        START=$(date +%s)
        # Wait for git (max 60 seconds)
        WAIT_COUNT=0
        while ! command -v git &> /dev/null; do
            sleep 2
            ((WAIT_COUNT++)) || true
            if [ $WAIT_COUNT -gt 30 ]; then
                warn "[BG-2] Git not available after 60s, skipping TPM."
                exit 0
            fi
        done
        
        log "⚡ [BG-2] Cloning Tmux Plugin Manager..."
        mkdir -p ~/.tmux/plugins
        if [ ! -d ~/.tmux/plugins/tpm ]; then
            git clone --depth=1 https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm >/dev/null 2>&1 || true
        fi
        
        END=$(date +%s)
        log "✅ [BG-2] TPM installed in $((END - START))s"
    ) &
    BG_PIDS+=($!)
else
    log "⏭️ [BG-2] Tmux/TPM disabled in config (skipping)."
fi

# JOB 3: NvChad Configuration
if [ "$ENABLE_NVCHAD" = "true" ]; then
    (
        START=$(date +%s)
        
        # Wait for git (max 60 seconds)
        WAIT_COUNT=0
        while ! command -v git &> /dev/null; do
            sleep 2
            ((WAIT_COUNT++)) || true
            if [ $WAIT_COUNT -gt 30 ]; then exit 0; fi
        done

        # 100% Idempotent check: clone only if not already present
        if [ ! -d "$HOME/.config/nvim" ]; then
            log "🎨 [BG-3] Installing NvChad..."
            git clone https://github.com/NvChad/starter ~/.config/nvim >/dev/null 2>&1 || true
            END=$(date +%s)
            log "✅ [BG-3] NvChad installed in $((END - START))s"
        else
            log "🎨 [BG-3] NvChad already installed (skipping clone)."
        fi
    ) &
    BG_PIDS+=($!)
else
    log "⏭️ [BG-3] NvChad disabled in config (skipping)."
fi

# ==========================================
# PHASE 2: APT Operations (Main Thread)
# ==========================================
log "📦 [APT] Optimizing Sources & Installing Packages..."

# Quick fix for Github raw (safer grep)
if ! grep -q "raw.githubusercontent.com" /etc/hosts 2>/dev/null; then
    echo "185.199.108.133 raw.githubusercontent.com" | sudo tee -a /etc/hosts > /dev/null
fi

export DEBIAN_FRONTEND=noninteractive

# ⚡ Memory Shield: Configurable zram Memory Compression Engine
# Uses kernel-level compressed RAM device (Zstd / LZO-RLE) with 0 disk I/O & zero SSD wear
setup_zram() {
    if [ "$ENABLE_ZRAM" = "true" ]; then
        log "⚡ [MEM] Setting up zram (Size: ${ZRAM_SIZE}, Algo: ${ZRAM_ALGORITHM})..."
        
        # 1. Immediate kernel zram device activation (provides instant OOM shield for current script)
        if ! swapon --show | grep -q "/dev/zram0"; then
            sudo modprobe zram num_devices=1 2>/dev/null || true
            if [ -b /dev/zram0 ]; then
                # Set compression algorithm
                echo "$ZRAM_ALGORITHM" | sudo tee /sys/block/zram0/comp_algorithm 2>/dev/null || echo "lzo-rle" | sudo tee /sys/block/zram0/comp_algorithm 2>/dev/null || true
                
                # Calculate size in MB for instant kernel setup
                local MEM_TOTAL_MB
                MEM_TOTAL_MB=$(free -m | awk '/Mem:/ {print $2}')
                local ZRAM_CALC_MB=1024
                if [[ "$ZRAM_SIZE" == *"ram * 2"* ]]; then
                    ZRAM_CALC_MB=$((MEM_TOTAL_MB * 2))
                elif [[ "$ZRAM_SIZE" == *"ram * 0.5"* ]]; then
                    ZRAM_CALC_MB=$((MEM_TOTAL_MB / 2))
                elif [[ "$ZRAM_SIZE" == *"ram"* ]]; then
                    ZRAM_CALC_MB=$MEM_TOTAL_MB
                elif [[ "$ZRAM_SIZE" =~ ^[0-9]+$ ]]; then
                    ZRAM_CALC_MB="$ZRAM_SIZE"
                else
                    ZRAM_CALC_MB=$((MEM_TOTAL_MB * 2))
                fi
                
                sudo swapoff /dev/zram0 2>/dev/null || true
                echo "${ZRAM_CALC_MB}M" | sudo tee /sys/block/zram0/disksize >/dev/null 2>&1 || true
                sudo mkswap -L zram0 /dev/zram0 >/dev/null 2>&1
                sudo swapon -p 100 /dev/zram0 2>/dev/null || true
            fi
        fi

        # 2. Configure systemd-zram-generator for persistent systemd management across reboots
        sudo mkdir -p /etc/systemd
        cat << EOF | sudo tee /etc/systemd/zram-generator.conf >/dev/null
# Generated by Akari Dotfile Installer
[zram0]
zram-size = ${ZRAM_SIZE}
compression-algorithm = ${ZRAM_ALGORITHM}
swap-priority = 100
fs-type = swap
EOF
        log "✅ [MEM] zram active (${ZRAM_SIZE} compressed with ${ZRAM_ALGORITHM}, 0 disk I/O)!"
    else
        log "⏭️ [MEM] zram disabled in config (skipping)."
    fi
}
setup_zram

# Clean any broken/corrupted deb archives left by prior OOM kills
sudo rm -f /var/cache/apt/archives/partial/* /var/cache/apt/archives/docker-ce*.deb 2>/dev/null || true
sudo dpkg --configure -a 2>/dev/null || true

# Get Ubuntu codename (with fallback)
get_codename() {
    if command -v lsb_release &> /dev/null; then
        lsb_release -sc
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$VERSION_CODENAME"
    else
        echo "jammy"  # Default fallback
    fi
}

# Mirror Selection
select_fastest_mirror() {
    log "🏎️ [APT] Testing mirror speeds..."
    local CODENAME=$(get_codename)
    local TEMP_FILE=$(mktemp)
    
    # Mirrors to test
    local -a MIRROR_NAMES=("Aliyun" "Tsinghua" "Tencent" "Official")
    local -a MIRROR_URLS=(
        "http://mirrors.aliyun.com/ubuntu"
        "http://mirrors.tuna.tsinghua.edu.cn/ubuntu"
        "http://mirrors.cloud.tencent.com/ubuntu"
        "http://archive.ubuntu.com/ubuntu"
    )
    
    # 1. Dynamically extract original/factory cloud mirror from .bak first (prevents re-run overwrite)
    local ORIGINAL_MIRROR=""
    if [ -f /etc/apt/sources.list.d/ubuntu.sources.bak ]; then
        ORIGINAL_MIRROR=$(grep -E -o "https?://[a-zA-Z0-9.-]+/ubuntu" /etc/apt/sources.list.d/ubuntu.sources.bak 2>/dev/null | head -n 1 || true)
    elif [ -f /etc/apt/sources.list.bak ]; then
        ORIGINAL_MIRROR=$(grep -E -o "https?://[a-zA-Z0-9.-]+/ubuntu" /etc/apt/sources.list.bak 2>/dev/null | head -n 1 || true)
    elif [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
        ORIGINAL_MIRROR=$(grep -E -o "https?://[a-zA-Z0-9.-]+/ubuntu" /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null | head -n 1 || true)
    elif [ -f /etc/apt/sources.list ]; then
        ORIGINAL_MIRROR=$(grep -E -o "https?://[a-zA-Z0-9.-]+/ubuntu" /etc/apt/sources.list 2>/dev/null | head -n 1 || true)
    fi

    if [ -n "$ORIGINAL_MIRROR" ]; then
        local EXISTS=0
        for url in "${MIRROR_URLS[@]}"; do
            if [ "$url" = "$ORIGINAL_MIRROR" ]; then EXISTS=1; break; fi
        done
        if [ $EXISTS -eq 0 ]; then
            MIRROR_NAMES+=("Original/Cloud")
            MIRROR_URLS+=("$ORIGINAL_MIRROR")
        fi
    fi

    # 2. If on AWS (Lightsail/EC2), query 169.254.169.254 to auto-detect AWS Region mirror (5ms latency!)
    local AWS_REGION=""
    AWS_REGION=$(curl -4 -s -m 1 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
    if [ -n "$AWS_REGION" ]; then
        local AWS_MIRROR="http://${AWS_REGION}.ec2.archive.ubuntu.com/ubuntu"
        local AWS_EXISTS=0
        for url in "${MIRROR_URLS[@]}"; do
            if [ "$url" = "$AWS_MIRROR" ]; then AWS_EXISTS=1; break; fi
        done
        if [ $AWS_EXISTS -eq 0 ]; then
            MIRROR_NAMES+=("AWS-${AWS_REGION}")
            MIRROR_URLS+=("$AWS_MIRROR")
        fi
    fi
    
    for i in "${!MIRROR_NAMES[@]}"; do
        local NAME="${MIRROR_NAMES[$i]}"
        local URL="${MIRROR_URLS[$i]}"
        local TIME
        # Force IPv4 (-4) to eliminate dual-stack IPv6 DNS/handshake timeouts
        TIME=$(curl -4 -s -o /dev/null -w "%{time_total}" --connect-timeout 2 --max-time 3 "$URL/dists/$CODENAME/Release" 2>/dev/null) || TIME=""
        if [ -n "$TIME" ] && [ "$TIME" != "0.000000" ]; then
            echo "$TIME $URL" >> "$TEMP_FILE"
            log "   👉 $NAME: ${TIME}s"
        else
            log "   ❌ $NAME: Timeout/Failed"
        fi
    done
    
    local WINNER
    WINNER=$(sort -n "$TEMP_FILE" 2>/dev/null | head -n 1 | awk '{print $2}')
    rm -f "$TEMP_FILE"
    
    if [ -n "$WINNER" ]; then
        log "🏆 Applying fastest mirror: $WINNER"
        # Ubuntu 24.04+ (DEB822 format in ubuntu.sources)
        if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
            [ ! -f /etc/apt/sources.list.d/ubuntu.sources.bak ] && sudo cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak
            sudo sed -i -E "s|https?://[a-zA-Z0-9.-]+/ubuntu|$WINNER|g" /etc/apt/sources.list.d/ubuntu.sources
        fi
        # Legacy format (Ubuntu <= 22.04 in sources.list)
        if [ -f /etc/apt/sources.list ]; then
            [ ! -f /etc/apt/sources.list.bak ] && sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
            sudo sed -i -E "s|https?://[a-zA-Z0-9.-]+/ubuntu|$WINNER|g" /etc/apt/sources.list
        fi
    else
        warn "Mirror optimization failed, using default sources."
    fi
}

select_fastest_mirror

# Auto-repair any interrupted dpkg transactions (e.g. previous Ctrl+C)
sudo dpkg --configure -a 2>/dev/null || true

# Update and Upgrade
log "📦 [APT] Updating package lists..."
sudo apt-get update -qq

log "📦 [APT] Upgrading system..."
sudo apt-get upgrade -y -qq

# Server-side SSH keepalive (prevents remote terminal drops)
if [ -d /etc/ssh/sshd_config.d ]; then
    echo -e "ClientAliveInterval 30\nClientAliveCountMax 5" | sudo tee /etc/ssh/sshd_config.d/99-keepalive.conf >/dev/null 2>&1 || true
fi

# Assemble complete list of packages to install
INSTALL_PACKAGES=("curl" "git" "ca-certificates" "gnupg" "lsb-release")

if [ "$ENABLE_ZSH" = "true" ]; then
    INSTALL_PACKAGES+=("zsh")
fi

if [ "$ENABLE_TMUX" = "true" ]; then
    INSTALL_PACKAGES+=("tmux")
fi

# Add all user-defined APT packages with fastfetch auto-fallback
for pkg in "${APT_PACKAGES[@]}"; do
    if [ "$pkg" = "fastfetch" ]; then
        if ! apt-cache show fastfetch &>/dev/null; then
            pkg="neofetch"
        fi
    fi
    INSTALL_PACKAGES+=("$pkg")
done

log "📦 [APT] Installing packages: ${INSTALL_PACKAGES[*]}..."
sudo apt-get install -y -qq "${INSTALL_PACKAGES[@]}" >/dev/null

# Change shell (only if Zsh is enabled and not already default)
if [ "$ENABLE_ZSH" = "true" ]; then
    ZSH_PATH=$(which zsh)
    if [ "$SHELL" != "$ZSH_PATH" ]; then
        log "🐚 Changing default shell to zsh..."
        sudo chsh -s "$ZSH_PATH" "$USER"
    fi
fi

# ==========================================
# Docker Install (with proper modern method)
# ==========================================
if [ "$ENABLE_DOCKER" = "true" ]; then
    log "🐳 [APT] Installing Docker..."

    # Safely remove conflicting legacy packages
    for old_pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        sudo apt-get remove -y "$old_pkg" 2>/dev/null || true
    done

    # Setup keyrings directory
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo rm -f /etc/apt/keyrings/docker.asc

    # Download GPG key (Primary: official docker, Fallback: aliyun)
    if ! sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc 2>/dev/null; then
        sudo curl -fsSL http://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc 2>/dev/null || true
    fi
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add official docker repository
    CODENAME=$(get_codename)
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $CODENAME stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # If official repo fails to update, seamlessly fallback to Aliyun mirror
    if ! sudo apt-get update -qq 2>/dev/null; then
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] http://mirrors.aliyun.com/docker-ce/linux/ubuntu $CODENAME stable" | \
            sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -qq
    fi

    # Install Docker packages with auto-fallback
    if ! sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1; then
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    # Add current user to docker group (avoid needing sudo for docker)
    if ! groups "$USER" | grep -q docker; then
        sudo usermod -aG docker "$USER"
        log "👤 Added $USER to docker group (relogin required)"
    fi
else
    log "⏭️ [DOCKER] Docker disabled in config (skipping)."
fi

# ==========================================
# PHASE 3: Oh My Zsh (MUST complete before plugins)
# ==========================================
if [ "$ENABLE_ZSH" = "true" ]; then
    log "🐚 [ZSH] Installing Oh My Zsh..."
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        # Use RUNZSH=no to prevent it from starting zsh immediately
        export RUNZSH=no
        export CHSH=no
        if ! sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended; then
            err "Oh My Zsh installation failed!"
            exit 1
        fi
    fi

    # Verify OMZ installation
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        err "Oh My Zsh directory not found after installation!"
        exit 1
    fi
    log "✅ [ZSH] Oh My Zsh ready."

    # ==========================================
    # PHASE 4: Zsh Plugins (Parallel Cloning)
    # ==========================================
    log "⚡ [ZSH] Cloning plugins in parallel..."

    ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

    # Clone with error handling
    clone_plugin() {
        local URL="$1"
        local DEST="$2"
        local NAME=$(basename "$DEST")
        if [ ! -d "$DEST" ]; then
            if git clone --depth=1 "$URL" "$DEST" >/dev/null 2>&1; then
                log "   ✅ $NAME"
            else
                warn "   ❌ Failed to clone $NAME"
            fi
        else
            log "   ⏭️ $NAME (already exists)"
        fi
    }

    # Clone plugins in parallel for max performance
    PLUGIN_PIDS=()
    clone_plugin "https://github.com/romkatv/powerlevel10k.git" "$ZSH_CUSTOM/themes/powerlevel10k" &
    PLUGIN_PIDS+=($!)
    clone_plugin "https://github.com/zsh-users/zsh-autosuggestions" "$ZSH_CUSTOM/plugins/zsh-autosuggestions" &
    PLUGIN_PIDS+=($!)
    clone_plugin "https://github.com/zsh-users/zsh-syntax-highlighting.git" "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" &
    PLUGIN_PIDS+=($!)
    clone_plugin "https://github.com/zsh-users/zsh-completions" "$ZSH_CUSTOM/plugins/zsh-completions" &
    PLUGIN_PIDS+=($!)
    clone_plugin "https://github.com/wting/autojump.git" "$ZSH_CUSTOM/plugins/autojump" &
    PLUGIN_PIDS+=($!)

    for pid in "${PLUGIN_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Install autojump
    if [ -d "$ZSH_CUSTOM/plugins/autojump" ]; then
        log "   🔧 Installing autojump..."
        (
            cd "$ZSH_CUSTOM/plugins/autojump"
            python3 install.py >/dev/null 2>&1 || python install.py >/dev/null 2>&1 || true
        )
    fi

    log "✅ [ZSH] All plugins installed."
else
    log "⏭️ [ZSH] Zsh/Oh-My-Zsh disabled in config (skipping)."
fi

# ==========================================
# PHASE 5: Wait for Phase 1 background jobs
# ==========================================
log "⏳ Waiting for background tasks (Neovim, TPM)..."
for pid in "${BG_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

# ==========================================
# PHASE 6: Configuration Writing
# ==========================================
log "🔗 Writing configs..."

# Create .zshrc if ZSH is enabled
if [ "$ENABLE_ZSH" = "true" ]; then
    cat << 'EOF' > ~/.zshrc
# Enable Powerlevel10k instant prompt
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export ZSH="$HOME/.oh-my-zsh"
# Neovim is symlinked to /usr/local/bin, no need to modify PATH

ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(
    git
    sudo
    command-not-found
    colored-man-pages
    zsh-autosuggestions
    zsh-syntax-highlighting
    zsh-completions
    autojump
)

source $ZSH/oh-my-zsh.sh

# Powerlevel10k config
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# Autojump
[[ -s ~/.autojump/etc/profile.d/autojump.sh ]] && source ~/.autojump/etc/profile.d/autojump.sh
EOF
fi

# Create .tmux.conf if TMUX is enabled
if [ "$ENABLE_TMUX" = "true" ]; then
    cat << 'EOF' > ~/.tmux.conf
# Plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-resurrect'

# Settings
set -g default-terminal "screen-256color"
set -g default-shell /bin/zsh
set -g mouse on
set -g history-limit 50000

# Keybindings
unbind -n MouseDown3Pane
unbind C-b
set-option -g prefix C-a
bind-key C-a send-prefix

# Initialize TPM (keep this line at the very bottom)
run '~/.tmux/plugins/tpm/tpm'
EOF

    # Reload tmux if running
    if pgrep tmux >/dev/null; then
        tmux source ~/.tmux.conf 2>/dev/null || true
    fi
fi

# ==========================================
# Summary
# ==========================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
log "=========================================="
log "✨ Installation Complete!"
log "=========================================="
log "⏱️  Total time: ${DURATION}s"
log ""
log "📋 Service Deployment Summary:"
[ "$ENABLE_ZRAM" = "true" ]      && log "   • [ON]  zram Compression (${ZRAM_SIZE}, ${ZRAM_ALGORITHM})" || log "   • [OFF] zram"
[ "$ENABLE_ZSH" = "true" ]       && log "   • [ON]  Zsh + Oh My Zsh + Powerlevel10k" || log "   • [OFF] Zsh"
[ "$ENABLE_NEOVIM" = "true" ]    && log "   • [ON]  Neovim (latest)" || log "   • [OFF] Neovim"
[ "$ENABLE_NVCHAD" = "true" ]    && log "   • [ON]  NvChad Configuration" || log "   • [OFF] NvChad"
[ "$ENABLE_DOCKER" = "true" ]    && log "   • [ON]  Docker + Compose" || log "   • [OFF] Docker"
[ "$ENABLE_TMUX" = "true" ]      && log "   • [ON]  Tmux + TPM" || log "   • [OFF] Tmux"
if [ ${#APT_PACKAGES[@]} -gt 0 ]; then
    log "   • [APT] Installed Packages: ${APT_PACKAGES[*]}"
fi
log ""
log "⚠️  IMPORTANT: Please run these commands:"
log "   1. Log out and log back in (for group & shell refresh)"
[ "$ENABLE_ZSH" = "true" ] && log "   2. Run 'p10k configure' to setup your prompt theme"
log ""

# Cleanly terminate any remaining background keepalive loops
for pid in "${BG_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
done
if [ -n "$SUDO_KEEPALIVE_PID" ]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
fi

