# Configs

Configure and update a fresh Kali host to match my personal installation preferences.

Tools, shell, tmux, and desktop tweaks are applied globally for all users.

Full installation requires ~20 GB.

## Quick start

```bash
# Configure
curl -fsSL https://raw.githubusercontent.com/Mojo8898/configs/main/kali-setup.sh | sudo bash

# Configure with autologin and auto-reboot
curl -fsSL https://raw.githubusercontent.com/Mojo8898/configs/main/kali-setup.sh | sudo bash -s -- --autologin --reboot
```

## Options

| Flag | Effect |
|------|--------|
| `--only a,b,c` | Run only these sections |
| `--skip a,b,c` | Run everything except these sections |
| `--ssh-key "KEY"` | Public key for the aliasr "copy private key" cheat |
| `--autologin` | Also configure passwordless root GUI login (off by default) |
| `--force` | Redo stateful steps that otherwise skip (`bloodhound-cli install`, `msfdb reinit`) |
| `--reboot` | Reboot at the end if a step requires one (off by default) |
| `--list` / `-h` | List sections / show help |

Through a pipe: `curl -fsSL <url> | sudo bash -s -- --only apt,go`. The same knobs
exist as env vars (`SSH_PUBKEY`, `HTB_TOKEN`, `BH_TOKEN_ID`, `BH_TOKEN_KEY`,
`DO_AUTOLOGIN`, `DO_FORCE`, `DO_REBOOT`) — pass them after `sudo`, or use `sudo -E`.

## Sections

Run in order; target a subset with `--only`/`--skip` (`--list` to print them):

```
apt base tools vscode python go rust ruby gittools bloodhound
sqlcmd cloud pcredz scripts tmux configs services xfce upgrade
```

## How it works

- **Idempotent, non-aborting.** Safe to re-run; failures are logged and summarized,
  not fatal. Re-run a failed section with `--only <section>`. Logs to `/root/kali-setup.log`.
- **Global, all-users.** Shell, tmux, PATH, and keybinds are installed under `/etc`
  (no per-home copying). Hand-built/curated tools go in `/opt/tools/bin`; package-managed
  tools (uv/go/cargo) go in `/usr/local/bin`.
- **Config lives in this repo** and is the source of truth. kali-setup clones it to
  `/opt/tools/configs` and points the system at it:
  - `zsh/configs.zsh` → sourced from `/etc/zsh/zshrc`
  - `tmux/tmux.conf` → sourced from `/etc/tmux.conf`

  Edit the repo, re-pull (or re-run `--only configs,tmux`), and changes apply. Build
  from a local checkout with `CONFIGS_REPO=/path/to/clone`.
- **Reboot is opt-in.** With `--reboot`, if a step requires one (kernel upgrade or
  `--autologin`) the box reboots at the end and the summary shows on the first
  terminal after reboot. Without it, you get a reminder and reboot yourself.

## Updating

`update-tools.sh` refreshes the installed toolchain (apt packages, uv/go/cargo/ruby
tools, source builds). Run manually as root, not mid-engagement:

```bash
sudo update-tools.sh            # everything
sudo update-tools.sh --only go  # a subset (--list / --help for more)
```

## Notes

- API tokens, when provided, are written into the deployed `configs.zsh` (this is a
  dedicated box — don't `git push` the clone with tokens filled in).
- `--autologin` is passwordless root GUI login — set a root password first (`passwd root`).
- Browser extensions and the `~/staging` VMware mount are manual; see the run summary.
