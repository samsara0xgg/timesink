#!/usr/bin/env python3
"""Fetch WhoTracks.me site_categories.csv and emit seed_domains.csv (domain,categoryID)."""
import csv, io, sys, urllib.request

SRC = "https://raw.githubusercontent.com/whotracksme/whotracks.me/master/whotracksme/data/assets/site_categories.csv"
VERSION = 1
MAPPING = {
    "business": "business", "banking": "business", "government": "business",
    "e-commerce": "shopping", "ecommerce": "shopping",
    "entertainment": "entertainment", "recreation": "entertainment", "adult": "entertainment",
    "news and portals": "news", "news": "news",
    "reference": "learning", "education": "learning", "health": "learning",
    "political": "news",
    "uncategorized": None, "unknown": None,
}
VALID = {"softwareDev","learning","writing","business","utilities","communication",
         "news","shopping","socialMedia","entertainment","misc"}

def main():
    raw = urllib.request.urlopen(SRC, timeout=60).read().decode("utf-8")
    reader = csv.DictReader(io.StringIO(raw))
    cols = reader.fieldnames or []
    site_col = next((c for c in cols if "site" in c.lower() or "domain" in c.lower()), cols[0])
    cat_col = next((c for c in cols if "categor" in c.lower()), cols[-1])
    out, unmapped = {}, {}
    for row in reader:
        site = (row.get(site_col) or "").strip().lower().removeprefix("www.")
        cat = (row.get(cat_col) or "").strip().lower()
        if not site or "." not in site:
            continue
        mapped = MAPPING.get(cat, "MISSING")
        if mapped == "MISSING":
            unmapped[cat] = unmapped.get(cat, 0) + 1
            continue
        if mapped in VALID:
            out[site] = mapped
    with open("Sources/TimeSinkKit/Resources/seed_domains.csv", "w") as f:
        f.write(f"# version: {VERSION}\n")
        for site in sorted(out):
            f.write(f"{site},{out[site]}\n")
    print(f"wrote {len(out)} domains")
    if unmapped:
        print("UNMAPPED categories (add to MAPPING and re-run):")
        for cat, n in sorted(unmapped.items(), key=lambda kv: -kv[1]):
            print(f"  {cat}: {n}")

if __name__ == "__main__":
    main()
