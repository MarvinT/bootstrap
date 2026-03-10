#!/usr/bin/env bash
set -euo pipefail

log()  { printf "\n\033[1;32m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m==>\033[0m %s\n" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

ensure_line() {
  local file="$1" line="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  grep -Fqx "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

replace_or_append_kv() {
  # replace key=... (quoted) else append
  local file="$1" key="$2" value="$3"
  touch "$file"
  if grep -qE "^${key}=" "$file"; then
    sed -i -E "s|^${key}=\"[^\"]*\"|${key}=\"${value}\"|" "$file"
    sed -i -E "s|^${key}=[^ ].*|${key}=\"${value}\"|" "$file"
  else
    echo "${key}=\"${value}\"" >> "$file"
  fi
}

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "Run as a normal user (not root). This script uses sudo when needed."
  exit 1
fi

if ! have sudo; then
  echo "sudo not found. Install it first."
  exit 1
fi

# Detect systemd (WSL may or may not have it enabled)
is_systemd=false
if [[ -d /run/systemd/system ]] || (have systemctl && systemctl is-system-running >/dev/null 2>&1); then
  is_systemd=true
fi

log "Apt: base packages + CLI niceties"
sudo apt-get update -y
sudo apt-get install -y \
  ca-certificates curl wget gnupg lsb-release \
  git jq unzip xz-utils zip \
  build-essential \
  openssh-server \
  fzf command-not-found \
  ripgrep fd-find bat tmux neovim \
  direnv zoxide \
  clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-12-dev mesa-utils

# Some Ubuntu packages install binaries with different names:
# - fd-find => fdfind
# - bat => batcat
log "Fix convenience symlinks for fd/bat (to ~/.local/bin)"
mkdir -p "$HOME/.local/bin"
if have fdfind && [[ ! -e "$HOME/.local/bin/fd" ]]; then
  ln -s "$(command -v fdfind)" "$HOME/.local/bin/fd"
fi
if have batcat && [[ ! -e "$HOME/.local/bin/bat" ]]; then
  ln -s "$(command -v batcat)" "$HOME/.local/bin/bat"
fi

# Update command-not-found DB if available
if have update-command-not-found; then
  sudo update-command-not-found || true
fi

log "Create folder structure"
mkdir -p "$HOME/code" "$HOME/vaults" "$HOME/opt" "$HOME/.ssh"

chmod 700 "$HOME/.ssh"

log "Ensure ~/.local/bin is on PATH for bash + zsh"
ensure_line "$HOME/.bashrc" ''
ensure_line "$HOME/.bashrc" '# Local user binaries'
ensure_line "$HOME/.bashrc" 'export PATH="$HOME/.local/bin:$PATH"'

ensure_line "$HOME/.zshrc" ''
ensure_line "$HOME/.zshrc" '# Local user binaries'
ensure_line "$HOME/.zshrc" 'export PATH="$HOME/.local/bin:$PATH"'

export PATH="$HOME/.local/bin:$PATH"

log "Git defaults"
git config --global init.defaultBranch main || true

log "SSH key setup (ed25519)"
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -a 64 -f "$HOME/.ssh/id_ed25519" -N "" -C "$USER@$(hostname)"
fi
chmod 600 "$HOME/.ssh/id_ed25519" || true
chmod 644 "$HOME/.ssh/id_ed25519.pub" || true

# Basic SSH config for GitHub (idempotent: only creates if missing)
if [[ ! -f "$HOME/.ssh/config" ]]; then
  cat > "$HOME/.ssh/config" <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
  chmod 600 "$HOME/.ssh/config" || true
fi

# Add GitHub host key to known_hosts (best-effort; don't fail offline)
touch "$HOME/.ssh/known_hosts"
chmod 644 "$HOME/.ssh/known_hosts" || true
if have ssh-keyscan && ! grep -q "github.com" "$HOME/.ssh/known_hosts" 2>/dev/null; then
  ssh-keyscan -H github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
fi

log "Install uv (Python tooling)"
if ! have uv; then
  # Official installer
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

log "Install nvm + Node 22 (Codex CLI via npm works reliably with Node 22+)"
NVM_VERSION="v0.40.4"
if [[ ! -s "$HOME/.nvm/nvm.sh" ]]; then
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"

if have nvm; then
  nvm install 22
  nvm alias default 22
  nvm use default
fi

# Ensure nvm loads for future shells
ensure_line "$HOME/.bashrc" 'export NVM_DIR="$HOME/.nvm"'
ensure_line "$HOME/.bashrc" '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'

ensure_line "$HOME/.zshrc" 'export NVM_DIR="$HOME/.nvm"'
ensure_line "$HOME/.zshrc" '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'

log "Install GitHub CLI (gh) using official repo"
if ! have gh; then
  # Official instructions use /etc/apt/keyrings
  (type -p wget >/dev/null || (sudo apt-get update -y && sudo apt-get install -y wget))
  sudo mkdir -p -m 755 /etc/apt/keyrings
  out="$(mktemp)"
  wget -nv -O "$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg
  cat "$out" | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  sudo mkdir -p -m 755 /etc/apt/sources.list.d
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y gh
fi

log "Install Codex CLI"
if ! have codex; then
  npm i -g @openai/codex@latest
fi

log "Install Claude Code"
if ! have claude; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

log "Install Flutter"

# Common prereqs for Flutter tooling on Linux
sudo apt-get install -y libglu1-mesa git unzip xz-utils zip

# Detect WSL
is_wsl=false
if grep -qi microsoft /proc/version 2>/dev/null; then
  is_wsl=true
fi

# Decide whether the currently-resolved flutter is acceptable
flutter_ok=false
flutter_cmd="$(command -v flutter 2>/dev/null || true)"

if [[ -n "${flutter_cmd}" ]]; then
  # In WSL, reject Windows-side flutter paths outright
  if [[ "$is_wsl" == "true" && "$flutter_cmd" == /mnt/* ]]; then
    warn "WSL detected and flutter resolves to Windows path: $flutter_cmd (will install Linux flutter)"
    flutter_ok=false
  # Reject CRLF shebangs (bash\r)
  elif head -n1 "$flutter_cmd" | grep -q $'\r'; then
    warn "flutter has CRLF shebang (bash\\r): $flutter_cmd (will install Linux flutter)"
    flutter_ok=false
  else
    # Require that flutter actually runs
    "$flutter_cmd" --version >/dev/null 2>&1 && flutter_ok=true || flutter_ok=false
  fi
fi

# If flutter is missing or unacceptable, install a Linux flutter into ~/opt/flutter
if [[ "$flutter_ok" != "true" ]]; then
  # On non-WSL Linux, snap may work; on WSL it often doesn't (snapd/systemd).
  if [[ "$is_wsl" != "true" && -x "$(command -v snap 2>/dev/null)" ]]; then
    set +e
    sudo snap install flutter --classic
    rc=$?
    set -e
    if [[ $rc -eq 0 ]] && command -v flutter >/dev/null 2>&1 && flutter --version >/dev/null 2>&1; then
      flutter_ok=true
    else
      warn "snap install flutter failed; falling back to git clone."
      flutter_ok=false
    fi
  fi

  if [[ "$flutter_ok" != "true" ]]; then
    if [[ ! -d "$HOME/opt/flutter/.git" ]]; then
      git clone https://github.com/flutter/flutter.git -b stable "$HOME/opt/flutter"
    else
      (cd "$HOME/opt/flutter" && git fetch --all -p && git checkout stable && git pull --ff-only) || true
    fi

    # Ensure scripts are LF (defensive; avoids bash\r if a checkout ever gets CRLF)
    (cd "$HOME/opt/flutter" && git config core.autocrlf false && git config core.eol lf && git checkout -f >/dev/null 2>&1) || true

    # Put Linux flutter first in PATH for both shells
    ensure_line "$HOME/.bashrc" '# Flutter (Linux install)'
    ensure_line "$HOME/.bashrc" 'export PATH="$HOME/opt/flutter/bin:$PATH"'
    ensure_line "$HOME/.zshrc"  '# Flutter (Linux install)'
    ensure_line "$HOME/.zshrc"  'export PATH="$HOME/opt/flutter/bin:$PATH"'

    export PATH="$HOME/opt/flutter/bin:$PATH"

    # In WSL, also remove Windows flutter path entries (zsh + bash), idempotently
    if [[ "$is_wsl" == "true" ]]; then
      # zsh: remove Windows flutter path if present
      if ! grep -Fq 'path=(${path:#/mnt/c/Users/*/Documents/GitHub/flutter/bin})' "$HOME/.zshrc"; then
        cat >> "$HOME/.zshrc" <<'EOF'

# WSL: prefer Linux Flutter; remove Windows Flutter path if it exists
path=(${path:#/mnt/c/Users/*/Documents/GitHub/flutter/bin})
EOF
      fi

      # bash: filter Windows flutter from PATH
      if ! grep -Fq 'WSL: remove Windows Flutter from PATH' "$HOME/.bashrc"; then
        cat >> "$HOME/.bashrc" <<'EOF'

# WSL: remove Windows Flutter from PATH if present
# (keeps Linux flutter in ~/opt/flutter/bin winning consistently)
case ":$PATH:" in
  *":/mnt/c/Users/"*"/Documents/GitHub/flutter/bin:"*)
    PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vE '^/mnt/c/Users/.*/Documents/GitHub/flutter/bin$' | paste -sd: -)"
    export PATH
    ;;
esac
EOF
      fi
    fi
  fi
fi

# Refresh command lookup cache (helps zsh/busy sessions after PATH edits)
hash -r 2>/dev/null || true

# Final sanity output
echo "flutter resolved to: $(command -v flutter 2>/dev/null || echo 'missing')"
flutter --version 2>/dev/null | head -n1 || true

log "Chrome for Flutter web (WSL-friendly)"

# Detect WSL (if not already set earlier)
is_wsl=false
if grep -qi microsoft /proc/version 2>/dev/null; then
  is_wsl=true
fi

chrome_path=""
if [[ "$is_wsl" == "true" ]]; then
  # Prefer Windows Chrome/Edge (works via WSL interop)
  candidates=(
    "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe"
    "/mnt/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"
    "/mnt/c/Program Files/Microsoft/Edge/Application/msedge.exe"
    "/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
  )
  for p in "${candidates[@]}"; do
    if [[ -f "$p" ]]; then
      chrome_path="$p"
      break
    fi
  done
fi

if [[ -n "$chrome_path" ]]; then
  ensure_line "$HOME/.bashrc" "export CHROME_EXECUTABLE=\"$chrome_path\""
  ensure_line "$HOME/.zshrc"  "export CHROME_EXECUTABLE=\"$chrome_path\""
  export CHROME_EXECUTABLE="$chrome_path"
fi

#log "Enable/start SSH server (for VS Code Remote-SSH)"
## Ensure runtime dir exists for sshd
#sudo mkdir -p /run/sshd
#
#if [[ "$is_systemd" == "true" ]]; then
#  sudo systemctl enable ssh
#  sudo systemctl restart ssh
#else
#  # WSL without systemd: service may still work; otherwise user can run sshd manually
#  if have service; then
#    sudo service ssh start || true
#  fi
#fi

log "Oh My Zsh + Powerlevel10k + plugins"
sudo apt-get install -y zsh

# Install Oh My Zsh (unattended; don't auto-run zsh; don't auto-chsh; don't overwrite .zshrc)
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" \
    --unattended --keep-zshrc
fi

# Ensure ~/.zshrc exists
if [[ ! -f "$HOME/.zshrc" ]]; then
  cp "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" "$HOME/.zshrc"
fi

ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

clone_or_update () {
  local repo_url="$1" dest_dir="$2"
  if [[ ! -d "$dest_dir/.git" ]]; then
    git clone --depth=1 "$repo_url" "$dest_dir"
  else
    (cd "$dest_dir" && git pull --ff-only) || true
  fi
}

# Theme: powerlevel10k
clone_or_update \
  "https://github.com/romkatv/powerlevel10k.git" \
  "${ZSH_CUSTOM}/themes/powerlevel10k"

# Plugins: autosuggestions + syntax highlighting (external)
clone_or_update \
  "https://github.com/zsh-users/zsh-autosuggestions.git" \
  "${ZSH_CUSTOM}/plugins/zsh-autosuggestions"

clone_or_update \
  "https://github.com/zsh-users/zsh-syntax-highlighting.git" \
  "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting"

# Custom uv plugin (completions)
mkdir -p "${ZSH_CUSTOM}/plugins/uv"
if have uv; then
  {
    echo "# Autogenerated by bootstrap.sh"
    uv generate-shell-completion zsh
    if have uvx; then
      uvx --generate-shell-completion zsh
    fi
  } > "${ZSH_CUSTOM}/plugins/uv/uv.plugin.zsh"
fi

# --- Oh My Zsh: ensure init + theme + plugins are correct (idempotent) ---

# Ensure export ZSH points at the OMZ install (put it near the top for clarity)
if grep -q '^export ZSH=' "$HOME/.zshrc"; then
  sed -i -E 's|^export ZSH=.*$|export ZSH="$HOME/.oh-my-zsh"|' "$HOME/.zshrc"
else
  # Insert at top (fine even if PATH/NVM is above; ZSH just needs to exist before sourcing OMZ)
  sed -i '1i export ZSH="$HOME/.oh-my-zsh"\n' "$HOME/.zshrc"
fi

# Set theme
if grep -q '^ZSH_THEME=' "$HOME/.zshrc"; then
  sed -i -E 's|^ZSH_THEME="[^"]*"|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$HOME/.zshrc"
else
  echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> "$HOME/.zshrc"
fi

# Set plugin list (explicit + stable)
# NOTE: docker/docker-compose plugins are OK even if you skip installing docker
plugins_line='plugins=(git docker docker-compose python pip uv extract fzf z sudo colored-man-pages command-not-found direnv zoxide zsh-autosuggestions)'
if grep -q '^plugins=' "$HOME/.zshrc"; then
  sed -i -E "s|^plugins=\(.*\)$|${plugins_line}|" "$HOME/.zshrc"
else
  echo "$plugins_line" >> "$HOME/.zshrc"
fi

# Ensure OMZ is sourced AFTER ZSH_THEME/plugins and BEFORE any "must be last" plugins.
# Remove any existing OMZ source line (wherever it is), then re-insert right after plugins=...
sed -i -E '/^source \$ZSH\/oh-my-zsh\.sh$/d' "$HOME/.zshrc"

if grep -q '^plugins=' "$HOME/.zshrc"; then
  # Insert immediately after the plugins=... line
  sed -i '/^plugins=/a source $ZSH/oh-my-zsh.sh' "$HOME/.zshrc"
else
  # Fallback (shouldn't happen, but keeps it robust)
  echo 'source $ZSH/oh-my-zsh.sh' >> "$HOME/.zshrc"
fi

# zoxide + direnv
# Prefer OMZ plugins (direnv + zoxide) to avoid double init.
# Remove any old manual init lines the script might have added previously:
sed -i -E '/^eval "\$\((zoxide init zsh|direnv hook zsh)\)"/d' "$HOME/.zshrc"

# Fallback: only add manual init if OMZ plugin folders are missing (rare, but safe)
if [[ ! -d "$HOME/.oh-my-zsh/plugins/direnv" && ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/direnv" ]]; then
  if ! grep -Fq 'eval "$(direnv hook zsh)"' "$HOME/.zshrc"; then
    cat >> "$HOME/.zshrc" <<'EOF'

# direnv (fallback init)
eval "$(direnv hook zsh)"
EOF
  fi
fi

if [[ ! -d "$HOME/.oh-my-zsh/plugins/zoxide" && ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zoxide" ]]; then
  if ! grep -Fq 'eval "$(zoxide init zsh)"' "$HOME/.zshrc"; then
    cat >> "$HOME/.zshrc" <<'EOF'

# zoxide (fallback init)
eval "$(zoxide init zsh)"
EOF
  fi
fi

# Also add direnv hook for bash (handy if you ever stay in bash)
if ! grep -Fq 'eval "$(direnv hook bash)"' "$HOME/.bashrc"; then
  cat >> "$HOME/.bashrc" <<'EOF'

# direnv
eval "$(direnv hook bash)"
EOF
fi

# zsh-syntax-highlighting MUST be sourced at the very end of .zshrc
if ! grep -Fq 'zsh-syntax-highlighting.zsh' "$HOME/.zshrc"; then
  cat >> "$HOME/.zshrc" <<'EOF'

# zsh-syntax-highlighting (must be last)
source ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
EOF
fi

# Try to set default shell to zsh (may fail on some WSL setups; that's fine)
if [[ "${SHELL##*/}" != "zsh" ]]; then
  if chsh -s "$(command -v zsh)" >/dev/null 2>&1; then
    log "Default shell set to zsh (takes effect next login/new session)."
  else
    warn "Couldn't chsh automatically (common on some systems). You can run manually: chsh -s $(command -v zsh)"
  fi
fi

log "Optional: add SSH key to GitHub via gh (only if you're already logged in)"
if have gh && gh auth status >/dev/null 2>&1; then
  # This may fail if the key already exists; ignore errors to stay idempotent.
  gh ssh-key add "$HOME/.ssh/id_ed25519.pub" -t "$(hostname)-$USER" >/dev/null 2>&1 || true
fi

log "Verify installs (best-effort)"
set +e
echo "uv:      $(uv --version 2>/dev/null || echo 'missing')"
echo "python:  $(python3 --version 2>/dev/null || echo 'missing')"
echo "node:    $(node -v 2>/dev/null || echo 'missing')"
echo "npm:     $(npm -v 2>/dev/null || echo 'missing')"
echo "gh:      $(gh --version 2>/dev/null | head -n1 || echo 'missing')"
echo "codex:   $(codex --version 2>/dev/null || echo 'missing')"
echo "claude:  $(claude --version 2>/dev/null || echo 'missing')"
echo "flutter: $(flutter --version 2>/dev/null | head -n1 || echo 'missing')"
echo "rg:      $(rg --version 2>/dev/null | head -n1 || echo 'missing')"
echo "fd:      $(fd --version 2>/dev/null | head -n1 || echo 'missing')"
echo "bat:     $(bat --version 2>/dev/null || echo 'missing')"
echo "tmux:    $(tmux -V 2>/dev/null || echo 'missing')"
echo "nvim:    $(nvim --version 2>/dev/null | head -n1 || echo 'missing')"
echo "direnv:  $(direnv --version 2>/dev/null || echo 'missing')"
echo "zoxide:  $(zoxide --version 2>/dev/null || echo 'missing')"
echo "ssh:     $(ssh -V 2>&1 | head -n1 || echo 'missing')"
if have sshd; then
  sshd -t >/dev/null 2>&1 && echo "sshd:    config ok" || echo "sshd:    config check FAILED"
fi
set -e

log "Next steps"
cat <<EOF
- Reload your shell:
    exec zsh
  (or open a new terminal)

- Configure Powerlevel10k:
    p10k configure

- GitHub auth (recommended):
    gh auth login

- Add your SSH public key to GitHub if needed:
    cat ~/.ssh/id_ed25519.pub

- Run Flutter doctor:
    flutter doctor
EOF
