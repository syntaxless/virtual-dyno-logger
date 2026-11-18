# Dyno Logger (iOS)

An iPhone app that records a run from an OBD-II adapter, a GPS and a GoPro at the same time and saves the two files
the [Virtual Dyno](https://dyno.turboloser.co) reads.

| Source | How it connects | What it records |
| --- | --- | --- |
| ELM327 BLE OBD-II adapter (OBDLink CX/MX+, Vgate iCar Pro, vLinker, Veepeak...) | CoreBluetooth, ELM327 text commands | RPM, speed, accelerator pedal (or throttle), manifold pressure, barometric pressure, ambient temperature |
| RaceBox Mini / Mini S / Micro | CoreBluetooth, Nordic UART, RaceBox binary messages | 25 Hz GPS: position, speed, heading, altitude |
| Any BLE GPS that sends NMEA over Nordic UART | CoreBluetooth | GPS at the receiver's rate |
| The iPhone's own GPS | CoreLocation | about 1 Hz GPS (used when no external GPS is connected) |
| The iPhone's barometer | CoreMotion (CMAltimeter) | air pressure, and altitude change in steps of about 10 cm for road grade |
| Open-Meteo weather | HTTPS, at the start and end of a run (a switch on the Record screen) | humidity, wind, air temperature and sea-level pressure where the phone is |
| GoPro HERO9 or later | Open GoPro BLE | starts and stops video with the run; sets the camera clock to the phone's so the video lines up with the logs |

Dragy is listed but not supported: its Bluetooth protocol is not public. Export the run from the Dragy app and load its
CSV into the dyno's GPS box, which already reads Dragy files.

## What it writes

Each run is a folder in the app's Documents (Files app: On My iPhone > Dyno Logger > Sessions):

```
GolfR_2026-10-10_170503/
  GolfR_2026-10-10_170503.csv   -> dyno's "Cobb Accessport log" box
  GolfR_2026-10-10_170503.gpx   -> dyno's "RaceBox, Dragy or GPX" box (video-overlay reads it too)
  session.json
```

The `.csv` uses Cobb Accessport column names, because that is what the dyno's `parse()` matches:

```
Time (msec),Engine Speed (RPM),Vehicle Speed (km/h),Accel. Pedal Position (%),Ambient Air Temp (F),Ambient Pressure (psi),Boost Press. (psi)
0,2400,50,16.1,69.8,14.21,0.3
```

- Speed stays in km/h, the resolution OBD-II reports; the dyno converts it and rebuilds stepped speed from RPM.
- The pedal is rescaled so a floored pedal reads 100 %. OBD pedal sensors rest near 15 % and top out near 80 %, and the
  dyno only counts a pull above its "Throttle Position >=" field (90 % by default).
- Boost is gauge pressure: manifold pressure minus the logged barometric pressure.
- Ambient temperature and pressure fill the dyno's air temperature and density altitude.

After those come columns the dyno can pick from (their names stay clear of the words the dyno's column matching
looks for, so they never replace the columns above by mistake):

- `Phone Pressure (psi)`: the iPhone's barometer. When the car reports no barometric pressure, `Ambient Pressure (psi)`
  is filled from the phone too.
- `Weather Humidity (%)`, `Weather Wind (MPH)`, `Weather Wind From (deg)`, `Weather Air Temp (F)`,
  `Weather Sea-Level Pressure (hPa)`: Open-Meteo's current conditions where the phone was, from the snapshot nearest
  each row (one at the start of the run and one at the end). Only the location rounded to 0.01 degree (about 1 km) is
  sent. With no signal the run is saved without them, and the dyno can still look the weather up from the GPX.

- `Fuel Level (%)` from the car (PID 0x2F), and the vehicle profile from **Weight & drag** on the Record screen:
  `Curb Weight (lbs)` (the typed full-tank curb weight less the fuel missing at that row, 6.1 lb a gallon),
  `Driver + Cargo (lbs)`, `Drag Coefficient` and `Frontal Area (m2)`. The dyno fills its fields of the same names.

The `.gpx` is GPX 1.0 so each point can carry `<speed>` (m/s), which both the dyno and video-overlay read. Each point
also carries the phone's barometer in the app's own namespace (`xmlns:dl="https://dynologger.turboloser.co/gpx/1"`):
`<dl:relalt>` is the altitude change since the run started in metres, for road grade, and `<dl:pressure>` is in hPa.
Other GPX readers skip them.

## Recording a pull

Connect the devices on the Devices tab (they reconnect on their own after that), type the vehicle name, press record.
Floor it in one gear from low RPM to redline on a flat, straight road, then stop recording. A coast in neutral or with
the clutch in from about 70 to 30 MPH in the same run lets the dyno fit rolling resistance.

How fast the OBD log is depends on the car: CAN cars (2008 and later) answer all four fast PIDs in one request and
give roughly 10-25 rows a second through a good adapter; older protocols are much slower.

## Look

The app uses the Virtual Dyno page's look: its green phosphor palette (the page's default theme tokens, in
`App/Views/Theme.swift` under the same names), the VT323 font (bundled with its OFL licence in `App/Resources/Fonts`),
a terminal title bar, fieldset-style panels and `[ bracket ]` buttons. The app icon is the dyno's own 8-bit chart icon
with a red record dot; `python3 tools/app_icon.py` redraws it.

## Screenshot mode

Launch with `-demo` for made-up devices and a simulated pull on a loop (the Simulator has no Bluetooth);
`tools/screenshots.sh` takes the App Store screenshots that way. See `App/Model/Demo.swift` and `APP_STORE.md`.

## Building

```
brew install xcodegen
xcodegen                     # writes DynoLogger.xcodeproj from project.yml
open DynoLogger.xcodeproj    # run on an iPhone (Bluetooth needs a real device)
swift test --package-path Core
```

`Core/` is a Swift package with everything that does not need an iPhone (file writers, ELM327, NMEA and RaceBox
decoders, GoPro commands) and its tests. `App/` is the SwiftUI app.

`python tools/check_dyno.py <path to virtual-dyno>` simulates a session, writes it in the app's format and loads it
into the dyno page in headless Chromium (needs `pip install playwright`). CI runs it, the Core tests and an
unsigned simulator build.

## Not verified yet

- Nothing here has run on an iPhone or against real hardware. The RaceBox message offsets and the Open GoPro
  commands are from their published protocol documents and need a check with a real unit.
- The Swift has not been compiled yet; CI on macOS is the first compile.
