#!/usr/bin/env python3
"""jobsearch -- find internships across company career portals, deterministically.

No LLM at runtime: each adapter hits the company's real public careers API/page and
extracts postings by fixed rules. Lists the openings, saves them to cvfill/jobs.json,
and with --enqueue pushes each portal's login into the authenticator's queue so you
can sign in to each one once (webauth.py login-next) before filling applications.

Adapters:
  nvidia  -> Workday CXS JSON   (clean: title/location/posted/id)
  apple   -> jobs.apple.com /api/v1 (CSRF token + cookie, then search)
  google  -> careers results page (regex-extract job links)
  <greenhouse board> / <lever board> -> generic JSON (extensible; --greenhouse/--lever)

Usage:
  jobsearch.py [--query intern] [--companies nvidia,apple,google] [--limit 20]
               [--greenhouse NAME ...] [--lever NAME ...] [--enqueue] [--json]
"""
import argparse, http.cookiejar, json, os, re, sys, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import portals

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 cvfill-jobsearch"

def _open(req, opener):
    # a built opener exposes .open; the module exposes .urlopen
    return (opener.open if opener else urllib.request.urlopen)(req, timeout=30)

def _get(url, headers=None, opener=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    with _open(req, opener) as r:
        return r.read().decode("utf-8", "replace"), dict(r.headers)

def _post_json(url, body, headers=None, opener=None):
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method="POST",
        headers={"User-Agent": UA, "Content-Type": "application/json",
                 "Accept": "application/json", **(headers or {})})
    with _open(req, opener) as r:
        return json.loads(r.read().decode("utf-8", "replace"))

# "intern"/"internship" but NOT "international"
def is_internship(text):
    return bool(re.search(r"intern(?!ational)", text or "", re.I))

def job(company, portal, title, location, url, posted="", jid=""):
    return {"company": company, "portal": portal, "title": title.strip(),
            "location": location.strip(), "url": url, "posted": posted, "id": jid}

# ---- adapters ----
def search_workday(portal, query, limit):
    m = portals.portal_meta(portal)
    url = f"{m['base']}/wday/cxs/{m['tenant']}/{m['site']}/jobs"
    out, offset, pagesize = [], 0, min(limit, 20)
    while len(out) < limit:
        data = _post_json(url, {"appliedFacets": {}, "limit": pagesize,
                                "offset": offset, "searchText": query})
        posts = data.get("jobPostings", [])
        if not posts:
            break
        for j in posts:
            title = j.get("title", "")
            if not is_internship(title):
                continue
            path = j.get("externalPath", "")
            full = f"{m['base']}/en-US/{m['site']}{path}" if path else m["base"]
            jid = (j.get("bulletFields") or [""])[0]
            out.append(job(m["company"], portal, title, j.get("locationsText", ""),
                           full, j.get("postedOn", ""), jid))
            if len(out) >= limit:
                break
        offset += pagesize
        if offset >= data.get("total", 0):
            break
    return out

def search_apple(portal, query, limit):
    m = portals.portal_meta(portal)
    cj = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
    _, hdr = _get("https://jobs.apple.com/api/v1/csrfToken", opener=opener)
    token = hdr.get("X-Apple-CSRF-Token") or hdr.get("x-apple-csrf-token")
    out, page = [], 1
    while len(out) < limit and page <= 5:
        res = _post_json("https://jobs.apple.com/api/v1/search",
            {"query": query, "filters": {"range": {"standardWeeklyHours": {"start": None, "end": None}}},
             "page": page, "locale": "en-us", "sort": "relevance",
             "format": {"longDate": "MMMM D, YYYY", "mediumDate": "MMM D, YYYY"}},
            headers={"X-Apple-CSRF-Token": token or "",
                     "Referer": "https://jobs.apple.com/en-us/search",
                     "Origin": "https://jobs.apple.com"}, opener=opener)
        results = (res.get("res") or {}).get("searchResults") or []
        if not results:
            break
        for r in results:
            title = r.get("postingTitle") or r.get("title") or ""
            if not is_internship(title):
                continue
            pid = r.get("positionId") or r.get("id", "")
            slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
            url = f"https://jobs.apple.com/en-us/details/{pid}/{slug}" if pid \
                  else "https://jobs.apple.com/en-us/search?search=" + urllib.parse.quote(query)
            locs = ", ".join(l.get("name", "") for l in (r.get("locations") or []))
            out.append(job(m["company"], portal, title, locs, url,
                           r.get("postingDate", "") or r.get("postDateInGMT", ""), pid))
            if len(out) >= limit:
                break
        page += 1
    return out

def search_google(portal, query, limit):
    m = portals.portal_meta(portal)
    base = "https://www.google.com/about/careers/applications/jobs/results/"
    html, _ = _get(base + "?" + urllib.parse.urlencode({"q": query}))
    out, seen = [], set()
    for mt in re.finditer(r"jobs/results/(\d+)-([a-z0-9\-]+?)(?:\?|&|\"|')", html):
        jid, slug = mt.group(1), mt.group(2)
        if jid in seen:
            continue
        seen.add(jid)
        title = slug.replace("-", " ").title()
        if not is_internship(title):
            continue
        out.append(job(m["company"], portal, title, "",
                       f"{base}{jid}-{slug}", "", jid))
        if len(out) >= limit:
            break
    return out

def search_greenhouse(name, query, limit):
    data = json.loads(_get(f"https://boards-api.greenhouse.io/v1/boards/{name}/jobs?content=false")[0])
    out = []
    for j in data.get("jobs", []):
        title = j.get("title", "")
        if not (is_internship(title) or query.lower() in title.lower()):
            continue
        out.append(job(name.title(), "gh:" + name, title,
                       (j.get("location") or {}).get("name", ""),
                       j.get("absolute_url", ""), j.get("updated_at", ""), str(j.get("id", ""))))
        if len(out) >= limit:
            break
    return out

def search_lever(name, query, limit):
    data = json.loads(_get(f"https://api.lever.co/v0/postings/{name}?mode=json&limit=100")[0])
    out = []
    for j in data:
        title = j.get("text", "")
        if not (is_internship(title) or query.lower() in title.lower()):
            continue
        out.append(job(name.title(), "lever:" + name, title,
                       (j.get("categories") or {}).get("location", ""),
                       j.get("hostedUrl", ""), "", j.get("id", "")))
        if len(out) >= limit:
            break
    return out

ADAPTERS = {"nvidia": search_workday, "apple": search_apple, "google": search_google}

def run_source(portal, query, limit):
    try:
        return ADAPTERS[portal](portal, query, limit), None
    except Exception as e:
        return [], f"{type(e).__name__}: {e}"

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--query", default="intern")
    ap.add_argument("--companies", default="nvidia,apple,google",
                    help="comma list from: " + ",".join(ADAPTERS))
    ap.add_argument("--limit", type=int, default=20, help="max postings per source")
    ap.add_argument("--greenhouse", action="append", default=[], metavar="BOARD",
                    help="extra Greenhouse board slug (repeatable)")
    ap.add_argument("--lever", action="append", default=[], metavar="BOARD",
                    help="extra Lever board slug (repeatable)")
    ap.add_argument("--enqueue", action="store_true",
                    help="queue a login for each portal found (webauth.py login-next)")
    ap.add_argument("--json", action="store_true", help="print raw JSON instead of a table")
    ap.add_argument("--out", default=os.path.join(HERE, "jobs.json"))
    a = ap.parse_args()

    all_jobs, errors = [], []
    for portal in [c.strip() for c in a.companies.split(",") if c.strip()]:
        if portal not in ADAPTERS:
            errors.append(f"{portal}: unknown company"); continue
        jobs, err = run_source(portal, a.query, a.limit)
        all_jobs += jobs
        print(f"  {portal:8} {len(jobs):3} internship(s)" + (f"  [!] {err}" if err else ""),
              file=sys.stderr)
        if err:
            errors.append(f"{portal}: {err}")
    for name in a.greenhouse:
        try: all_jobs += search_greenhouse(name, a.query, a.limit)
        except Exception as e: errors.append(f"greenhouse/{name}: {e}")
    for name in a.lever:
        try: all_jobs += search_lever(name, a.query, a.limit)
        except Exception as e: errors.append(f"lever/{name}: {e}")

    with open(a.out, "w") as f:
        json.dump({"query": a.query, "count": len(all_jobs), "jobs": all_jobs}, f, indent=2)

    if a.json:
        print(json.dumps(all_jobs, indent=2))
    else:
        print(f"\n{len(all_jobs)} internship posting(s) for {a.query!r}:\n")
        w = max([len(j["company"]) for j in all_jobs], default=7)
        for j in all_jobs:
            loc = f"  ({j['location']})" if j["location"] else ""
            print(f"  [{j['company']:<{w}}] {j['title']}{loc}")
            print(f"  {' '*w}   {j['url']}")
        print(f"\nsaved -> {a.out}")

    if a.enqueue:
        seen = {}
        for j in all_jobs:
            portal = j["portal"]
            meta = portals.portal_meta(portal)
            if not meta or portal in seen:        # only known portals have a login flow
                continue
            seen[portal] = portals.enqueue(portal, meta["company"], meta["login_url"])
        queued = [p for p, added in seen.items() if added]
        skipped = [p for p, added in seen.items() if not added]
        print("\n=== login queue ===")
        if queued:  print("  queued login for:", ", ".join(queued))
        if skipped: print("  already queued:   ", ", ".join(skipped))
        print("  next:  python3 cvfill/webauth.py login-next   (then log in by hand)")
        print("  list:  python3 cvfill/webauth.py queue")

    if errors:
        print("\nnotes:", file=sys.stderr)
        for e in errors:
            print("  -", e, file=sys.stderr)
    return 0

if __name__ == "__main__":
    sys.exit(main())
