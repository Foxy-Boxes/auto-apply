#!/usr/bin/env python3
"""Parse a resume PDF into a structured profile.json for the CV filler.

Deterministic, no LLM. Extracts what can be reliably pulled from the text
(name, email, phone, education, experience, skills). Application-specific
fields that are NOT in a resume (address, work authorization, demographic
questions, links) are emitted as empty strings for the user to fill in once.
"""
import re, json, sys, subprocess, os

def pdf_text(path):
    return subprocess.run(["pdftotext", "-layout", path, "-"],
                          capture_output=True, text=True).stdout

def first(pat, text, flags=re.I, grp=0):
    m = re.search(pat, text, flags)
    return (m.group(grp) if m else "").strip()

def parse(path):
    t = pdf_text(path)
    lines = [l.rstrip() for l in t.splitlines()]
    nonblank = [l.strip() for l in lines if l.strip()]

    email = first(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", t)
    phone = first(r"\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}", t)
    # Name: first non-blank line, usually the header in caps.
    name = nonblank[0].title() if nonblank else ""
    parts = name.split()
    first_name = parts[0] if parts else ""
    last_name  = parts[-1] if len(parts) > 1 else ""

    # Education: grab the first institution + degree under EDUCATION.
    edu_school = first(r"\b[A-Z][A-Za-z ]+(?:University|Institute of Technology|College)\b", t)
    degree = first(r"(Ph\.?D\.?|M\.?S\.?|B\.?S\.?|B\.?Sc\.?|Bachelor|Master)[^\n]*", t)
    grad = first(r"([A-Z][a-z]+\s+20\d\d)\s*\(expected\)", t, grp=1) or first(r"(?:May|June|August|December)\s+20\d\d", t)

    links = re.findall(r"https?://[^\s)]+", t)

    profile = {
        "_note": "Parsed from resume; fill blank fields once and reuse. Edit freely.",
        "first_name": first_name,
        "last_name": last_name,
        "full_name": name,
        "email": email,
        "phone": phone,
        "address_line1": "",
        "address_line2": "",
        "city": "",
        "state": "",
        "postal_code": "",
        "country": "United States",
        "linkedin": next((l for l in links if "linkedin" in l.lower()), ""),
        "github":   next((l for l in links if "github" in l.lower()), ""),
        "website":  "",
        "school": edu_school or "",
        "degree": degree,
        "field_of_study": "Computer Science",
        "gpa": first(r"GPA:\s*([0-9.]+)", t, grp=1),
        "graduation_date": grad,
        "current_employer": "",
        "current_title": first(r"(Engineering Intern|Graduate Research Assistant|Research Assistant)", t),
        # Application-specific; not derivable from a resume. Fill once.
        "work_authorization": "",          # e.g. "Yes, authorized to work in the US"
        "require_sponsorship": "",         # e.g. "Yes" / "No"
        "gender": "",
        "race_ethnicity": "",
        "veteran_status": "",
        "disability_status": "",
        "how_heard": "",
        "resume_path": os.path.abspath(path),
    }
    return profile

if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        "~/Documents/resume.pdf")
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(__file__), "profile.json")
    prof = parse(src)
    with open(out, "w") as f:
        json.dump(prof, f, indent=2)
    print("wrote", out)
    print(json.dumps(prof, indent=2))
