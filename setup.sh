#!/bin/bash

# ==========================================
# Akari's Dotfile Optimized Installer 🚀
# ==========================================
# v4: Neovim URL Fix + Per-Step Timing
set -euo pipefail
START_TIME=$(date +%s)

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

# Check if running as root (not recommended)
if [ "$EUID" -eq 0 ]; then
    warn "Running as root is not recommended. Consider running as normal user with sudo."
fi

# Store PIDs to wait for them later
declare -a BG_PIDS=()

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
(
    START_NVIM=$(date +%s)
    log "☁️ [BG-1] Downloading Neovim ($NVIM_ARCH)..."
    
    # Primary: Latest release
    NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/${NVIM_ARCH}.tar.gz"
    
    if ! curl -fsSL "$NVIM_URL" -o /tmp/nvim.tar.gz 2>/dev/null; then
        # Fallback: Known good version
        warn "[BG-1] Latest failed, trying v0.9.5..."
        NVIM_URL="https://github.com/neovim/neovim/releases/download/v0.9.5/${NVIM_ARCH}.tar.gz"
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

# JOB 2: Tmux Plugin Manager (independent, doesn't need OMZ)
(
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
    log "✅ [BG-2] TPM installed."
) &
BG_PIDS+=($!)

# ==========================================
# PHASE 2: APT Operations (Main Thread)
# ==========================================
log "📦 [APT] Optimizing Sources & Installing Packages..."

# Quick fix for Github raw (safer grep)
if ! grep -q "raw.githubusercontent.com" /etc/hosts 2>/dev/null; then
    echo "185.199.108.133 raw.githubusercontent.com" | sudo tee -a /etc/hosts > /dev/null
fi

export DEBIAN_FRONTEND=noninteractive

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
    
    for i in "${!MIRROR_NAMES[@]}"; do
        local NAME="${MIRROR_NAMES[$i]}"
        local URL="${MIRROR_URLS[$i]}"
        local TIME
        TIME=$(curl -s -o /dev/null -w "%{time_total}" --connect-timeout 2 --max-time 3 "$URL/dists/$CODENAME/Release" 2>/dev/null) || TIME=""
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
        [ ! -f /etc/apt/sources.list.bak ] && sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
        sudo sed -i "s|http://archive.ubuntu.com/ubuntu|$WINNER|g" /etc/apt/sources.list
        sudo sed -i "s|http://security.ubuntu.com/ubuntu|$WINNER|g" /etc/apt/sources.list
    else
        warn "Mirror optimization failed, using default sources."
    fi
}

select_fastest_mirror

# Update and Upgrade
log "📦 [APT] Updating package lists..."
sudo apt-get update -qq

log "📦 [APT] Upgrading system..."
sudo apt-get upgrade -y -qq

# Install core packages
log "📦 [APT] Installing utilities..."
sudo apt-get install -y -qq \
    zsh tmux htop glances btop curl python-is-python3 p7zip-full ncdu neofetch \
    git ca-certificates gnupg lsb-release >/dev/null

# Change shell (only if not already zsh)
ZSH_PATH=$(which zsh)
if [ "$SHELL" != "$ZSH_PATH" ]; then
    log "🐚 Changing default shell to zsh..."
    sudo chsh -s "$ZSH_PATH" "$USER"
fi

# ==========================================
# Docker Install (with proper modern method)
# ==========================================
log "🐳 [APT] Installing Docker..."

# Remove old versions if present
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Setup repository
sudo install -m 0755 -d /etc/apt/keyrings

# Download GPG key (proper method for newer apt)
DOCKER_GPG_URL="http://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg"
sudo curl -fsSL "$DOCKER_GPG_URL" -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add repository
CODENAME=$(get_codename)
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] http://mirrors.aliyun.com/docker-ce/linux/ubuntu $CODENAME stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -qq
sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null

# Add current user to docker group (avoid needing sudo for docker)
if ! groups "$USER" | grep -q docker; then
    sudo usermod -aG docker "$USER"
    log "👤 Added $USER to docker group (relogin required)"
fi

# ==========================================
# PHASE 3: Oh My Zsh (MUST complete before plugins)
# ==========================================
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
# PHASE 4: Zsh Plugins (AFTER OMZ is confirmed)
# ==========================================
log "⚡ [ZSH] Cloning plugins..."

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

# Clone plugins (sequential for better error visibility, still fast due to --depth=1)
clone_plugin "https://github.com/romkatv/powerlevel10k.git" "$ZSH_CUSTOM/themes/powerlevel10k"
clone_plugin "https://github.com/zsh-users/zsh-autosuggestions" "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
clone_plugin "https://github.com/zsh-users/zsh-syntax-highlighting.git" "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
clone_plugin "https://github.com/zsh-users/zsh-completions" "$ZSH_CUSTOM/plugins/zsh-completions"
clone_plugin "https://github.com/wting/autojump.git" "$ZSH_CUSTOM/plugins/autojump"

# Install autojump
if [ -d "$ZSH_CUSTOM/plugins/autojump" ]; then
    log "   🔧 Installing autojump..."
    (
        cd "$ZSH_CUSTOM/plugins/autojump"
        python3 install.py >/dev/null 2>&1 || python install.py >/dev/null 2>&1 || true
    )
fi

log "✅ [ZSH] All plugins installed."

# ==========================================
# PHASE 5: Wait for Phase 1 background jobs
# ==========================================
log "⏳ Waiting for background tasks (Neovim, TPM)..."
for pid in "${BG_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

# ==========================================
# PHASE 6: Configuration
# ==========================================
log "🔗 Writing configs..."

# Create .zshrc
cat << 'EOF' > ~/.zshrc
# Enable Powerlevel10k instant prompt
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export ZSH="$HOME/.oh-my-zsh"
export PATH="$PATH:/opt/nvim-linux64/bin"

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

# Tmux Conf
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
log "📋 What's installed:"
log "   • Zsh + Oh My Zsh + Powerlevel10k"
log "   • Neovim (latest)"
log "   • Docker + Compose"
log "   • Tmux + TPM"
log "   • Utilities: htop, btop, glances, ncdu, neofetch"
log ""
log "⚠️  IMPORTANT: Please run these commands:"
log "   1. Log out and log back in (for docker group & zsh)"
log "   2. Run 'p10k configure' to setup your prompt theme"
log ""
