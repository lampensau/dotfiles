#!/usr/bin/env bash
# Installs prerequisites, waits for an SSH agent with a key, clones a private
# dotfiles repo (URL asked at run time) and hands over to its install.sh.
# Run as a downloaded file: bash bootstrap.sh
set -euo pipefail

if [ "${1:-}" = "-h" ]; then
    echo "usage: bash bootstrap.sh"
    echo "Supports Arch, Debian and Fedora families. Answers are read from stdin."
    exit 0
fi

die() {
    echo "error: $*" >&2
    exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# ask PROMPT: reads one line into $REPLY; end of input counts as empty.
ask() {
    printf '%s ' "$1"
    REPLY=
    read -r REPLY || echo
}

# 1. Platform
pm=
if [ -r /etc/os-release ]; then
    ids=$(
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "${ID:-} ${ID_LIKE:-}"
    )
    for id in $ids; do
        case $id in
        arch) pm=pacman ;;
        debian) pm=apt ;;
        fedora) pm=dnf ;;
        *) continue ;;
        esac
        break
    done
fi
[ -n "$pm" ] || die "unsupported platform: only Arch, Debian and Fedora families (macOS is out of scope)"

SUDO=
if [ "$(id -u)" -ne 0 ]; then
    have sudo || die "not root and sudo is missing"
    SUDO=sudo
fi

pm_install() {
    case $pm in
    pacman) $SUDO pacman -Syu --needed --noconfirm "$@" </dev/null ;;
    apt)
        $SUDO apt-get update </dev/null
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" </dev/null
        ;;
    dnf) $SUDO dnf install -y "$@" </dev/null ;;
    esac
}

# 2. Prerequisites
# an earlier run may have put chezmoi into ~/.local/bin; a new shell does not have it on PATH yet
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
need=()
have git || need+=(git)
have curl || need+=(curl)
have fish || need+=(fish)
if ! { have ssh && have ssh-keyscan && have ssh-keygen; }; then
    case $pm in
    pacman) need+=(openssh) ;;
    apt) need+=(openssh-client) ;;
    dnf) need+=(openssh-clients) ;;
    esac
fi
# Debian has no chezmoi package; it gets the upstream installer below.
if [ "$pm" != apt ] && ! have chezmoi; then
    need+=(chezmoi)
fi
if [ "${#need[@]}" -gt 0 ]; then
    echo "Installing: ${need[*]}"
    pm_install "${need[@]}"
fi
if ! have chezmoi; then
    echo "Installing chezmoi with the upstream installer"
    sh -c "$(curl -fsLS https://get.chezmoi.io)" -- -b "$HOME/.local/bin" </dev/null
fi

# warn_unmanaged CMD...: a tool found outside /usr/bin is kept, but not where the package manager puts it.
warn_unmanaged() {
    local c p
    for c in "$@"; do
        p=$(type -P "$c") || continue
        case $p in /usr/bin/*) continue ;; esac
        [ "$c" = chezmoi ] && [ "$pm" = apt ] && [ "$p" = "$HOME/.local/bin/chezmoi" ] && continue
        echo "warning: $c found at $p, not in /usr/bin where the package manager puts it"
    done
}
warn_unmanaged git curl fish ssh chezmoi

# 3. Bitwarden desktop
bw_installed() {
    have bitwarden || have bitwarden-desktop ||
        { have flatpak && flatpak info com.bitwarden.desktop >/dev/null 2>&1; }
}
if ! bw_installed; then
    ask "Install Bitwarden desktop? [Y/n]"
    case $REPLY in
    [Nn]*) ;;
    *)
        if [ "$pm" = pacman ]; then
            pm_install bitwarden
        else
            have flatpak || pm_install flatpak
            $SUDO flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo </dev/null
            $SUDO flatpak remote-modify --enable flathub </dev/null
            $SUDO flatpak install -y flathub com.bitwarden.desktop </dev/null
        fi
        ;;
    esac
fi
warn_unmanaged bitwarden bitwarden-desktop

# 4. Private repo URL
ask "Private dotfiles repo URL:"
url=$REPLY
[ -n "$url" ] || die "no URL given"
host=
port=22
if [[ $url =~ ^ssh://([^@/]+@)?([^/:]+)(:([0-9]+))?/ ]]; then
    host=${BASH_REMATCH[2]}
    port=${BASH_REMATCH[4]:-22}
elif [[ $url =~ ^[^/@:]+@([^/:]+): ]]; then
    host=${BASH_REMATCH[1]}
fi

retry_or_quit() {
    printf 'Press Enter to retry or q to quit: '
    read -r REPLY || {
        echo
        exit 1
    }
    case $REPLY in
    [Qq]*) exit 1 ;;
    esac
}

if [ -n "$host" ]; then
    # 5. SSH agent
    agent_ok() {
        local s
        for s in "${SSH_AUTH_SOCK:-}" "$HOME/.bitwarden-ssh-agent.sock" \
            "$HOME/.var/app/com.bitwarden.desktop/data/.bitwarden-ssh-agent.sock"; do
            [ -S "$s" ] || continue
            if SSH_AUTH_SOCK=$s ssh-add -l >/dev/null 2>&1; then
                export SSH_AUTH_SOCK=$s
                return 0
            fi
        done
        return 1
    }
    until agent_ok; do
        cat <<'EOF'
No SSH agent with a key found. In the Bitwarden desktop app:
  1. Log in and unlock the vault.
  2. Settings > SSH agent: enable it.
  3. Make sure the vault holds an SSH key.
EOF
        retry_or_quit
    done

    # 6. Host key
    if [ "$port" = 22 ]; then
        known=$host
    else
        known="[$host]:$port"
    fi
    if ! ssh-keygen -F "$known" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
        keys=$(ssh-keyscan -p "$port" "$host" 2>/dev/null </dev/null | grep -v '^#' || true)
        [ -n "$keys" ] || die "ssh-keyscan returned no host keys for $known"
        echo "Host key fingerprints for $known:"
        echo "$keys" | ssh-keygen -lf -
        ask "Do these fingerprints match the ones your forge publishes? [y/N]"
        case $REPLY in
        [Yy]*) ;;
        *) die "host key not accepted" ;;
        esac
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        echo "$keys" >>"$HOME/.ssh/known_hosts"
    fi
fi

# 7. Clone
dest=$HOME/.dotfiles
if [ -e "$dest/.git" ]; then
    echo "$dest is already a git repo, skipping the clone"
elif [ -e "$dest" ]; then
    die "$dest exists and is not a git repo"
else
    until git ls-remote "$url" >/dev/null </dev/null; do
        echo "Cannot reach $url"
        retry_or_quit
    done
    git clone "$url" "$dest"
fi

# 8. Handover
exec bash "$dest/install.sh"
