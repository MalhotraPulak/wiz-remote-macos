# WiZ Remote App

WiZ Remote is a small native macOS app for finding and controlling WiZ smart
lights on the same local network. It communicates directly with the lights over
UDP; no WiZ cloud account is required.

This repository now includes a reproducible Swift Package Manager build. The
original source-only repository did not contain an Xcode project or package
manifest and scanned the LAN by launching 253 shell processes at once. Discovery
now uses one native UDP broadcast socket instead.

## Requirements

- macOS 13 or newer
- Apple Command Line Tools or Xcode with Swift 6
- A Mac and WiZ lights connected to the same non-guest LAN

## Build the app

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

### Phase 1 music-sync lab

On macOS 14.2 or newer, expand **Music Sync Lab** in the menu-bar app to test
direct system-audio analysis. The app uses a private Core Audio process tap;
audio is analyzed in memory and is never recorded, saved, or sent over the
network.

1. Leave **Send UDP colours to selected lights** off and start capture.
2. Approve **System Audio Recording** when macOS asks, then play audio and check
   the level, bass, mids, high, and beat indicators.
3. Stop capture, select the desired lights, enable UDP colour output, choose
   5, 10, 15, or 20 Hz, and start the test again.
4. Use **Stop and Restore** when finished. The selected lights' previous power,
   brightness, colour/temperature, or scene state is restored on stop, sleep,
   and normal app termination.

Sockets are excluded by requiring lighting metadata from the WiZ device. Live
frames use a persistent non-blocking UDP socket and are never retried, so an old
animation frame cannot queue behind a newer one.

The repository also contains a `Package.swift` manifest for opening the source as
a Swift package in Xcode. The build script uses `swiftc` directly, so it works
with Apple's Command Line Tools and does not require a generated Xcode project.

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

## Current scope

The app discovers and controls multiple lights and shows the metadata available
from WiZ's local UDP API. Brightness, color temperature, RGB color, and scene
controls are not implemented yet.

## Credits

Original app by [Aditya Bhadang](https://github.com/AdityaBhadang/WizRemoteApp).
