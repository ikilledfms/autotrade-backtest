# seed_login.py - first-time broker login via the MetaTrader5 Python package.
#
# Why this step exists: on a fresh runner the terminal never attempts a login
# from the [Common] section of /config: ini files. Run #4 proved it: the
# pre-flight terminal spent its 120s on first-run recompilation + LiveUpdate
# and never logged in, and the sync terminal wrote only startup lines then
# total silence for 10 minutes - no login attempt at all, no failure marker.
# The MetaTrader5 package logs in through the terminal's own API, which
# saves the account (with password) into the terminal's data folder, so
# later /config: launches can log in from the saved account - the same
# saved-session behaviour that was verified working on the local VM.
#
# Env vars (from GitHub Secrets, never printed): HFM_MT5_LOGIN,
# HFM_MT5_PASSWORD, HFM_MT5_SERVER. MT5_DIR is the portable data folder.
# Prints only the account number, server, balance and leverage - NEVER the
# password. Exits non-zero on any failure so the workflow fails fast.
import os
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

path = os.path.join(MT5_DIR, "terminal64.exe")
ok = False
for attempt in range(1, 4):
    print(f"seed_login: initialize attempt {attempt}/3 at {path} (portable)...")
    ok = mt5.initialize(path=path, login=int(LOGIN), password=PASSWORD,
                        server=SERVER, timeout=300000, portable=True)
    if ok:
        break
    print(f"seed_login: attempt {attempt} failed, last_error={mt5.last_error()}",
          file=sys.stderr)
    mt5.shutdown()
    if attempt < 3:
        time.sleep(60)
if not ok:
    print("seed_login: initialize failed after 3 attempts", file=sys.stderr)
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
