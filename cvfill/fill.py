#!/usr/bin/env python3
"""cvfill -- deterministic job-application auto-filler on top of uidrive.

No LLM at runtime. Reads profile.json, enumerates the target app's editable
fields via `uidrive do <app> fields`, maps each profile value to the best
form field by label keywords, fills it through the Accessibility value setter
(no focus steal, no mouse), then VERIFIES via AX read-back and (optionally)
screenshot OCR. On a verify mismatch it tries the next candidate field.

Safety: never clicks Submit. It fills and stops for human review.

Usage:
  fill.py <pid|app> [--profile profile.json] [--ocr] [--capture out.png]
          [--type-fallback] [--dry-run]
"""
import argparse, json, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from vault import load_profile
UIDRIVE = os.path.join(HERE, "..", "build", "uidrive")
OCRTEXT = os.path.join(HERE, "..", "build", "ocrtext")

# profile key -> label keywords, MOST specific first. A form field matches a key
# if its label contains one of these substrings (case-insensitive).
FIELD_MAP = {
    "first_name":     ["legal first name", "first name", "given name", "first"],
    "last_name":      ["legal last name", "last name", "family name", "surname", "last"],
    "full_name":      ["full name", "name"],
    "email":          ["email address", "e-mail", "email"],
    "phone":          ["phone number", "mobile", "telephone", "phone"],
    "address_line1":  ["address line 1", "street address", "address 1", "address"],
    "address_line2":  ["address line 2", "address 2", "apt", "suite", "unit"],
    "city":           ["city", "town"],
    "state":          ["state", "province", "region"],
    "postal_code":    ["postal code", "zip code", "zip", "postcode"],
    "country":        ["country"],
    "linkedin":       ["linkedin"],
    "github":         ["github"],
    "website":        ["website", "portfolio", "personal site", "url"],
    "school":         ["school", "university", "institution", "college"],
    "degree":         ["degree"],
    "field_of_study": ["field of study", "major", "discipline"],
    "gpa":            ["gpa", "grade point"],
    "current_employer": ["current employer", "employer", "company"],
    "current_title":  ["job title", "position title", "title", "position"],
}

def ud(app, *cmd, timeout=20):
    try:
        r = subprocess.run([UIDRIVE, "do", str(app), *map(str, cmd)],
                           capture_output=True, text=True, timeout=timeout)
        return r.stdout, r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        print(f"  ! uidrive {cmd[0] if cmd else ''} timed out after {timeout}s", file=sys.stderr)
        return "", "timeout", 124

def get_fields(app):
    out, err, rc = ud(app, "fields")
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        print("  ! could not parse fields:", (err or out)[:200], file=sys.stderr)
        return []

def norm(s):
    return re.sub(r"\s+", " ", (s or "").strip().lower())

def label_matches(label, keywords):
    l = norm(label)
    for i, kw in enumerate(keywords):
        if kw in l:
            return len(keywords) - i          # higher = more specific
    return 0

def choose_targets(fields, keywords, used):
    """All fields matching, best (most specific, longest label) first, skipping used."""
    scored = []
    for f in fields:
        if f["i"] in used:
            continue
        s = label_matches(f.get("label", ""), keywords)
        if s:
            scored.append((s, -len(norm(f.get("label", ""))), f))
    scored.sort(key=lambda x: (-x[0], x[1]))
    return [f for _, _, f in scored]

def ocr_contains(png, expected):
    if not (png and os.path.exists(png)):
        return None
    try:
        r = subprocess.run([OCRTEXT, png], capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return None
    try:
        toks = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None
    want = norm(expected)
    joined = norm(" ".join(t["text"] for t in toks))
    return want in joined

def verify(app, field_label_substr, expected):
    """Re-read the field's AX value and compare (normalized)."""
    for f in get_fields(app):
        if norm(field_label_substr) in norm(f.get("label", "")):
            return norm(f.get("value", "")) == norm(expected), f.get("value", "")
    return False, "(field vanished)"

def fill(app, profile, do_ocr=False, capture=None, type_fallback=False, dry=False):
    fields = get_fields(app)
    print(f"found {len(fields)} editable field(s)")
    if not fields:
        print("no fields — is the form loaded and the app's a11y tree warm?")
        return 1
    used, filled, failed, skipped = set(), 0, [], 0

    for key, keywords in FIELD_MAP.items():
        value = str(profile.get(key, "") or "").strip()
        if not value:
            continue
        targets = choose_targets(fields, keywords, used)
        if not targets:
            skipped += 1
            continue
        ok = False
        for t in targets:                       # try candidates until one verifies
            lbl = t.get("label", "")
            print(f"- {key!r} -> field #{t['i']} {lbl!r}")
            if dry:
                used.add(t["i"]); ok = True; break
            out, err, rc = ud(app, "setval", lbl, value)
            readback_ok, got = verify(app, lbl, value)
            if readback_ok:
                print(f"    set + AX-verified = {got!r}")
                used.add(t["i"]); ok = True; break
            if type_fallback:                   # web field w/ read-only AXValue: focus+type (steals focus)
                ud(app, "focus", lbl); ud(app, "type", value)
                readback_ok, got = verify(app, lbl, value)
                if readback_ok:
                    print(f"    set via type-fallback = {got!r}")
                    used.add(t["i"]); ok = True; break
            print(f"    mismatch (got {got!r}); trying another box")
        if ok:
            filled += 1
        else:
            failed.append(key)

    if do_ocr or capture:
        png = capture or os.path.join(HERE, "cvfill_capture.png")
        out, err, rc = ud(app, "capture", png)
        print(f"capture: {out.strip() or err.strip()}")
        if do_ocr:
            for key in list(FIELD_MAP):
                v = str(profile.get(key, "") or "").strip()
                if v and key not in failed:
                    res = ocr_contains(png, v)
                    tag = {True: "OCR-confirmed", False: "OCR-NOT-visible", None: "OCR-skip"}[res]
                    print(f"    {key}: {tag}")

    print(f"\nfilled {filled}, failed {len(failed)}, skipped-no-field {skipped}")
    if failed:
        print("  failed:", ", ".join(failed))
    print("NOT submitting — review the form, then submit yourself.")
    return 0 if not failed else 2

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("app", help="pid or app name (the browser/app showing the form)")
    ap.add_argument("--profile", default=None, help="override; defaults to the vault, then profile.json")
    ap.add_argument("--ocr", action="store_true", help="cross-check filled values via screenshot OCR")
    ap.add_argument("--capture", help="write a screenshot to this path")
    ap.add_argument("--type-fallback", action="store_true",
                    help="if AXValue is read-only (web forms), focus+type (NOTE: takes focus)")
    ap.add_argument("--dry-run", action="store_true", help="show the field mapping, change nothing")
    a = ap.parse_args()
    profile = load_profile(a.profile)
    return fill(a.app, profile, a.ocr, a.capture, a.type_fallback, a.dry_run)

if __name__ == "__main__":
    sys.exit(main())
