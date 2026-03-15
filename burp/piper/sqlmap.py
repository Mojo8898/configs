#!/usr/bin/env python3
"""
Piper menu item: launch sqlmap SQLi testing against the current request.
- Reconstructs the full URL from the request line + Host header.
- Cookies present in the raw request are forwarded via --cookie.
- A small GUI dialog lets you toggle --batch and set --level / --risk.
Piper config: passHeaders: true, inputMethod: stdin, hasGUI: true
"""
import subprocess
import sys

# ---------------------------------------------------------------------------
# GUI: sqlmap options dialog
# ---------------------------------------------------------------------------

def show_options_gui() -> dict | None:
    """
    Show a dialog to configure the sqlmap run.
    Returns a dict of chosen options, or None if cancelled.
    """
    from PyQt5.QtWidgets import (
        QApplication, QDialog, QVBoxLayout, QHBoxLayout,
        QGroupBox, QCheckBox, QLabel, QLineEdit,
        QDialogButtonBox,
    )

    app = QApplication.instance() or QApplication(sys.argv)

    dialog = QDialog()
    dialog.setWindowTitle("SQLi Check – sqlmap Options")
    dialog.setMinimumWidth(320)

    root = QVBoxLayout(dialog)
    root.setSpacing(10)

    # ── Batch mode ──
    batch_group = QGroupBox("Options")
    bg_layout = QVBoxLayout(batch_group)
    batch_cb = QCheckBox("Non-interactive mode  (--batch)")
    batch_cb.setChecked(True)
    bg_layout.addWidget(batch_cb)
    root.addWidget(batch_group)

    # ── Level ──
    level_group = QGroupBox("Level  (1–5, default 3)")
    lg_layout = QVBoxLayout(level_group)
    level_input = QLineEdit("3")
    lg_layout.addWidget(level_input)
    root.addWidget(level_group)

    # ── Risk ──
    risk_group = QGroupBox("Risk  (1–3, default 2)")
    rg_layout = QVBoxLayout(risk_group)
    risk_input = QLineEdit("2")
    rg_layout.addWidget(risk_input)
    root.addWidget(risk_group)

    # ── Buttons ──
    buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
    buttons.accepted.connect(dialog.accept)
    buttons.rejected.connect(dialog.reject)
    root.addWidget(buttons)

    if dialog.exec_() != QDialog.Accepted:
        return None

    return {
        "batch":  batch_cb.isChecked(),
        "level":  level_input.text().strip() or "3",
        "risk":   risk_input.text().strip() or "2",
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    raw = sys.stdin.buffer.read()

    # Split headers from body (handle both CRLF and LF)
    sep = b"\r\n\r\n" if b"\r\n\r\n" in raw else b"\n\n"
    head_bytes, _, _ = raw.partition(sep)
    head_str = head_bytes.decode("utf-8", errors="replace")
    lines = head_str.splitlines()

    # Parse request line
    try:
        method, path, _http_ver = lines[0].split()
    except ValueError:
        sys.exit(1)

    # Parse headers
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if ": " in line:
            k, v = line.split(": ", 1)
            headers[k.lower()] = v

    host = headers.get("host", "target")
    proto = "https" if ":443" in host else "http"
    url = f"{proto}://{host}{path}"

    # Show options dialog
    opts = show_options_gui()
    if opts is None:
        sys.exit(0)  # user cancelled

    # Build sqlmap command
    cmd = ["sqlmap", "-u", f"'{url}'"]

    if opts["batch"]:
        cmd.append("--batch")

    cmd += ["--level", opts["level"], "--risk", opts["risk"]]

    cookie = headers.get("cookie", "")
    if cookie:
        cmd += ["--cookie", f"'{cookie}'"]

    # Pretty-print the command for the terminal title bar
    cmd_str = " ".join(cmd)

    bash_cmd = (
        f"echo '$ {cmd_str}';"
        f" echo;"
        f" {cmd_str};"
        f" echo;"
        f" echo '[*] Done. Press enter to close.';"
        f" read"
    )
    subprocess.Popen(
        ["/usr/bin/qterminal", "-e", "bash", "-c", bash_cmd]
    )


if __name__ == "__main__":
    main()
