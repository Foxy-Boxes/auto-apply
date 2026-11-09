#!/usr/bin/env python3
"""vault -- a keychain-style store for your application info, used by the fillers.

Save everything once; every fill (webfill.py / fill.py) pulls from here. Ordinary
fields live in ~/.cvfill/vault.json (chmod 600, outside any repo, reused for ANY
application). Anything you mark secret (e.g. a careers-portal password) is stored
in the real macOS login Keychain via `security`, never written to the JSON.

Commands:
  vault.py init                     create the vault with the full field schema (blanks)
  vault.py import-resume [pdf]      fill fields parsed from your resume (won't overwrite)
  vault.py set <key> <value>        set an ordinary field
  vault.py set-secret <key>         store a secret in the macOS Keychain (prompts, no echo)
  vault.py get <key>                print one value (secrets shown only if --reveal)
  vault.py list [--reveal]          show everything (secrets masked unless --reveal)
  vault.py rm <key>                 remove a field (and its Keychain item if secret)
  vault.py export [--out FILE]      write a resolved plain profile (secrets inlined) for a filler
  vault.py path                     print the vault file location

Other tools import `load_profile()` to get the resolved dict directly.
"""
import argparse, getpass, json, os, subprocess, sys

VAULT_DIR  = os.path.expanduser("~/.cvfill")
VAULT_FILE = os.path.join(VAULT_DIR, "vault.json")
KEYCHAIN_SERVICE = "cvfill"

# Full schema of common application fields. Keys match the fillers' FIELD_MAP where
# they overlap; extras are stored for your reference / future dropdown support.
SCHEMA = [
    "first_name","last_name","full_name","preferred_name","email","phone",
    "address_line1","address_line2","city","state","postal_code","country",
    "linkedin","github","website",
    "school","degree","field_of_study","gpa","graduation_date",
    "current_employer","current_title",
    "work_authorization","require_sponsorship",
    "gender","race_ethnicity","veteran_status","disability_status",
    "how_heard","desired_salary","earliest_start_date","willing_to_relocate",
]

# ---- storage ----
def _ensure_dir():
    os.makedirs(VAULT_DIR, exist_ok=True)
    try: os.chmod(VAULT_DIR, 0o700)
    except OSError: pass

def load():
    try:
        with open(VAULT_FILE) as f: return json.load(f)
    except Exception:
        return {"fields": {}, "secrets": []}

def save(v):
    _ensure_dir()
    with open(VAULT_FILE, "w") as f: json.dump(v, f, indent=2)
    try: os.chmod(VAULT_FILE, 0o600)
    except OSError: pass

# ---- macOS Keychain for secrets ----
def kc_set(key, value):
    subprocess.run(["security","add-generic-password","-U",
                    "-a",key,"-s",KEYCHAIN_SERVICE,"-w",value],
                   check=True, capture_output=True)

def kc_get(key):
    r = subprocess.run(["security","find-generic-password",
                        "-a",key,"-s",KEYCHAIN_SERVICE,"-w"],
                       capture_output=True, text=True)
    return r.stdout.rstrip("\n") if r.returncode == 0 else None

def kc_del(key):
    subprocess.run(["security","delete-generic-password",
                    "-a",key,"-s",KEYCHAIN_SERVICE], capture_output=True)

# ---- resolved profile for the fillers ----
def resolve():
    """Flat dict of every field, with secret keys resolved from the Keychain."""
    v = load()
    out = dict(v.get("fields", {}))
    for k in v.get("secrets", []):
        val = kc_get(k)
        if val is not None: out[k] = val
    return out

def load_profile(path=None):
    """Used by the fillers: explicit --profile file wins; otherwise the vault;
    otherwise the legacy cvfill/profile.json next to this module."""
    if path:
        with open(path) as f: return json.load(f)
    if os.path.exists(VAULT_FILE):
        return resolve()
    legacy = os.path.join(os.path.dirname(os.path.abspath(__file__)), "profile.json")
    with open(legacy) as f: return json.load(f)

# ---- commands ----
def cmd_init(a):
    v = load()
    for k in SCHEMA: v["fields"].setdefault(k, "")
    save(v); print(f"vault ready at {VAULT_FILE} with {len(v['fields'])} fields")
    return 0

def cmd_import_resume(a):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import parse_resume
    pdf = a.pdf or os.path.expanduser("~/Documents/resume.pdf")
    parsed = parse_resume.parse(pdf)
    v = load(); added = []
    for k, val in parsed.items():
        if k.startswith("_"): continue
        val = str(val or "").strip()
        if val and not v["fields"].get(k):
            v["fields"][k] = val; added.append(k)
    save(v)
    print(f"imported {len(added)} field(s) from {os.path.basename(pdf)}: {', '.join(added)}")
    return 0

def cmd_set(a):
    v = load(); v["fields"][a.key] = a.value
    if a.key in v.get("secrets", []): v["secrets"].remove(a.key)  # now a plain field
    save(v); print(f"set {a.key}")
    return 0

def cmd_set_secret(a):
    val = getpass.getpass(f"value for secret {a.key!r} (hidden): ")
    if not val: print("empty; nothing stored"); return 1
    kc_set(a.key, val)
    v = load()
    v["fields"].pop(a.key, None)                     # never keep a secret in the JSON
    if a.key not in v.setdefault("secrets", []): v["secrets"].append(a.key)
    save(v); print(f"stored secret {a.key} in macOS Keychain (service {KEYCHAIN_SERVICE})")
    return 0

def cmd_get(a):
    v = load()
    if a.key in v.get("secrets", []):
        print(kc_get(a.key) if a.reveal else "******** (secret; --reveal to show)")
    else:
        print(v["fields"].get(a.key, ""))
    return 0

def cmd_list(a):
    v = load(); secrets = set(v.get("secrets", []))
    for k in sorted(set(v["fields"]) | secrets):
        if k in secrets:
            val = (kc_get(k) if a.reveal else None) or "******** (secret)"
        else:
            val = v["fields"].get(k, "")
        mark = "🔒" if k in secrets else "  "
        print(f"{mark} {k:22} {val}")
    return 0

def cmd_rm(a):
    v = load()
    v["fields"].pop(a.key, None)
    if a.key in v.get("secrets", []): v["secrets"].remove(a.key); kc_del(a.key)
    save(v); print(f"removed {a.key}")
    return 0

def cmd_export(a):
    prof = resolve()
    if a.out:
        with open(a.out, "w") as f: json.dump(prof, f, indent=2)
        try: os.chmod(a.out, 0o600)
        except OSError: pass
        print(f"wrote resolved profile ({len(prof)} fields) -> {a.out}")
    else:
        print(json.dumps(prof, indent=2))
    return 0

def cmd_path(a):
    print(VAULT_FILE); return 0

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init").set_defaults(fn=cmd_init)
    p = sub.add_parser("import-resume"); p.add_argument("pdf", nargs="?"); p.set_defaults(fn=cmd_import_resume)
    p = sub.add_parser("set"); p.add_argument("key"); p.add_argument("value"); p.set_defaults(fn=cmd_set)
    p = sub.add_parser("set-secret"); p.add_argument("key"); p.set_defaults(fn=cmd_set_secret)
    p = sub.add_parser("get"); p.add_argument("key"); p.add_argument("--reveal", action="store_true"); p.set_defaults(fn=cmd_get)
    p = sub.add_parser("list"); p.add_argument("--reveal", action="store_true"); p.set_defaults(fn=cmd_list)
    p = sub.add_parser("rm"); p.add_argument("key"); p.set_defaults(fn=cmd_rm)
    p = sub.add_parser("export"); p.add_argument("--out"); p.set_defaults(fn=cmd_export)
    sub.add_parser("path").set_defaults(fn=cmd_path)
    a = ap.parse_args()
    return a.fn(a)

if __name__ == "__main__":
    sys.exit(main())
