# seed_login.py - first-time broker login via the MetaTrader5 Python package.
#
# FIX #7 changes (see ../fix7/DIAGNOSIS.md for the full reasoning):
#  1. Fail fast if `python` is the Microsoft Store build: its sandbox
#     cannot open the MT5 IPC named pipe, and initialize() then ALWAYS
#     fails with (-10005, 'IPC timeout'). The workflow pins a real
#     CPython via setup-python; this check is the second line of defence.
#  2. Two-phase connect: initialize(path-only) FIRST, with no login /
#     password / server, then mt5.login() separately. The combined
#     initialize(login, password, server) call is reported to hang /
#     IPC-timeout where the split succeeds, and splitting separates the
#     error signal: "IPC dead" (initialize fails) vs "login failed"
#     (login fails with an authorisation error, not a timeout).
#  3. initialize() timeout 300s -> 180s per attempt: a healthy terminal
#     answers the handshake in seconds (it binds its IPC channel at
#     startup); 300s only burns time when IPC is dead. 3 attempts kept.
#  4. Last-resort fallback: if path-based initialize() fails 3x, try a
#     bare mt5.initialize() (auto-detect) once, in case the path-based
#     launch is what breaks the pipe lookup.
#  5. Per-attempt diagnostics: tasklist state of terminal64.exe is
#     printed on every failure, so the log shows whether the terminal
#     was alive / which session it was in when IPC failed.
#
# Env vars (from GitHub Secrets, never printed): HFM_MT5_LOGIN,
# HFM_MT5_PASSWORD, HFM_MT5_SERVER. MT5_DIR is the portable data folder.
# Prints only the account number, server, balance and leverage - NEVER the
# password. Exits non-zero on any failure so the workflow fails fast.
import os
import subprocess
import sys
import time

import MetaTrader5 as mt5

LOGIN = os.environ.get("HFM_MT5_LOGIN", "")
PASSWORD = os.environ.get("HFM_MT5_PASSWORD", "")
SERVER = os.environ.get("HFM_MT5_SERVER", "")
MT5_DIR = os.environ.get("MT5_DIR", r"C:\Program Files\MetaTrader 5")

if not LOGIN or not PASSWORD or not SERVER:
    print("seed_login: missing HFM_MT5_LOGIN / HFM_MT5_PASSWORD / HFM_MT5_SERVER",
          file=sys.stderr)
    sys.exit(2)

# FIX #7 (1): refuse to run under the Microsoft Store Python.
_exe = sys.executable or ""
if "WindowsApps" in _exe:
    print(f"seed_login: FATAL - python is the Microsoft Store build ({_exe}). "
          "Its sandbox cannot open the MT5 IPC named pipe, so initialize() "
          "always fails with (-10005, 'IPC timeout'). Use a real CPython "
          "(setup-python step) instead.", file=sys.stderr)
    sys.exit(2)
print(f"seed_login: python={_exe} version={sys.version.split()[0]} "
      f"mt5_package={getattr(mt5, '__version__', 'unknown')}")


def _kill_terminal():
    # A terminal left over from warm-up, or one mid-restart after a
    # failed initialize(), breaks the next IPC connect. Kill it so every
    # attempt starts from a clean state.
    try:
        subprocess.run(["taskkill", "/F", "/IM", "terminal64.exe"],
                       capture_output=True, timeout=30)
    except Exception as exc:  # noqa: BLE001 - best effort only
        print(f"seed_login: taskkill skipped ({exc})", file=sys.stderr)


def _terminal_state():
    # Best-effort snapshot for the log: is a terminal alive right now,
    # and in which session / as which user? (Fix #7 hypothesis #3.)
    try:
        out = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq terminal64.exe",
             "/FO", "TABLE", "/NH"],
            capture_output=True, text=True, timeout=30)
        print("seed_login: tasklist terminal64:\n"
              + (out.stdout.strip() or "(no terminal64.exe running)"))
    except Exception as exc:  # noqa: BLE001 - best effort only
        print(f"seed_login: tasklist skipped ({exc})", file=sys.stderr)


_kill_terminal()
time.sleep(10)

path = os.path.join(MT5_DIR, "terminal64.exe")

# FIX #7 (2): phase 1 - connect only, no credentials.
ok = False
for attempt in range(1, 4):
    print(f"seed_login: initialize attempt {attempt}/3 (path-only, no credentials)...")
    ok = mt5.initialize(path=path, timeout=180000, portable=True)
    if ok:
        print(f"seed_login: initialize OK - terminal version={mt5.version()}")
        break
    print(f"seed_login: attempt {attempt} initialize failed, "
          f"last_error={mt5.last_error()}", file=sys.stderr)
    _terminal_state()
    mt5.shutdown()
    if attempt < 3:
        _kill_terminal()
        time.sleep(30)

# FIX #7 (4): last resort - bare auto-detect initialize().
if not ok:
    print("seed_login: path-based initialize failed 3x - trying bare "
          "mt5.initialize() (auto-detect) once...")
    ok = mt5.initialize(timeout=180000)
    if not ok:
        print(f"seed_login: auto-detect initialize failed, "
              f"last_error={mt5.last_error()}", file=sys.stderr)
        sys.exit(1)
    print(f"seed_login: auto-detect initialize OK - terminal version={mt5.version()}")

# FIX #7 (2): phase 2 - log in separately, so a login failure reports as
# an authorisation error instead of an IPC timeout.
print(f"seed_login: logging in to server={SERVER} login={LOGIN} ...")
if not mt5.login(login=int(LOGIN), password=PASSWORD, server=SERVER,
                 timeout=120000):
    print(f"seed_login: login failed, last_error={mt5.last_error()}",
          file=sys.stderr)
    mt5.shutdown()
    sys.exit(1)

deadline = time.time() + 300
info = None
while time.time() < deadline:
    info = mt5.account_info()
    if info is not None and info.login == int(LOGIN):
        break
    time.sleep(10)
if info is None or info.login != int(LOGIN):
    print(f"seed_login: account_info did not return login {LOGIN} within 300s, "
          f"last_error={mt5.last_error()}", file=sys.stderr)
    mt5.shutdown()
    sys.exit(1)

print(f"seed_login: logged in - login={info.login} server={info.server} "
      f"balance={info.balance} leverage={info.leverage} currency={info.currency}")
mt5.shutdown()
print("seed_login: terminal shut down, account saved in the data folder.")
