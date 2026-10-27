#!/usr/bin/env bash
#
# update-tools.sh — update the toolchain installed by kali-setup.sh.
# Run MANUALLY as root, when not mid-engagement:  sudo update-tools.sh
# See --help for flags. Logs to /root/update-tools.log.
# Do NOT wire this to boot/login — replacing a binary mid-use corrupts it.
#
set -uo pipefail

ALL_SECTIONS=(apt python go rust ruby gittools bloodhound)
ONLY=""
SKIP=""
LOGFILE="/root/update-tools.log"
LOCKFILE="/var/lock/update-tools.lock"
FAILED=()
NOTES=()

c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'

log()  { printf '%s\n' "$*" >>"$LOGFILE" 2>/dev/null || true; }
say()  { printf '%s\n' "$*"; log "$*"; }
ok()   { printf '    %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; log "OK: $*"; }
warn() { printf '    %s✗ %s%s\n' "$c_yel" "$*" "$c_rst"; log "WARN: $*"; }
note() { NOTES+=("$*"); }
banner() {
  say ""
  say "${c_cyn}============================================================${c_rst}"
  say "${c_cyn}  $*${c_rst}"
  say "${c_cyn}============================================================${c_rst}"
}

# run <desc> <cmd...> — never aborts; records failures.
run() {
  local desc="$1"; shift
  printf '  → %s\n' "$desc"
  log "RUN: $desc :: $*"
  if "$@" >>"$LOGFILE" 2>&1; then ok "$desc"; else
    local rc=$?; warn "$desc (rc=$rc, continuing)"; FAILED+=("$desc"); fi
  return 0
}
run_sh() { local desc="$1"; shift; run "$desc" bash -c "$*"; }

# have <cmd> — installed? This script updates, never installs, so it skips
# anything missing (install is kali-setup.sh's job).
have() { command -v "$1" >/dev/null 2>&1; }

# git_update <dir> — pull if it's a repo. Returns 0 if HEAD moved (rebuild
# warranted), 1 if unchanged/failed.
git_update() {
  [[ -d "$1/.git" ]] || { warn "not a repo: $1"; return 1; }
  local before after stashed=0
  before="$(git -C "$1" rev-parse HEAD 2>/dev/null)"
  # Stash tracked edits (e.g. john.conf) so a ff-only pull isn't blocked; restore
  # after. Untracked build output (venv/, dist/) is left alone.
  git -C "$1" diff --quiet 2>/dev/null || { git -C "$1" stash push -q && stashed=1; }
  run_sh "git pull $(basename "$1")" "git -C '$1' pull --ff-only || git -C '$1' pull --ff-only --unshallow"
  [[ "$stashed" == 1 ]] && { git -C "$1" stash pop -q 2>/dev/null || warn "stash pop failed in $(basename "$1") — local tweaks not reapplied"; }
  after="$(git -C "$1" rev-parse HEAD 2>/dev/null)"
  [[ "$before" != "$after" ]]
}

preflight() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Run as root:  sudo update-tools.sh" >&2
    exit 1
  fi
  export HOME=/root USER=root
  : >"$LOGFILE" 2>/dev/null || LOGFILE="/tmp/update-tools.log"
  log "update-tools started $(date -Iseconds)"

  # Same default locations kali-setup.sh installs into, plus the cloned-tools bin.
  export PATH="/opt/tools/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.cargo/bin:/usr/local/go/bin:$PATH"
  export GOPATH="${GOPATH:-$HOME/go}"
  export GOTMPDIR="$HOME/.cache/go-tmp"; mkdir -p "$GOTMPDIR"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
}

setup_apt() {
  banner "apt full-upgrade"
  run "apt update" apt-get update
  local out; out="$(mktemp)"
  printf '  → %s\n' "apt full-upgrade"
  if apt-get full-upgrade -y >"$out" 2>&1; then ok "apt full-upgrade"; else
    warn "apt full-upgrade (rc=$?, continuing)"; FAILED+=("apt full-upgrade"); fi
  cat "$out" >>"$LOGFILE"
  run "apt autoremove" apt-get autoremove -y
  if grep -qE '^Setting up (linux-image|linux-headers|open-vm-tools|libc6|systemd)' "$out"; then
    note "A kernel/open-vm-tools/core package was upgraded — reboot when convenient."
  fi
  rm -f "$out"
}

setup_python() {
  banner "Python tools (uv)"
  have uv || { warn "uv not found — skipping"; FAILED+=("uv (missing)"); return 0; }
  run "uv tool upgrade --all" uv tool upgrade --all
  if have bbot; then run "bbot --install-all-deps" bbot --install-all-deps; else ok "not installed, skipped: bbot"; fi
  if have whatportis; then run_sh "whatportis --update" "yes | whatportis --update"; else ok "not installed, skipped: whatportis"; fi
}

setup_go() {
  banner "Go tools"
  have go || { warn "go not found — skipping"; FAILED+=("go (missing)"); return 0; }
  local g bin
  local go_pkgs=(
    "github.com/sensepost/gowitness@latest"
    "github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
    "github.com/projectdiscovery/httpx/cmd/httpx@latest"
    "github.com/projectdiscovery/vulnx/v2/cmd/vulnx@latest"
  )
  for g in "${go_pkgs[@]}"; do
    bin="$(basename "${g%@*}")"
    if have "$bin"; then run "go install $bin" go install -v "$g"; else ok "not installed, skipped: $bin"; fi
  done
  if have katana; then
    run "go install katana (CGO)" env CGO_ENABLED=1 go install -v \
        github.com/projectdiscovery/katana/cmd/katana@latest
  else
    ok "not installed, skipped: katana"
  fi
  # Template/DB refreshes — installed tools only.
  have nuclei && run "nuclei -up"     nuclei -up
  have nuclei && run "nuclei -ut"     nuclei -ut
  have httpx  && run "httpx -up"      httpx -up
  have vulnx  && run "vulnx --update" vulnx --update
  have katana && run "katana -up"     katana -up
  return 0
}

setup_rust() {
  banner "Rust tools"
  have cargo || { warn "cargo not found — skipping"; FAILED+=("cargo (missing)"); return 0; }
  # Re-install pulls the newest crates.io version (no-op if current).
  if have rusthound-ce; then run "cargo install rusthound-ce" cargo install rusthound-ce; else ok "not installed, skipped: rusthound-ce"; fi
  if have skewrun; then run "cargo install skewrun" cargo install skewrun; else ok "not installed, skipped: skewrun"; fi
}

setup_ruby() {
  banner "Ruby tools"
  have gem || { warn "gem not found — skipping"; FAILED+=("gem (missing)"); return 0; }
  # gem update would install a missing gem, so gate on the installed binary.
  if have haiti; then run "gem update haiti-hash" gem update haiti-hash; else ok "not installed, skipped: haiti-hash"; fi
}

setup_gittools() {
  banner "Git-built tools (pull + rebuild)"
  # Rebuild only when the pull moved HEAD — the builds are expensive.
  # John the Ripper
  if [[ -d /opt/tools/john/.git ]]; then
    if git_update /opt/tools/john; then
      run_sh "rebuild john" "cd /opt/tools/john/src && ./configure && make -s -j\"\$(nproc)\""
    else ok "john unchanged — skip rebuild"; fi
  fi
  # kerbrute
  if [[ -d /opt/tools/kerbrute/.git ]]; then
    if git_update /opt/tools/kerbrute; then
      run_sh "rebuild kerbrute" "make -C /opt/tools/kerbrute linux"
    else ok "kerbrute unchanged — skip rebuild"; fi
  fi
  # fzf (binary only; shell integration is global via `fzf --zsh`)
  if [[ -d /opt/tools/fzf/.git ]]; then
    if git_update /opt/tools/fzf; then
      run "fzf install (bin only)" /opt/tools/fzf/install --bin
    else ok "fzf unchanged — skip reinstall"; fi
  fi
  # PCredz — refresh venv deps every run (pcapy-ng versions independently).
  if [[ -d /opt/tools/PCredz/.git ]]; then
    git_update /opt/tools/PCredz || true
    [[ -x /opt/tools/PCredz/venv/bin/pip ]] && \
      run "PCredz deps" /opt/tools/PCredz/venv/bin/pip install -U pcapy-ng
  fi
}

setup_bloodhound() {
  banner "BloodHound images"
  command -v bloodhound-cli >/dev/null 2>&1 || { warn "bloodhound-cli not found — skipping"; FAILED+=("bloodhound (missing)"); return 0; }
  local i   # needs a responding Docker daemon
  for i in 1 2 3; do docker info >/dev/null 2>&1 && break; systemctl start docker 2>/dev/null; sleep 2; done
  if ! docker info >/dev/null 2>&1; then
    warn "docker daemon not responding — skipping"; FAILED+=("bloodhound (docker down)"); return 0
  fi
  run_sh "bloodhound-cli update" "cd /opt/tools/bin && ./bloodhound-cli update"
}

summary() {
  banner "Done"
  say "Log file: $LOGFILE"
  say ""
  if [[ ${#FAILED[@]} -gt 0 ]]; then
    say "${c_red}Updates that failed (re-run that section, e.g. --only <section>):${c_rst}"
    local f; for f in "${FAILED[@]}"; do say "  - $f"; done
    say ""
  else
    say "${c_grn}All updates completed without recorded failures.${c_rst}"
    say ""
  fi
  local n; for n in "${NOTES[@]}"; do say "  - $n"; done
  return 0
}

in_list() { local x="$1"; shift; local e; for e in "$@"; do [[ "$e" == "$x" ]] && return 0; done; return 1; }

usage() {
  cat <<EOF
update-tools.sh — update the kali-setup.sh toolchain (run manually, as root)

Options:
  -o, --only  a,b,c   Update only these sections
  -s, --skip  a,b,c   Update everything except these sections
  -l, --list          List sections and exit
  -h, --help          Show this help

Sections (in order):
  ${ALL_SECTIONS[*]}

Do NOT run this on boot/login or while actively using the tools.
EOF
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o|--only) ONLY="$2"; shift 2 ;;
      -s|--skip) SKIP="$2"; shift 2 ;;
      -l|--list) printf '%s\n' "${ALL_SECTIONS[@]}"; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
  done

  # Serialize before preflight truncates the log — refuse if another run holds the lock.
  exec 9>"$LOCKFILE" || { echo "cannot open lock $LOCKFILE" >&2; exit 1; }
  if ! flock -n 9; then
    echo "Another update-tools run holds $LOCKFILE — exiting." >&2
    exit 1
  fi

  preflight

  IFS=',' read -r -a only_arr <<<"$ONLY"
  IFS=',' read -r -a skip_arr <<<"$SKIP"
  local s
  for s in "${ALL_SECTIONS[@]}"; do
    [[ -n "$ONLY" ]] && ! in_list "$s" "${only_arr[@]}" && continue
    [[ -n "$SKIP" ]] && in_list "$s" "${skip_arr[@]}" && { say "(skipping $s)"; continue; }
    "setup_$s"
  done

  summary
}

main "$@"
