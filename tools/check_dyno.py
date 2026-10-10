"""Checks that the files this app writes load in the real Virtual Dyno page.

It simulates one session (cruise, a 4th-gear wide-open pull, a lift), writes the engine .csv and the .gpx exactly as
Core/Sources/DynoLoggerCore (EngineLog.csv, PedalScale, GPX.document) formats them, loads both into the dyno's
index.html in headless Chromium, and prints what the page says: rows read, columns used, GPS matched, and the four
result tiles. Exits 1 if the page rejects a file or finds no pull.

    pip install playwright
    python tools/check_dyno.py /path/to/virtual-dyno [--keep DIR]

The Swift tests pin the exact text format; this script pins that the format is one the dyno accepts. If the writer's
format changes, change it here too.
"""
import asyncio
import datetime as dt
import math
import os
import pathlib
import random
import sys
import tempfile

from playwright.async_api import async_playwright

random.seed(7)
PSI_PER_KPA = 1 / 6.89476


def simulate():
    """(engine samples, track points) for a 2016 Golf R-ish car, ~20 Hz OBD with jitter, 25 Hz GPS."""
    tq = [(2000, 240), (2500, 300), (3000, 340), (3500, 360), (4000, 362), (4500, 355), (5000, 345), (5500, 328),
          (6000, 308), (6500, 275), (6800, 255)]

    def torque(r):
        if r <= tq[0][0]:
            return tq[0][1]
        for (a, b), (c, e) in zip(tq, tq[1:]):
            if r <= c:
                return b + (e - b) * (r - a) / (c - a)
        return tq[-1][1]

    k = 150.0                         # RPM per m/s in 4th
    mass = (3300 + 200) * 0.453592 + 36
    v, t, dt_sim = 1900 / k, 0.0, 0.005
    states = []                       # (t, v, pedal_raw, map_kpa)
    while t < 30:
        r = k * v
        if t < 8:
            pedal, F = 22.0, 0.5 * 1.2 * .32 * 2.2 * v * v + .012 * mass * 9.81    # steady cruise
        elif r < 6700 and t < 25:
            pedal = 81.2
            P = torque(r) * 1.35582 * r * math.pi / 30
            F = P * 0.8 / v
        else:
            pedal, F = 15.3, -300.0
        a = (F - 0.5 * 1.2 * .32 * 2.2 * v * v - .012 * mass * 9.81) / (mass + 36)
        boost = 0 if pedal < 50 else min(20, max(0, (r - 2000) / 1600 * 19))
        states.append((t, v, pedal, 98 + boost / PSI_PER_KPA))
        v += a * dt_sim
        t += dt_sim

    def at(T):
        i = min(int(T / dt_sim), len(states) - 1)
        return states[i]

    engine, T = [], 0.0
    cycle = 0
    while T < 29.5:
        _, v, ped, mp = at(T)
        s = dict(time=T, rpm=k * v + random.uniform(-15, 15), kmh=round(v * 3.6), ped=round(ped * 255 / 100) * 100 / 255,
                 map=round(mp), baro=None, amb=None)
        if cycle % 30 == 0:
            s["baro"], s["amb"] = 98.0, 21.0
        engine.append(s)
        T += random.uniform(0.04, 0.06)
        cycle += 1

    start = dt.datetime(2026, 10, 10, 17, 5, 3, tzinfo=dt.timezone.utc)
    lat0, lon0, ele0 = 39.7392358, -104.990251, 1609.3
    track, T, x = [], 0.0, 0.0
    while T < 29.5:
        _, v, _, _ = at(T)
        track.append(dict(time=start + dt.timedelta(seconds=T + 3.0), lat=lat0, lon=lon0 + x / (111320 * math.cos(math.radians(lat0))),
                          ele=ele0 + x * 0.002, speed=v + random.gauss(0, 0.05), course=90.0, sat=14, hdop=0.7))
        x += v * 0.04
        T += 0.04
    return engine, track


def engine_csv(samples):
    """Mirror of EngineLog.csv(_:pedalSource: .pedal)."""
    vals = sorted(s["ped"] for s in samples)
    lo, hi = vals[int((len(vals) - 1) * 0.02)], vals[int((len(vals) - 1) * 0.995)]
    if hi - lo < 25:
        lo, hi = 0, 100
    lines = ["Time (msec),Engine Speed (RPM),Vehicle Speed (km/h),Accel. Pedal Position (%),Ambient Air Temp (F),"
             "Ambient Pressure (psi),Boost Press. (psi)"]
    last, baro, amb = None, None, None
    for s in samples:
        baro = s["baro"] if s["baro"] is not None else baro
        amb = s["amb"] if s["amb"] is not None else amb
        ms = round(s["time"] * 1000)
        if last is not None and ms <= last:
            continue
        last = ms
        ped = min(100, max(0, (s["ped"] - lo) / (hi - lo) * 100))
        lines.append(",".join([str(ms), str(round(s["rpm"])), str(s["kmh"]), f"{ped:.1f}",
                               "" if amb is None else f"{amb * 9 / 5 + 32:.1f}",
                               "" if baro is None else f"{baro * PSI_PER_KPA:.2f}",
                               f"{(s['map'] - (baro or 101.325)) * PSI_PER_KPA:.1f}"]))
    return "\n".join(lines) + "\n"


def gpx(points, name):
    """Mirror of GPX.document(_:name:)."""
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<gpx version="1.0" creator="Virtual Dyno Logger" xmlns="http://www.topografix.com/GPX/1/0">',
           f"<trk><name>{name}</name><trkseg>"]
    for p in points:
        ts = p["time"].strftime("%Y-%m-%dT%H:%M:%S.") + f"{p['time'].microsecond // 1000:03d}Z"
        out.append(f'<trkpt lat="{p["lat"]:.7f}" lon="{p["lon"]:.7f}"><ele>{p["ele"]:.2f}</ele><time>{ts}</time>'
                   f'<course>{p["course"]:.1f}</course><speed>{p["speed"]:.3f}</speed><sat>{p["sat"]}</sat>'
                   f'<hdop>{p["hdop"]:.2f}</hdop></trkpt>')
    out.append("</trkseg></trk>\n</gpx>\n")
    return "\n".join(out)


async def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    page_url = (pathlib.Path(sys.argv[1]) / "index.html").resolve().as_uri()
    keep = pathlib.Path(sys.argv[sys.argv.index("--keep") + 1]) if "--keep" in sys.argv else None
    d = keep or pathlib.Path(tempfile.mkdtemp())
    d.mkdir(parents=True, exist_ok=True)
    engine, track = simulate()
    name = "GolfR_2026-10-10_110503"
    (d / f"{name}.csv").write_text(engine_csv(engine))
    (d / f"{name}.gpx").write_text(gpx(track, name))

    async with async_playwright() as pw:
        b = await pw.chromium.launch(executable_path=os.environ.get("CHROMIUM") or None)
        ctx = await b.new_context(viewport={"width": 1200, "height": 900}, reduced_motion="reduce")
        page = await ctx.new_page()
        errors = []
        page.on("pageerror", lambda e: errors.append(str(e)))
        await page.add_init_script("try{sessionStorage.setItem('dyno-boot','1')}catch(e){}")
        await page.goto(page_url)
        await page.wait_for_timeout(300)
        await page.set_input_files("#file", str(d / f"{name}.csv"))
        await page.wait_for_timeout(500)
        await page.set_input_files("#gps", str(d / f"{name}.gpx"))
        await page.wait_for_timeout(2800)
        msg = await page.inner_text("#msg")
        gmsg = await page.inner_text("#gmsg")
        failed = [i for i in ("#msg", "#gmsg") if "err" in (await page.get_attribute(i, "class") or "")]
        tiles = await page.evaluate("""['s1','s2','s3','s4'].map(id=>{const e=document.getElementById(id);
            return e.querySelector('legend').textContent+': '+e.querySelector('.n').textContent+' '+e.querySelector('i').textContent+' '+e.querySelector('em').textContent})""")
        fields = await page.evaluate("""['temp','da','head','grade'].map(id=>id+'='+document.getElementById(id).value)""")
        await b.close()

    print("engine log:", msg, "\ngps:", gmsg, "\nfields:", ", ".join(fields))
    print("\n".join(tiles))
    bad = errors or failed or not any(c.isdigit() for c in tiles[0].split(":")[1].split()[0])
    if errors:
        print("page errors:", errors)
    if keep:
        print("files kept in", keep)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    asyncio.run(main())
