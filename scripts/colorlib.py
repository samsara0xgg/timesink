"""OKLCH, WCAG contrast and colour-blind simulation helpers (stdlib only)."""
import math

def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))

def rgb_hex(rgb):
    return "#" + "".join(f"{round(max(0, min(1, c)) * 255):02X}" for c in rgb)

def to_lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

def to_srgb(c):
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055

def lin_to_oklab(r, g, b):
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = (math.copysign(abs(x) ** (1 / 3), x) for x in (l, m, s))
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)

def oklab_to_lin(L, a, b):
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)

def oklab(hexv):
    return lin_to_oklab(*(to_lin(c) for c in hex_rgb(hexv)))

def oklch(hexv):
    L, a, b = oklab(hexv)
    return L, math.hypot(a, b), math.degrees(math.atan2(b, a)) % 360

def from_oklch(L, C, h, fit=True):
    """sRGB hex; chroma is reduced until the colour is inside the gamut."""
    while True:
        a, b = C * math.cos(math.radians(h)), C * math.sin(math.radians(h))
        lin = oklab_to_lin(L, a, b)
        if not fit or all(-0.0005 <= c <= 1.0005 for c in lin) or C <= 0:
            return rgb_hex(tuple(to_srgb(max(0, min(1, c))) for c in lin))
        C -= 0.002

def luminance(hexv):
    r, g, b = (to_lin(c) for c in hex_rgb(hexv))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)

# Machado, Oliveira, Fernandes 2009, severity 1.0, applied in linear sRGB.
MACHADO = {
    "deuteranopia": ((0.367322, 0.860646, -0.227968), (0.280085, 0.672501, 0.047413), (-0.011820, 0.042940, 0.968881)),
    "protanopia": ((0.152286, 1.052583, -0.204868), (0.114503, 0.786281, 0.099216), (-0.003882, -0.048116, 1.051998)),
}

def simulate(hexv, kind):
    if kind == "normal":
        return hexv
    lin = [to_lin(c) for c in hex_rgb(hexv)]
    m = MACHADO[kind]
    out = [sum(row[i] * lin[i] for i in range(3)) for row in m]
    return rgb_hex(tuple(to_srgb(max(0, min(1, c))) for c in out))

def delta(a, b):
    """OKLab distance x 100 (about 2 is a just-noticeable difference)."""
    return 100 * math.dist(oklab(a), oklab(b))

def label_ink(fill, dark="#1D1D1F"):
    """White or the dark ink, whichever has more contrast on the fill."""
    return ("#FFFFFF", contrast("#FFFFFF", fill)) if contrast("#FFFFFF", fill) >= contrast(dark, fill) else (dark, contrast(dark, fill))
