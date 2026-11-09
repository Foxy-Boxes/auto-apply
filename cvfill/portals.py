#!/usr/bin/env python3
"""portals -- shared registry of career portals + the held-session and login-queue stores.

One place that both the searcher (jobsearch.py) and the authenticator (webauth.py)
agree on: what portals exist, how to reach each one's login page, which held
WebDriver session belongs to which portal, and which logins are still queued.

State files (all gitignored, next to this module):
  .sessions.json      portal -> {port, session_id, login_url, created}  (held logins)
  .login_queue.json   [ {portal, company, label, login_url, status} ]   (login requests)

A single safaridriver (one port) can hold many sessions, so each portal gets its
own session_id under the same port and its own cookie jar / login.
"""
import json, os, time
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
SESSIONS_FILE = os.path.join(HERE, ".sessions.json")
QUEUE_FILE    = os.path.join(HERE, ".login_queue.json")
STATE_FILE    = os.path.join(HERE, ".session.json")        # legacy single-session pointer

# Known portals. `host_match` substrings map an application URL back to its portal
# so a fill can pick the right authenticated session automatically.
PORTALS = {
    "nvidia": {
        "company":    "NVIDIA",
        "kind":       "workday",
        "base":       "https://nvidia.wd5.myworkdayjobs.com",
        "tenant":     "nvidia",
        "site":       "NVIDIAExternalCareerSite",
        "login_url":  "https://nvidia.wd5.myworkdayjobs.com/en-US/NVIDIAExternalCareerSite/login",
        "host_match": ["nvidia.wd5.myworkdayjobs.com"],
    },
    "apple": {
        "company":    "Apple",
        "kind":       "apple",
        "login_url":  "https://jobs.apple.com/app/en-us/profile",
        "host_match": ["jobs.apple.com"],
    },
    "google": {
        "company":    "Google",
        "kind":       "google_html",
        "login_url":  "https://accounts.google.com/ServiceLogin?continue=https://www.google.com/about/careers/applications/",
        "host_match": ["google.com/about/careers", "careers.google.com"],
    },
}

def portal_meta(portal):
    return PORTALS.get(portal)

def portal_for_url(url):
    """Best-effort: which known portal does this application URL belong to?"""
    u = (url or "").lower()
    host = (urlparse(u).netloc or "")
    for portal, meta in PORTALS.items():
        for frag in meta.get("host_match", []):
            if frag in host or frag in u:
                return portal
    return None

# ---- generic small json store ----
def _load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default

def _save(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)

# ---- held sessions ----
def load_sessions():
    return _load(SESSIONS_FILE, {})

def save_sessions(d):
    _save(SESSIONS_FILE, d)

def set_session(portal, port, session_id, login_url=None):
    s = load_sessions()
    s[portal] = {"port": port, "session_id": session_id,
                 "login_url": login_url, "created": time.time()}
    save_sessions(s)

def get_session(portal):
    return load_sessions().get(portal)

def drop_session(portal):
    s = load_sessions()
    s.pop(portal, None)
    save_sessions(s)

def resolve_session(portal=None, url=None):
    """Pick a held session: explicit portal, else by URL host, else the only one held."""
    s = load_sessions()
    if portal:
        return portal, s.get(portal)
    if url:
        p = portal_for_url(url)
        if p and p in s:
            return p, s[p]
    if len(s) == 1:
        p = next(iter(s))
        return p, s[p]
    return None, None

# ---- login queue ----
def load_queue():
    return _load(QUEUE_FILE, [])

def save_queue(q):
    _save(QUEUE_FILE, q)

def enqueue(portal, company, login_url, label=""):
    """Add a pending login request (idempotent per portal while still pending)."""
    q = load_queue()
    for item in q:
        if item["portal"] == portal and item["status"] == "pending":
            return False                      # already queued, don't duplicate
    q.append({"portal": portal, "company": company, "label": label,
              "login_url": login_url, "status": "pending", "queued": time.time()})
    save_queue(q)
    return True

def next_pending():
    for item in load_queue():
        if item["status"] == "pending":
            return item
    return None

def mark_status(portal, status):
    q = load_queue()
    for item in q:
        if item["portal"] == portal:
            item["status"] = status
    save_queue(q)
