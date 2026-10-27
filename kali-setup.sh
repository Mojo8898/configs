#!/usr/bin/env bash
#
# kali-setup.sh — provision a fresh Kali pentest box in root's own account.
# Run as root:  curl -s <raw_github_link> | sudo bash   (--help for flags)
# Idempotent, non-interactive, logs to /root/kali-setup.log. A full run ends
# with autologin + reboot; the summary then prints on the next terminal.
#
set -uo pipefail

# Config (override via env or flags). Tokens -> ~/.zshrc.
HTB_TOKEN="${HTB_TOKEN:-}"
BH_TOKEN_ID="${BH_TOKEN_ID:-}"
BH_TOKEN_KEY="${BH_TOKEN_KEY:-}"

# Config assets repo (zsh/, tmux/, ...), cloned to REPO_DIR; the config sections
# read from there. CONFIGS_REPO may be a local path (unpushed checkout).
CONFIGS_REPO="${CONFIGS_REPO:-https://github.com/Mojo8898/configs.git}"
REPO_DIR=/opt/tools/configs
DO_FORCE="${DO_FORCE:-0}"             # 1 = re-run stateful steps (bloodhound, msfdb)

# mongosh: newest GitHub release, falling back to this pinned .deb on lookup failure.
MONGOSH_DEB_URL="https://downloads.mongodb.com/compass/mongodb-mongosh_2.14.0_amd64.deb"
MONGOSH_GH_REPO="mongodb-js/mongosh"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Section registry
ALL_SECTIONS=(apt base tools vscode python go rust ruby gittools bloodhound \
              sqlcmd cloud pcredz scripts tmux configs services xfce upgrade)
ONLY=""
SKIP=""

# Logging / helpers
LOGFILE="/root/kali-setup.log"
FIRSTRUN_FILE="/root/.kali-setup-firstrun"     # summary shown on first terminal after reboot
FAILED=()
NOTES=()
BH_LOGIN=""            # BloodHound admin login, surfaced in the post-reboot summary
REBOOT_NEEDED=0
REBOOT_REASONS=()

c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'

log()    { printf '%s\n' "$*" >>"$LOGFILE" 2>/dev/null || true; }
say()    { printf '%s\n' "$*"; log "$*"; }
info()   { printf '%s%s%s\n' "$c_cyn" "$*" "$c_rst"; log "$*"; }
ok()     { printf '    %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; log "OK: $*"; }
warn()   { printf '    %s✗ %s%s\n' "$c_yel" "$*" "$c_rst"; log "WARN: $*"; }
note()   { NOTES+=("$*"); }
need_reboot() { REBOOT_NEEDED=1; REBOOT_REASONS+=("$1"); }

banner() {
  say ""
  say "${c_cyn}============================================================${c_rst}"
  say "${c_cyn}  $*${c_rst}"
  say "${c_cyn}============================================================${c_rst}"
}

# run <description> <cmd...>  — never aborts; records failures.
run() {
  local desc="$1"; shift
  printf '  → %s\n' "$desc"
  log "RUN: $desc :: $*"
  if "$@" >>"$LOGFILE" 2>&1; then
    ok "$desc"
    return 0
  else
    local rc=$?
    warn "$desc (rc=$rc, continuing)"
    FAILED+=("$desc")
    return 0
  fi
}

# run_sh <description> <shell-string>  — for multi-command / pipeline steps.
run_sh() {
  local desc="$1"; shift
  run "$desc" bash -c "$*"
}

# apt_install <pkgs...> — batch, then retry individually so one bad name
# does not block the rest.
apt_install() {
  if apt-get install -y --no-install-recommends "$@" >>"$LOGFILE" 2>&1; then
    ok "apt: $*"
    return 0
  fi
  warn "apt batch failed — retrying individually"
  local p
  for p in "$@"; do
    if apt-get install -y --no-install-recommends "$p" >>"$LOGFILE" 2>&1; then
      ok "apt: $p"
    else
      warn "apt FAILED: $p"
      FAILED+=("apt:$p")
    fi
  done
}

# gclone <url> <dest> [git-opts...] — clone only if missing.
gclone() {
  local url="$1" dest="$2"; shift 2
  if [[ -d "$dest/.git" ]]; then
    ok "repo present: $dest"
    return 0
  fi
  run "clone $(basename "$dest")" git clone "$@" "$url" "$dest"
}

# symlink <target> <linkname> — idempotent, replaces existing link.
symlink() {
  ln -sfn "$1" "$2" && ok "link $2 -> $1" || warn "link failed: $2 -> $1"
}

enable_service() {
  run "enable service: $1" systemctl enable --now "$1"
}

# gh_latest_tag <owner/repo> — newest release tag via the releases/latest
# redirect (avoids rate-limited api.github.com). Empty on failure.
gh_latest_tag() {
  curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/$1/releases/latest" 2>/dev/null \
    | sed -n 's#.*/releases/tag/##p'
}

# set_qterminal_opaque <ini> — TerminalTransparency=0. Kali's default terminal
# is qterminal (QSettings INI), not xfce4-terminal.
set_qterminal_opaque() {
  local ini="$1"
  mkdir -p "$(dirname "$ini")"
  if [[ ! -f "$ini" ]]; then
    printf '[General]\nTerminalTransparency=0\n' > "$ini"
  else
    grep -q '^\[General\]' "$ini" || printf '[General]\n' >> "$ini"
    if grep -q '^TerminalTransparency=' "$ini"; then
      sed -i 's/^TerminalTransparency=.*/TerminalTransparency=0/' "$ini"
    else
      sed -i '/^\[General\]/a TerminalTransparency=0' "$ini"
    fi
  fi
}

# resolve_assets — clone/refresh the config assets repo into REPO_DIR, once up
# front; the config sections read configs.zsh and the tmux tree from there.
resolve_assets() {
  banner "Config assets ($CONFIGS_REPO)"
  if [[ -d "$REPO_DIR/.git" ]]; then
    run "refresh configs repo" git -C "$REPO_DIR" pull --ff-only
  else
    gclone "$CONFIGS_REPO" "$REPO_DIR"
  fi
  [[ -d "$REPO_DIR/zsh" && -d "$REPO_DIR/tmux" ]] || \
    warn "configs repo is missing expected trees (zsh/, tmux/) — those sections may skip"
}

# Preflight (always runs)
preflight() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This script must run as root (all paths assume /root)." >&2
    echo "Re-run with:  curl -s <link> | sudo bash" >&2
    exit 1
  fi

  # sudo can leave HOME pointing at the invoking user — force root's home.
  export HOME=/root
  export USER=root

  : >"$LOGFILE" 2>/dev/null || LOGFILE="/tmp/kali-setup.log"
  log "kali-setup started $(date -Iseconds)"

  # PATH for this run: the default dirs uv/go/cargo install into, plus the
  # cloned-tools bin. Post-install hooks (bbot, nuclei -up, …) call tools by name.
  export PATH="/opt/tools/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.cargo/bin:/usr/local/go/bin:$PATH"
  export GOPATH="${GOPATH:-$HOME/go}"

  mkdir -p /opt/tools/bin /opt/lists /opt/scripts \
           "$HOME/.config/ffuf" "$HOME/.vscode" \
           /etc/apt/keyrings

  # .hushlogin early so later sections' shells don't dump the login banner to the log.
  touch "$HOME/.hushlogin"

  info "Refreshing apt and installing prerequisites (toolchains, etc.)..."
  run "apt update" apt-get update
  # Toolchains/utilities later sections depend on.
  apt_install git curl wget gnupg ca-certificates apt-transport-https \
              zsh tmux build-essential pkg-config \
              golang-go rustc cargo ruby ruby-dev \
              python3 python3-venv python3-pip pipx \
              direnv entr fzf seclists wordlists

  log "go version: $(go version 2>/dev/null | awk '{print $3}')"
}

# apt — purge/replace + main package set
setup_apt() {
  banner "APT packages"
  run "purge netexec/impacket-scripts (reinstalled via uv)" \
      apt-get purge -y netexec impacket-scripts

  apt_install libreoffice gcc python3-dev libkrb5-dev krb5-pkinit krb5-user \
              rlwrap docker.io docker-cli docker-compose rustscan \
              putty jq build-essential gitleaks testssl.sh lftp \
              pkg-config libssl-dev zlib1g-dev libgmp-dev libpcap-dev \
              libbz2-dev sshuttle faketime rdate sshpass evil-winrm-py

  run "apt autoremove" apt-get autoremove -y
  enable_service docker   # up before the bloodhound section
}

# base — filesystem scaffolding, wordlists
setup_base() {
  banner "Base files & wordlists"
  if [[ -f /usr/share/wordlists/rockyou.txt.gz ]]; then
    run "gunzip rockyou" gzip -d /usr/share/wordlists/rockyou.txt.gz
  else
    ok "rockyou already decompressed (or package missing)"
  fi

  # Combined seclists lists.
  local qh=/usr/share/seclists/Discovery/Web-Content/quickhits.txt
  local cm=/usr/share/seclists/Discovery/Web-Content/common.txt
  if [[ -f "$qh" && -f "$cm" ]]; then
    run_sh "build quickcommon.txt" \
      "cat '$qh' '$cm' | sort -u > /opt/lists/quickcommon.txt"
    run_sh "build quickcommon-lowercase.txt" \
      "cat '$qh' '$cm' | tr '[:upper:]' '[:lower:]' | sort -u > /opt/lists/quickcommon-lowercase.txt"
  else
    warn "seclists files not found — skipping combined lists"
    note "seclists lists not built (quickhits/common not found). Install seclists and re-run --only base."
  fi
}

# tools — mongosh + standalone git clones
setup_tools() {
  banner "Tools (mongosh + git clones)"

  if ! command -v mongosh >/dev/null 2>&1; then
    local mongo_url="$MONGOSH_DEB_URL"
    # Build the bundled-deb URL from the latest tag (not the shared-openssl variant).
    local tag; tag="$(gh_latest_tag "$MONGOSH_GH_REPO")"
    if [[ -n "$tag" ]]; then
      mongo_url="https://github.com/$MONGOSH_GH_REPO/releases/download/$tag/mongodb-mongosh_${tag#v}_amd64.deb"
      ok "mongosh latest -> $mongo_url"
    else
      warn "mongosh latest lookup failed — using pinned $MONGOSH_DEB_URL"
    fi
    run_sh "install mongosh" "
      cd /opt/tools &&
      wget -q '$mongo_url' -O mongosh.deb &&
      apt-get install -y ./mongosh.deb &&
      rm -f mongosh.deb"
    command -v mongosh >/dev/null 2>&1 || \
      note "mongosh install failed — latest lookup and pinned .deb both unavailable. Grab a current build from https://www.mongodb.com/try/download/shell"
  else
    ok "mongosh already installed"
  fi

  gclone https://github.com/dirkjanm/krbrelayx.git             /opt/tools/krbrelayx
  gclone https://github.com/p0dalirius/windows-coerced-authentication-methods.git \
                                                               /opt/tools/windows-coerced-authentication-methods
  gclone https://github.com/berdav/CVE-2021-4034.git           /opt/tools/CVE-2021-4034
}

# vscode — VS Code via Microsoft's apt repo (stays current with apt upgrade)
setup_vscode() {
  banner "Visual Studio Code"
  if command -v code >/dev/null 2>&1; then
    ok "code already installed"
    return 0
  fi
  run_sh "add vscode apt repo" "
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --yes --dearmor -o /usr/share/keyrings/packages.microsoft.gpg &&
    printf 'deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main\n' > /etc/apt/sources.list.d/vscode.list"
  run "apt update" apt-get update
  apt_install code
  command -v code >/dev/null 2>&1 || note "VS Code install failed — check the apt repo step in $LOGFILE."
}

# python — uv + uv tools
setup_python() {
  banner "Python tooling (uv)"

  # uv -> default ~/.local/bin (on PATH via ~/.zshrc). UV_NO_MODIFY_PATH stops
  # the installer touching rc files — ~/.zshrc already handles PATH.
  if [[ ! -x "$HOME/.local/bin/uv" ]]; then
    run_sh "install uv" \
      "curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh"
    hash -r
  else
    ok "uv already installed"
  fi

  if ! command -v uv >/dev/null 2>&1; then
    warn "uv unavailable — skipping all uv tools"
    FAILED+=("uv (not installed)")
    return 0
  fi

  # Entries are word-split intentionally (some carry flags).
  local t
  local uv_tools=(
    "--with pip bbot"
    "aliasr"
    "bloodyAD"
    "coercer"
    "git+https://github.com/fortra/impacket"
    "mitm6"
    "mitmproxy"
    "git+https://github.com/Pennyw0rth/NetExec"
    "powerview"
    "tldr"
    "updog"
    "smbclientng"
    "modpoll"
    "git-dumper"
    "whatportis"
    "git+https://github.com/ly4k/Certipy.git"
    "pypykatz"
    "git+https://github.com/Mojo8898/pyGPOAbuse.git"
    "semgrep"
    "wafw00f"
    "git+https://github.com/EnableSecurity/sipvicious.git"
    "git+https://github.com/ThePorgs/Exegol-history"
    "git+https://github.com/epinna/weevely3.git"
    "git+https://github.com/c0inslot/CorpCrack.git"
  )
  for t in "${uv_tools[@]}"; do
    run "uv tool install $t" uv tool install $t
  done

  run "bbot --install-all-deps" bbot --install-all-deps
  # whatportis --update prompts [y/N] — feed 'y' for headless.
  run_sh "whatportis --update" "yes | whatportis --update"
}

setup_go() {
  banner "Go tooling"
  command -v go >/dev/null 2>&1 || { warn "go not found — skipping"; FAILED+=("go (not installed)"); return 0; }
  export GOPATH="${GOPATH:-$HOME/go}"
  export PATH="$GOPATH/bin:$PATH"
  # Keep CGO link scratch off the small /tmp tmpfs (nuclei/katana overflow it).
  export GOTMPDIR="$HOME/.cache/go-tmp"; mkdir -p "$GOTMPDIR"

  local g
  local go_pkgs=(
    "github.com/sensepost/gowitness@latest"
    "github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
    "github.com/projectdiscovery/httpx/cmd/httpx@latest"
    "github.com/projectdiscovery/vulnx/v2/cmd/vulnx@latest"
  )
  for g in "${go_pkgs[@]}"; do
    run "go install $(basename "${g%@*}")" go install -v "$g"
  done
  run "go install katana (CGO)" env CGO_ENABLED=1 go install -v \
      github.com/projectdiscovery/katana/cmd/katana@latest

  # Post-install template/db updates (best effort).
  run "nuclei -up"  nuclei -up
  run "nuclei -ut"  nuclei -ut
  run "httpx -up"   httpx -up
  run "vulnx --update" vulnx --update
  run "katana -up"  katana -up
}

setup_rust() {
  banner "Rust tooling"
  command -v cargo >/dev/null 2>&1 || { warn "cargo not found — skipping"; FAILED+=("cargo (not installed)"); return 0; }
  run "cargo install rusthound-ce" cargo install rusthound-ce
  run "cargo install skewrun"      cargo install skewrun
}

setup_ruby() {
  banner "Ruby tooling"
  command -v gem >/dev/null 2>&1 || { warn "gem not found — skipping"; FAILED+=("gem (not installed)"); return 0; }
  run "gem install haiti-hash" gem install haiti-hash
}

# gittools — fzf, john, kerbrute
setup_gittools() {
  banner "Git-built tools (fzf, john, kerbrute)"

  # fzf — binary only; shell integration comes from ~/.zshrc via `fzf --zsh`.
  gclone https://github.com/junegunn/fzf.git /opt/tools/fzf --depth 1
  if [[ -x /opt/tools/fzf/install ]]; then
    run "fzf install (bin only)" /opt/tools/fzf/install --bin
  fi
  [[ -x /opt/tools/fzf/bin/fzf ]] && symlink /opt/tools/fzf/bin/fzf /opt/tools/bin/fzf

  # John the Ripper (jumbo) — build from source.
  gclone https://github.com/openwall/john.git /opt/tools/john
  if [[ -d /opt/tools/john/src && ! -x /opt/tools/john/run/john ]]; then
    run_sh "build john" "cd /opt/tools/john/src && ./configure && make -s -j\"\$(nproc)\""
  else
    ok "john already built (or source missing)"
  fi
  [[ -f /opt/tools/john/run/keepass2john ]] && \
    symlink /opt/tools/john/run/keepass2john /opt/tools/bin/keepass2john
  # Default wordlist -> rockyou. Edits a tracked file; update-tools stashes
  # around its pull so this doesn't block updates.
  local jconf=/opt/tools/john/run/john.conf
  [[ -f "$jconf" ]] && run "john.conf default wordlist -> rockyou" \
    sed -i 's#^Wordlist = \$JOHN/password\.lst#Wordlist = /usr/share/wordlists/rockyou.txt#' "$jconf"

  # kerbrute — build from source.
  gclone https://github.com/0xZDH/kerbrute.git /opt/tools/kerbrute
  if [[ -d /opt/tools/kerbrute && ! -f /opt/tools/kerbrute/dist/kerbrute_linux_amd64 ]]; then
    run_sh "build kerbrute" "make -C /opt/tools/kerbrute linux"
  fi
  [[ -f /opt/tools/kerbrute/dist/kerbrute_linux_amd64 ]] && \
    symlink /opt/tools/kerbrute/dist/kerbrute_linux_amd64 /opt/tools/bin/kerbrute
}

setup_bloodhound() {
  banner "BloodHound CLI"
  if [[ ! -x /opt/tools/bin/bloodhound-cli ]]; then
    run_sh "download bloodhound-cli" "
      cd /opt/tools/bin &&
      wget -q https://github.com/SpecterOps/bloodhound-cli/releases/latest/download/bloodhound-cli-linux-amd64.tar.gz -O bh.tar.gz &&
      tar -xzf bh.tar.gz && rm -f bh.tar.gz"
  else
    ok "bloodhound-cli binary present"
  fi

  # install/update need a responding Docker daemon — wait briefly for it.
  enable_service docker
  local i
  for i in 1 2 3 4 5; do docker info >/dev/null 2>&1 && break; sleep 2; done
  if ! docker info >/dev/null 2>&1; then
    warn "docker daemon not responding — skipping bloodhound"
    FAILED+=("bloodhound (docker daemon not ready)")
    return 0
  fi

  # 'install' pulls images and resets admin creds — run once (marker) unless
  # --force. It deploys to root's ~/.config/bloodhound.
  if [[ -f /opt/tools/bin/.bloodhound-installed && "$DO_FORCE" != "1" ]]; then
    ok "bloodhound already installed (skip; --force to reinstall)"
  elif [[ -x /opt/tools/bin/bloodhound-cli ]]; then
    run_sh "bloodhound-cli install" \
      "cd /opt/tools/bin && ./bloodhound-cli install && touch /opt/tools/bin/.bloodhound-installed"
  fi

  # Web UI port 8080 -> 8081, then pull the latest images.
  if [[ -d /root/.config/bloodhound ]]; then
    run_sh "bloodhound port 8080 -> 8081" "cd /root/.config/bloodhound && sed -i 's/8080/8081/g' *"
    run_sh "bloodhound-cli update (latest images)" "cd /opt/tools/bin && ./bloodhound-cli update"
  fi

  # Print the default admin login.
  local bhconf=/root/.config/bloodhound/bloodhound.config.json
  if [[ -f "$bhconf" ]]; then
    local bhuser bhpass bhurl
    bhuser="$(jq -r '.default_admin.principal_name // "admin"' "$bhconf" 2>/dev/null)"
    bhpass="$(jq -r '.default_password // .default_admin.password // empty' "$bhconf" 2>/dev/null)"
    bhurl="$(jq -r '.root_url // empty' "$bhconf" 2>/dev/null)"
    if [[ -n "$bhpass" ]]; then
      BH_LOGIN="${bhuser} / ${bhpass}${bhurl:+  ($bhurl)}"
      say "${c_grn}BloodHound login:${c_rst} ${BH_LOGIN}"
    fi
  fi
}

setup_sqlcmd() {
  banner "mssql-tools (sqlcmd)"
  run_sh "add microsoft prod repo" "
    cd /tmp &&
    curl -sSL -O https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb &&
    dpkg -i packages-microsoft-prod.deb &&
    rm -f packages-microsoft-prod.deb"
  run "apt update" apt-get update
  run_sh "install mssql-tools18" "ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev"
  [[ -f /opt/mssql-tools18/bin/sqlcmd ]] && \
    symlink /opt/mssql-tools18/bin/sqlcmd /opt/tools/bin/sqlcmd
}

# cloud — gcloud, kubectl, aws, azure
setup_cloud() {
  banner "Cloud CLIs (gcloud, kubectl, aws, az)"
  apt_install apt-transport-https ca-certificates gnupg curl

  # Google Cloud SDK
  run_sh "gcloud apt key" \
    "curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloud.google.gpg"
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    > /etc/apt/sources.list.d/google-cloud-sdk.list
  ok "wrote google-cloud-sdk.list"

  # Azure CLI
  run_sh "azure apt key" \
    "curl -sLS https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | tee /etc/apt/keyrings/microsoft.gpg >/dev/null && chmod go+r /etc/apt/keyrings/microsoft.gpg"
  cat > /etc/apt/sources.list.d/azure-cli.sources <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: bookworm
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg
EOF
  ok "wrote azure-cli.sources"

  run "apt update" apt-get update
  apt_install google-cloud-cli awscli azure-cli

  # kubectl (latest stable)
  run_sh "install kubectl" "
    cd /opt/tools/bin &&
    curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\" &&
    chmod +x kubectl"
}

setup_pcredz() {
  banner "PCredz"
  gclone https://github.com/lgandx/PCredz.git /opt/tools/PCredz
  if [[ -d /opt/tools/PCredz ]]; then
    run_sh "build PCredz venv" "
      cd /opt/tools/PCredz &&
      python3 -m venv venv &&
      ./venv/bin/pip install -q pcapy-ng"
    # Wrapper instead of editing Pcredz's shebang in place: keeps the clone
    # pristine so update-tools' git pull --ff-only isn't blocked by a dirty tree.
    if [[ -f /opt/tools/PCredz/Pcredz ]]; then
      rm -f /opt/tools/bin/pcredz
      cat > /opt/tools/bin/pcredz <<'EOF'
#!/bin/sh
exec /opt/tools/PCredz/venv/bin/python3 /opt/tools/PCredz/Pcredz "$@"
EOF
      chmod +x /opt/tools/bin/pcredz
      ok "wrote pcredz wrapper -> /opt/tools/bin/pcredz"
    fi
  fi
}

# scripts — personal scripts repo + staging symlinks
setup_scripts() {
  banner "Personal scripts & symlinks"
  gclone https://github.com/Mojo8898/scripts.git /opt/scripts
  if [[ -d /opt/scripts ]]; then
    symlink /opt/scripts/cradle_gen.py            /opt/tools/bin/cradle_gen.py
    symlink /opt/scripts/parse_certipy.py         /opt/tools/bin/parse_certipy.py
    symlink /opt/scripts/scan_machine.py          /opt/tools/bin/scan_machine.py
    symlink /opt/scripts/scan_targets.py          /opt/tools/bin/scan_targets.py
    symlink /opt/scripts/recon_setup/recon_setup.py /opt/tools/bin/recon_setup.py
  fi

  # VMware shared folder — these dangle without the mount.
  symlink /mnt/hgfs/shared/staging "$HOME/staging"
  symlink "$HOME/staging/proxy"    /opt/tools/bin/proxy
  symlink "$HOME/staging/agent"    /opt/tools/bin/agent
  if [[ ! -e /mnt/hgfs/shared/staging ]]; then
    note "Staging symlinks point at /mnt/hgfs/shared/staging (VMware shared folder) which is not mounted here — they are currently dangling."
  fi
}

# tmux — entry at ~/.tmux.conf; its config/ and plugins/ live under ~/.config/tmux.
setup_tmux() {
  banner "tmux config & plugins (~/.tmux.conf + ~/.config/tmux)"
  if [[ ! -f "$REPO_DIR/tmux/tmux.conf" ]]; then
    warn "tmux tree not found in configs repo ($REPO_DIR/tmux) — skipping"
    return 0
  fi
  mkdir -p "$HOME/.config/tmux/config"
  run_sh "install tmux config" "
    cp '$REPO_DIR/tmux/tmux.conf'               '$HOME/.tmux.conf' &&
    cp '$REPO_DIR/tmux/config/options.conf'     '$HOME/.config/tmux/config/options.conf' &&
    cp '$REPO_DIR/tmux/config/keybindings.conf' '$HOME/.config/tmux/config/keybindings.conf' &&
    cp '$REPO_DIR/tmux/config/theme.conf'       '$HOME/.config/tmux/config/theme.conf'"
  # Plugins tmux.conf runs directly; others (@plugin) are fetched by tpm (prefix+I).
  gclone https://github.com/tmux-plugins/tpm                "$HOME/.config/tmux/plugins/tpm"
  gclone https://github.com/MunifTanjim/tmux-mode-indicator "$HOME/.config/tmux/plugins/tmux-mode-indicator"
}

# configs — ~/.zshrc block, ffufrc, snmp.conf, chromium policy, aliasr cheat
setup_configs() {
  banner "Shell & tool configs"

  # --- zsh: inline configs.zsh at the end of /root/.zshrc, so it wins over
  # Kali's stock config. Edit configs.zsh in the repo, not here.
  local zshrc="$HOME/.zshrc" czsh="$REPO_DIR/zsh/configs.zsh" kv val esc prev
  if [[ -f "$czsh" ]]; then
    touch "$zshrc"
    # Keep tokens from a prior block when this run doesn't re-supply them.
    for kv in HTB_TOKEN BH_TOKEN_ID BH_TOKEN_KEY; do
      [[ -n "${!kv}" ]] && continue
      prev="$(sed -n "s|^export $kv=\"\(.*\)\"\$|\1|p" "$zshrc" | tail -n1)"
      [[ -n "$prev" ]] && printf -v "$kv" '%s' "$prev"
    done
    # Replace any previous block, then append the current one.
    sed -i '/^### KALI-SETUP:CONFIGS-START/,/^### KALI-SETUP:CONFIGS-END/d' "$zshrc"
    {
      printf '\n### KALI-SETUP:CONFIGS-START  (managed by kali-setup.sh — edit the repo, not here)\n'
      cat "$czsh"
      printf '### KALI-SETUP:CONFIGS-END\n'
    } >> "$zshrc"
    ok "inlined configs.zsh into $zshrc"
    # Fill tokens (dedicated box; not secret). Escape sed metacharacters so a
    # token with | & \ can't corrupt the line.
    for kv in HTB_TOKEN BH_TOKEN_ID BH_TOKEN_KEY; do
      val="${!kv}"; [[ -z "$val" ]] && continue
      esc="$(printf '%s' "$val" | sed -e 's/[\\&|]/\\&/g')"
      sed -i "s|^export $kv=.*|export $kv=\"$esc\"|" "$zshrc"
      ok "set $kv in ~/.zshrc"
    done
  else
    warn "zsh/configs.zsh not in configs repo — skipping ~/.zshrc block"
  fi

  # --- ffufrc ------------------------------------------------------------- #
  mkdir -p "$HOME/.config/ffuf"
  cat > "$HOME/.config/ffuf/ffufrc" <<'EOF'
[http]
    headers = [
        "User-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
        "Accept: */*",
        "Accept-Encoding: gzip, deflate, br",
        "Accept-Language: en-US,en;q=0.9"
    ]

[general]
    colors = true
    threads = 50

[input]
    ignorewordlistcomments = true
    requestproto = "http"

[matcher]
    status = "all"
EOF
  ok "wrote ~/.config/ffuf/ffufrc"

  # --- snmp.conf: enable MIB loading -------------------------------------- #
  [[ -f /etc/snmp/snmp.conf ]] && run "comment 'mibs :' in snmp.conf" \
    sed -i 's/^\(mibs[[:space:]]*:.*\)$/# \1/' /etc/snmp/snmp.conf

  # --- chromium: silence --no-sandbox command-line warning ---------------- #
  mkdir -p /etc/chromium/policies/managed
  cat > /etc/chromium/policies/managed/command_line_warnings.json <<'EOF'
{
  "CommandLineFlagSecurityWarningsEnabled": false
}
EOF
  ok "wrote chromium managed policy"

  # --- qterminal: 0% transparency (opaque) for root ----------------------- #
  set_qterminal_opaque "$HOME/.config/qterminal.org/qterminal.ini"
  ok "qterminal transparency -> 0 (opaque)"

  # --- aliasr cheat ------------------------------------------------------- #
  # <public_key> is a placeholder — fill it in on the box when needed.
  mkdir -p "$HOME/.cheats"
  cat > "$HOME/.cheats/custom.md" <<'CEOF'
# custom

## Copy private key
```
mkdir ~/.ssh 2>/dev/null; echo '<public_key>' >> ~/.ssh/authorized_keys
```
CEOF
  ok "wrote aliasr cheat to ~/.cheats"

  # Make zsh root's default shell.
  command -v zsh >/dev/null 2>&1 && run "chsh root -> zsh" chsh -s "$(command -v zsh)" root
}

# services — postgres/msfdb
setup_services() {
  banner "Services (postgres / msfdb)"
  enable_service postgresql
  # 'msfdb reinit' wipes the DB — skip if already initialised unless --force.
  if [[ -f "$HOME/.msf4/database.yml" && "$DO_FORCE" != "1" ]]; then
    ok "msfdb already initialised (skip; --force to reinit)"
  else
    run "msfdb reinit" msfdb reinit
  fi
}

# xfce — per-login tweaks: ctrl+alt+t hotkey + no screen blanking (needs X/D-Bus)
setup_xfce() {
  banner "XFCE settings (ctrl+alt+t hotkey, no screen blanking)"
  # xfsettingsd/the power manager own these at runtime, so apply them via
  # xfconf-query from an autostart entry that runs on each XFCE login.
  local P='/commands/custom/<Primary><Alt>t'
  local V='env TMUX_HOTKEY=1 exo-open --launch TerminalEmulator'
  local helper=/usr/local/bin/kali-xfce-settings

  cat > "$helper" <<EOF
#!/bin/sh
# Applied on each XFCE login (idempotent): set the value, else create it.

# ctrl+alt+t -> tmux terminal
xfconf-query -c xfce4-keyboard-shortcuts -p '$P' -s '$V' 2>/dev/null \\
  || xfconf-query -c xfce4-keyboard-shortcuts -p '$P' -n -t string -s '$V'

# Never blank / power off the screen (match daily driver).
for kv in "dpms-enabled bool false" "dpms-on-ac-off uint 0" "dpms-on-ac-sleep uint 0"; do
  set -- \$kv
  xfconf-query -c xfce4-power-manager -p "/xfce4-power-manager/\$1" -s "\$3" 2>/dev/null \\
    || xfconf-query -c xfce4-power-manager -p "/xfce4-power-manager/\$1" -n -t "\$2" -s "\$3"
done
EOF
  chmod +x "$helper"

  mkdir -p "$HOME/.config/autostart"
  cat > "$HOME/.config/autostart/kali-xfce-settings.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Kali XFCE settings
Exec=$helper
OnlyShowIn=XFCE;
NoDisplay=true
X-XFCE-Autostart-Overridden=false
EOF
  ok "xfce settings autostart installed (applies on root's next login)"

  # Apply immediately if this run is inside a live XFCE session.
  if command -v xfconf-query >/dev/null 2>&1 && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    run "apply xfce settings now (live session)" "$helper"
  else
    note "XFCE settings (ctrl+alt+t, no screen blanking) take effect on next XFCE login. To apply now: $helper"
  fi
}

# upgrade — full-upgrade (heavy; runs last)
setup_upgrade() {
  banner "apt full-upgrade (this can take a while)"
  run "apt update" apt-get update

  # Capture output to decide whether a reboot is warranted.
  local out; out="$(mktemp)"
  printf '  → %s\n' "apt full-upgrade"
  if apt-get full-upgrade -y >"$out" 2>&1; then
    ok "apt full-upgrade"
  else
    warn "apt full-upgrade (rc=$?, continuing)"; FAILED+=("apt full-upgrade")
  fi
  cat "$out" >>"$LOGFILE"

  # "Setting up <pkg>" appears only for packages (re)configured this run, so a
  # no-op upgrade matches nothing and triggers no reboot.
  if grep -qE '^Setting up (linux-image|linux-headers|open-vm-tools|libc6|systemd)' "$out"; then
    local hit; hit="$(grep -oE '^Setting up (linux-image|linux-headers|open-vm-tools|libc6|systemd)[^ ]*' "$out" | awk '{print $3}' | sort -u | paste -sd', ')"
    need_reboot "full-upgrade reconfigured reboot-relevant package(s): $hit"
  else
    ok "full-upgrade: no reboot-relevant packages changed — no reboot needed"
  fi
  rm -f "$out"
}

# autologin — root GUI autologin (default on a full run)
setup_autologin() {
  banner "Root autologin"
  # Allow root to autologin under LightDM (its PAM blocks root by default).
  if [[ -f /etc/pam.d/lightdm-autologin ]]; then
    run "allow root in lightdm-autologin pam" \
      sed -i 's/^\(auth\s*required\s*pam_succeed_if.so user != root quiet_success\)/# \1/' \
      /etc/pam.d/lightdm-autologin
  fi
  run "ensure autologin group" bash -c 'groupadd -r autologin 2>/dev/null; gpasswd -a root autologin'
  mkdir -p /etc/lightdm/lightdm.conf.d
  cat > /etc/lightdm/lightdm.conf.d/99-kali-autologin.conf <<'EOF'
[Seat:*]
autologin-user=root
autologin-user-timeout=0
greeter-show-manual-login=true
EOF
  ok "wrote lightdm autologin drop-in"
  note "Root autologin configured. Set a root password first if you haven't: run 'passwd root'."
  need_reboot "root autologin takes effect after reboot"
}

# render_summary <live|postreboot> — the colored summary. 'live' ends a no-reboot
# run; 'postreboot' is stored and shown on the first terminal after the reboot.
render_summary() {
  local mode="$1"
  printf '\n%s============================================================%s\n' "$c_cyn" "$c_rst"
  if [[ "$mode" == postreboot ]]; then
    printf '%s  Kali setup complete — system was rebooted%s\n' "$c_cyn" "$c_rst"
  else
    printf '%s  Kali setup complete%s\n' "$c_cyn" "$c_rst"
  fi
  printf '%s============================================================%s\n\n' "$c_cyn" "$c_rst"
  printf 'Log file: %s\n\n' "$LOGFILE"

  if [[ ${#FAILED[@]} -gt 0 ]]; then
    printf '%sSteps that failed (re-run that section, e.g. --only <section>):%s\n' "$c_red" "$c_rst"
    local f; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
    printf '\n'
  else
    printf '%sAll steps completed without recorded failures.%s\n\n' "$c_grn" "$c_rst"
  fi

  # BloodHound login — the live `say` scrolled away before the reboot.
  [[ "$mode" == postreboot && -n "$BH_LOGIN" ]] && \
    printf '%sBloodHound login:%s %s\n\n' "$c_grn" "$c_rst" "$BH_LOGIN"

  # Full install only — the checklist would mislead on a targeted run.
  if [[ -z "$ONLY" ]]; then
    printf '%sManual steps still required:%s\n' "$c_yel" "$c_rst"
    printf '  - Install browser extensions: FoxyProxy, Wappalyzer, OneTab, Cookie Editor.\n'
    local n; for n in "${NOTES[@]}"; do printf '  - %s\n' "$n"; done
    printf '\n'
  fi

  if [[ "$mode" == postreboot ]]; then
    printf '%sShown on the first terminal opened after the setup reboot.%s\n' "$c_cyn" "$c_rst"
  else
    printf 'Start a fresh zsh shell to pick up the new config:  exec zsh\n'
  fi
}

# install_firstrun_hook — make root's bash/zsh print the stored summary once,
# on the first terminal after reboot (a marker stops it repeating).
install_firstrun_hook() {
  local marker='# kali-setup: post-setup summary (shown once)'
  local line='if [[ $- == *i* && -r '"$FIRSTRUN_FILE"' && ! -e "$HOME/.kali-setup-summary-shown" ]]; then command cat '"$FIRSTRUN_FILE"'; : > "$HOME/.kali-setup-summary-shown" 2>/dev/null; fi'
  local rc
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [[ -e "$rc" ]] || touch "$rc"
    grep -qF "$marker" "$rc" 2>/dev/null || printf '\n%s\n%s\n' "$marker" "$line" >> "$rc"
  done
}

# Summary — printed live, or stored for the first post-reboot terminal.
summary() {
  # Honour a system-flagged reboot too.
  [[ -f /run/reboot-required || -f /var/run/reboot-required ]] && \
    need_reboot "system flagged /run/reboot-required"

  if [[ "$REBOOT_NEEDED" == "1" ]]; then
    install_firstrun_hook
    render_summary postreboot > "$FIRSTRUN_FILE" 2>/dev/null

    banner "Setup complete — rebooting"
    say "A step that requires a reboot ran:"
    local r; for r in "${REBOOT_REASONS[@]}"; do say "  - $r"; done
    say ""
    say "The full summary will appear on the first terminal you open after reboot."
    systemctl reboot 2>/dev/null || reboot
  else
    render_summary live
  fi
  return 0
}

# Dispatcher
in_list() { local x="$1"; shift; local e; for e in "$@"; do [[ "$e" == "$x" ]] && return 0; done; return 1; }

usage() {
  cat <<EOF
kali-setup.sh — provision a fresh Kali pentest box

Options:
  -o, --only  a,b,c   Run only these sections
  -s, --skip  a,b,c   Run everything except these sections
  -f, --force         Re-run stateful steps that otherwise skip when already
                      set up (bloodhound-cli install, msfdb reinit)
  -l, --list          List sections and exit
  -h, --help          Show this help

A full run (no --only) also configures root autologin and reboots at the end.

Sections (in order):
  ${ALL_SECTIONS[*]}
EOF
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o|--only)   ONLY="$2"; shift 2 ;;
      -s|--skip)   SKIP="$2"; shift 2 ;;
      -f|--force)  DO_FORCE=1; shift ;;
      -l|--list)   printf '%s\n' "${ALL_SECTIONS[@]}"; exit 0 ;;
      -h|--help)   usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
  done

  preflight
  resolve_assets

  IFS=',' read -r -a only_arr <<<"$ONLY"
  IFS=',' read -r -a skip_arr <<<"$SKIP"

  local s
  for s in "${ALL_SECTIONS[@]}"; do
    if [[ -n "$ONLY" ]] && ! in_list "$s" "${only_arr[@]}"; then continue; fi
    if [[ -n "$SKIP" ]] && in_list "$s" "${skip_arr[@]}"; then
      say "(skipping $s)"; continue
    fi
    "setup_$s"
  done

  # Full run only: autologin (which also flags the reboot). Targeted runs skip both.
  [[ -z "$ONLY" && -z "$SKIP" ]] && setup_autologin

  summary
}

main "$@"
