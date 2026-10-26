# configs.zsh — managed global zsh config, deployed by kali-setup.sh.
# Sourced from /etc/zsh/zshrc, so every user (root, kali, future) inherits it.
# Edit here in the configs repo; re-pull on the box (or --only configs) to apply.
# $HOME-relative paths resolve per user at runtime.

# Exegol-history + Aliasr
function exh { exegol-history "$@" && exec zsh }
function a { aliasr "$@" && exec zsh }
[ -f "$HOME/.exegol_history/profile.sh" ] && source "$HOME/.exegol_history/profile.sh"

# Named uniquely so Kali's per-user ~/.zshrc (which defines its own
# configure_prompt and is sourced after this file) can't shadow ours.
__ks_configure_prompt() {
    local db_prompt=""
    if [[ -n "$USER" ]]; then
        if [[ -n "$DOMAIN" ]]; then
            db_prompt="%F{white}[%F{yellow}${USER}@${DOMAIN}%F{white}]%F{%(#.blue.green)}─"
        else
            db_prompt="%F{white}[%F{yellow}${USER}%F{white}]%F{%(#.blue.green)}─"
        fi
    fi

    case "$PROMPT_ALTERNATIVE" in
        twoline)
            PROMPT=$'%F{%(#.blue.green)}┌──'"${db_prompt}"$'${debian_chroot:+($debian_chroot)─}${VIRTUAL_ENV:+($(basename $VIRTUAL_ENV))─}(%B%F{%(#.red.blue)}%n%b%F{%(#.blue.green)})-[%B%F{reset}%(6~.%-1~/…/%4~.%5~)%b%F{%(#.blue.green)}]\n└─%B%(#.%F{red}#.%F{blue}$)%b%F{reset} '
            ;;
        oneline)
            PROMPT="${db_prompt}"$'${debian_chroot:+($debian_chroot)}${VIRTUAL_ENV:+($(basename $VIRTUAL_ENV))}%B%F{%(#.red.blue)}%n@%m%b%F{reset}:%B%F{%(#.blue.green)}%~%b%F{reset}%(#.#.$) '
            RPROMPT=
            ;;
        backtrack)
            PROMPT="${db_prompt}"$'${debian_chroot:+($debian_chroot)}${VIRTUAL_ENV:+($(basename $VIRTUAL_ENV))}%B%F{red}%n@%m%b%F{reset}:%B%F{blue}%~%b%F{reset}%(#.#.$) '
            RPROMPT=
            ;;
    esac
}

export U="$USER" P="$PASSWORD" N="$NT_HASH" D="$DOMAIN" I="$IP"

# Start terminal in tmux if first launch and from hotkey
if [[ -o interactive ]] && [[ -n "$TMUX_HOTKEY" ]] && [[ -z "$TMUX" ]] && command -v tmux >/dev/null 2>&1; then
    if ! tmux ls >/dev/null 2>&1; then
        tmux new -s initial
    fi
fi

# Aliases
alias ipa='ip --brief --color a;echo;ip r'
alias proxychains='proxychains4 -q'
alias tshark-adhoc='tshark -Q -T fields -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e _ws.col.Protocol -e frame.len -e _ws.col.Info'
alias badpdf.py='python2 /opt/tools/Bad-Pdf/badpdf.py'
alias malicious-pdf.py='/opt/tools/malicious-pdf/venv/bin/python3 /opt/tools/malicious-pdf/malicious-pdf.py'
alias adaptixserver='cd /opt/tools/AdaptixC2/dist && ./adaptixserver -profile profile.json'
alias debug_globals="ls ~/.aliasr.json | entr -p sh -c 'clear; date; jq . ~/.aliasr.json'"
alias code='code --no-sandbox --user-data-dir=$HOME/.vscode'
alias pc='proxychains'
alias sqlite='sqlite3'
alias chromium='chromium --no-sandbox --user-data-dir=$HOME/.config/chromium-profile --disable-features=DisableWebAuthnWithBrokenCerts --ignore-certificate-errors --password-store=basic &> /dev/null & disown'
alias fzf-wordlists='find /opt/lists /usr/share/wordlists /usr/share/wfuzz /usr/share/dirb -type f | fzf'
alias fzf-rules='find /opt/rules/ /usr/share/hashcat/rules/ -type f | fzf'
alias fzf-haiti-hashcat='(){ haiti -e $1 | fzf --ansi | grep -E -o " [0-9]*]" | cut -d "]" -f 1 | cut -d " " -f 2 ;}'
alias fzf-haiti-john='(){ haiti -e $1 | fzf --ansi | grep -E -o "JtR: .*]" | cut -d "]" -f 1 | cut -d " " -f 2 ;}'
alias hcat='(){ if [ -f "$1" ]; then hashcat -m $(fzf-haiti-hashcat $(head -n 1 "$1")) "$1" $(fzf-wordlists) "${@:2}"; elif [ -n "$1" ]; then hashcat -m $(fzf-haiti-hashcat "$1") "$1" $(fzf-wordlists) "${@:2}"; fi ;}'
alias hjohn='(){ if [ -f "$1" ]; then john --format=$(fzf-haiti-john $(head -n 1 "$1")) --wordlist=$(fzf-wordlists) "${@:2}" $1; elif [ -n "$1" ]; then echo "$1" | john --format=$(fzf-haiti-john "$1") --wordlist=$(fzf-wordlists) "${@:2}" /dev/stdin; fi ;}'
alias john='/opt/tools/john/run/john'
alias lh='ls -lh'
alias htb-gui='/opt/tools/htb-gui/.venv/bin/python3 /opt/tools/htb-gui/main.py &> /dev/null & disown'
alias wgcc='x86_64-w64-mingw32-gcc'
alias wdis='x86_64-w64-mingw32-objdump -d -M intel --disassembler-color=on'
alias wdisr='x86_64-w64-mingw32-objdump -dr -M intel --disassembler-color=on'
alias wreloc='x86_64-w64-mingw32-objdump -r'
alias whex='x86_64-w64-mingw32-objdump -s'
alias wdump='x86_64-w64-mingw32-objcopy --dump-section .text='

alias igcc='i686-w64-mingw32-gcc'
alias idis='i686-w64-mingw32-objdump -d -M intel --disassembler-color=on'
alias idisr='i686-w64-mingw32-objdump -dr -M intel --disassembler-color=on'
alias ireloc='i686-w64-mingw32-objdump -r'
alias ihex='i686-w64-mingw32-objdump -s'
alias idump='i686-w64-mingw32-objcopy --dump-section .text='

crystal-demo () {
    rm ./out.bin 2>/dev/null
    crystal-link "$1" /mnt/c/Users/Tester/Desktop/CS/Crystal-Palace/dist/demo/test.x64.dll out.bin
    if [ $? -eq 0 ] && [ -s out.bin ]; then
        /mnt/c/Users/Tester/Desktop/CS/Crystal-Palace/dist/demo/run.x64.exe out.bin
    else
        echo "Build failed or output file is empty"
        return 1
    fi
}
exports() {
    if [ -z "$1" ]; then
        echo "Usage: peexports <pe_file>"
        return 1
    fi
    x86_64-w64-mingw32-objdump -p "$1" | awk '
    /\[Ordinal\/Name Pointer\] Table/,/^$/ {
        if ($0 ~ /Ordinal.*Hint.*Name/) {
            print
        } else if ($NF ~ /[A-Za-z]/) {
            match($0, /[A-Za-z][A-Za-z0-9_]*$/)
            printf "%s\033[1;32m%s\033[0m\n", substr($0, 1, RSTART-1), substr($0, RSTART)
        } else {
            print
        }
    }'
}
imports() {
    if [ -z "$1" ]; then
        echo "Usage: imports <pe_file>"
        return 1
    fi

    x86_64-w64-mingw32-objdump -p "$1" | awk '
    /DLL Name:/ {
        in_block = 1
        dll = $3
        printf "        DLL Name: \033[1;33m%s\033[0m\n", dll
        next
    }
    in_block && NF == 0 {
        print ""
        in_block = 0
        next
    }
    in_block {
        if ($0 ~ /vma:.*Member-Name/) {
            print
            next
        }
        if ($NF ~ /[A-Za-z_]/) {
            name = $NF
            sub(/[A-Za-z_][A-Za-z0-9_@]*$/, "", $0)
            printf "%s\033[1;32m%s\033[0m\n", $0, name
        } else {
            print
        }
        next
    }
    '
}

# Functions
precmd() { if [[ "$NEWLINE_BEFORE_PROMPT" == "yes" ]]; then echo; fi }
mkcd () { mkdir -p $@ && cd ${@:$#} }
psencode(){ printf '%s' "$*" | iconv -t UTF-16LE | base64 -w0; echo; }
nthash(){ printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | openssl dgst -md4 | awk '{print $2}'; }
ffuf-scan() {
    local url="$1"; shift
    local host=$(echo "$url" | sed -E 's|https?://||; s|/.*||; s|:|_|g')
    local ts=$(date +%Y%m%d_%H%M%S)
    local outdir="${FFUF_OUT:-$HOME/ffuf-scans}/$host"
    mkdir -p "$outdir"
    local outfile="$outdir/${ts}_ffuf"
    echo "[*] Output: $outfile.*"
    command ffuf -u "$url" -o "$outfile" -of all "$@"
}
# how: ls -al + file + which for a command
how() {
    if [ -z "$1" ]; then echo "Usage: how <command>"; return 1; fi
    local p; p="$(command -v "$1" 2>/dev/null)"
    if [ -z "$p" ]; then echo "not found: $1"; return 1; fi
    echo "which: $p"
    file "$p"
    [ -e "$p" ] && ls -al "$p"
}

# Export paths
export PATH="/opt/tools/bin:${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"

[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"

# fzf key bindings (Ctrl-R history search, Ctrl-T, Alt-C) + completion, all users
if command -v fzf >/dev/null 2>&1; then
  if fzf --zsh >/dev/null 2>&1; then
    source <(fzf --zsh)
  elif [ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]; then
    source /usr/share/doc/fzf/examples/key-bindings.zsh
    [ -f /usr/share/doc/fzf/examples/completion.zsh ] && source /usr/share/doc/fzf/examples/completion.zsh
  fi
fi

command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh)"

# API tokens — kali-setup.sh fills these in the deployed copy when provided.
export HTB_TOKEN=""
export BH_TOKEN_ID=""
export BH_TOKEN_KEY=""

fpath=($HOME/.zsh/completions $fpath)
autoload -Uz compinit && compinit

setopt SHARE_HISTORY
[[ $- == *i* ]] && stty -ixon

# This file (/etc/zsh/zshrc) is sourced before the per-user ~/.zshrc, which on
# Kali redefines the prompt. Apply ours on the first prompt via a one-shot
# precmd hook so it wins, then unregister.
autoload -Uz add-zsh-hook
__ks_apply_prompt() { __ks_configure_prompt; add-zsh-hook -d precmd __ks_apply_prompt; }
add-zsh-hook precmd __ks_apply_prompt
