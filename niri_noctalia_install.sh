#!/usr/bin/env bash
#
# Fedora Niri + Noctalia installer
#
# Merged from niri_noctalia_install.sh and niri_noctalia_install2.sh,
# using niri_noctalia_install2.sh as the base and preserving the comments
# from both scripts.
#
# Intended for:
#   A fresh minimal Fedora installation (Fedora Everything ISO), or an
#   existing minimal Fedora 44+ system (no desktop environment preinstalled).
#
# Target:
#   Fedora 44+ (niri 25.11+, Noctalia v5)
#
# Installs:
#   Niri
#   Noctalia v5 (from the official Fedora 44+ repositories)
#   XWayland Satellite + XWayland
#   XDG Desktop Portals
#   PipeWire / WirePlumber
#   NetworkManager (including Wi-Fi)
#   Bluetooth
#   Brightness control
#   Screen locking
#   Media controls
#
# Applications / utilities:
#   Firefox
#   Nautilus (GNOME Files) with File Roller (archive support)
#   Alacritty, Kitty and Foot terminals
#   Mousepad, Evince, Loupe, VLC
#   Git, curl, wget, OpenSSH
#   micro, ripgrep, fd, fzf, zoxide, jq, tree
#   zip / unzip / 7zip
#   pavucontrol, btop, fastfetch
#
# Optional components (enabled through environment variables):
#   Nerd Fonts (che/nerd-fonts COPR)
#   Steam (RPM Fusion)
#
# The script:
#   - is intended to be run as a normal user
#   - uses sudo when root privileges are needed
#   - backs up an existing Niri config
#   - does not overwrite your monitor configuration
#   - creates your screenshot directory
#   - enables NetworkManager, Bluetooth, seatd and the chosen display manager
#   - only writes Noctalia blur rules if your niri supports them (>= 26.04)
#   - validates the Niri configuration before finishing
#
# Usage:
#   chmod +x niri_noctalia_install2.sh
#   ./niri_noctalia_install2.sh
#
# Options (environment variables):
#
#   DISPLAY_MANAGER=gdm|sddm|greetd   Display manager to install and enable.
#                                    Default is gdm. Example:
#
#                                    DISPLAY_MANAGER=sddm ./niri_noctalia_install2.sh
#
#   INSTALL_NERD_FONTS=1              Enable che/nerd-fonts COPR and install nerd-fonts
#   INSTALL_STEAM=1                   Enable RPM Fusion and install steam
#
# Example:
#   DISPLAY_MANAGER=greetd INSTALL_NERD_FONTS=1 ./niri_noctalia_install2.sh
#
# After installation:
#   reboot
#
# Then select "Niri" from the display manager session selector
# (with greetd, niri-session is started directly instead).

set -Eeuo pipefail

# ============================================================
# Configuration
# ============================================================

DISPLAY_MANAGER="${DISPLAY_MANAGER:-gdm}"
INSTALL_NERD_FONTS="${INSTALL_NERD_FONTS:-0}"
INSTALL_STEAM="${INSTALL_STEAM:-0}"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"

NIRI_DIR="$CONFIG_DIR/niri"
NIRI_CONFIG="$NIRI_DIR/config.kdl"

ENV_DIR="$CONFIG_DIR/environment.d"
ENV_FILE="$ENV_DIR/10-niri.conf"

FONT_NAME="JetBrains Mono"

# ============================================================
# Helpers
# ============================================================

info() {
    printf '\n==> %s\n' "$*"
}

warn() {
    printf '\nWARNING: %s\n' "$*" >&2
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

sudo_cmd() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

backup() {
    local file="$1"

    [[ -e "$file" ]] || return 0

    local timestamp
    timestamp="$(date '+%Y%m%d-%H%M%S')"

    cp -a "$file" "${file}.backup-${timestamp}"

    info "Backup created:"
    printf '    %s\n' "${file}.backup-${timestamp}"
}

# Noctalia publishes blur regions via niri's background-effect support,
# which was introduced in niri 26.04. Older niri rejects those layer-rules
# during validation, so they are only written when supported.
niri_blur_supported() {
    NIRI_VERSION="$(niri --version 2>/dev/null | awk '{print $2}')" || return 1
    [[ "${NIRI_VERSION:-}" =~ ^([0-9]+)\.([0-9]+) ]] || return 1

    local major=$((10#${BASH_REMATCH[1]}))
    local minor=$((10#${BASH_REMATCH[2]}))

    (( major > 26 )) && return 0
    (( major == 26 && minor >= 4 ))
}

# Print the failing command and line number before set -e exits.
trap 'rc=$?; printf "\nERROR: command failed (exit %s) near line %s: %s\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ============================================================
# Safety checks
# ============================================================

if [[ $EUID -eq 0 ]]; then
    die "Run this script as your normal user, not with sudo."
fi

[[ -n "${HOME:-}" ]] ||
    die "HOME is not set."

[[ -r /etc/os-release ]] ||
    die "/etc/os-release is missing."

# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == "fedora" ]] ||
    die "This script is specifically for Fedora."

FEDORA_VERSION="${VERSION_ID:-}"

[[ "$FEDORA_VERSION" =~ ^[0-9]+$ ]] ||
    die "Could not determine the Fedora version (VERSION_ID='${VERSION_ID:-}')."

have sudo ||
    die "sudo is required."

have dnf ||
    die "dnf is required."

# ============================================================
# Fedora version check
# ============================================================

if (( FEDORA_VERSION < 44 )); then
    warn "This setup targets Fedora 44 and newer."
    warn "Detected Fedora ${FEDORA_VERSION}."
    exit 1
fi

case "$DISPLAY_MANAGER" in
    gdm|sddm|greetd) ;;
    *)
        die "DISPLAY_MANAGER must be 'gdm', 'sddm' or 'greetd' (got '${DISPLAY_MANAGER}')."
        ;;
esac

info "Fedora ${FEDORA_VERSION} detected."
info "Display manager: ${DISPLAY_MANAGER}."
[[ "$INSTALL_NERD_FONTS" == "1" ]] && info "Nerd Fonts: enabled"
[[ "$INSTALL_STEAM" == "1" ]] && info "Steam: enabled"

# ============================================================
# sudo authentication
# ============================================================

info "Checking sudo access..."

sudo -v

# Keep sudo authentication alive while the script runs.
(
    while true; do
        sudo -n true
        sleep 50
        kill -0 "$$" 2>/dev/null || exit
    done
) 2>/dev/null &

SUDO_KEEPALIVE_PID=$!

cleanup() {
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
}

trap cleanup EXIT

# ============================================================
# Optional repositories
# ============================================================

if [[ "$INSTALL_STEAM" == "1" ]]; then
    info "Enabling RPM Fusion (free + nonfree)..."
    sudo_cmd dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
        || warn "RPM Fusion install failed; continuing."
fi

if [[ "$INSTALL_NERD_FONTS" == "1" ]]; then
    info "Enabling che/nerd-fonts COPR..."
    sudo_cmd dnf copr enable che/nerd-fonts -y || warn "Failed to enable nerd-fonts COPR."
fi

# ============================================================
# Update Fedora
# ============================================================

info "Updating Fedora..."

sudo_cmd dnf upgrade --refresh -y

# ============================================================
# Core desktop
# ============================================================

CORE_PKGS=(
    niri
    noctalia
    xwayland-satellite
    xorg-x11-server-Xwayland
    xdg-desktop-portal
    xdg-desktop-portal-gtk
    xdg-desktop-portal-gnome
    pipewire
    pipewire-pulseaudio
    pipewire-alsa
    wireplumber
    playerctl
    NetworkManager
    NetworkManager-wifi
    nm-connection-editor
    bluez
    bluez-tools
    brightnessctl
    upower
    power-profiles-daemon
    polkit
    swaylock
    wl-clipboard
    cliphist
    gvfs
    tumbler
    xdg-user-dirs
    adwaita-icon-theme
    abattis-cantarell-fonts
    dejavu-sans-fonts
    jetbrains-mono-fonts
    mesa-dri-drivers
    mesa-vulkan-drivers
    seatd
)

# Display-manager-specific package.
case "$DISPLAY_MANAGER" in
    gdm|sddm) CORE_PKGS+=("$DISPLAY_MANAGER") ;;
    greetd)   CORE_PKGS+=(greetd) ;;
esac

info "Installing Niri + Noctalia desktop..."

sudo_cmd dnf install -y "${CORE_PKGS[@]}"

# ============================================================
# Personal workstation software
# ============================================================

WORK_PKGS=(
    git
    curl
    wget
    openssh-clients
    micro
    ripgrep
    fd-find
    fzf
    zoxide
    jq
    tree
    zip
    unzip
    7zip
    firefox
    nautilus
    file-roller
    alacritty
    kitty
    foot
    mousepad
    evince
    loupe
    vlc
    pavucontrol
    btop
    fastfetch
)

# Nautilus is the file manager used by the Niri keybindings, so Thunar and
# its archive plugin are intentionally not installed.

[[ "$INSTALL_STEAM" == "1" ]] && WORK_PKGS+=(steam)
[[ "$INSTALL_NERD_FONTS" == "1" ]] && WORK_PKGS+=(nerd-fonts)

info "Installing workstation software..."

sudo_cmd dnf install -y "${WORK_PKGS[@]}"

# ============================================================
# Font configuration
# ============================================================

info "Configuring preferred font (JetBrains Mono)..."

mkdir -p "$CONFIG_DIR/fontconfig"
cat > "$CONFIG_DIR/fontconfig/fonts.conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>sans-serif</family>
    <prefer><family>${FONT_NAME}</family></prefer>
  </alias>
  <alias>
    <family>serif</family>
    <prefer><family>${FONT_NAME}</family></prefer>
  </alias>
  <alias>
    <family>monospace</family>
    <prefer><family>${FONT_NAME}</family></prefer>
  </alias>
</fontconfig>
EOF

mkdir -p "$CONFIG_DIR/alacritty"
cat > "$CONFIG_DIR/alacritty/alacritty.toml" <<EOF
[font]
size = 11.0

[font.normal]
family = "${FONT_NAME}"
style = "Regular"

[font.bold]
family = "${FONT_NAME}"
style = "Bold"

[font.italic]
family = "${FONT_NAME}"
style = "Italic"

[font.bold_italic]
family = "${FONT_NAME}"
style = "Bold Italic"
EOF

mkdir -p "$CONFIG_DIR/kitty"
cat > "$CONFIG_DIR/kitty/kitty.conf" <<EOF
font_family ${FONT_NAME}
font_size 11.0
EOF

mkdir -p "$CONFIG_DIR/foot"
cat > "$CONFIG_DIR/foot/foot.ini" <<EOF
[main]
font=${FONT_NAME}:size=11
EOF

fc-cache -f >/dev/null
info "Font configuration applied."

# ============================================================
# XDG directories
# ============================================================

info "Creating XDG user directories..."

xdg-user-dirs-update

mkdir -p "$HOME/Pictures/Screenshots"

# ============================================================
# Wayland environment
# ============================================================

info "Configuring Wayland environment..."

mkdir -p "$ENV_DIR"

cat > "$ENV_FILE" <<'EOF'
#
# Wayland environment
#

MOZ_ENABLE_WAYLAND=1
ELECTRON_OZONE_PLATFORM_HINT=auto
QT_QPA_PLATFORM=wayland;xcb
SDL_VIDEODRIVER=wayland
CLUTTER_BACKEND=wayland
EOF

# ============================================================
# Niri configuration
# ============================================================

info "Configuring Niri..."

mkdir -p "$NIRI_DIR"

backup "$NIRI_CONFIG"

cat > "$NIRI_CONFIG" <<'EOF'
//
// Niri + Noctalia
//
// Hardware-independent configuration.
// No monitor/output configuration is included intentionally.
//

//
// Required by Noctalia: allows notification actions and window activation
// from the shell.
//

debug {
    honor-xdg-activation-with-invalid-serial
}

input {
    keyboard {
        xkb {}
        numlock
    }

    touchpad {
        tap
        natural-scroll
    }
}

layout {
    gaps 4

    center-focused-column "never"
    always-center-single-column

    preset-column-widths {
        proportion 0.33333
        proportion 0.5
        proportion 0.66667
    }

    default-column-width {
        proportion 0.5
    }

    focus-ring {
        width 2
        active-color "#ffffff"
        inactive-color "#505050"
    }

    border {
        off
    }

    shadow {
        off
    }
}

//
// Noctalia v5
//

spawn-at-startup "noctalia"

//
// Prefer server-side decorations.
//

prefer-no-csd

//
// Screenshots
//

screenshot-path "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png"

//
// Firefox Picture-in-Picture
//

window-rule {
    match app-id=r#"firefox$" title=r#"^Picture-in-Picture$"#
    open-floating true
}

//
// Floating Noctalia settings window
//

window-rule {
    match app-id="dev.noctalia.Noctalia"
    open-floating true

    default-column-width { fixed 1080; }
    default-window-height { fixed 920; }
}

//
// Keybindings
//

binds {

    //
    // System
    //

    Mod+Shift+Slash repeat=false {
        show-hotkey-overlay
    }

    Mod+Q repeat=false {
        close-window
    }

    Mod+O repeat=false {
        toggle-overview
    }

    //
    // Applications
    //

    Mod+T hotkey-overlay-title="Terminal" {
        spawn "alacritty"
    }

    Mod+E hotkey-overlay-title="File Manager" {
        spawn "nautilus"
    }

    Mod+B hotkey-overlay-title="Browser" {
        spawn "firefox"
    }

    //
    // Noctalia launcher, control center, settings and window switcher
    //

    Mod+S {
        spawn "noctalia" "msg" "panel-toggle" "launcher"
    }

    Mod+Space {
        spawn "noctalia" "msg" "panel-toggle" "control-center"
    }

    Mod+Comma {
        spawn "noctalia" "msg" "settings-toggle"
    }

    Alt+Tab {
        spawn "noctalia" "msg" "window-switcher" "hold"
    }

    //
    // Lock (uses the Noctalia lock screen)
    //

    Super+Alt+L hotkey-overlay-title="Lock Screen" {
        spawn "noctalia" "msg" "session" "lock"
    }

    //
    // Audio (routed through Noctalia for OSD feedback)
    //

    XF86AudioRaiseVolume allow-when-locked=true {
        spawn "noctalia" "msg" "volume-up"
    }

    XF86AudioLowerVolume allow-when-locked=true {
        spawn "noctalia" "msg" "volume-down"
    }

    XF86AudioMute allow-when-locked=true {
        spawn "noctalia" "msg" "volume-mute"
    }

    XF86AudioMicMute allow-when-locked=true {
        spawn "noctalia" "msg" "mic-mute"
    }

    //
    // Media
    //

    XF86AudioPlay allow-when-locked=true {
        spawn "playerctl" "play-pause"
    }

    XF86AudioStop allow-when-locked=true {
        spawn "playerctl" "stop"
    }

    XF86AudioPrev allow-when-locked=true {
        spawn "playerctl" "previous"
    }

    XF86AudioNext allow-when-locked=true {
        spawn "playerctl" "next"
    }

    //
    // Brightness (routed through Noctalia for OSD feedback)
    //

    XF86MonBrightnessUp allow-when-locked=true {
        spawn "noctalia" "msg" "brightness-up"
    }

    XF86MonBrightnessDown allow-when-locked=true {
        spawn "noctalia" "msg" "brightness-down"
    }

    //
    // Focus
    //

    Mod+Left {
        focus-column-left
    }

    Mod+Down {
        focus-window-down
    }

    Mod+Up {
        focus-window-up
    }

    Mod+Right {
        focus-column-right
    }

    Mod+Home {
        focus-column-first
    }

    Mod+End {
        focus-column-last
    }

    //
    // Move windows
    //

    Mod+Ctrl+Left {
        move-column-left
    }

    Mod+Ctrl+Down {
        move-window-down
    }

    Mod+Ctrl+Up {
        move-window-up
    }

    Mod+Ctrl+Right {
        move-column-right
    }

    Mod+Ctrl+Home {
        move-column-to-first
    }

    Mod+Ctrl+End {
        move-column-to-last
    }

    //
    // Monitor focus
    //

    Mod+Shift+Left {
        focus-monitor-left
    }

    Mod+Shift+Down {
        focus-monitor-down
    }

    Mod+Shift+Up {
        focus-monitor-up
    }

    Mod+Shift+Right {
        focus-monitor-right
    }

    //
    // Move column to monitor
    //

    Mod+Shift+Ctrl+Left {
        move-column-to-monitor-left
    }

    Mod+Shift+Ctrl+Down {
        move-column-to-monitor-down
    }

    Mod+Shift+Ctrl+Up {
        move-column-to-monitor-up
    }

    Mod+Shift+Ctrl+Right {
        move-column-to-monitor-right
    }

    //
    // Column sizing
    //

    Mod+R {
        switch-preset-column-width
    }

    Mod+Shift+R {
        switch-preset-window-height
    }

    Mod+F {
        maximize-column
    }

    Mod+Shift+F {
        fullscreen-window
    }

    Mod+C {
        center-column
    }

    //
    // Workspaces
    //

    Mod+1 { focus-workspace 1; }
    Mod+2 { focus-workspace 2; }
    Mod+3 { focus-workspace 3; }
    Mod+4 { focus-workspace 4; }
    Mod+5 { focus-workspace 5; }
    Mod+6 { focus-workspace 6; }
    Mod+7 { focus-workspace 7; }
    Mod+8 { focus-workspace 8; }
    Mod+9 { focus-workspace 9; }

    Mod+Shift+1 { move-column-to-workspace 1; }
    Mod+Shift+2 { move-column-to-workspace 2; }
    Mod+Shift+3 { move-column-to-workspace 3; }
    Mod+Shift+4 { move-column-to-workspace 4; }
    Mod+Shift+5 { move-column-to-workspace 5; }
    Mod+Shift+6 { move-column-to-workspace 6; }
    Mod+Shift+7 { move-column-to-workspace 7; }
    Mod+Shift+8 { move-column-to-workspace 8; }
    Mod+Shift+9 { move-column-to-workspace 9; }

    //
    // Workspace navigation
    //

    Mod+Page_Down {
        focus-workspace-down
    }

    Mod+Page_Up {
        focus-workspace-up
    }

    Mod+Ctrl+Page_Down {
        move-column-to-workspace-down
    }

    Mod+Ctrl+Page_Up {
        move-column-to-workspace-up
    }

    //
    // Quit
    //

    Mod+Shift+E {
        quit
    }
}
EOF

if niri_blur_supported; then
    cat >> "$NIRI_CONFIG" <<'EOF'

//
// Noctalia surfaces: disable client-requested blur and xray.
// Requires niri >= 26.04.
//

layer-rule {
    match namespace=r#"^noctalia-(bar-[^"]+|notification|dock|panel|attached-panel|osd)$"#

    background-effect {
        blur false
        xray false
    }
}
EOF
else
    warn "niri ${NIRI_VERSION:-unknown} does not support background-effect rules (needs >= 26.04)."
    warn "Skipping the Noctalia blur layer-rule."
fi

# ============================================================
# Validate Niri configuration
# ============================================================

info "Validating Niri configuration..."

if niri validate; then
    info "Niri configuration is valid."
else
    warn "Niri configuration validation failed."
    warn "The configuration has been written to:"
    warn "    $NIRI_CONFIG"
    exit 1
fi

# ============================================================
# Enable system services
# ============================================================

info "Enabling NetworkManager..."

sudo_cmd systemctl enable --now NetworkManager

info "Enabling Bluetooth..."

sudo_cmd systemctl enable --now bluetooth || warn "Bluetooth service enable failed (may not be available)."

info "Enabling seatd..."

sudo_cmd systemctl enable --now seatd

case "$DISPLAY_MANAGER" in
    gdm|sddm)
        other_dm=""
        [[ "$DISPLAY_MANAGER" == "gdm" ]] && other_dm="sddm"
        [[ "$DISPLAY_MANAGER" == "sddm" ]] && other_dm="gdm"

        if [[ -n "$other_dm" ]] && systemctl is-enabled "$other_dm" >/dev/null 2>&1; then
            info "Disabling $other_dm (replaced by $DISPLAY_MANAGER)..."
            sudo_cmd systemctl disable "$other_dm" || true
        fi

        # Do not immediately switch display managers while the current
        # session is running. The new display manager is used after reboot.
        sudo_cmd systemctl enable "$DISPLAY_MANAGER"
        ;;
    greetd)
        info "Configuring greetd..."
        sudo_cmd mkdir -p /etc/greetd
        sudo_cmd tee /etc/greetd/config.toml >/dev/null <<EOF
[default_session]
command = "niri-session"
user = "$(whoami)"
EOF
        sudo_cmd systemctl enable greetd
        sudo_cmd systemctl set-default graphical.target
        sudo_cmd loginctl enable-linger "$(whoami)" || warn "Could not enable linger."
        ;;
esac

# ============================================================
# Enable PipeWire user services
# ============================================================

info "Enabling PipeWire user services..."

if systemctl --user enable pipewire.service pipewire-pulse.service wireplumber.service; then
    info "PipeWire user services enabled."
else
    warn "Could not enable PipeWire user services (no user session bus?)."
    warn "Fedora presets enable them automatically on your next login."
fi

# ============================================================
# Final font cache
# ============================================================

info "Refreshing font cache..."

fc-cache -f

# ============================================================
# Final checks
# ============================================================

info "Running final checks..."

printf '\n'

FAILED=0

check_bin() {
    local label="$1" bin="$2" path

    if path="$(command -v "$bin" 2>/dev/null)"; then
        printf '  [ok]   %-20s %s\n' "$label" "$path"
    else
        printf '  [FAIL] %-20s not found\n' "$label"
        FAILED=1
    fi
}

check_bin "Niri" niri
check_bin "Noctalia" noctalia
check_bin "XWayland Satellite" xwayland-satellite
check_bin "PipeWire" pipewire
check_bin "WirePlumber" wireplumber
check_bin "Alacritty" alacritty
check_bin "Nautilus" nautilus
check_bin "Firefox" firefox
check_bin "VLC" vlc

if [[ -f /usr/share/wayland-sessions/niri.desktop ]]; then
    printf '  [ok]   %-20s %s\n' "Niri session" "/usr/share/wayland-sessions/niri.desktop"
else
    printf '  [FAIL] %-20s missing\n' "Niri session"
    FAILED=1
fi

printf '\n  Services:\n'

for svc in NetworkManager bluetooth seatd "$DISPLAY_MANAGER"; do
    state="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
    printf '  %-8s %-16s %s\n' "" "$svc" "${state:-unknown}"
done

printf '\n'

if (( FAILED )); then
    warn "Some components are missing. Review the output above."
    exit 1
fi

# ============================================================
# Finished
# ============================================================

info "Setup complete."

if [[ "$DISPLAY_MANAGER" == "greetd" ]]; then
    printf '\nReboot. greetd will start the Niri session automatically.\n\n'
else
    printf '\nReboot, then select "Niri" in the %s session menu.\n\n' "${DISPLAY_MANAGER^^}"
fi
