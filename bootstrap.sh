#!/usr/bin/env bash
# Bootstrap a machine from nothing. Run with (keeps stdin on the TTY so
# interactive prompts work -- `curl | bash` would break them):
#
#   DOTFILES_REPO=git@github.com:<user>/dotfiles.git \
#   BW_EMAIL=you@example.com \
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/<user>/dotfiles/v1.0.0/bootstrap.sh)"
#
# No identity is hardcoded here on purpose: this file is committed, and a repo
# should never carry PII.
set -euo pipefail

: "${DOTFILES_REPO:?set DOTFILES_REPO, e.g. git@github.com:<user>/dotfiles.git}"
REPO="$DOTFILES_REPO"

if [ -z "${BW_EMAIL:-}" ]; then
  printf 'Bitwarden account email: '
  read -r BW_EMAIL
fi
[ -n "$BW_EMAIL" ] || { echo "BW_EMAIL is required" >&2; exit 1; }

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# ---------- 1. package manager ----------
if [ "$(uname)" = "Darwin" ] && ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
for p in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
  [ -x "$p" ] && eval "$("$p" shellenv)" && break
done

# ---------- 2. prerequisites ----------
log "Installing prerequisites"
if command -v brew >/dev/null 2>&1; then
  brew install chezmoi rbw git gh age gitleaks
else
  sudo apt-get update -qq
  sudo apt-get install -y git curl age gnupg pinentry-curses build-essential
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"
  command -v rbw >/dev/null 2>&1 || cargo install --locked rbw 2>/dev/null || \
    log "WARNING: rbw not installed; install it before enabling secrets"
fi

# ---------- 3. unlock the vault ----------
log "Configuring rbw"
rbw config set email "$BW_EMAIL"
rbw config set pinentry "$([ "$(uname)" = Darwin ] && echo pinentry-mac || echo pinentry-curses)"
rbw config set lock_timeout 900
rbw unlocked >/dev/null 2>&1 || { rbw login; rbw unlock; }

# ---------- 4. age identity (must exist BEFORE apply decrypts anything) ----------
mkdir -p "$HOME/.config/chezmoi"
if [ ! -f "$HOME/.config/chezmoi/key.txt" ]; then
  log "Fetching age identity from Bitwarden"
  if rbw get chezmoi-age-key > "$HOME/.config/chezmoi/key.txt" 2>/dev/null; then
    chmod 600 "$HOME/.config/chezmoi/key.txt"
  else
    rm -f "$HOME/.config/chezmoi/key.txt"
    log "WARNING: vault item 'chezmoi-age-key' not found; encrypted files will fail"
  fi
fi

# ---------- 5. per-machine SSH key (never synced) ----------
if [ ! -f "$HOME/.ssh/id_ed25519_personal" ]; then
  log "Generating a per-machine SSH key"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -C "personal@$(hostname -s)-$(date +%Y%m)" \
    -f "$HOME/.ssh/id_ed25519_personal" -N ""
  log "Add this key to GitHub:"
  cat "$HOME/.ssh/id_ed25519_personal.pub"
fi

# ---------- 6. apply ----------
command -v gh >/dev/null 2>&1 && { gh auth status >/dev/null 2>&1 || gh auth login; }
log "Applying dotfiles"
chezmoi init --apply "$REPO"

log "Done. Restart your shell."
