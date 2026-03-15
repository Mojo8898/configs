#!/usr/bin/env python3
"""
Piper menu item: launch ffuf LFI fuzzing against the current request.
FUZZ injection priority:
  1. If multiple parameters exist, a GUI dialog lets you pick which one to fuzz.
  2. If only one parameter exists, it is fuzzed automatically.
  3. Fallback: appends ?file=FUZZ to the path.
A filter-mode dialog always appears, letting you choose between:
  - Auto-calibrate  (-ac)
  - Match 200 only  (-mc 200)
Cookies already present in the raw request are forwarded automatically
via the -request file; no separate -b flag is needed.
Piper config: passHeaders: true, inputMethod: stdin, hasGUI: true
"""
import re
import subprocess
import sys
import tempfile

WORDLIST = "/usr/share/seclists/Fuzzing/LFI/LFI-Jhaddix.txt"


# ---------------------------------------------------------------------------
# Parameter extraction
# ---------------------------------------------------------------------------

def extract_params(s: str, source: str) -> list[dict]:
    """
    Return a list of dicts describing every key=value pair found in *s*.
    Each dict has:
      - name   : parameter name
      - start  : start index of the value in *s*
      - end    : end index of the value in *s*
      - source : 'query' or 'body'
    """
    params = []
    for m in re.finditer(r"(?<=[?&])[^=&\s#]+=([^&\s#]*)", s):
        # The parameter name sits between the previous ? / & and the =
        name_start = m.start() - 1  # points at ? or &
        eq_pos = s.index("=", m.start())
        name = s[m.start(): eq_pos]
        params.append({
            "name": name,
            "start": m.start(1),
            "end": m.end(1),
            "source": source,
        })
    return params


# ---------------------------------------------------------------------------
# GUI: combined param picker + filter mode selector
# ---------------------------------------------------------------------------

def show_options_gui(params: list[dict]) -> tuple[dict | None, str] | None:
    """
    Show a single dialog with:
      - (optional) a parameter list when len(params) > 1
      - radio buttons to choose the ffuf filter mode

    Returns:
      (chosen_param_or_None, filter_flag)  on OK
      None                                  if cancelled

    filter_flag is either '-ac' or '-mc 200'.
    When params has 0 or 1 entries the parameter section is hidden and
    the sole/fallback param (or None) is returned automatically.
    """
    from PyQt5.QtWidgets import (
        QApplication, QDialog, QVBoxLayout, QHBoxLayout,
        QLabel, QListWidget, QListWidgetItem,
        QGroupBox, QCheckBox, QLineEdit, QDialogButtonBox, QFrame,
    )
    from PyQt5.QtCore import Qt

    app = QApplication.instance() or QApplication(sys.argv)

    dialog = QDialog()
    dialog.setWindowTitle("LFI Fuzzer – Options")
    dialog.setMinimumWidth(360)

    root = QVBoxLayout(dialog)
    root.setSpacing(10)

    # ── Parameter selection (only shown when there are multiple params) ──
    list_widget = None
    if len(params) > 1:
        param_group = QGroupBox("Parameter to fuzz")
        pg_layout = QVBoxLayout(param_group)
        list_widget = QListWidget()
        for p in params:
            item = QListWidgetItem(f"{p['name']}  [{p['source']}]")
            item.setData(Qt.UserRole, p)
            list_widget.addItem(item)
        list_widget.setCurrentRow(0)
        pg_layout.addWidget(list_widget)
        root.addWidget(param_group)

        # Divider
        line = QFrame()
        line.setFrameShape(QFrame.HLine)
        line.setFrameShadow(QFrame.Sunken)
        root.addWidget(line)

    # ── Filter mode ──
    filter_group = QGroupBox("Filter mode  (-mc 200, -ac, etc.)")
    fg_layout = QVBoxLayout(filter_group)

    filter_input = QLineEdit("-mc 200")
    filter_input.setPlaceholderText("e.g. -mc 200  or  -ac")
    fg_layout.addWidget(filter_input)
    root.addWidget(filter_group)

    # ── Debug ──
    debug_group = QGroupBox("Debug")
    dg_layout = QVBoxLayout(debug_group)
    cat_cb = QCheckBox("Print request file contents before running  (cat)")
    cat_cb.setChecked(False)
    dg_layout.addWidget(cat_cb)
    root.addWidget(debug_group)

    # ── Buttons ──
    buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
    buttons.accepted.connect(dialog.accept)
    buttons.rejected.connect(dialog.reject)
    root.addWidget(buttons)

    if dialog.exec_() != QDialog.Accepted:
        return None

    # Resolve chosen param
    if list_widget is not None:
        sel = list_widget.currentItem()
        chosen = sel.data(Qt.UserRole) if sel else (params[0] if params else None)
    else:
        chosen = params[0] if params else None

    filter_flag = filter_input.text().strip() or "-mc 200"
    return chosen, filter_flag, cat_cb.isChecked()


# ---------------------------------------------------------------------------
# FUZZ injection helpers
# ---------------------------------------------------------------------------

def inject_fuzz_at(s: str, param: dict) -> str:
    """Replace the value of the chosen parameter with FUZZ."""
    return s[: param["start"]] + "FUZZ" + s[param["end"]:]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    raw = sys.stdin.buffer.read()

    # Split headers from body (handle both CRLF and LF)
    sep = b"\r\n\r\n" if b"\r\n\r\n" in raw else b"\n\n"
    head_bytes, _, body = raw.partition(sep)
    head_str = head_bytes.decode("utf-8", errors="replace")
    lines = head_str.splitlines()

    # Parse request line
    try:
        method, path, http_ver = lines[0].split()
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
    body_str = body.decode("utf-8", errors="replace")

    # Collect all parameters from query string and body
    query_params = extract_params(path, "query")
    body_params = extract_params(body_str, "body")
    all_params = query_params + body_params

    # -----------------------------------------------------------------------
    # Show options dialog (always) to pick param + filter mode
    # -----------------------------------------------------------------------
    result = show_options_gui(all_params)
    if result is None:
        sys.exit(0)  # user cancelled
    chosen, filter_flag, show_cat = result

    # -----------------------------------------------------------------------
    # Decide which parameter to fuzz
    # -----------------------------------------------------------------------
    if chosen is None:
        # Fallback: no parameters found – append ?file=FUZZ
        sep_char = "&" if "?" in path else "?"
        lines[0] = f"{method} {path}{sep_char}file=FUZZ {http_ver}"
    elif chosen["source"] == "query":
        fuzzed_path = inject_fuzz_at(path, chosen)
        lines[0] = f"{method} {fuzzed_path} {http_ver}"
    else:
        body_str = inject_fuzz_at(body_str, chosen)
        body = body_str.encode("utf-8")

    # -----------------------------------------------------------------------
    # Write modified request to a temp file
    # -----------------------------------------------------------------------
    new_request = "\r\n".join(lines).encode() + sep + body
    with tempfile.NamedTemporaryFile(
        prefix="piper-ffuf-lfi-", suffix=".txt", delete=False, mode="wb"
    ) as f:
        f.write(new_request)
        req_file = f.name

    cookie = headers.get("cookie", "")
    cookie_flag = f' -b "{cookie}"' if cookie else ""

    cmd_str = (
        f"ffuf -request {req_file} -request-proto {proto}"
        f" -w {WORDLIST} {filter_flag}{cookie_flag}"
    )

    cat_block = (
        f" echo '=== Request file: {req_file} ===';"
        f" echo;"
        f" cat {req_file};"
        f" echo;"
        f" echo '=== Command ===';"
        f" echo;"
    ) if show_cat else ""

    bash_cmd = (
        f"{cat_block}"
        f" echo '$ {cmd_str}';"
        f" echo;"
        f" {cmd_str};"
        f" echo;"
        f" echo '[*] Done. Press enter to close.';"
        f" read;"
        f" rm -f {req_file}"
    )
    subprocess.Popen(
        ["/usr/bin/qterminal", "-e", "bash", "-c", bash_cmd]
    )


if __name__ == "__main__":
    main()
