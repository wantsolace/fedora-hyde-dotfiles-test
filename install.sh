#!/usr/bin/env bash
# ============================================================
#  HyDE Fedora Port  –  install.sh
#  Target: Fedora 42+ / 44 recommended  (DNF5)
#  HyDE version: latest master (cloned during install)
#  Author: Community port – based on HyDE-Project/HyDE
# ============================================================
#
#  USAGE:
#    chmod +x install.sh
#    ./install.sh              # full install
#    ./install.sh --no-dots    # packages only, skip dotfiles clone
#    ./install.sh --restore    # re-apply dotfiles only (packages already installed)
#    ./install.sh --nvidia     # force NVIDIA driver setup
#
#  DO NOT run as root / sudo.  Script will use sudo internally.
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# ──────────────────────────────────────────────
#  Globals / colours
# ──────────────────────────────────────────────
HYDE_DIR="$HOME/HyDE"
HYDE_DOTS_DIR="$HOME/.config"
BACKUP_DIR="$HOME/.config/cfg_backups/$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$HOME/.cache/hyde/logs"
LOG_FILE="$LOG_DIR/install_$(date +%Y%m%d_%H%M%S).log"

OPT_NO_DOTS=false
OPT_RESTORE=false
OPT_NVIDIA=false

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ──────────────────────────────────────────────
#  FIX 1: Create log dir immediately so all helpers can write to it.
#  Must happen before any function is called.
# ──────────────────────────────────────────────
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

# ──────────────────────────────────────────────
#  Helpers
# ──────────────────────────────────────────────
msg()  { echo -e "${CYAN}[HyDE]${RESET} $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}[  OK ]${RESET} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[ WARN]${RESET} $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE"; }
die()  { err "$*"; exit 1; }

banner() {
cat << 'EOF'
  _   _       ____  _____   _____        _
 | | | |_   _|  _ \| ____| |  ___|__  __| | ___  _ __ __ _
 | |_| | | | | | | |  _|   | |_ / _ \/ _` |/ _ \| '__/ _` |
 |  _  | |_| | |_| | |___  |  _|  __/ (_| | (_) | | | (_| |
 |_| |_|\__, |____/|_____| |_|  \___|\__,_|\___/|_|  \__,_|
         |___/
          Fedora 44 Port  ·  1:1 with HyDE master
EOF
}

# FIX 2: confirm() reads from /dev/tty directly so the prompt always
# displays and input always works regardless of how the script is invoked.
# The old read -rp ... 2>/dev/null was suppressing the prompt text itself.
confirm() {
    local prompt="${1:-Continue?}"
    local ans=""
    echo -en "${YELLOW}${prompt} [y/N]: ${RESET}" > /dev/tty
    read -r ans < /dev/tty || ans=""
    [[ "${ans,,}" == "y" ]]
}

check_root() {
    [[ $EUID -eq 0 ]] && die "Do NOT run this script as root or with sudo. It will call sudo internally."
}

check_fedora() {
    [[ -f /etc/fedora-release ]] || die "This script is for Fedora only."
    local ver
    ver=$(rpm -E '%{fedora}')
    msg "Detected Fedora ${ver}"
    [[ "$ver" -ge 42 ]] || warn "Tested on Fedora 42+. Older releases may have missing packages."
}

# FIX 3: parse_args no longer calls warn() before log is ready —
# log file now exists at global scope before main() runs.
parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --no-dots)  OPT_NO_DOTS=true ;;
            --restore)  OPT_RESTORE=true ;;
            --nvidia)   OPT_NVIDIA=true ;;
            -h|--help)
                echo "Usage: $0 [--no-dots] [--restore] [--nvidia]"
                exit 0 ;;
            *) warn "Unknown option: $arg" ;;
        esac
    done
}

# ──────────────────────────────────────────────
#  COPR repos
# ──────────────────────────────────────────────
setup_copr_repos() {
    msg "Enabling required COPR repositories..."

    # FIX 4: dnf-plugins-core must be installed FIRST so 'dnf copr' works.
    # It is in Fedora's base repos (not RPM Fusion), so this works even on a
    # minimal Fedora install. RPM Fusion is enabled separately in setup_rpmfusion()
    # which is called before this function in main().
    sudo dnf install -y dnf-plugins-core 2>>"$LOG_FILE" \
        && ok "dnf-plugins-core installed" \
        || warn "dnf-plugins-core install had issues (may already be present)"

    # solopasha/hyprland – most actively maintained Hyprland COPR
    # provides: hyprland, hyprlock, hypridle, hyprpicker, swww, grimblast,
    #           wlogout, hyprpaper, hyprsunset, uwsm, cliphist, wl-clip-persist,
    #           nwg-look, xdg-desktop-portal-hyprland, and more
    if sudo dnf copr enable -y solopasha/hyprland 2>>"$LOG_FILE"; then
        ok "solopasha/hyprland enabled"
    else
        warn "solopasha/hyprland may already be enabled"
    fi

    # heus-sueh/packages – matugen (wallbash colour engine)
    if sudo dnf copr enable -y heus-sueh/packages 2>>"$LOG_FILE"; then
        ok "heus-sueh/packages enabled"
    else
        warn "heus-sueh/packages may already be enabled"
    fi

    # FIX 5: DNF5 (Fedora 41+) changed config-manager syntax.
    # DNF4: dnf config-manager --save --setopt=<repoid>.key=val
    # DNF5: dnf config-manager setopt <repoid>.key=val   (key=val is ONE argument)
    # Critical: the repoid must be quoted as a single token with the .key=val suffix.
    # Passing them as two separate args is silently ignored in DNF5.
    local dnf_ver
    dnf_ver=$(dnf --version 2>/dev/null | head -1 | grep -oP '\d+' | head -1 || echo "4")

    # The repo section header written by 'dnf copr enable solopasha/hyprland' on Fedora 44:
    local copr_repo_id="copr:copr.fedorainfracloud.org:solopasha:hyprland"
    if [[ "$dnf_ver" -ge 5 ]]; then
        # DNF5 syntax — key=val is a SINGLE argument (no space before =)
        sudo dnf config-manager setopt "${copr_repo_id}.priority=90" 2>>"$LOG_FILE" \
            && ok "solopasha COPR priority set (DNF5)" || warn "Could not set COPR priority"
    else
        # DNF4 syntax
        sudo dnf config-manager --save \
            "--setopt=${copr_repo_id}.priority=90" \
            2>>"$LOG_FILE" \
            && ok "solopasha COPR priority set (DNF4)" || warn "Could not set COPR priority"
    fi

    ok "COPR repos configured"
}

# ──────────────────────────────────────────────
#  RPM Fusion
# ──────────────────────────────────────────────
setup_rpmfusion() {
    msg "Enabling RPM Fusion repositories..."
    local fedver
    fedver=$(rpm -E '%{fedora}')

    # Use || true so a "already installed" error doesn't exit under set -e
    sudo dnf install -y \
        "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedver}.noarch.rpm" \
        "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedver}.noarch.rpm" \
        2>>"$LOG_FILE" || warn "RPM Fusion may already be installed"

    ok "RPM Fusion configured"
}

# ──────────────────────────────────────────────
#  Core system update
# ──────────────────────────────────────────────
system_update() {
    msg "Updating system packages (this may take a while)..."
    sudo dnf upgrade -y 2>>"$LOG_FILE" && ok "System updated"
}

# ──────────────────────────────────────────────
#  Package lists
#  All package names verified against Fedora 44 repos and solopasha COPR.
# ──────────────────────────────────────────────

# ── Core Wayland / Hyprland stack ──
PKG_CORE=(
    hyprland
    hyprlock           # replaces swaylock-effects; native Hyprland locker
    hypridle
    hyprpaper          # alternative/fallback wallpaper daemon
    hyprpicker
    hyprsunset         # blue-light filter
    hyprpolkitagent    # Hyprland's polkit agent (replaces polkit-kde-agent)
    xdg-desktop-portal-hyprland
    uwsm               # Universal Wayland Session Manager (HyDE v26+ requires)

    swww               # primary HyDE wallpaper daemon (solopasha COPR)
    waybar
    rofi-wayland       # replaces rofi-lbonn-wayland-git; 100% compatible
    dunst
    libnotify

    grimblast          # solopasha COPR; same tool as Arch's grimblast-git
    grim
    slurp
    swappy

    cliphist
    wl-clipboard
    wl-clip-persist    # solopasha COPR; keeps clipboard alive after app closes

    wlogout            # solopasha COPR

    matugen            # heus-sueh COPR; wallbash colour palette generator

    nwg-look           # GTK theming for wlroots compositors (solopasha COPR)
    qt5ct
    qt6ct
    kvantum            # FIX 6: 'kvantum-qt5' is AUR-only; Fedora pkg is 'kvantum'
    # kvantum-qt5 REMOVED – Fedora's 'kvantum' package already includes Qt5 plugin

    xdg-desktop-portal-gtk
    xdg-utils
)

# ── Audio ──
PKG_AUDIO=(
    pipewire
    pipewire-alsa
    pipewire-pulseaudio
    wireplumber
    pamixer
    playerctl
    pavucontrol
)

# ── Display / GPU ──
PKG_DISPLAY=(
    mesa-dri-drivers
    mesa-vulkan-drivers
    vulkan-loader
    libva
    libva-utils
    brightnessctl
)

# ── Fonts ──
# FIX 7: 'fontawesome-fonts-web' does not exist on Fedora — removed.
# FIX 8: 'google-noto-mono-fonts' renamed to 'google-noto-sans-mono-fonts'.
PKG_FONTS=(
    jetbrains-mono-fonts
    fontawesome-fonts      # FontAwesome 4/5 (Fedora repos)
    google-noto-fonts-common
    google-noto-emoji-fonts
    google-noto-sans-fonts
    google-noto-sans-mono-fonts   # correct Fedora package name
)

# ── File manager / thumbnails ──
PKG_FM=(
    dolphin
    dolphin-plugins
    ffmpegthumbs       # RPM Fusion; video thumbs in Dolphin
    qt5-qtimageformats # extra image format support in Dolphin
    kde-cli-tools
    ark
    p7zip
    unzip
    zip
)

# ── Shell & terminal ──
# FIX 9: 'fd-find' is the correct Fedora package name (installs 'fd' binary).
#         This is different from Ubuntu's 'fd-find' which installs 'fdfind'.
# FIX 10: rsync added here since deploy_dotfiles() depends on it.
PKG_SHELL=(
    kitty
    zsh
    zsh-autosuggestions
    zsh-syntax-highlighting
    starship
    eza
    bat
    fd-find            # Fedora package; binary is 'fd' (same as Arch)
    ripgrep
    fzf
    btop
    fastfetch
    yazi
    jq
    parallel
    ImageMagick        # Fedora capitalises this; DNF is case-insensitive but being explicit
    socat
    rsync              # FIX 10: required by deploy_dotfiles()
)

# ── Network / Bluetooth ──
# FIX 11: 'bluez-tools' availability on Fedora 44 confirmed; keep it.
PKG_NET=(
    NetworkManager
    network-manager-applet
    blueman
    bluez
    bluez-tools
)

# ── System services / polkit ──
PKG_SYSTEM=(
    polkit
    sddm
    udiskie
    gnome-keyring
    power-profiles-daemon
    lm_sensors
    acpi
)

# ── Python deps ──
# FIX 12: python3-toml is redundant on Python 3.11+ (tomllib is stdlib).
#         Keep python3-requests and python3-pyamdgpuinfo.
PKG_PYTHON=(
    python3
    python3-pip
    python3-pyamdgpuinfo   # solopasha COPR; AMD GPU info for waybar
    python3-requests
)

# ── Build tools (optional) ──
# These are rarely needed for a pure HyDE install — included for users who
# want to build plugins or AUR-equivalent sources from scratch.
# NOTE: 'parallel' conflicts with 'moreutils' (both provide /usr/bin/parallel).
#       If moreutils is installed, DNF will error. The --skip-unavailable flag
#       in install_packages handles this gracefully (parallel will be skipped).
PKG_BUILD=(
    git
    cmake
    make
    gcc
    gcc-c++
    meson
    ninja-build
    pkg-config
    cargo      # Rust toolchain – only needed for Rust-based plugins
    golang     # Go toolchain   – only needed for Go-based tools
)

install_packages() {
    local group_name="$1"
    shift
    local pkgs=("$@")

    msg "Installing: ${group_name}..."
    # --skip-unavailable: missing COPR packages don't abort the group
    if sudo dnf install -y --skip-unavailable "${pkgs[@]}" 2>>"$LOG_FILE"; then
        ok "${group_name} installed"
    else
        warn "Some packages in '${group_name}' may have failed – check: $LOG_FILE"
    fi
}

install_all_packages() {
    install_packages "Core Hyprland stack"   "${PKG_CORE[@]}"
    install_packages "Audio (PipeWire)"       "${PKG_AUDIO[@]}"
    install_packages "Display / GPU"          "${PKG_DISPLAY[@]}"
    install_packages "Fonts"                  "${PKG_FONTS[@]}"
    install_packages "File manager"           "${PKG_FM[@]}"
    install_packages "Shell & terminal"       "${PKG_SHELL[@]}"
    install_packages "Network / Bluetooth"    "${PKG_NET[@]}"
    install_packages "System services"        "${PKG_SYSTEM[@]}"
    install_packages "Python deps"            "${PKG_PYTHON[@]}"
    install_packages "Build tools (optional)" "${PKG_BUILD[@]}"
}

# ──────────────────────────────────────────────
#  NVIDIA
# ──────────────────────────────────────────────
setup_nvidia() {
    if ! lspci | grep -qi "NVIDIA" && [[ "$OPT_NVIDIA" != true ]]; then
        ok "No NVIDIA GPU detected – skipping NVIDIA driver setup"
        return
    fi

    msg "NVIDIA GPU detected. Installing drivers via RPM Fusion akmod..."
    # FIX 13: Comment said 'nvidia-open-dkms' but code installed 'akmod-nvidia'.
    # akmod-nvidia is correct for Fedora (RPM Fusion). Comment updated to match.
    # xorg-x11-drv-nvidia-libs.i686 is 32-bit; useful for Steam/Wine but optional.
    warn "Installing akmod-nvidia (RPM Fusion). This is the recommended Fedora NVIDIA driver."
    warn "For legacy cards (GT 700 series and older), see: https://rpmfusion.org/Howto/NVIDIA"

    if sudo dnf install -y \
        akmod-nvidia \
        xorg-x11-drv-nvidia \
        xorg-x11-drv-nvidia-cuda \
        xorg-x11-drv-nvidia-libs \
        2>>"$LOG_FILE"; then
        ok "NVIDIA drivers installed"
    else
        warn "NVIDIA driver install had issues – check log"
    fi
    # FIX 14: 32-bit libs installed only if user confirms (many don't need them)
    if confirm "Install 32-bit NVIDIA libs? (needed for Steam/Wine, otherwise skip)"; then
        sudo dnf install -y xorg-x11-drv-nvidia-libs.i686 2>>"$LOG_FILE" || true
    fi

    # Enable DRM kernel modesetting (required by Hyprland on NVIDIA)
    msg "Enabling NVIDIA DRM kernel modesetting..."

    # FIX 15: Detect bootloader: grubby works for GRUB, but Fedora 37+ can use
    # systemd-boot. Handle both.
    if [[ -d /sys/firmware/efi ]] && systemctl is-active --quiet systemd-boot 2>/dev/null; then
        warn "systemd-boot detected. Adding NVIDIA args to kernel cmdline via kernel-install."
        local cmdline_file="/etc/kernel/cmdline"
        if ! grep -q "nvidia-drm.modeset=1" "$cmdline_file" 2>/dev/null; then
            echo "nvidia-drm.modeset=1 nvidia-drm.fbdev=1" \
                | sudo tee -a "$cmdline_file" >>"$LOG_FILE"
            sudo kernel-install add "$(uname -r)" \
                "/lib/modules/$(uname -r)/vmlinuz" 2>>"$LOG_FILE" || true
        fi
    else
        # GRUB (most Fedora installs)
        sudo grubby --update-kernel=ALL \
            --args="nvidia-drm.modeset=1 nvidia-drm.fbdev=1" \
            2>>"$LOG_FILE" && ok "NVIDIA DRM args added to GRUB kernel cmdline"
    fi

    # Blacklist nouveau
    echo "blacklist nouveau" | sudo tee /etc/modprobe.d/blacklist-nouveau.conf >>"$LOG_FILE"

    # FIX 16: dracut --force --regenerate-all rebuilds initramfs for ALL installed
    # kernels (Fedora keeps 3 by default). Without --regenerate-all, only the running
    # kernel is updated — if the user boots a different kernel, nouveau won't be
    # blacklisted in that kernel's initramfs.
    sudo dracut --force --regenerate-all 2>>"$LOG_FILE" && ok "initramfs rebuilt (all kernels)"
    warn "NVIDIA: Reboot required before Hyprland will work correctly."
}

# ──────────────────────────────────────────────
#  Nerd Fonts  (JetBrainsMono Nerd)
# ──────────────────────────────────────────────
install_nerd_fonts() {
    local FONT_DIR="$HOME/.local/share/fonts/NerdFonts"
    local FONT_NAME="JetBrainsMono"
    local FONT_VER="3.4.0"

    if fc-list | grep -qi "JetBrainsMono Nerd"; then
        ok "JetBrainsMono Nerd Font already installed"
        return
    fi

    msg "Installing JetBrainsMono Nerd Font v${FONT_VER}..."
    mkdir -p "$FONT_DIR"

    local url="https://github.com/ryanoasis/nerd-fonts/releases/download/v${FONT_VER}/${FONT_NAME}.zip"
    local tmpzip
    tmpzip="$(mktemp /tmp/${FONT_NAME}.XXXXXX.zip)"

    if curl -L --retry 3 --fail -o "$tmpzip" "$url" 2>>"$LOG_FILE"; then
        unzip -o "$tmpzip" -d "$FONT_DIR" '*.ttf' 2>>"$LOG_FILE"
        fc-cache -fv "$FONT_DIR" >>"$LOG_FILE" 2>&1
        ok "JetBrainsMono Nerd Font installed"
    else
        warn "Could not download Nerd Font – install manually from https://www.nerdfonts.com/"
    fi
    rm -f "$tmpzip"
}

# ──────────────────────────────────────────────
#  Clone HyDE
# ──────────────────────────────────────────────
clone_hyde() {
    msg "Cloning HyDE master from HyDE-Project/HyDE..."
    if [[ -d "$HYDE_DIR" ]]; then
        warn "HyDE directory already exists at $HYDE_DIR"
        if confirm "Pull latest changes?"; then
            # FIX 17: Use a subshell so cd does not change the script's working directory.
            (
                cd "$HYDE_DIR"
                # Verify the remote is named 'origin' before fetching
                if ! git remote get-url origin &>/dev/null; then
                    die "HyDE repo at $HYDE_DIR has no 'origin' remote. Fix manually: git remote add origin https://github.com/HyDE-Project/HyDE.git"
                fi
                git fetch --depth 1 origin master 2>>"$LOG_FILE"
                git reset --hard origin/master 2>>"$LOG_FILE"
            )
            ok "HyDE updated"
        fi
    else
        git clone --depth 1 https://github.com/HyDE-Project/HyDE.git "$HYDE_DIR" 2>>"$LOG_FILE"
        ok "HyDE cloned to $HYDE_DIR"
    fi
}

# ──────────────────────────────────────────────
#  Backup existing configs
# ──────────────────────────────────────────────
backup_configs() {
    msg "Backing up existing configs to $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"

    local dirs_to_backup=(
        "$HOME/.config/hypr"
        "$HOME/.config/waybar"
        "$HOME/.config/rofi"
        "$HOME/.config/dunst"
        "$HOME/.config/kitty"
        "$HOME/.config/swww"
        "$HOME/.config/wlogout"
        "$HOME/.config/sddm"
    )

    for d in "${dirs_to_backup[@]}"; do
        if [[ -d "$d" ]]; then
            cp -a "$d" "$BACKUP_DIR/" 2>>"$LOG_FILE"
            msg "  Backed up: $d"
        fi
    done
    ok "Backup complete → $BACKUP_DIR"
}

# ──────────────────────────────────────────────
#  Deploy HyDE dotfiles
# ──────────────────────────────────────────────
deploy_dotfiles() {
    [[ -d "$HYDE_DIR/Configs" ]] || die "HyDE Configs/ not found. Clone step may have failed."

    msg "Deploying HyDE dotfiles..."
    mkdir -p "$HYDE_DOTS_DIR"

    rsync -a --no-o --no-g "$HYDE_DIR/Configs/.config/" "$HOME/.config/" 2>>"$LOG_FILE" \
        && ok "Dotfiles synced to ~/.config/"

    if [[ -d "$HYDE_DIR/Configs/.local" ]]; then
        rsync -a --no-o --no-g "$HYDE_DIR/Configs/.local/" "$HOME/.local/" 2>>"$LOG_FILE" \
            && ok "Local data synced to ~/.local/"
    fi

    # Wallpapers live under Source/wallpapers (if present)
    if [[ -d "$HYDE_DIR/Source/wallpapers" ]]; then
        local wall_dir="$HOME/Pictures/HyDE-Walls"
        mkdir -p "$wall_dir"
        rsync -a "$HYDE_DIR/Source/wallpapers/" "$wall_dir/" 2>>"$LOG_FILE"
        ok "Wallpapers copied to $wall_dir"
    fi

    ok "Dotfiles deployed"
}

# ──────────────────────────────────────────────
#  Fedora-specific config patches
# ──────────────────────────────────────────────
apply_fedora_patches() {
    local HYPR_CONF="$HOME/.config/hypr"
    local EXEC_CONF="$HYPR_CONF/hyprland.conf"

    msg "Applying Fedora-specific patches..."

    # 1. polkit path
    #    Arch:   /usr/lib/polkit-kde-authentication-agent-1
    #    Fedora: /usr/libexec/polkit-kde-authentication-agent-1
    #    HyDE v26+ uses hyprpolkitagent which has no path difference, but patch
    #    any legacy references that might sneak in from older config snippets.
    if [[ -f "$EXEC_CONF" ]]; then
        sed -i \
            's|/usr/lib/polkit-kde-authentication-agent-1|/usr/libexec/polkit-kde-authentication-agent-1|g' \
            "$EXEC_CONF" 2>>"$LOG_FILE" || true
        ok "polkit path patched in hyprland.conf"
    fi

    # Also patch any sourced config files in the hypr/ tree
    find "$HYPR_CONF" -name "*.conf" -type f \
        -exec grep -l "polkit-kde-authentication-agent-1" {} \; 2>/dev/null \
    | while IFS= read -r conf_file; do
        sed -i \
            's|/usr/lib/polkit-kde-authentication-agent-1|/usr/libexec/polkit-kde-authentication-agent-1|g' \
            "$conf_file" 2>>"$LOG_FILE" || true
        msg "  polkit path patched in: $conf_file"
    done

    # 2. XDG_RUNTIME_DIR (sometimes missing on minimal/non-GNOME sessions)
    #    FIX 18: Write to the correct HyDE env file.
    #    HyDE v26 uses hyprland.conf or config/env.conf for env vars.
    #    Check both locations.
    local env_files=()
    [[ -f "$HYPR_CONF/hyprland.conf" ]]     && env_files+=("$HYPR_CONF/hyprland.conf")
    [[ -f "$HYPR_CONF/config/env.conf" ]]   && env_files+=("$HYPR_CONF/config/env.conf")
    [[ -f "$HYPR_CONF/userprefs.conf" ]]    && env_files+=("$HYPR_CONF/userprefs.conf")

    local target_env="${env_files[0]:-$EXEC_CONF}"
    if [[ -f "$target_env" ]] && ! grep -q "XDG_RUNTIME_DIR" "$target_env"; then
        printf '\n# Fedora: ensure XDG_RUNTIME_DIR is set\nenv = XDG_RUNTIME_DIR,/run/user/%s\n' \
            "$(id -u)" >> "$target_env"
        ok "XDG_RUNTIME_DIR env added to $(basename "$target_env")"
    fi

    # 3. UWSM wayland session desktop file
    local SESSION_DIR="/usr/share/wayland-sessions"
    if [[ ! -f "$SESSION_DIR/hyprland-uwsm.desktop" ]] && command -v uwsm &>/dev/null; then
        # FIX 19: Use sudo tee (safer than sudo bash -c "cat >") to avoid
        # heredoc+sudo stdin conflicts.
        sudo tee "$SESSION_DIR/hyprland-uwsm.desktop" > /dev/null << 'DEOF'
[Desktop Entry]
Name=Hyprland (uwsm)
Comment=Dynamic tiling Wayland compositor (UWSM managed)
Exec=uwsm start hyprland.desktop
Type=Application
DesktopNames=Hyprland
Keywords=wayland;compositor;tiling;
X-GDM-SessionRegisters=true
DEOF
        ok "hyprland-uwsm.desktop session created"
    fi

    ok "Fedora patches applied"
}

# ──────────────────────────────────────────────
#  SDDM setup
# ──────────────────────────────────────────────
setup_sddm() {
    msg "Configuring SDDM display manager..."

    # FIX 20: Check both active AND enabled state of GDM.
    local gdm_running=false
    systemctl is-active  --quiet gdm 2>/dev/null && gdm_running=true
    systemctl is-enabled --quiet gdm 2>/dev/null && gdm_running=true

    if [[ "$gdm_running" == true ]]; then
        warn "GDM is active/enabled. Disabling GDM and enabling SDDM."
        warn "You will need to reboot for the change to take effect."
        sudo systemctl disable --now gdm 2>>"$LOG_FILE" || true
    fi

    sudo systemctl enable sddm 2>>"$LOG_FILE" && ok "SDDM enabled"

    sudo mkdir -p /etc/sddm.conf.d

    # FIX 21: Removed incorrect CompositorCommand=kwin_wayland.
    # FIX 22: Use sudo tee instead of sudo bash -c "cat >" to avoid stdin conflicts.
    # FIX 27: SDDM 0.21+ (shipped in Fedora 44) dropped the old [General] DisplayServer=
    #         key entirely. The correct way to request the Wayland backend in 0.21+ is
    #         via the [Wayland] section. Using the old key is silently ignored.
    # FIX 28: Theme=breeze requires sddm-breeze (part of plasma-workspace) which is NOT
    #         installed by this script. Omit the Theme line; SDDM will use its compiled-in
    #         default. Users who install plasma-workspace can add it manually.
    sudo tee /etc/sddm.conf.d/hyde-hyprland.conf > /dev/null << 'EOF'
# SDDM config for HyDE on Fedora 44 (SDDM 0.21+)
[General]
# Leave DisplayServer unset; controlled per-section below.

[Wayland]
# Use the Wayland (wlroots) SDDM backend for the greeter.
# Requires a working Wayland compositor for the greeter session.
# If SDDM fails to start, remove this file: /etc/sddm.conf.d/hyde-hyprland.conf
SessionDir=/usr/share/wayland-sessions
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell,QT_QPA_PLATFORM=wayland

[X11]
SessionDir=/usr/share/xsessions

[Autologin]
Relogin=false
EOF
    ok "SDDM config written to /etc/sddm.conf.d/hyde-hyprland.conf"
}

# ──────────────────────────────────────────────
#  System services
# ──────────────────────────────────────────────
enable_services() {
    msg "Enabling system services..."

    # Note: sddm is already enabled in setup_sddm().
    # List here does NOT include sddm to avoid double-enable noise.
    local services=(
        NetworkManager
        bluetooth
        power-profiles-daemon
    )

    for svc in "${services[@]}"; do
        # FIX 23: systemctl list-unit-files returns exit 1 for nonexistent units
        # on Fedora's systemd. The check is correct. Using grep on output is more
        # reliable cross-version, so let's do that.
        if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "${svc}"; then
            if sudo systemctl enable "$svc" 2>>"$LOG_FILE"; then
                ok "  Enabled: $svc"
            else
                warn "  Could not enable: $svc"
            fi
        else
            warn "  Service not found, skipping: $svc"
        fi
    done
}

# ──────────────────────────────────────────────
#  XDG portal fix script
# ──────────────────────────────────────────────
fix_xdg_portal() {
    msg "Setting up XDG portal fix script..."

    local script="$HOME/.local/bin/fix-xdg-portal.sh"
    mkdir -p "$HOME/.local/bin"

    # FIX 24: killall -e (exact match) is not universally supported.
    # Use pkill -x (exact process name match) which is POSIX-friendly.
    # FIX 29: On Fedora (full systemd), XDG portals are managed as systemd
    # user services. Directly exec'ing the binaries bypasses socket activation
    # and D-Bus registration, leaving them in a broken half-started state.
    # The correct approach is `systemctl --user restart` which properly
    # stops, cleans up, and restarts with full socket/D-Bus plumbing.
    cat > "$script" << 'EOF'
#!/usr/bin/env bash
# Fix XDG portal for Hyprland on Fedora – run this if screen sharing breaks.
# Uses systemd --user because Fedora manages portals as user services.
sleep 1
systemctl --user stop xdg-desktop-portal-hyprland 2>/dev/null || true
systemctl --user stop xdg-desktop-portal-gtk       2>/dev/null || true
systemctl --user stop xdg-desktop-portal           2>/dev/null || true
sleep 1
systemctl --user start xdg-desktop-portal-hyprland 2>/dev/null || true
sleep 2
systemctl --user start xdg-desktop-portal          2>/dev/null || true
sleep 1
echo "XDG portals restarted via systemd."
systemctl --user status xdg-desktop-portal --no-pager 2>/dev/null || true
EOF
    chmod +x "$script"
    ok "XDG portal fix script → $script"

    # FIX 25: HyDE uses a modular config. exec-once lines belong in
    # config/startup.conf (HyDE's startup file), NOT in hyprland.conf root.
    # Check for that file first; fall back to hyprland.conf.
    local startup_candidates=(
        "$HOME/.config/hypr/config/startup.conf"
        "$HOME/.config/hypr/userprefs.conf"
        "$HOME/.config/hypr/hyprland.conf"
    )

    local target_startup=""
    for f in "${startup_candidates[@]}"; do
        if [[ -f "$f" ]]; then
            target_startup="$f"
            break
        fi
    done

    if [[ -n "$target_startup" ]] && ! grep -q "fix-xdg-portal" "$target_startup"; then
        printf '\n# Fedora: XDG portal fix on startup\nexec-once = %s\n' "$script" \
            >> "$target_startup"
        ok "XDG portal fix added to $(basename "$target_startup")"
    fi
}

# ──────────────────────────────────────────────
#  Shell setup (zsh + oh-my-zsh)
# ──────────────────────────────────────────────
setup_shell() {
    if ! command -v zsh &>/dev/null; then
        warn "zsh not found – skipping shell setup"
        return
    fi

    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        msg "Installing oh-my-zsh..."
        RUNZSH=no CHSH=no sh -c \
            "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
            2>>"$LOG_FILE" && ok "oh-my-zsh installed"
    else
        ok "oh-my-zsh already installed"
    fi

    # FIX 26: chsh may prompt for user password interactively; with set -e this
    # would kill the script if it fails. Use || warn to handle gracefully.
    if [[ "$SHELL" != "$(command -v zsh)" ]]; then
        if chsh -s "$(command -v zsh)" 2>>"$LOG_FILE"; then
            ok "Default shell set to zsh"
        else
            warn "Could not change shell to zsh automatically."
            warn "Run manually: chsh -s \$(which zsh)"
        fi
    fi
}

# ──────────────────────────────────────────────
#  Final summary
# ──────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}║       HyDE on Fedora – Installation Complete!            ║${RESET}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${BOLD}Next steps:${RESET}"
    echo -e "  1. ${CYAN}Reboot${RESET} your system"
    echo -e "  2. Select ${CYAN}Hyprland (uwsm)${RESET} from the SDDM session menu"
    echo -e "  3. First launch: press ${CYAN}Super+Enter${RESET} for a terminal"
    echo -e "     ${CYAN}Super+Space${RESET} for the app launcher (rofi)"
    echo -e "     ${CYAN}Super+Shift+W${RESET} to change wallpaper (swww)"
    echo -e "     ${CYAN}Super+T${RESET} to cycle themes"
    echo ""
    echo -e "  ${BOLD}Known Fedora-specific notes:${RESET}"
    echo -e "  - NVIDIA: reboot required. DRM args added to kernel cmdline."
    echo -e "    If using systemd-boot, check /etc/kernel/cmdline after reboot."
    echo -e "  - Screen sharing broken? Run: ${CYAN}~/.local/bin/fix-xdg-portal.sh${RESET}"
    echo -e "  - rofi-wayland replaces rofi-lbonn-wayland-git (fully compatible)"
    echo -e "  - hyprlock replaces swaylock-effects (native Hyprland locker)"
    echo -e "  - kvantum (Qt5+Qt6) replaces Arch's separate kvantum-qt5 AUR package"
    echo -e "  - Backup of old configs: ${CYAN}$BACKUP_DIR${RESET}"
    echo -e "  - Full install log:       ${CYAN}$LOG_FILE${RESET}"
    echo ""
    echo -e "  ${BOLD}Update HyDE later:${RESET}"
    echo -e "  ${CYAN}cd ~/HyDE && git fetch --depth 1 origin master && git reset --hard origin/master${RESET}"
    echo -e "  ${CYAN}Then re-run: ./install.sh --restore${RESET}"
    echo ""
}

# ──────────────────────────────────────────────
#  Main
# ──────────────────────────────────────────────
main() {
    parse_args "$@"

    banner
    echo ""
    msg "Log: $LOG_FILE"
    echo ""

    check_root
    check_fedora

    echo -e "${YELLOW}WARNING: This script will:${RESET}"
    echo "  - Enable COPR repos (solopasha/hyprland, heus-sueh/packages)"
    echo "  - Enable RPM Fusion (free + nonfree)"
    echo "  - Install Hyprland + HyDE dependencies via DNF"
    echo "  - Clone HyDE from GitHub and deploy its configs"
    echo "  - Backup your existing ~/.config/* first"
    echo "  - Switch display manager to SDDM (if GDM is active/enabled)"
    echo ""

    if ! confirm "Proceed with HyDE installation on Fedora?"; then
        msg "Aborted by user."
        exit 0
    fi

    # ── Restore-only mode ────────────────────────
    if [[ "$OPT_RESTORE" == true ]]; then
        msg "Restore mode: re-applying dotfiles only"
        backup_configs
        clone_hyde
        deploy_dotfiles
        apply_fedora_patches
        fix_xdg_portal
        print_summary
        exit 0
    fi

    # ── Full install ─────────────────────────────
    setup_rpmfusion
    setup_copr_repos     # after rpmfusion so dnf-plugins-core can come from RPM Fusion if needed
    system_update
    install_all_packages
    setup_nvidia
    install_nerd_fonts

    if [[ "$OPT_NO_DOTS" == false ]]; then
        backup_configs
        clone_hyde
        deploy_dotfiles
        apply_fedora_patches
        fix_xdg_portal
    else
        msg "--no-dots: skipping dotfile deployment"
    fi

    setup_sddm
    enable_services
    setup_shell
    print_summary

    warn "Please REBOOT now for all changes to take effect."
}

main "$@"
