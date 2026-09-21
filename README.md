# WiZ Remote for macOS

WiZ Remote is a small native macOS app for finding and controlling WiZ smart
lights on the same local network. It communicates directly with the lights over
UDP; no WiZ cloud account is required.

> Community project. Not affiliated with or endorsed by WiZ or Signify.

This repository now includes a reproducible Swift Package Manager build. The
original source-only repository did not contain an Xcode project or package
manifest and scanned the LAN by launching 253 shell processes at once. Discovery
now uses one native UDP broadcast socket instead.

## Features

- Native macOS window and separate menu-bar controller
- Automatic discovery of multiple WiZ lights and sockets
- Per-device power control with IP, MAC, model, firmware, signal, and state data
- Works when the Mac uses 5 GHz and the lights use 2.4 GHz, provided both bands
  share the same LAN
- Native **Launch at Login** support for the menu-bar app
- Direct system-audio capture on macOS 14.2 and newer
- Beat-aware party lighting with BPM estimation, adaptive loudness, transient
  detection, coordinated multi-bulb patterns, palettes, and intensity control
- Restores each selected light's previous state when music sync stops
- No cloud account, audio upload, recording, analytics, or tracking

## Requirements

- macOS 13 or newer
- Apple Command Line Tools or Xcode with Swift 6
- A Mac and WiZ lights connected to the same non-guest LAN

## Build and install

```bash
./scripts/build-app.sh
```

The signed local build is created at:

```text
dist/WiZ Remote.app
```

To build the separate menu-bar companion:

```bash
./scripts/build-menubar-app.sh
```

It creates `dist/WiZ Remote Menu Bar.app`. This edition has no Dock icon and
provides compact per-device power switches, discovery status, and a shortcut to
the full app from the macOS menu bar. It registers itself with the native macOS
Login Items service on first launch; the **Launch at Login** switch in the menu
can disable or re-enable that behavior.

To install local builds:

```bash
ditto "dist/WiZ Remote.app" "/Applications/WiZ Remote.app"
ditto "dist/WiZ Remote Menu Bar.app" "/Applications/WiZ Remote Menu Bar.app"
```

The scripts use ad-hoc signing. On first launch, macOS may ask for **Local
Network** access. Music sync additionally requires **Screen & System Audio
Recording** access.

## Beat-aware music sync

On macOS 14.2 or newer, expand **Music Sync Lab** in the menu-bar app to test
direct system-audio analysis. The app uses a private Core Audio process tap;
audio is analyzed in memory and is never recorded, saved, or sent over the
network.

The party renderer detects low-, mid-, and high-frequency transients, learns the
beat period, adapts to the track's loudness, and coordinates selected lights
instead of mapping spectrum levels directly to RGB. Colours stay within a chosen
palette, regular beats alternate between lights, and downbeats illuminate the
group together. The menu reports its estimated BPM, beat-lock confidence, and
current section mode.

1. Leave **Send UDP colours to selected lights** off and start capture.
2. Approve **System Audio Recording** when macOS asks, then play audio and check
   the level, bass, mids, high, and beat indicators.
3. Stop capture, select the desired lights, choose a palette and intensity,
   enable UDP colour output, select an update rate, and start music sync again.
4. Use **Stop and Restore** when finished. The selected lights' previous power,
   brightness, colour/temperature, or scene state is restored on stop, sleep,
   and normal app termination.

Sockets are excluded by requiring lighting metadata from the WiZ device. Live
frames use a persistent non-blocking UDP socket and are never retried, so an old
animation frame cannot queue behind a newer one.

The repository also contains a `Package.swift` manifest for opening the full app
source as a Swift package in Xcode. The build scripts use `swiftc` directly, so
they work with Apple's Command Line Tools and do not require a generated Xcode
project.

## Use it

1. Open `dist/WiZ Remote.app`.
2. Allow **Local Network** access when macOS asks.
3. Keep the Mac and lights on the same LAN. The Mac can use 5 GHz while the
   lights use 2.4 GHz; both bands only need to route to each other.
4. The app searches automatically; use **Scan again** to retry.
5. Identify each light by its module, IP, MAC, firmware, room ID, and live-state
   metadata, then use the power button on that light's card.

If discovery fails, turn off any VPN temporarily and confirm the router does not
isolate its 2.4 GHz and 5 GHz bands or Wi-Fi clients (often enabled on guest
networks). macOS permissions can be
reviewed in **System Settings → Privacy & Security → Local Network**.

If a light reports its state but ignores control commands, check **Settings →
Security → Local communication** in the WiZ app. WiZ can reject unverified
third-party UDP commands when **Only verified controls** is selected. This app
does not currently import or store the WiZ home security key.

## Development checks

```bash
./scripts/test-audio-analyzer.sh
./scripts/test-party-engine.sh
```

The party-engine test verifies transient analysis, a deterministic 120 BPM lock,
two-light contrast, and breakdown detection. A manual, opt-in rate probe is also
available for explicitly selected ES/ESP25 SHRGB test bulbs:

```bash
./scripts/run-wiz-rate-probe.sh       # discovery only
./scripts/run-wiz-rate-probe.sh --run # four-second 5 Hz sweep, then restore
```

## Privacy and limitations

- Audio samples are processed in memory and are never written to disk or sent
  over the network.
- WiZ control packets stay on the local LAN and use the devices' UDP API.
- WiZ does not publish a dedicated high-rate entertainment stream or a documented
  safe update limit for this local protocol. Start at 10 Hz and increase only if
  the specific lights remain responsive.
- Running the full app and menu-bar app simultaneously is not recommended because
  both perform local UDP discovery.
- If **Only verified controls** is enabled in WiZ security settings, unverified
  third-party local commands may be rejected.

## Project layout

- `WizRemote/` — full macOS application and shared WiZ discovery/control service
- `WizRemoteMenuBar/` — menu-bar UI, system-audio capture, party engine, and UDP
  animation sender
- `Packaging/` — application property lists and command-line build support
- `Tests/` — deterministic analyzer, party-engine, and device-rate probes
- `scripts/` — reproducible build and test commands

## Credits

Original app by [Aditya Bhadang](https://github.com/AdityaBhadang/WizRemoteApp).
This repository preserves the original Git history and attribution. The upstream
repository did not include a license file; no additional license is asserted here.
