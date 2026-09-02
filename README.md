# OneTicker

A macOS menu bar app that shows one stock's live price. One ticker, nothing else.

![Version](https://img.shields.io/badge/version-2.4.0-blue) ![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey) ![License](https://img.shields.io/badge/license-MIT-green)

```
🏷  Price:  181,94 EUR
📈  ▼ -2,32  (-1,26%)
🏛  Deutsche Börse (Xetra) · SAP.DE
────────────────────────────
⟳  Refresh now
⚙  Settings…                ⌘,
────────────────────────────
ⓘ  About OneTicker
⏻  Quit                     ⌘Q
```

## What it does

Sits in the menu bar showing a symbol, its price and the day's change. Pick a market and a
symbol in Settings and it does the rest. That is the whole app.

- 16 markets: 15 European exchanges plus a combined US entry
- You type the plain symbol (`SAP`), the app adds the exchange suffix (`.DE`)
- Prices formatted for your region, so `1.431,05` in Germany and `1,431.05` in the US
- Market hours come from the exchange the instrument actually trades on, not a hardcoded
  timetable, so it works the same for Xetra and NASDAQ
- Refreshes once a minute while the market is open, slowly while it is closed
- No Dock icon, no window, no account, no telemetry

## Requirements

macOS 13 or later. Nothing else. No Xcode project, no package manager, no third-party
dependencies.

## Build

```bash
git clone https://github.com/rpetrako/OneTicker.git
cd OneTicker
bash build_swift.sh
```

That compiles with `swiftc`, builds the app bundle, generates the icon, ad-hoc signs it and
installs it to `/Applications`. Roughly ten seconds.

The app is ad-hoc signed rather than notarized, so macOS may warn on first launch. Right
click, Open.

## A note on the data

Prices come from an **undocumented Yahoo Finance endpoint**, and Yahoo's terms do not permit
automated access to it. That is a deliberate, documented limitation rather than an oversight:

- This is a personal tool. It is published as source so you can read it and build it
  yourself, not distributed as a binary.
- Quotes are delayed by 15 to 30 minutes depending on the exchange, per Yahoo's published
  schedule. The delay is a sliding window, so the value does change every minute.
- The endpoint is undocumented and unversioned. It has changed before and will change again.

If you want to run something like this properly licensed, the alternatives are documented in
`CLAUDE.md`: exchange-operated free delayed feeds (Deutsche Börse publishes Xetra data free
of charge), or a commercial provider with a developer programme that permits each user to
bring their own API key.

## Repo layout

```
Sources/OneTicker/main.swift   the entire app, one file
build_swift.sh                 build, sign, install
devbuild.sh                    visible twin for UI testing
icon/                          1024x1024 master and the icns generator
CLAUDE.md                      design notes and the things that cost time to learn
```

`CLAUDE.md` is worth reading before changing anything. It records the non-obvious bits, such
as why every menu row carries an icon and why the refresh timer must not be gated on whether
the market is open.

## Licence

MIT. See [LICENSE](LICENSE).

Not affiliated with, endorsed by, or connected to Yahoo, SAP SE, or any exchange.
