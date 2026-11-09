#!/usr/bin/env python3
"""webfill -- fill a web application form (Workday etc.) via safaridriver/WebDriver.

DOM-level, so it works where the no-focus Accessibility path can't see web inputs.
Matches each field in-page by label/placeholder/aria/name/autocomplete/data-automation-id
(deterministic, no LLM), fills with a React-friendly native setter, then VERIFIES via the
DOM value it reads back and (when the window is on-screen) our Vision OCR on a WebDriver
screenshot. Never submits.

Two modes:
  * fresh:   starts its own safaridriver + throwaway session (for one-off / local tests)
  * --session: attaches to the authenticated session held by webauth.py and REUSES its
               login across every application URL (does not create or quit the session)

Prereq (one-time): `sudo safaridriver --enable` + Safari Develop > Allow Remote Automation.

Usage:
  webfill.py <url> [--profile profile.json] [--port 4712] [--session]
             [--offscreen X Y] [--keep] [--shot path]
"""
import argparse, base64, json, os, re, subprocess, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from vault import load_profile
import portals
OCRTEXT = os.path.join(HERE, "..", "build", "ocrtext")
STATE_FILE = os.path.join(HERE, ".session.json")      # {port, session_id} held by webauth (legacy)
COOKIES_FILE = os.path.join(HERE, ".cookies.json")

FIELD_MAP = {
    "first_name":     ["legal first name", "first name", "given name"],
    "last_name":      ["legal last name", "last name", "family name", "surname"],
    "email":          ["email address", "e-mail", "email"],
    "phone":          ["phone number", "mobile", "telephone", "phone"],
    "address_line1":  ["address line 1", "street address", "address 1"],
    "address_line2":  ["address line 2", "address 2", "apt", "suite"],
    "city":           ["city", "town"],
    "state":          ["state", "province", "region"],
    "postal_code":    ["postal code", "zip code", "zip", "postcode"],
    "country":        ["country"],
    "linkedin":       ["linkedin"],
    "github":         ["github"],
    "website":        ["website", "portfolio"],
}

FILL_JS = r"""
const specs = arguments[0];
function labelFor(el){
  let bits = [];
  if (el.id){ const l=document.querySelector('label[for="'+CSS.escape(el.id)+'"]'); if(l) bits.push(l.innerText); }
  const wrap = el.closest('label'); if (wrap) bits.push(wrap.innerText);
  for (const a of ['aria-label','placeholder','name','autocomplete','data-automation-id']) {
    const v = el.getAttribute(a); if (v) bits.push(v);
  }
  if (el.getAttribute('aria-labelledby')) {
    el.getAttribute('aria-labelledby').split(/\s+/).forEach(id=>{
      const n=document.getElementById(id); if(n) bits.push(n.innerText);
    });
  }
  return bits.join(' ').toLowerCase().replace(/\s+/g,' ');
}
const inputs = [...document.querySelectorAll(
  'input:not([type=hidden]):not([type=submit]):not([type=button]):not([type=checkbox]):not([type=radio]), textarea')]
  .filter(el => el.offsetParent !== null && !el.disabled && !el.readOnly);
const used = new Set();
const report = [];
for (const spec of specs) {
  let best=null, bestScore=0;
  for (const el of inputs) {
    if (used.has(el)) continue;
    const lab = labelFor(el);
    for (let i=0;i<spec.keywords.length;i++){
      if (lab.includes(spec.keywords[i])) {
        const score = (spec.keywords.length - i)*100 - lab.length;
        if (score>bestScore){ bestScore=score; best=el; }
        break;
      }
    }
  }
  if (!best){ report.push({key:spec.key, matched:false}); continue; }
  used.add(best);
  const proto = best.tagName==='TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto,'value').set;
  best.focus();
  setter.call(best, spec.value);
  best.dispatchEvent(new Event('input',{bubbles:true}));
  best.dispatchEvent(new Event('change',{bubbles:true}));
  best.blur();
  const r = best.getBoundingClientRect();
  report.push({key:spec.key, matched:true, label:labelFor(best),
               value:best.value, x:Math.round(r.x), y:Math.round(r.y),
               w:Math.round(r.width), h:Math.round(r.height)});
}
return report;
"""

class WD:
    def __init__(self, port, sid=None): self.base=f"http://localhost:{port}"; self.sid=sid
    def _req(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base+path, data=data, method=method,
                                     headers={"Content-Type":"application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode())
    def start(self):
        v = self._req("POST","/session",
            {"capabilities":{"alwaysMatch":{"browserName":"safari"}}})
        self.sid = v["value"]["sessionId"]; return self.sid
    def alive(self):
        try: self.current_url(); return True
        except Exception: return False
    def get(self,url): self._req("POST",f"/session/{self.sid}/url",{"url":url})
    def current_url(self): return self._req("GET",f"/session/{self.sid}/url")["value"]
    def script(self,js,args): return self._req("POST",f"/session/{self.sid}/execute/sync",
                                               {"script":js,"args":args})["value"]
    def rect(self,x,y,w=1200,h=900): self._req("POST",f"/session/{self.sid}/window/rect",
                                               {"x":x,"y":y,"width":w,"height":h})
    def shot(self): return base64.b64decode(self._req("GET",f"/session/{self.sid}/screenshot")["value"])
    def get_cookies(self): return self._req("GET",f"/session/{self.sid}/cookie")["value"]
    def add_cookie(self,c): self._req("POST",f"/session/{self.sid}/cookie",{"cookie":c})
    def delete(self):
        try: self._req("DELETE",f"/session/{self.sid}")
        except Exception: pass

def load_state():
    try: return json.load(open(STATE_FILE))
    except Exception: return None

def save_state(d): json.dump(d, open(STATE_FILE, "w"))

def ensure_driver(port, detach=False):
    """Start safaridriver on `port` if nothing answers there. Returns Popen or None.
    detach=True makes it outlive this process (its own session group) so a held
    WebDriver session survives after the launcher exits."""
    try:
        urllib.request.urlopen(f"http://localhost:{port}/status", timeout=2); return None
    except Exception:
        sd = subprocess.Popen(["safaridriver","-p",str(port)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                              start_new_session=detach)
        time.sleep(1.5)
        if sd.poll() is not None:
            err = sd.stderr.read().decode()
            sys.stderr.write("safaridriver failed to start:\n"+err+
                "\nRun once:  sudo safaridriver --enable   (+ Safari Develop > Allow Remote Automation)\n")
            sys.exit(1)
        return sd

def norm(s): return re.sub(r"\s+"," ",(s or "").strip().lower())

def ocr_tokens(png_path):
    try:
        r = subprocess.run([OCRTEXT, png_path], capture_output=True, text=True, timeout=30)
        return json.loads(r.stdout)
    except Exception: return []

def do_fill(wd, profile, shot_path, offscreen=None):
    if offscreen: wd.rect(offscreen[0], offscreen[1])
    specs = [{"key":k,"value":str(profile.get(k,"") or "").strip(),"keywords":FIELD_MAP[k]}
             for k in FIELD_MAP if str(profile.get(k,"") or "").strip()]
    report = wd.script(FILL_JS, [specs])
    want = {s['key']:norm(s['value']) for s in specs}

    print("=== DOM fill ===")
    dom_ok = 0
    for r in report:
        if not r.get("matched"): print(f"  {r['key']}: no field found"); continue
        ok = norm(r['value'])==want[r['key']]; dom_ok += ok
        print(f"  {r['key']}: {'OK' if ok else 'MISMATCH'} -> {r['value']!r}  [{norm(r.get('label',''))[:40]!r}]")

    with open(shot_path,"wb") as f: f.write(wd.shot())
    toks = ocr_tokens(shot_path); joined = norm(" ".join(t["text"] for t in toks)); ocr_ok = 0
    if len(toks) == 0:
        print("=== OCR verify: SKIPPED — screenshot blank (window off-screen / not rendering). "
              "DOM verification stands. Run without --offscreen for the visual check. ===")
    else:
        print(f"=== OCR verify (screenshot {shot_path}, {len(toks)} tokens) ===")
        for r in report:
            if not r.get("matched"): continue
            v = norm(r["value"])
            if not v: continue
            seen = v in joined; ocr_ok += seen
            print(f"  {r['key']}: {'OCR-confirmed' if seen else 'OCR-not-visible'} ({r['value']!r})")

    matched = [r for r in report if r.get('matched')]
    print(f"\nfilled {len(matched)}/{len(specs)}; DOM-verified {dom_ok}; OCR-confirmed {ocr_ok}")
    print("NOT submitting — review in Safari, then submit yourself.")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--profile", default=None, help="override; defaults to the vault, then profile.json")
    ap.add_argument("--port", type=int, default=4712)
    ap.add_argument("--session", action="store_true",
                    help="attach to the authenticated session from webauth.py (reuse login; don't quit it)")
    ap.add_argument("--portal", help="which held portal session to use (else picked by URL host)")
    ap.add_argument("--offscreen", nargs=2, type=int, metavar=("X","Y"))
    ap.add_argument("--shot", default=os.path.join(HERE,"webfill_shot.png"))
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    profile = load_profile(a.profile)

    if a.session:                                   # reuse the held, authenticated session
        portal, st = portals.resolve_session(a.portal, a.url)   # by --portal, else URL host, else sole
        if not st:
            st = load_state()                        # legacy single-session fallback
        if not st:
            print("no held session — run:  webauth.py login-next  (or login <url>) first", file=sys.stderr); return 1
        wd = WD(st["port"], st["session_id"])
        if not wd.alive():
            print(f"held session{' for '+portal if portal else ''} is gone — re-run webauth.py login-next",
                  file=sys.stderr); return 1
        if portal: print(f"using held session for portal: {portal}")
        wd.get(a.url); time.sleep(1.5)
        do_fill(wd, profile, a.shot, a.offscreen)   # never delete a shared session
        return 0

    sd = ensure_driver(a.port)                       # fresh throwaway session
    wd = WD(a.port)
    try:
        wd.start()
        wd.get(a.url); time.sleep(1.5)
        do_fill(wd, profile, a.shot, a.offscreen)
        if not a.keep: wd.delete()
        return 0
    finally:
        if not a.keep: wd.delete()

if __name__ == "__main__":
    sys.exit(main())
