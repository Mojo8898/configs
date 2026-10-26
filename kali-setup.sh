#!/usr/bin/env bash
#
# kali-setup.sh — fresh Kali pentest environment provisioning.
# Run as root on a fresh host:  curl -s <raw_github_link> | bash
# See --help for flags. Idempotent, non-interactive, logs to /root/kali-setup.log.
# With --reboot, reboots at the end if a step requires it; the summary then
# prints on the first terminal opened after reboot.
#
set -uo pipefail

# Config (override via env or flags)
HTB_TOKEN="${HTB_TOKEN:-}"            # HackTheBox token  -> written into configs.zsh
BH_TOKEN_ID="${BH_TOKEN_ID:-}"        # BloodHound token id -> configs.zsh
BH_TOKEN_KEY="${BH_TOKEN_KEY:-}"      # BloodHound token key -> configs.zsh

# Config assets repo — the trees kali-setup deploys (zsh/, tmux/, ...). Cloned to
# REPO_DIR; every config section installs from there. Point CONFIGS_REPO at a
# local path to build from an unpushed checkout.
CONFIGS_REPO="${CONFIGS_REPO:-https://github.com/Mojo8898/configs.git}"
REPO_DIR=/opt/tools/configs
DO_AUTOLOGIN="${DO_AUTOLOGIN:-0}"     # 1 = configure root autologin (off by default)
DO_FORCE="${DO_FORCE:-0}"             # 1 = re-run stateful steps that otherwise skip (bloodhound, msfdb)
DO_REBOOT="${DO_REBOOT:-0}"           # 1 = reboot at the end if a step requires one

# mongosh resolves to the newest GitHub release (via the releases/latest tag),
# falling back to this known-good pinned bundled .deb if the lookup fails.
MONGOSH_DEB_URL="https://downloads.mongodb.com/compass/mongodb-mongosh_2.14.0_amd64.deb"  # fallback
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
FIRSTRUN_FILE="/var/lib/kali-setup/firstrun"   # world-readable; shown once per user
FAILED=()
NOTES=()
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

# append_block <file> <marker>  (content on stdin) — append once only.
append_block() {
  local file="$1" marker="$2" content
  content="$(cat)"
  touch "$file"
  if grep -qF "$marker" "$file" 2>/dev/null; then
    ok "block already in $(basename "$file")"
    return 0
  fi
  printf '\n%s\n' "$content" >>"$file"
  ok "appended block to $(basename "$file")"
}

enable_service() {
  run "enable service: $1" systemctl enable --now "$1"
}

# gh_latest_tag <owner/repo> — newest release tag via the releases/latest
# redirect on github.com (not the rate-limited api.github.com). Empty on failure.
gh_latest_tag() {
  curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/$1/releases/latest" 2>/dev/null \
    | sed -n 's#.*/releases/tag/##p'
}

# set_qterminal_opaque <qterminal.ini-path> — TerminalTransparency=0 (opaque).
# Kali's default terminal is qterminal (QSettings INI), not xfce4-terminal.
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

# seed_homes <relpath> — copy /etc/skel/<relpath> into every EXISTING home too,
# owned by that home's user. Only for configs with no system-wide location
# (ffuf, aliasr, .hushlogin): /etc/skel handles future users, this handles
# current ones. Everything with an /etc location uses that instead.
seed_homes() {
  local rel="$1" h owner
  [[ -e "/etc/skel/$rel" ]] || return 0
  for h in /root /home/*; do
    [[ -d "$h" ]] || continue
    mkdir -p "$(dirname "$h/$rel")"
    cp -f "/etc/skel/$rel" "$h/$rel"
    owner="$(stat -c %U "$h" 2>/dev/null)"
    [[ -n "$owner" ]] && chown "$owner:$(id -gn "$owner" 2>/dev/null || echo "$owner")" "$h/$rel" 2>/dev/null
  done
  ok "seeded $rel into existing homes"
}

# resolve_assets — clone/refresh the config assets repo into REPO_DIR. Every
# config section (configs, tmux, ...) installs from there, so this runs once up
# front. CONFIGS_REPO may be a URL or a local path (unpushed checkout).
resolve_assets() {
  banner "Config assets ($CONFIGS_REPO)"
  if [[ -d "$REPO_DIR/.git" ]]; then
    # Stash local edits (the token values written into configs.zsh) so a ff-only
    # pull isn't blocked by a dirty worktree; restore them after.
    local stashed=0
    git -C "$REPO_DIR" diff --quiet 2>/dev/null || { git -C "$REPO_DIR" stash push -q && stashed=1; }
    run "refresh configs repo" git -C "$REPO_DIR" pull --ff-only
    [[ "$stashed" == 1 ]] && { git -C "$REPO_DIR" stash pop -q 2>/dev/null || warn "configs stash pop failed — token values may need re-applying (--only configs)"; }
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

  # PATH that covers everything we install, for this non-interactive run.
  # /usr/local/bin is explicit: managed tools (uv/go/cargo) land there, and
  # sudo's secure_path may omit it, so post-install hooks (bbot, nuclei -up, …)
  # that call those tools by name would 127 if we relied on inheritance.
  export PATH="/opt/tools/bin:/usr/local/bin:/usr/local/sbin:$HOME/.local/bin:$HOME/go/bin:$HOME/.cargo/bin:/usr/local/go/bin:$PATH"
  export GOPATH="${GOPATH:-$HOME/go}"

  # Install tool binaries into a shared /opt/tools/bin (on every user's PATH via
  # the configs section) so root, kali, and any other user can run them.
  export UV_TOOL_DIR=/opt/uv               # uv tool venvs (shared, world-readable)
  export UV_TOOL_BIN_DIR=/usr/local/bin   # uv tool executables (managed -> /usr/local/bin)
  export GOBIN=/usr/local/bin             # go install drops binaries here (managed)

  # Core directories a lot of later steps assume.
  mkdir -p /opt/tools/bin /opt/lists /opt/scripts /opt/uv \
           "$HOME/.config/ffuf" "$HOME/.vscode" \
           /etc/apt/keyrings

  # .hushlogin early: preflight always runs (even under --only/--skip), so MOTD
  # is suppressed before any later section spawns a shell and dumps the login
  # banner into the log. /etc/skel (future users) + every existing home.
  mkdir -p /etc/skel
  touch /etc/skel/.hushlogin
  seed_homes .hushlogin

  info "Refreshing apt and installing prerequisites (toolchains, etc.)..."
  run "apt update" apt-get update
  # Toolchains/utilities that later sections depend on but the notes assume present.
  apt_install git curl wget gnupg ca-certificates apt-transport-https \
              zsh tmux build-essential pkg-config \
              golang-go rustc cargo ruby ruby-dev \
              python3 python3-venv python3-pip pipx \
              direnv entr fzf seclists wordlists

  # Record the Go version for the log (Go builds redirect scratch to $GOTMPDIR
  # in the go section to avoid filling a small /tmp tmpfs).
  log "go version: $(go version 2>/dev/null | awk '{print $3}')"
}

# apt — purge/replace + main package set
setup_apt() {
  banner "APT packages"
  run "purge netexec/impacket-scripts (reinstalled via uv)" \
      apt-get purge -y netexec impacket-scripts

  # docker.io = daemon only on current Kali/Debian; docker-cli provides the
  # `docker` command (the piece that was missing). docker-compose provides
  # Compose v2.
  apt_install libreoffice gcc python3-dev libkrb5-dev krb5-pkinit krb5-user \
              rlwrap docker.io docker-cli docker-compose \
              putty jq build-essential gitleaks testssl.sh \
              pkg-config libssl-dev zlib1g-dev libgmp-dev libpcap-dev \
              libbz2-dev sshuttle faketime rdate sshpass evil-winrm-py

  run "apt autoremove" apt-get autoremove -y

  # Docker needs to be up before bloodhound-cli install later.
  enable_service docker
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
    # Resolve the latest tag via the releases/latest redirect, then build the
    # bundled-deb URL (mongodb-mongosh_<ver>_amd64.deb — not the shared-openssl
    # variants). Fall back to the pin if the tag lookup fails.
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

  # Install uv itself into /usr/local/bin (on PATH + secure_path, all users) so
  # it's always resolvable — not a per-user ~/.local/bin that isn't on PATH.
  if [[ ! -x /usr/local/bin/uv ]]; then
    run_sh "install uv" \
      "curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh"
    hash -r
  else
    ok "uv already installed"
  fi

  if ! command -v uv >/dev/null 2>&1; then
    warn "uv unavailable — skipping all uv tools"
    FAILED+=("uv (not installed)")
    return 0
  fi

  # Each entry is passed through word-splitting intentionally (some have flags).
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
  )
  for t in "${uv_tools[@]}"; do
    run "uv tool install $t" uv tool install $t
  done

  run "bbot --install-all-deps" bbot --install-all-deps
  # whatportis --update prompts [y/N]; feed 'y' so it doesn't abort headless.
  run_sh "whatportis --update" "yes | whatportis --update"
}

# go
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

# rust
setup_rust() {
  banner "Rust tooling"
  command -v cargo >/dev/null 2>&1 || { warn "cargo not found — skipping"; FAILED+=("cargo (not installed)"); return 0; }
  # --root /usr/local puts binaries in /usr/local/bin (managed; on PATH by default).
  run "cargo install rusthound-ce" cargo install --root /usr/local rusthound-ce
  run "cargo install skewrun"      cargo install --root /usr/local skewrun
}

# ruby
setup_ruby() {
  banner "Ruby tooling"
  command -v gem >/dev/null 2>&1 || { warn "gem not found — skipping"; FAILED+=("gem (not installed)"); return 0; }
  run "gem install haiti-hash" gem install haiti-hash
}

# gittools — fzf, john, kerbrute
setup_gittools() {
  banner "Git-built tools (fzf, john, kerbrute)"

  # fzf — shared binary in /opt (on the global PATH); the shell integration
  # (Ctrl-R, Ctrl-T, Alt-C) is sourced globally from /etc/zsh/zshrc via
  # `fzf --zsh`, so build the binary only — no per-home ~/.fzf.zsh.
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
  # Default wordlist -> rockyou (idempotent). Edits a tracked file; update-tools
  # stashes local changes around its git pull so this doesn't block updates.
  local jconf=/opt/tools/john/run/john.conf
  [[ -f "$jconf" ]] && run "john.conf default wordlist -> rockyou" \
    sed -i 's#^Wordlist = \$JOHN/password\.lst#Wordlist = /usr/share/wordlists/rockyou.txt#' "$jconf"

  # kerbrute — build from source (explicit dest fixes the clone-into-cwd bug).
  gclone https://github.com/0xZDH/kerbrute.git /opt/tools/kerbrute
  if [[ -d /opt/tools/kerbrute && ! -f /opt/tools/kerbrute/dist/kerbrute_linux_amd64 ]]; then
    run_sh "build kerbrute" "make -C /opt/tools/kerbrute linux"
  fi
  [[ -f /opt/tools/kerbrute/dist/kerbrute_linux_amd64 ]] && \
    symlink /opt/tools/kerbrute/dist/kerbrute_linux_amd64 /opt/tools/bin/kerbrute

  # testssl.sh is installed from apt (see the apt section).
}

# bloodhound
setup_bloodhound() {
  banner "BloodHound CLI"
  # docker.io is installed and enabled by the apt section.
  # Fetch the CLI binary if missing (idempotent).
  if [[ ! -x /opt/tools/bin/bloodhound-cli ]]; then
    run_sh "download bloodhound-cli" "
      cd /opt/tools/bin &&
      wget -q https://github.com/SpecterOps/bloodhound-cli/releases/latest/download/bloodhound-cli-linux-amd64.tar.gz -O bh.tar.gz &&
      tar -xzf bh.tar.gz && rm -f bh.tar.gz"
  else
    ok "bloodhound-cli binary present"
  fi

  # install/update both need a responding Docker daemon — wait briefly in case
  # it's still coming up after the apt section installed/enabled it.
  enable_service docker
  local i
  for i in 1 2 3 4 5; do docker info >/dev/null 2>&1 && break; sleep 2; done
  if ! docker info >/dev/null 2>&1; then
    warn "docker daemon not responding — skipping bloodhound"
    FAILED+=("bloodhound (docker daemon not ready)")
    return 0
  fi

  # 'install' pulls images and resets admin creds, so run it once only unless
  # --force. A marker records a successful install. bloodhound-cli writes its
  # deployment to the invoking user's ~/.config/bloodhound (here: root).
  if [[ -f /opt/tools/bin/.bloodhound-installed && "$DO_FORCE" != "1" ]]; then
    ok "bloodhound already installed (skip; --force to reinstall)"
  elif [[ -x /opt/tools/bin/bloodhound-cli ]]; then
    run_sh "bloodhound-cli install" \
      "cd /opt/tools/bin && ./bloodhound-cli install && touch /opt/tools/bin/.bloodhound-installed"
  fi

  # Web UI port 8080 -> 8081 (needs sed -i; a bare sed only prints, it doesn't
  # edit), then pull the truly-latest images with `update`.
  if [[ -d /root/.config/bloodhound ]]; then
    run_sh "bloodhound port 8080 -> 8081" "cd /root/.config/bloodhound && sed -i 's/8080/8081/g' *"
    run_sh "bloodhound-cli update (latest images)" "cd /opt/tools/bin && ./bloodhound-cli update"
  fi

  # Print the default admin login from the deployed config.
  local bhconf=/root/.config/bloodhound/bloodhound.config.json
  if [[ -f "$bhconf" ]]; then
    local bhuser bhpass bhurl
    bhuser="$(jq -r '.default_admin.principal_name // "admin"' "$bhconf" 2>/dev/null)"
    bhpass="$(jq -r '.default_password // .default_admin.password // empty' "$bhconf" 2>/dev/null)"
    bhurl="$(jq -r '.root_url // empty' "$bhconf" 2>/dev/null)"
    [[ -n "$bhpass" ]] && \
      say "${c_grn}BloodHound login:${c_rst} ${bhuser} / ${bhpass}${bhurl:+  ($bhurl)}"
  fi
}

# sqlcmd (mssql-tools)
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

# pcredz
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

  # Host-specific (VMware shared folder). These will dangle without the mount.
  symlink /mnt/hgfs/shared/staging "$HOME/staging"
  symlink "$HOME/staging/proxy"    /opt/tools/bin/proxy
  symlink "$HOME/staging/agent"    /opt/tools/bin/agent
  if [[ ! -e /mnt/hgfs/shared/staging ]]; then
    note "Staging symlinks point at /mnt/hgfs/shared/staging (VMware shared folder) which is not mounted here — they are currently dangling."
  fi
}

# tmux — global config + plugins, sourced live from the configs repo.
# tmux reads /etc/tmux.conf for every user; we make that a one-line source of
# the repo's tmux.conf (REPO_DIR/tmux/tmux.conf), which sets its own base dir.
# Edits to the repo apply on the next tmux server start — no copy/rewrite.
# tpm plugins install under REPO_DIR/tmux/plugins (gitignored in the repo).
setup_tmux() {
  banner "tmux config & plugins (global /etc/tmux.conf -> configs repo)"
  if [[ ! -f "$REPO_DIR/tmux/tmux.conf" ]]; then
    warn "tmux tree not found in configs repo ($REPO_DIR/tmux) — skipping"
    return 0
  fi
  printf 'source "%s/tmux/tmux.conf"\n' "$REPO_DIR" > /etc/tmux.conf
  ok "wrote /etc/tmux.conf -> source $REPO_DIR/tmux/tmux.conf"
  # Pre-install the plugins tmux.conf runs directly (tpm + mode-indicator);
  # others declared via @plugin are fetched by tpm (prefix+I).
  gclone https://github.com/tmux-plugins/tpm                "$REPO_DIR/tmux/plugins/tpm"
  gclone https://github.com/MunifTanjim/tmux-mode-indicator "$REPO_DIR/tmux/plugins/tmux-mode-indicator"
  chmod -R a+rX "$REPO_DIR/tmux/plugins" /etc/tmux.conf 2>/dev/null || true
}

# configs — zshrc, ffufrc, snmp.conf, chromium policy, aliasr cheats
setup_configs() {
  banner "Shell & tool configs"

  # --- global zsh config (all users) -------------------------------------- #
  # Managed config lives in the configs repo ($REPO_DIR/zsh/configs.zsh) and is
  # sourced from /etc/zsh/zshrc, inherited by every user. Edit it in the repo,
  # not here.
  if [[ -f "$REPO_DIR/zsh/configs.zsh" ]]; then
    append_block /etc/zsh/zshrc "### KALI-SETUP:ZSHRC-SOURCE" <<EOF
### KALI-SETUP:ZSHRC-SOURCE  (managed by kali-setup.sh)
[ -r "$REPO_DIR/zsh/configs.zsh" ] && source "$REPO_DIR/zsh/configs.zsh"
EOF
    ok "global zsh config sourced from $REPO_DIR/zsh/configs.zsh"
  else
    warn "zsh/configs.zsh not in configs repo — skipping global zsh config"
  fi

  # Tokens -> written straight into the deployed configs.zsh (dedicated box;
  # not secret here). resolve_assets stashes this local edit around its pull.
  local czsh="$REPO_DIR/zsh/configs.zsh" kv var val
  if [[ -f "$czsh" ]]; then
    for kv in "HTB_TOKEN=$HTB_TOKEN" "BH_TOKEN_ID=$BH_TOKEN_ID" "BH_TOKEN_KEY=$BH_TOKEN_KEY"; do
      var="${kv%%=*}"; val="${kv#*=}"
      [[ -z "$val" ]] && continue
      sed -i "s|^export $var=.*|export $var=\"$val\"|" "$czsh"
      ok "set $var in configs.zsh"
    done
  fi

  # --- ffufrc (no system-wide location; seed /etc/skel for all users) ---- #
  mkdir -p /etc/skel/.config/ffuf
  cat > /etc/skel/.config/ffuf/ffufrc <<'EOF'
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
  ok "wrote ffufrc to /etc/skel"
  seed_homes .config/ffuf/ffufrc   # ffuf has no /etc config path — reach current users too

  # --- snmp.conf: enable MIB loading -------------------------------------- #
  [[ -f /etc/snmp/snmp.conf ]] && run "comment 'mibs :' in snmp.conf" \
    sed -i 's/^\(mibs[[:space:]]*:.*\)$/# \1/' /etc/snmp/snmp.conf

  # --- chromium root support ---------------------------------------------- #
  mkdir -p /etc/chromium/policies/managed
  cat > /etc/chromium/policies/managed/command_line_warnings.json <<'EOF'
{
  "CommandLineFlagSecurityWarningsEnabled": false
}
EOF
  ok "wrote chromium managed policy"

  # --- qterminal: 0% transparency (opaque), system-wide default ---------- #
  # Kali's default terminal is qterminal; TerminalTransparency=0 = opaque.
  set_qterminal_opaque /etc/xdg/qterminal.org/qterminal.ini
  ok "qterminal transparency -> 0 (opaque; system default /etc/xdg)"

  # --- system-wide PATH so every user gets the shared /opt tools --------- #
  cat > /etc/profile.d/zz-pentest-tools.sh <<'EOF'
# kali-setup.sh — shared pentest tools on PATH for all users
export PATH="/opt/tools/bin:$PATH"
EOF
  # zsh reads zshenv on every invocation (login or not); add it there too.
  if [[ -d /etc/zsh ]]; then
    grep -q '/opt/tools/bin' /etc/zsh/zshenv 2>/dev/null || \
      printf '\nexport PATH="/opt/tools/bin:$PATH"\n' >> /etc/zsh/zshenv
  fi
  # Make the shared tool trees readable/executable by every user.
  chmod -R a+rX /opt/tools /opt/uv 2>/dev/null || true
  ok "shared tools on PATH for all users (/opt/tools/bin)"

  # Put /opt/tools/bin on sudo's secure_path so `sudo <tool>` resolves. Written
  # as a validated drop-in; a bad sudoers file breaks sudo, so install only if
  # visudo accepts it.
  local sd=/etc/sudoers.d/kali-setup-path tmp
  tmp="$(mktemp)"
  printf 'Defaults secure_path="/opt/tools/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n' > "$tmp"
  if visudo -cf "$tmp" >/dev/null 2>&1; then
    install -m 0440 "$tmp" "$sd"
    ok "added /opt/tools/bin to sudo secure_path"
  else
    warn "sudoers drop-in failed validation — not installed"
    FAILED+=("sudo secure_path")
  fi
  rm -f "$tmp"

  # --- aliasr cheat (no system-wide location; seed /etc/skel) ------------ #
  # <public_key> is a fixed placeholder — fill it in on the box when needed.
  mkdir -p /etc/skel/.cheats
  cat > /etc/skel/.cheats/custom.md <<'CEOF'
# custom

## Copy private key
```
mkdir ~/.ssh 2>/dev/null; echo '<public_key>' >> ~/.ssh/authorized_keys
```
CEOF
  ok "wrote aliasr cheat to /etc/skel"
  seed_homes .cheats/custom.md     # aliasr has no /etc config path — reach current users too

  # Make zsh the default shell for root.
  command -v zsh >/dev/null 2>&1 && run "chsh root -> zsh" chsh -s "$(command -v zsh)" root
}

# services — postgres/msfdb
setup_services() {
  banner "Services (postgres / msfdb)"
  enable_service postgresql
  # 'msfdb reinit' wipes an existing DB, so skip if already initialised unless --force.
  if [[ -f "$HOME/.msf4/database.yml" && "$DO_FORCE" != "1" ]]; then
    ok "msfdb already initialised (skip; --force to reinit)"
  else
    run "msfdb reinit" msfdb reinit
  fi
}

# xfce — tmux hotkey (needs a live X / D-Bus session)
setup_xfce() {
  banner "XFCE tmux hotkey (ctrl+alt+t)"
  # Editing the keyboard-shortcuts XML directly doesn't stick: xfsettingsd owns
  # it at runtime and rewrites it from memory. Instead, apply the shortcut via
  # xfconf-query (the live API) from an autostart entry that runs on every XFCE
  # login — for every user, and surviving xfsettingsd rewrites.
  local P='/commands/custom/<Primary><Alt>t'
  local V='env TMUX_HOTKEY=1 exo-open --launch TerminalEmulator'

  cat > /usr/local/bin/kali-xfce-keybind <<EOF
#!/bin/sh
# Set ctrl+alt+t to open a tmux terminal (idempotent). Runs per XFCE login.
xfconf-query -c xfce4-keyboard-shortcuts -p '$P' -s '$V' 2>/dev/null \\
  || xfconf-query -c xfce4-keyboard-shortcuts -p '$P' -n -t string -s '$V'
EOF
  chmod +x /usr/local/bin/kali-xfce-keybind

  mkdir -p /etc/xdg/autostart
  cat > /etc/xdg/autostart/kali-xfce-keybind.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Kali tmux hotkey
Exec=/usr/local/bin/kali-xfce-keybind
OnlyShowIn=XFCE;
NoDisplay=true
X-XFCE-Autostart-Overridden=false
EOF
  ok "xfce ctrl+alt+t keybind autostart installed (applies on next login, all users)"

  # If this run is inside a live XFCE session, apply it immediately too.
  if command -v xfconf-query >/dev/null 2>&1 && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    run "apply xfce keybind now (live session)" /usr/local/bin/kali-xfce-keybind
  else
    note "ctrl+alt+t keybind takes effect on next XFCE login. To apply in the current session: /usr/local/bin/kali-xfce-keybind"
  fi
}

# upgrade — full-upgrade (heavy; runs last)
setup_upgrade() {
  banner "apt full-upgrade (this can take a while)"
  run "apt update" apt-get update

  # Capture the upgrade output so we can decide whether a reboot is warranted
  # (only if a reboot-relevant package was actually (re)configured).
  local out; out="$(mktemp)"
  printf '  → %s\n' "apt full-upgrade"
  if apt-get full-upgrade -y >"$out" 2>&1; then
    ok "apt full-upgrade"
  else
    warn "apt full-upgrade (rc=$?, continuing)"; FAILED+=("apt full-upgrade")
  fi
  cat "$out" >>"$LOGFILE"

  # "Setting up <pkg>" appears only for packages actually installed/upgraded in
  # this run, so a no-op upgrade matches nothing and triggers no reboot.
  if grep -qE '^Setting up (linux-image|linux-headers|open-vm-tools|libc6|systemd)' "$out"; then
    local hit; hit="$(grep -oE '^Setting up (linux-image|linux-headers|open-vm-tools|libc6|systemd)[^ ]*' "$out" | awk '{print $3}' | sort -u | paste -sd', ')"
    need_reboot "full-upgrade reconfigured reboot-relevant package(s): $hit"
  else
    ok "full-upgrade: no reboot-relevant packages changed — no reboot needed"
  fi
  rm -f "$out"
}

# autologin — root GUI autologin (opt-in via --autologin)
setup_autologin() {
  banner "Root autologin (opt-in)"
  # Allow root to autologin under LightDM.
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

# render_summary <live|postreboot> — the colored summary, printed to stdout.
# Wording differs: 'live' ends on a run that did not reboot; 'postreboot' is
# what gets stored and shown on the first terminal after an automatic reboot.
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

  # Only on a full install — a --only run isn't a complete setup, so the
  # "manual steps" checklist would be misleading there.
  if [[ -z "$ONLY" ]]; then
    printf '%sManual steps still required:%s\n' "$c_yel" "$c_rst"
    printf '  - Install browser extensions: FoxyProxy, Wappalyzer, OneTab, Cookie Editor.\n'
    [[ "$DO_AUTOLOGIN" != "1" ]] && \
      printf '  - Root autologin NOT configured (re-run with --autologin to enable).\n'
    local n; for n in "${NOTES[@]}"; do printf '  - %s\n' "$n"; done
    printf '\n'
  fi

  if [[ "$mode" == postreboot ]]; then
    printf '%sShown once per user, on the first terminal after the setup reboot.%s\n' "$c_cyn" "$c_rst"
  else
    printf 'Start a fresh zsh shell to pick up the new config:  exec zsh\n'
  fi
}

# install_firstrun_hook — add a system-wide line (sourced by every user's
# interactive bash/zsh) that prints the stored summary on that user's first
# terminal, then drops a per-user marker so it never repeats. Whichever user
# opens a terminal first after the reboot sees it; the shared file is
# world-readable so it works for root, kali, or any other user.
install_firstrun_hook() {
  local marker='# kali-setup: post-setup summary (shown once per user)'
  local line='if [[ $- == *i* && -r '"$FIRSTRUN_FILE"' && ! -e "$HOME/.kali-setup-summary-shown" ]]; then command cat '"$FIRSTRUN_FILE"'; : > "$HOME/.kali-setup-summary-shown" 2>/dev/null; fi'
  local rc
  for rc in /etc/zsh/zshrc /etc/bash.bashrc; do
    [[ -e "$rc" ]] || touch "$rc"
    grep -qF "$marker" "$rc" 2>/dev/null || printf '\n%s\n%s\n' "$marker" "$line" >> "$rc"
  done
}

# Summary — printed live, or stored for the first post-reboot terminal.
summary() {
  # Honour a system-flagged reboot in addition to our explicit triggers.
  [[ -f /run/reboot-required || -f /var/run/reboot-required ]] && \
    need_reboot "system flagged /run/reboot-required"

  if [[ "$REBOOT_NEEDED" == "1" && "$DO_REBOOT" == "1" ]]; then
    install_firstrun_hook
    mkdir -p "$(dirname "$FIRSTRUN_FILE")"
    render_summary postreboot > "$FIRSTRUN_FILE" 2>/dev/null
    chmod 0755 "$(dirname "$FIRSTRUN_FILE")" 2>/dev/null
    chmod 0644 "$FIRSTRUN_FILE" 2>/dev/null

    banner "Setup complete — rebooting (--reboot)"
    say "A step that requires a reboot ran:"
    local r; for r in "${REBOOT_REASONS[@]}"; do say "  - $r"; done
    say ""
    say "The full summary will appear on the first terminal you open after reboot."
    systemctl reboot 2>/dev/null || reboot
  else
    render_summary live
    [[ "$REBOOT_NEEDED" == "1" ]] && \
      say "${c_yel}A reboot is recommended. Re-run with --reboot, or reboot manually.${c_rst}"
  fi
  return 0
}

# Dispatcher
in_list() { local x="$1"; shift; local e; for e in "$@"; do [[ "$e" == "$x" ]] && return 0; done; return 1; }

usage() {
  cat <<EOF
kali-setup.sh — provision a fresh Kali pentest box

Options:
  --only  a,b,c     Run only these sections
  --skip  a,b,c     Run everything except these sections
  --autologin       Also configure root GUI autologin (off by default)
  --force           Re-run stateful steps that otherwise skip when already
                    set up (bloodhound-cli install, msfdb reinit)
  --reboot          Reboot at the end if a step requires one
  --list            List sections and exit
  -h, --help        Show this help

Sections (in order):
  ${ALL_SECTIONS[*]}
EOF
}

main() {
  # Parse args.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only)      ONLY="$2"; shift 2 ;;
      --skip)      SKIP="$2"; shift 2 ;;
      --autologin) DO_AUTOLOGIN=1; shift ;;
      --force)     DO_FORCE=1; shift ;;
      --reboot)    DO_REBOOT=1; shift ;;
      --list)      printf '%s\n' "${ALL_SECTIONS[@]}"; exit 0 ;;
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

  [[ "$DO_AUTOLOGIN" == "1" ]] && setup_autologin

  summary
}

main "$@"
