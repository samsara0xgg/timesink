#!/usr/bin/env python3
"""Colour tokens: design (OKLCH) and checks. Stdlib only.

  python3 scripts/color_check.py --emit    Swift tables for the harmonised scheme (B) from the OKLCH recipe below
  python3 scripts/color_check.py           checks of Sources/TimeSinkKit/UI/ColorSystem.swift (exit 1 on a failure)
"""
import itertools, pathlib, re, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from colorlib import *

SWIFT = pathlib.Path(__file__).parent.parent / "Sources/TimeSinkKit/UI/ColorSystem.swift"
INK_DARK = "#1D1D1F"
GREYS = ("utilities", "misc", "uncategorized")

# ---- Scheme B recipe: OKLCH (L, C, hue), light mode. Hues are the shipped ones; warm and green fills are
# lifted so a dark label reads on them, the rest stay at L 0.56 where a white label reaches 4.5:1.
B_CATEGORIES = {
    "softwareDev": (0.56, 0.14, 258), "jobSearch": (0.63, 0.065, 72), "learning": (0.80, 0.15, 148),
    "writing": (0.68, 0.10, 197), "research": (0.82, 0.08, 235), "business": (0.56, 0.15, 328),
    "communication": (0.75, 0.15, 58), "entertainment": (0.89, 0.15, 100), "socialMedia": (0.58, 0.18, 27),
    "news": (0.47, 0.13, 280), "utilities": (0.55, 0.015, 260), "misc": (0.68, 0.01, 260),
    "uncategorized": (0.84, 0.005, 260),
}
# Projects: deep jewel tones, darker than any category, hues kept out of the muddy 50-135 band (found by search).
B_PROJECTS = [(0.48, 0.10, 225.6), (0.48, 0.12, 349.5), (0.38, 0.12, 260), (0.48, 0.12, 47.5), (0.52, 0.12, 163.1),
              (0.38, 0.12, 340), (0.36, 0.12, 31), (0.54, 0.12, 290), (0.52, 0.02, 255)]
# Dark mode: white-label fills keep their lightness, lifted fills step down so they glare less.
DARK_OVERRIDE = {"news": (0.45, 0.14, 282), "utilities": (0.67, 0.015, 260), "misc": (0.52, 0.01, 260), "uncategorized": (0.42, 0.006, 260)}
def dark_of(spec, name=None):
    L, C, h = spec
    if name in DARK_OVERRIDE: return DARK_OVERRIDE[name]
    return (L, C * 0.92, h) if L <= 0.56 else (max(0.50, L - 0.07), C * 0.95, h)
# Dark projects must stand off the card (>= 3:1) and still differ for colour-blind eyes: the light hues
# on three lightness tiers (searched for the best minimum distance, label contrast >= 4.5 on every one).
DARK_PROJECT_L = [0.76, 0.52, 0.64, 0.52, 0.76, 0.64, 0.64, 0.52]
def dark_project(spec, index=None):
    L, C, h = spec
    if C < 0.03: return (0.64, 0.02, 255)
    return (DARK_PROJECT_L[index], 0.11, h)

# Magnitude ramp (indigo, low chroma so no category is mistaken for it), 5 stops from "little" to "much".
RAMP_LIGHT = [(0.95, 0.02), (0.85, 0.05), (0.70, 0.09), (0.54, 0.11), (0.38, 0.10)]
RAMP_DARK = [(0.31, 0.035), (0.44, 0.07), (0.58, 0.09), (0.72, 0.095), (0.86, 0.075)]
RAMP_HUE = 275
# Interruption: one soft amber; radar steps from the leading app to the fifth.
AMBER_LIGHT, AMBER_HOVER_LIGHT = (0.79, 0.13, 78), (0.69, 0.145, 72)
AMBER_DARK, AMBER_HOVER_DARK = (0.80, 0.12, 80), (0.87, 0.115, 84)
RADAR_LIGHT = [(0.52, 0.115, 68), (0.62, 0.125, 72), (0.72, 0.13, 76), (0.81, 0.12, 80), (0.89, 0.09, 85)]
RADAR_DARK = [(0.86, 0.11, 84), (0.77, 0.115, 80), (0.68, 0.115, 76), (0.59, 0.105, 72), (0.51, 0.09, 68)]
REST_LIGHT, REST_DARK = (0.74, 0.012, 260), (0.48, 0.012, 260)

def hx(spec): return from_oklch(*spec)
def sw(h): return "0x" + h[1:]

def emit():
    print("// categoriesB")
    for k, s in B_CATEGORIES.items(): print(f'        "{k}": ({sw(hx(s))}, {sw(hx(dark_of(s, k)))}),')
    print("// projectsB")
    for i, s in enumerate(B_PROJECTS): print(f"        ({sw(hx(s))}, {sw(hx(dark_project(s, i)))}),")
    print("// ramp", [hx((L, C, RAMP_HUE)) for L, C in RAMP_LIGHT], [hx((L, C, RAMP_HUE)) for L, C in RAMP_DARK])
    print("// amber", hx(AMBER_LIGHT), hx(AMBER_HOVER_LIGHT), hx(AMBER_DARK), hx(AMBER_HOVER_DARK))
    print("// radar light", [hx(s) for s in RADAR_LIGHT], hx(REST_LIGHT), "dark", [hx(s) for s in RADAR_DARK], hx(REST_DARK))

# ---- Checks on the shipped file
def table(text, name):
    m = re.search(rf"{name}[^=]*=\s*\[(.*?)\]", text, re.S)
    if not m: sys.exit(f"missing table {name}")
    return m.group(1)

def pairs(text, name):
    body = table(text, name)
    named = re.findall(r'"(\w+)":\s*\(0x([0-9A-Fa-f]{6}),\s*0x([0-9A-Fa-f]{6})\)', body)
    if named: return {k: ("#" + a, "#" + b) for k, a, b in named}
    return [("#" + a, "#" + b) for a, b in re.findall(r"\(0x([0-9A-Fa-f]{6}),\s*0x([0-9A-Fa-f]{6})\)", body)]

def check():
    text = SWIFT.read_text()
    fails = []
    def need(ok, msg):
        if not ok: fails.append(msg)
    surfaces = {"light": ("#F5F5F7", "#FFFFFF"), "dark": ("#1B1B1D", "#252528")}
    for scheme in "AB":
        cats, projs = pairs(text, f"categories{scheme}"), pairs(text, f"projects{scheme}")
        print(f"\n=== Scheme {scheme} ===")
        for mode, idx in (("light", 0), ("dark", 1)):
            fills = {k: v[idx] for k, v in cats.items()}
            pf = [v[idx] for v in projs]
            print(f"-- {mode}: label contrast (white or dark ink, whichever is higher; the app picks the same)")
            worst = 99
            for name, f in list(fills.items()) + [(f"project{i}", f) for i, f in enumerate(pf)]:
                ink, c = label_ink(f, INK_DARK)
                worst = min(worst, c)
                need(c >= 4.5, f"{scheme} {mode} {name} {f} label {c:.2f}")
                print(f"   {name:15}{f} {'white' if ink == '#FFFFFF' else 'dark '} {c:5.2f}")
            print(f"   worst label contrast {worst:.2f}")
            chroma = {k: f for k, f in fills.items() if k not in GREYS}
            for kind in ("normal", "deuteranopia", "protanopia"):
                ranked = sorted((delta(simulate(a, kind), simulate(b, kind)), i, j) for (i, a), (j, b) in itertools.combinations(chroma.items(), 2))
                print(f"   categories {kind:13} min dE {ranked[0][0]:.1f} ({ranked[0][1]}/{ranked[0][2]})")
                need(ranked[0][0] >= 4.0 or scheme == "A", f"{scheme} {mode} {kind} categories dE {ranked[0][0]:.1f}")
                prank = sorted((delta(simulate(a, kind), simulate(b, kind)), i, j) for (i, a), (j, b) in itertools.combinations(list(enumerate(pf[:8])), 2))
                print(f"   projects   {kind:13} min dE {prank[0][0]:.1f}")
            vs = min(delta(p, c) for p in pf[:8] for c in fills.values())
            print(f"   projects vs categories (normal) min dE {vs:.1f}")
    # inks on the floor and on a card
    def token(name, idx):
        m = re.search(rf"static let {name} = Design\.color\(light: 0x([0-9A-F]{{6}}),(?: [0-9.]+,)? dark: 0x([0-9A-F]{{6}})", text)
        return "#" + m.group(1 + idx)
    for mode, idx in (("light", 0), ("dark", 1)):
        print(f"\ninks ({mode}):", end=" ")
        for ink in ("ink", "ink2", "iconInk", "warning", "live"):
            for bg in ("floor", "surface"):
                c = contrast(token(ink, idx), token(bg, idx))
                if ink in ("ink", "ink2"): need(c >= 4.5, f"{mode} {ink} on {bg} {c:.2f}")
                print(f"{ink}/{bg} {c:.1f}", end="  ")
        print()
    # ramp and amber: shared by both schemes
    ramp_l = re.findall(r"0x([0-9A-Fa-f]{6})", table(text, "rampLight"))
    ramp_d = re.findall(r"0x([0-9A-Fa-f]{6})", table(text, "rampDark"))
    for mode, ramp, idx in (("light", ramp_l, 0), ("dark", ramp_d, 1)):
        ramp = ["#" + r for r in ramp]
        steps = [delta(a, b) for a, b in zip(ramp, ramp[1:])]
        print(f"\nramp {mode}: {ramp} step dE {[round(s, 1) for s in steps]}")
        need(min(steps) > 6, f"ramp {mode} steps too close")
        for scheme in "AB":
            cats = pairs(text, f"categories{scheme}")
            near = min((delta(r, v[idx]), k) for r in ramp[1:] for k, v in cats.items() if k not in GREYS)
            print(f"   nearest category to ramp stops 2-5, scheme {scheme}: dE {near[0]:.1f} ({near[1]})")
    return fails

if __name__ == "__main__":
    if "--emit" in sys.argv: emit(); sys.exit(0)
    f = check()
    print("\nFAILS:" if f else "\nALL CHECKS PASS", *f, sep="\n  ")
    sys.exit(1 if f else 0)
