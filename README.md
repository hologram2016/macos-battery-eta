# Battery ETA

Glanceable **time-to-empty** (and time-to-full) in the macOS menu bar. Apple removed the old “2:14 Remaining” text; this puts a short estimate back.

| Menu bar | Meaning |
|----------|---------|
| `2:14` | About 2 hours 14 minutes to empty |
| `48m` | Under an hour to empty |
| `+48m` | About 48 minutes to full |
| `+1:12` | About 1 hour 12 minutes to full |
| `AC` | On power, holding (not charging) |
| `58%` | Estimate still settling |

Turns orange under ~45 minutes and red under ~20. Hover for a one-line tooltip. Click for pack current, health, and macOS’s own guess.

The figure is remaining mAh ÷ pack current, smoothed for a few minutes — not the first `pmset` guess after unplug, which is often optimistic.

Laptop-only. On a desktop Mac (no battery) the app exits. Universal binary (Intel + Apple Silicon). macOS 12+.

## Install

Prebuilt app. No Xcode, no Homebrew, no sudo. User-space only (`~/Applications` + a login LaunchAgent).

**[Download the latest release](https://github.com/hologram2016/macos-battery-eta/releases/latest)**

Or install in one step:

```bash
curl -fsSL https://raw.githubusercontent.com/hologram2016/macos-battery-eta/main/install.sh | bash
```

Prefer to read it first:

```bash
curl -fsSL https://raw.githubusercontent.com/hologram2016/macos-battery-eta/main/install.sh -o /tmp/install-battery-eta.sh
less /tmp/install-battery-eta.sh
bash /tmp/install-battery-eta.sh
```

Starts at every login after boot. When a newer release exists, the menu shows **Update to …** — click to download and restart.

```bash
battery-eta            # status
battery-eta stop
battery-eta start
battery-eta uninstall
```

## Notes

- macOS can still show the **percentage** next to the system battery icon: System Preferences / System Settings → Control Centre / Dock & Menu Bar → Battery → Show Percentage.
- Time-to-empty is a live drain estimate, not a promise. Video / brightness jumps will move it.
- Serial number and machine identity are not shown or logged.
