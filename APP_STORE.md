# App Store submission notes

Everything App Store Connect asks for that is not in the code. The Team ID is set in `project.yml` (`DEVELOPMENT_TEAM`), so the app is ready to archive.

## Build and upload

```
brew install xcodegen
xcodegen
open DynoLogger.xcodeproj
```

In Xcode: pick "Any iOS Device (arm64)", then Product > Archive, then Distribute App > App Store Connect > Upload.
The build appears in TestFlight after processing (10 to 30 minutes). For every later upload, raise
`CURRENT_PROJECT_VERSION` in `project.yml` (2, 3, ...); raise `MARKETING_VERSION` for a new store version.

Create the app record first in App Store Connect > Apps > + > New App: platform iOS, name "Virtual Dyno Logger",
primary language English (U.S.), bundle ID `com.itschefff.virtualdynologger` (register it at
developer.apple.com > Identifiers if it is not offered; Xcode's automatic signing usually registers it on the first
archive), SKU anything, e.g. `virtualdynologger`.

## Listing

| Field | Value |
| --- | --- |
| Name | Virtual Dyno Logger |
| Subtitle (30 max) | OBD-II + GPS logs for your dyno |
| Category | Utilities (secondary: Navigation, or none) |
| Age rating | 4+ (answer "None" to everything) |
| Price | Free |
| Support URL | https://dynologger.turboloser.co/support/ |
| Marketing URL | https://dynologger.turboloser.co/ |
| Privacy Policy URL | https://dynologger.turboloser.co/privacy/ |
| Copyright | 2026 followed by your name or business name |

Keywords (100 characters, comma separated, no spaces needed):
`dyno,obd2,obd,elm327,racebox,horsepower,torque,gps,logger,gopro,accessport,datalog,track,car,tuning`

Description (draft):

> Virtual Dyno Logger records a dyno run from your car and saves the files the free Virtual Dyno
> (dyno.turboloser.co) turns into horsepower and torque curves.
>
> Connect a Bluetooth OBD-II adapter, a GPS (a RaceBox, any Bluetooth NMEA receiver, or the iPhone's own) and
> optionally a GoPro, then press Start Run. The app logs engine speed, vehicle speed, accelerator pedal, boost,
> barometric pressure and air temperature, records a GPS track with speed, and starts and stops the GoPro with the run
> so the video lines up with the data.
>
> Each run is saved as a Cobb Accessport-style CSV and a GPX track, ready for the Virtual Dyno's two upload boxes and
> visible in the Files app.
>
> - Works with ELM327 Bluetooth LE adapters such as OBDLink CX and MX+, Vgate iCar Pro, vLinker and Veepeak
> - 25 Hz GPS from a RaceBox Mini, Mini S or Micro
> - GoPro HERO9 and later
> - No account, no ads, no tracking: your runs stay on your iPhone until you share them
>
> Only use the app where it is legal and safe: on a closed course or a dyno. Set it up before you drive.

## App Privacy ("Data Not Collected")

App Store Connect > App Privacy > Get Started > "No, we do not collect data from this app". The app sends nothing off
the phone (no analytics, no network calls other than opening links in Safari), which is what Apple counts as collection,
and `App/Resources/PrivacyInfo.xcprivacy` says the same. If the app ever starts sending anything, update both and the
privacy policy page.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in Info.plist, so App Store Connect will not ask about encryption.

## Notes for App Review

Paste into App Review Information > Notes. No sign-in is needed.

> This app records data from Bluetooth car accessories (an ELM327 OBD-II adapter, a RaceBox GPS, a GoPro) during a
> driving run and saves it as CSV and GPX files for the web tool at https://dyno.turboloser.co.
>
> Background modes: "location" keeps the GPS track recording when the screen locks during a run (the blue location
> indicator shows), and "bluetooth-central" keeps the OBD-II and GPS connections streaming. Recording only happens
> between Start Run and Stop Run. Location permission is "While Using the App" only.
>
> Without the hardware the app shows empty screens. To see it with simulated devices and data, launch it with the
> argument `-demo` (Xcode scheme). A demo video is attached / available at <add a link if you record one>.

Reviewers often ask for a video of the app working with real hardware when Bluetooth accessories are needed. A short
screen recording of a real run with the adapter connected (from Control Center > Screen Recording) avoids a round trip.

## Screenshots

App Store Connect needs one set at 6.9" (1320x2868, iPhone 16 Pro Max); it scales those for smaller iPhones. On a Mac:

```
tools/screenshots.sh
```

It writes `screenshots/iPhone_16_Pro_Max/` with the app in screenshot mode (made-up devices and a simulated pull, since
the Simulator has no Bluetooth), a 9:41 status bar and full battery. CI runs the same script and keeps the images as the
`screenshots` artifact of each run. Suggested order for the listing:

1. `1_record_live`: recording mid-pull, big RPM, MPH and boost numbers. The strongest one; use it first.
2. `2_runs`: the saved runs.
3. `3_devices`: OBD-II adapter, RaceBox and GoPro connected.
4. `4_record_idle`: the record screen before a run.
5. `5_about`: optional.

A run's detail screen (files and Share buttons) is a good sixth: run the app with `-demo`, open a run and press
Cmd+S in the Simulator.
