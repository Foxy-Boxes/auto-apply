#!/usr/bin/env python3
"""webauth -- authenticate ONCE per portal, then reuse each login across every link.

A WebDriver session is HTTP-addressable by port+session_id and holds its cookie jar
as long as safaridriver runs. One safaridriver can hold many sessions, so each career
portal (NVIDIA Workday, Apple, Google, ...) gets its own held session + login.

The searcher (jobsearch.py --enqueue) drops a login request into a QUEUE; you then
work the queue one portal at a time:

  queue                     show pending / in / done login requests
  login-next                open the next queued portal ON-SCREEN; you log in by hand
  enqueue <portal> [--login-url U] [--label L]   add a login request manually
  login <url> [--portal P]  log into one portal directly (no queue)
  sessions                  list held sessions (alive? current url)
  status [--portal P]       detail for one held session (legacy: the single session)
  save-cookies [--portal P] dump a session's cookies to .cookies.json
  quit [--portal P | --all] delete one/all held sessions

Then fill any link with the matching login (portal auto-picked from the URL host):
  webfill.py <application-url> --session  [--portal P]

Prereq (one-time): `sudo safaridriver --enable` + Safari Develop > Allow Remote Automation.
"""
import argparse, json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import portals
from webfill import WD, STATE_FILE, COOKIES_FILE, save_state, ensure_driver

def _start_session(port, login_url):
    """Ensure a detached driver is up, create a session, open login_url on-screen."""
    ensure_driver(port, detach=True)                 # must outlive this command
    wd = WD(port)
    wd.start()
    wd.get(login_url)
    return wd

def _register(portal, port, wd, login_url):
    portals.set_session(portal, port, wd.sid, login_url)
    save_state({"port": port, "session_id": wd.sid})   # legacy single-session back-compat

# ---- queue-driven ----
def cmd_enqueue(a):
    meta = portals.portal_meta(a.portal)
    login_url = a.login_url or (meta and meta["login_url"])
    if not login_url:
        print(f"unknown portal {a.portal!r}; pass --login-url", file=sys.stderr); return 1
    company = (meta and meta["company"]) or a.portal
    added = portals.enqueue(a.portal, company, login_url, a.label or "")
    print(f"{'queued' if added else 'already queued'}: {a.portal} -> {login_url}")
    return 0

def cmd_queue(a):
    q = portals.load_queue()
    if not q:
        print("login queue is empty. Add some with:  jobsearch.py --enqueue"); return 0
    held = portals.load_sessions()
    for it in q:
        live = "  (session held)" if it["portal"] in held else ""
        lab = f"  {it['label']}" if it.get("label") else ""
        print(f"  [{it['status']:>7}] {it['portal']:8} {it['company']}{lab}{live}")
        print(f"            {it['login_url']}")
    nxt = portals.next_pending()
    print("\nnext:", "python3 cvfill/webauth.py login-next" if nxt else "(nothing pending)")
    return 0

def cmd_login_next(a):
    it = portals.next_pending()
    if not it:
        print("no pending logins. Add some with:  jobsearch.py --enqueue"); return 0
    print(f">>> opening {it['company']} ({it['portal']}) for login...")
    wd = _start_session(a.port, it["login_url"])
    _register(it["portal"], a.port, wd, it["login_url"])
    portals.mark_status(it["portal"], "done")
    print(f"session {wd.sid} on port {a.port}  (portal: {it['portal']})")
    print(f"opened: {it['login_url']}")
    print("\n>>> Log in by hand in the Safari automation window (SSO/2FA all fine).")
    remaining = portals.next_pending()
    if remaining:
        print(f">>> Next queued: {remaining['company']} — run  login-next  again when done.")
    else:
        print(">>> That was the last queued login.")
    print(">>> Fill any link with:  python3 cvfill/webfill.py <url> --session")
    return 0

# ---- direct ----
def cmd_login(a):
    portal = a.portal or portals.portal_for_url(a.url) or "default"
    wd = _start_session(a.port, a.url)
    _register(portal, a.port, wd, a.url)
    portals.mark_status(portal, "done")
    print(f"session {wd.sid} on port {a.port}  (portal: {portal})")
    print(f"opened: {a.url}")
    print("\n>>> Log in by hand in the Safari automation window (SSO/2FA all fine).")
    print(">>> Then fill any link with:  python3 cvfill/webfill.py <url> --session")
    return 0

# ---- inspection ----
def cmd_sessions(a):
    s = portals.load_sessions()
    if not s:
        print("no held sessions. Start one:  webauth.py login-next"); return 0
    for portal, st in s.items():
        wd = WD(st["port"], st["session_id"])
        if wd.alive():
            try: url = wd.current_url()
            except Exception: url = "(unknown)"
            print(f"  {portal:8} alive  port {st['port']}  {url}")
        else:
            print(f"  {portal:8} DEAD   port {st['port']}  (re-run login-next)")
    return 0

def cmd_status(a):
    portal, st = portals.resolve_session(a.portal)
    if not st:
        st = portals.load_sessions() or None
        print("no single held session; use:  webauth.py sessions"); return 1
    wd = WD(st["port"], st["session_id"])
    if not wd.alive():
        print(f"held session{' for '+portal if portal else ''} is gone. Re-run login-next"); return 1
    print(f"session {st['session_id']} alive on port {st['port']}"
          + (f"  (portal: {portal})" if portal else ""))
    try: print("current url:", wd.current_url())
    except Exception as e: print("current url: (unknown)", e)
    try: print("cookies:", len(wd.get_cookies()), "set")
    except Exception: pass
    return 0

def cmd_save_cookies(a):
    portal, st = portals.resolve_session(a.portal)
    if not st:
        print("no held session"); return 1
    wd = WD(st["port"], st["session_id"])
    if not wd.alive():
        print("held session is gone"); return 1
    cookies = wd.get_cookies()
    out = COOKIES_FILE if not portal else COOKIES_FILE.replace(".cookies.json", f".cookies.{portal}.json")
    json.dump(cookies, open(out, "w"))
    print(f"saved {len(cookies)} cookies -> {out}")
    return 0

def cmd_quit(a):
    s = portals.load_sessions()
    targets = list(s) if a.all else ([a.portal] if a.portal else list(s)[:1])
    if not targets:
        print("no held sessions"); return 0
    for portal in targets:
        st = s.get(portal)
        if not st: continue
        WD(st["port"], st["session_id"]).delete()
        portals.drop_session(portal)
        print(f"deleted session for {portal}")
    if not portals.load_sessions():
        try: os.remove(STATE_FILE)
        except OSError: pass
    print("(safaridriver may still be running; that's fine.)")
    return 0

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=4712)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("enqueue"); p.add_argument("portal"); p.add_argument("--login-url")
    p.add_argument("--label", default=""); p.set_defaults(fn=cmd_enqueue)
    sub.add_parser("queue").set_defaults(fn=cmd_queue)
    sub.add_parser("login-next").set_defaults(fn=cmd_login_next)
    p = sub.add_parser("login"); p.add_argument("url"); p.add_argument("--portal"); p.set_defaults(fn=cmd_login)
    sub.add_parser("sessions").set_defaults(fn=cmd_sessions)
    p = sub.add_parser("status"); p.add_argument("--portal"); p.set_defaults(fn=cmd_status)
    p = sub.add_parser("save-cookies"); p.add_argument("--portal"); p.set_defaults(fn=cmd_save_cookies)
    p = sub.add_parser("quit"); p.add_argument("--portal"); p.add_argument("--all", action="store_true")
    p.set_defaults(fn=cmd_quit)
    a = ap.parse_args()
    return a.fn(a)

if __name__ == "__main__":
    sys.exit(main())
