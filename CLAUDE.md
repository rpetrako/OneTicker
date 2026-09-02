# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**OneTicker** is a macOS menu bar app that displays one stock's live price. The user picks
a market and a symbol; the app shows the price, the day's change, and nothing else.

Swift, single file, no third-party dependencies. Data comes from the Yahoo Finance v8
chart API over `URLSession`.

> The app previously carried a vendor-specific name, and there was an earlier Python
> (`rumps` + `yfinance`) implementation. Both are gone. Do not reintroduce either: the
> old name used a registered trademark, and the app is market-agnostic. The only place
> a vendor name legitimately appears is the default ticker symbol below.

## Commands

**Build and install:**

```bash
bash build_swift.sh
```

Compiles `Sources/OneTicker/main.swift` with `swiftc -O`, assembles a `.app` in
`dist_swift/`, copies in `icon/AppIcon.icns`, ad-hoc signs it, and installs it to
`/Applications/OneTicker.app`. No Xcode project, no package manager.

**Rebuild the icon** (only when `icon/AppIcon-1024.png` changes):

```bash
bash icon/make_icns.sh
```

**Build a visible variant for UI testing:**

```bash
bash devbuild.sh
```

## Version control

Single `main` branch, initial commit 2026-09-02. No remote yet; `gh` is installed if one is
wanted.

Ignored: `dist_swift/` and the derived `icon/AppIcon.icns`. The master `icon/AppIcon-1024.png`
IS tracked, and `build_swift.sh` regenerates the icns automatically when it is missing, so a
fresh clone builds correctly with no extra step. Verified by cloning to /tmp and building.

Note that `build_swift.sh` always installs to `/Applications/OneTicker.app`, so running it
from a scratch clone replaces the installed app.

## Identity

| | |
|---|---|
| App name | `OneTicker` |
| Bundle ID | `com.petrakovic.oneticker` (dev variant: `.dev`) |
| Version | 2.4.0 (`CFBundleShortVersionString` and `CFBundleVersion`) |
| Lock file | `~/.oneticker.lock` |
| UserDefaults domain | `com.petrakovic.oneticker` |
| `LSUIElement` | `true` (menu bar only, no Dock icon) |

The bundle ID is provisional; it has to match whatever gets registered in App Store
Connect.

## Build hygiene

`swiftc -O -warnings-as-errors` must stay clean. Full Swift 6 strict concurrency
(`-strict-concurrency=complete`) still reports ~130 diagnostics. That migration would mean
making `AppDelegate` `@MainActor` and threading `@Sendable` through the fetch completions.
Not attempted; the current code is correct under the Swift 5 language mode.

## Architecture

Everything is in `Sources/OneTicker/main.swift`:

- `kMarkets`: the 16 supported exchanges.
- `Settings`: a `UserDefaults` wrapper; `Settings.yahooSymbol` joins symbol and suffix.
- `fetchCrumb` / `fetchStock`: the Yahoo API dance, then JSON parsing.
- `SettingsWindowController`: a programmatic AppKit settings window.
- `AppDelegate`: status item, menu, 60 s refresh timer.

A `flock` on `~/.oneticker.lock` enforces a single instance; a second launch exits silently.

## Settings

Menu item **Settings…** (Cmd-,) opens a window with a market pop-up, a symbol field, and
a live "Yahoo symbol:" preview. The user enters the *plain* symbol (`SAP`); the app appends
the selected market's suffix (`.DE`). A suffix typed by hand is stripped rather than doubled.

| Key | Default |
|-----|---------|
| `tickerSymbol` | `SAP` |
| `marketID` | `xetra` |

The default is SAP on Xetra because that is what the author watches. Reconsider before
shipping to anyone else.

`kMarkets` holds 15 European exchanges plus one US entry. Suffixes come from Yahoo's
published exchange list:
<https://help.yahoo.com/kb/exchanges-data-providers-yahoo-finance-sln2310.html>.
NASDAQ and NYSE share a single "United States" entry because Yahoo gives US listings no
suffix at all.

## Menu layout and icons

Every row in the status menu carries an SF Symbol, the three read-only status rows
included. This is deliberate: AppKit does **not** pad menu items that have no image,
so a menu where only some rows have icons renders with two different left edges.
Giving every row a symbol keeps all titles on one edge.

| Row | Symbol |
|-----|--------|
| Price | `tag` |
| Change | `chart.line.uptrend.xyaxis` |
| Market | `building.columns` |
| Refresh now | `arrow.clockwise` |
| Settings… | `gearshape` |
| About | `info.circle` |
| Quit | `power` |

## About panel

`NSApp.orderFrontStandardAboutPanel`, the same panel shape as "About This Mac".
Shows name, version and copyright only.

- Name ← `CFBundleName`, copyright ← `NSHumanReadableCopyright`, version ←
  `CFBundleShortVersionString`, icon ← the bundle's `AppIcon.icns`.
- Two option keys are easy to confuse: `.applicationVersion` is the **"Version 2.4.0"
  line**, `.version` is the **"(build)" suffix**. Passing `.version = ""` suppresses the
  redundant "Version 2.4.0 (2.4.0)".
- `.credits` carries two short lines between the version and the copyright: the refresh
  cadence and a delayed-quotes note. The cadence string is derived from `kRefreshInterval`
  by `refreshPhrase()`, so it cannot drift out of step with the timer. The panel is narrow,
  so keep each line under about 46 characters or it wraps mid-sentence.

## App icon

Master artwork: `icon/AppIcon-1024.png`, a white candlestick on an indigo-to-violet
gradient, drawn full-bleed square at 1024×1024.

`make_icns.sh` refuses a master that is not exactly 1024×1024, fans it out with `sips`
to the ten required rasters (16/32/128/256/512, each @1x and @2x), and packs them with
`iconutil`. `build_swift.sh` declares `CFBundleIconFile = AppIcon` and warns rather than
failing if the `.icns` is missing.

**Leave the corners square.** macOS 26 masks app icons into the squircle itself. Verified
in the Dock, no grey container. Keep meaningful content inside the middle 80%.

Still needed for the App Store: a `.icon` bundle built in Icon Composer (Xcode 26) and
compiled to `Assets.car` with `actool`, referenced via `CFBundleIconName`. Ship that
alongside the `.icns` so pre-26 systems still show an icon.

## Testing the UI

The app is `LSUIElement`, so computer-use cannot see it, and `osascript` has neither
Accessibility nor Screen Recording. `bash devbuild.sh` works around this: same source,
installed as `/Applications/OneTicker Dev.app` with `LSUIElement` dropped and bundle ID
`com.petrakovic.oneticker.dev`, which IS visible to screenshots. Quit the real app first, because
both take the same `~/.oneticker.lock`. Delete the dev copy when done.

Note: the menu bar extras area counts as "desktop shell", so computer-use needs a Finder
grant in addition to the app's own before it will click the status item.

## Polling and market hours

Market-open detection is **not** hardcoded. Each fetch reads
`meta.currentTradingPeriod.regular.start/end` from the API response, the real session for
whichever exchange the instrument trades on. When the session is unknown (first launch, or
after a settings change) the app fetches anyway rather than wrongly showing "closed".

The timer ticks every `kTickInterval` (60 s) but *fetching* is gated on elapsed time:
`kRefreshInterval` (60 s) while open, `kClosedInterval` (900 s) while closed.

**Never gate fetching on "market is open" alone.** `currentTradingPeriod` describes one
specific day. Once `now > sessionEnd`, that test is false forever, so an app that only
fetches while open never learns about the next session. It goes silent after the first
close and stays that way until relaunched. This was a real bug, fixed in 2.4.0 by polling
slowly rather than not at all.

The tick timer sets `tolerance` so macOS can coalesce the wakeup.

## Formatting

Prices go through `NumberFormatter` (`kPlainFormatter` / `kSignedFormatter`), never
`String(format: "%.2f")`, which uses the C locale and always prints a period.
`NumberFormatter` defaults to `Locale.current`, which on macOS follows the user's **Region**
setting rather than the UI language, so the same build renders `1.431,05` in Germany or
Croatia and `1,431.05` in the US. `kSignedFormatter` carries `positivePrefix = "+"` so the
change line signs itself; negative values use the locale's own minus (hr and sv use U+2212,
not a hyphen). Do not hand-roll separators.

## Why the refresh interval is 60 s

Yahoo lists most European exchanges as 15 to 30 minutes delayed, which looks at first like a
reason to poll slowly. It is not. Measured on 2026-09-02: `regularMarketTime` advances in
lockstep with wall clock and the price changes on every poll, sitting a steady ~15 min 30 s
behind. **The delay is a sliding window, not a batch.** Polling every 60 s therefore returns
a genuinely new price every 60 s. Slowing the timer would add staleness on top of the
delay for nothing. See `claude/yahoo-feed-behaviour.md` in the project notes.

## Known fragility: Yahoo rate limiting

The v8 chart API needs a cookie plus a crumb scraped from `fc.yahoo.com` and
`/v1/test/getcrumb`. Under throttling that crumb endpoint returns the **plain string
"Too Many Requests"** with HTTP 200, not JSON, and the cooldown can last many minutes.

- The app caches the crumb, so a running instance keeps working once it has one.
- `fetchCrumb` checks the HTTP status and rejects anything with a space, a `{` prefix or
  32+ characters, so "Too Many Requests" is never accepted as valid.
- `CrumbStore` applies **exponential backoff** on failure (60 s doubling to a 900 s cap),
  and `fetchStock` fails fast with `.backingOff` while that is in effect. Without it, every
  60 s tick fired two more requests at an endpoint that was already throttling, which is
  what kept the cooldown alive.
- `CrumbStore` is `@unchecked Sendable` and serialises on its own queue: it is read on the
  main thread and written from URLSession's background threads.
- Do not hammer `getcrumb` when testing; it extends the cooldown.

This is also the main obstacle to shipping: the endpoint is undocumented and using it this
way is against Yahoo's terms. A submittable app needs a licensed market-data provider.
