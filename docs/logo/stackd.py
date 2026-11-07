"""Generates the stackd logo: three cups put away one inside the other, each
leaning further than the one below, beside the wordmark.

Each cup sits inside the one under it, so the lower cup is drawn in front.
A cup behind is cut by a gap round every cup in front of it (a mask, not a
paper-coloured stroke), so the SVGs stay transparent on any background.

Writes stackd-light.svg, stackd-dark.svg, stackd.svg (follows
prefers-color-scheme) and stackd-icon.svg (the cups on a rounded tile).
"""
import os

INK = {"light": "#18181b", "dark": "#f4f4f2"}
TILE = {"light": "#f1f1ee", "dark": "#1c1c20"}

W, H = 58, 52        # cup rim width, cup depth
HANDLE_R, HOLE_R = 13, 5
GAP = 4              # clear space round a cup that sits in front
# rim centre x, y and lean in degrees, top cup first; side = handle side
CUPS = [(72, -2, 26, -1), (58, 30, 10, -1), (48, 62, -4, 1)]
MARK_BOX = (2, -22, 118, 138)

# "stackd" in Geist (SIL OFL 1.1), weight 780, 60 px, tracking -0.02 em,
# outlined at baseline 0; advance width and x-height below.
WORD = "M18.02 0.72Q12.85 0.72 9.4 -0.68Q5.95 -2.09 4.14 -4.54Q2.33 -6.99 2.09 -10.16L12.25 -10.47Q12.64 -8.32 14.03 -7.2Q15.42 -6.09 18.07 -6.09Q20.26 -6.09 21.43 -6.79Q22.61 -7.5 22.61 -8.93Q22.61 -9.87 22.14 -10.51Q21.68 -11.14 20.37 -11.61Q19.07 -12.08 16.51 -12.5Q11.27 -13.38 8.3 -14.59Q5.32 -15.8 4.1 -17.72Q2.87 -19.64 2.87 -22.53Q2.87 -27.24 6.59 -30.11Q10.3 -32.98 17.79 -32.98Q22.51 -32.98 25.71 -31.54Q28.9 -30.11 30.66 -27.57Q32.42 -25.03 32.81 -21.68L22.78 -21.32Q22.61 -22.86 21.94 -23.95Q21.28 -25.03 20.22 -25.6Q19.16 -26.17 17.69 -26.17Q15.59 -26.17 14.4 -25.28Q13.21 -24.4 13.21 -22.86Q13.21 -21.8 13.74 -21.11Q14.26 -20.41 15.48 -19.99Q16.71 -19.56 18.75 -19.26Q23.98 -18.56 27.09 -17.27Q30.2 -15.98 31.57 -13.99Q32.95 -12 32.95 -9.16Q32.95 -5.99 31.14 -3.78Q29.33 -1.58 25.99 -0.43Q22.66 0.72 18.02 0.72ZM51.37 0Q46.19 0 43.78 -2.41Q41.36 -4.83 41.36 -10.08V-39.83H51.42V-11.38Q51.42 -9.04 52.4 -8.18Q53.39 -7.31 55.41 -7.31H59.88V0ZM36.05 -24.94V-32.26H59.88V-24.94ZM73.74 0.72Q68.69 0.72 65.48 -1.61Q62.27 -3.93 62.27 -8.1Q62.27 -12.36 65.01 -14.68Q67.76 -17 73.02 -18.1L83.12 -20.15Q83.12 -23.03 81.84 -24.51Q80.57 -25.99 78.2 -25.99Q75.86 -25.99 74.55 -24.88Q73.25 -23.78 72.85 -21.66L62.81 -22.03Q63.76 -27.58 67.73 -30.28Q71.71 -32.98 78.2 -32.98Q85.69 -32.98 89.43 -29.55Q93.17 -26.12 93.17 -19.38V-9.02Q93.17 -7.57 93.65 -7.1Q94.14 -6.63 95.04 -6.63H95.84V0Q95.37 0.15 94.33 0.27Q93.29 0.39 92.28 0.39Q90.44 0.39 88.7 -0.23Q86.96 -0.85 85.86 -2.5Q84.76 -4.15 84.76 -7.24L85.54 -6.48Q84.94 -4.3 83.41 -2.68Q81.88 -1.05 79.46 -0.16Q77.04 0.72 73.74 0.72ZM76.32 -5.91Q78.31 -5.91 79.83 -6.71Q81.36 -7.5 82.24 -9.04Q83.12 -10.58 83.12 -12.81V-14.17L76.63 -12.71Q74.71 -12.29 73.66 -11.38Q72.61 -10.47 72.61 -9.04Q72.61 -7.55 73.54 -6.73Q74.47 -5.91 76.32 -5.91ZM114.25 0.72Q109.17 0.72 105.4 -1.37Q101.63 -3.45 99.53 -7.25Q97.43 -11.04 97.43 -16.13Q97.43 -21.21 99.53 -24.98Q101.63 -28.74 105.4 -30.86Q109.17 -32.98 114.25 -32.98Q118.68 -32.98 122.19 -31.41Q125.7 -29.85 127.89 -26.96Q130.08 -24.06 130.53 -19.98L120.19 -19.52Q119.78 -22.48 118.2 -23.96Q116.62 -25.44 114.25 -25.44Q111.14 -25.44 109.46 -23Q107.77 -20.55 107.77 -16.13Q107.77 -11.66 109.46 -9.21Q111.14 -6.77 114.25 -6.77Q116.67 -6.77 118.27 -8.27Q119.88 -9.78 120.19 -12.97L130.53 -12.61Q130.13 -8.52 127.98 -5.52Q125.84 -2.52 122.33 -0.9Q118.82 0.72 114.25 0.72ZM134.51 0V-42.6H144.56V-20.13L155.57 -32.26H167.49L155 -19.08L167.8 0H156.94L148.52 -13.51L144.56 -9.28V0ZM184.53 0.72Q180.48 0.72 177.55 -1.34Q174.61 -3.41 173.01 -7.19Q171.41 -10.98 171.41 -16.13Q171.41 -21.27 173.03 -25.06Q174.65 -28.85 177.61 -30.91Q180.58 -32.98 184.53 -32.98Q188.03 -32.98 190.49 -31.56Q192.95 -30.14 194.22 -27.63V-42.6H204.28V0H194.57L194.39 -4.71Q193.07 -2.13 190.48 -0.7Q187.89 0.72 184.53 0.72ZM188.02 -6.77Q190.02 -6.77 191.4 -7.8Q192.78 -8.83 193.5 -10.91Q194.22 -12.98 194.22 -16.13Q194.22 -19.3 193.5 -21.37Q192.78 -23.44 191.4 -24.46Q190.02 -25.49 188.02 -25.49Q185.14 -25.49 183.45 -22.97Q181.75 -20.46 181.75 -16.13Q181.75 -11.9 183.47 -9.33Q185.18 -6.77 188.02 -6.77Z"
WORD_W, WORD_X = 207.96, 32.28


def f(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def body():
    """Cup body, rim centre at the origin: straight-ish sides into a round foot."""
    a = W / 2
    return (f"M{f(-a)} 0H{f(a)}V{f(H*.18)}C{f(a)} {f(H*.62)} {f(a*.72)} {H} {f(a*.32)} {H}"
            f"H{f(-a*.32)}C{f(-a*.72)} {H} {f(-a)} {f(H*.62)} {f(-a)} {f(H*.18)}Z")


def handle(side):
    a = W / 2
    hx, hy = side * (a + HANDLE_R - 3), H * 0.34
    neck_x = min(side * a, hx)
    return hx, hy, (f'<circle cx="{f(hx)}" cy="{f(hy)}" r="{HANDLE_R}"/>'
                    f'<rect x="{f(neck_x)}" y="{f(hy-6)}" width="{f(abs(hx - side*a))}" height="12"/>')


def place(x, y, rot):
    return f'translate({f(x)} {f(y)}) rotate({rot})'


def cups(cls, fill=None):
    """The cups, back to front; each masked by its hole and the gaps of the cups in front."""
    paint = f'class="{cls}"' if cls else f'fill="{fill}"'
    x0, y0, w, h = MARK_BOX
    box = f'x="{x0-20}" y="{y0-20}" width="{w+40}" height="{h+40}"'
    defs, out = [], []
    for i, (x, y, rot, side) in enumerate(CUPS):
        hx, hy, hd = handle(side)
        cut = f'<circle cx="{f(hx)}" cy="{f(hy)}" r="{HOLE_R}" fill="#000" transform="{place(x, y, rot)}"/>'
        for (fx, fy, frot, fside) in CUPS[i + 1:]:
            _, _, fhd = handle(fside)
            cut += (f'<g transform="{place(fx, fy, frot)}" fill="#000" stroke="#000" '
                    f'stroke-width="{2*GAP}" stroke-linejoin="round"><path d="{body()}"/>{fhd}</g>')
        mid = f"{cls or 'c'}{i}"
        defs.append(f'<mask id="{mid}" maskUnits="userSpaceOnUse" {box}><rect {box} fill="#fff"/>{cut}</mask>')
        out.append(f'<g mask="url(#{mid})"><g transform="{place(x, y, rot)}" {paint}><path d="{body()}"/>{hd}</g></g>')
    return "<defs>" + "".join(defs) + "</defs>" + "".join(out)


def lockup(cls=None, fill=None, gap=24):
    x0, y0, w, h = MARK_BOX
    s = 88 / h
    mw = w * s
    base = 44 + WORD_X / 2
    paint = f'class="{cls}"' if cls else f'fill="{fill}"'
    vb = (-4, -4, mw + gap + WORD_W + 8, 96)
    inner = (f'<g transform="scale({s:.4f}) translate({f(-x0)} {f(-y0)})">{cups(cls, fill)}</g>'
             f'<path transform="translate({f(mw + gap)} {f(base)})" d="{WORD}" {paint}/>')
    return vb, inner


def svg(vb, inner, style=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{" ".join(f(v) for v in vb)}" '
            f'width="{f(vb[2]*2)}" height="{f(vb[3]*2)}">{style}{inner}</svg>\n')


def squircle(n):
    k = n * 0.2237 * 1.528
    c = k * 0.45
    return (f"M{f(k)} 0H{f(n-k)}C{f(n-c)} 0 {n} {f(c)} {n} {f(k)}V{f(n-k)}C{n} {f(n-c)} {f(n-c)} {n} {f(n-k)} {n}"
            f"H{f(k)}C{f(c)} {n} 0 {f(n-c)} 0 {f(n-k)}V{f(k)}C0 {f(c)} {f(c)} 0 {f(k)} 0Z")


def adaptive(rules):
    light = "".join(f".{k}{{fill:{v[0]}}}" for k, v in rules.items())
    dark = "".join(f".{k}{{fill:{v[1]}}}" for k, v in rules.items())
    return f"<style>{light}@media (prefers-color-scheme:dark){{{dark}}}</style>"


def icon(n=1024, pad=0.2):
    x0, y0, w, h = MARK_BOX
    s = n * (1 - 2 * pad) / max(w, h)
    tx, ty = n / 2 - (x0 + w / 2) * s, n / 2 - (y0 + h / 2) * s
    inner = (f'<path d="{squircle(n)}" class="t"/>'
             f'<g transform="translate({f(tx)} {f(ty)}) scale({s:.4f})">{cups("m")}</g>')
    return svg((0, 0, n, n), inner, adaptive({"t": (TILE["light"], TILE["dark"]), "m": (INK["light"], INK["dark"])}))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = {
        "stackd-light.svg": svg(*lockup(fill=INK["light"])),
        "stackd-dark.svg": svg(*lockup(fill=INK["dark"])),
        "stackd.svg": svg(*lockup(cls="m"), adaptive({"m": (INK["light"], INK["dark"])})),
        "stackd-icon.svg": icon(),
    }
    for name, text in out.items():
        with open(os.path.join(here, name), "w") as fh:
            fh.write(text)


if __name__ == "__main__":
    main()
