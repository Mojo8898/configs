# Configs

Configure and update a fresh Kali host to match my personal preferences.

Everything is set up in root's own account; this box is always run as root.
Full installation needs ~20 GB.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/Mojo8898/configs/main/kali-setup.sh | sudo bash
```

A complete run (no `--only`/`--skip`) also configures root autologin and reboots
at the end. The run summary then shows on the first terminal after reboot.

## Options

| Flag | Effect |
|------|--------|
| `-o, --only a,b,c` | Run only these sections |
| `-s, --skip a,b,c` | Run everything except these sections |
| `-f, --force` | Redo stateful steps that otherwise skip (`bloodhound-cli install`, `msfdb reinit`) |
| `-l, --list` / `-h` | List sections / show help |

Through a pipe: `curl -fsSL <url> | sudo bash -s -- --only apt,go`. Any targeted
run (`--only` or `--skip`) skips autologin and the reboot. Tokens can be passed as env vars
(`HTB_TOKEN`, `BH_TOKEN_ID`, `BH_TOKEN_KEY`) after `sudo`, or with `sudo -E`.

## Sections

Run in order; target a subset with `--only`/`--skip` (`--list` to print them):

```
apt base tools vscode python go rust ruby gittools bloodhound
sqlcmd cloud pcredz scripts tmux configs services xfce upgrade
```

## How it works

- Runs as root with default locations. Config goes into root's home: zsh into
  `/root/.zshrc`, tmux into `/root/.tmux.conf` and `~/.config/tmux`,
  ffufrc/cheats/etc. into `/root`. No global `/etc` user config, no `/etc/skel`,
  no sudoers changes. Tools install to their defaults: uv to `~/.local/bin`, go
  to `~/go/bin`, cargo to `~/.cargo/bin`. Cloned and built tools live in
  `/opt/tools` (`/opt/tools/bin` is on PATH).
- Safe to re-run. Failures are logged and summarized rather than treated as
  fatal, so re-run a failed section with `--only <section>`. Logs go to
  `/root/kali-setup.log`.
- Config lives in this repo. kali-setup clones it to `/opt/tools/configs` and
  deploys from there: `zsh/configs.zsh` is inlined into `/root/.zshrc` (appended
  after Kali's stock config so it takes precedence), and the `tmux/` tree is
  copied into place. Edit the repo and re-run `--only configs,tmux` to reapply.
  Build from a local checkout with `CONFIGS_REPO=/path/to/clone`.

## Updating

`update-tools.sh` refreshes the installed toolchain (apt packages, uv/go/cargo/ruby
tools, source builds). Run manually as root, not mid-engagement:

```bash
sudo update-tools.sh            # everything
sudo update-tools.sh --only go  # a subset (--list / --help for more)
```

## Notes

- API tokens, when provided, are written straight into `/root/.zshrc` (dedicated
  box, not treated as secret).
- Autologin is passwordless root GUI login, so set a root password first
  (`passwd root`).
- BloodHound's default admin password is printed during the `bloodhound` section.
- Browser extensions and the `~/staging` VMware mount are manual; see the run summary.
