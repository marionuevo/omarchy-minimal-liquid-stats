# Minimal Liquid Stats

[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)
[![Omarchy](https://img.shields.io/badge/omarchy-shell%20plugin-1793d1)](https://omarchy.org)
[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/marionuevo/omarchy-minimal-liquid-stats)
[![NVIDIA GPU required](https://img.shields.io/badge/GPU-NVIDIA-76b900)](https://github.com/marionuevo/omarchy-minimal-liquid-stats)

A minimal `bar-widget` plugin for the [Omarchy](https://omarchy.org/) shell (Quickshell). Shows water reservoir temp, pump and radiator fan RPM, CPU/GPU temp, and CPU/GPU/RAM/disk usage as a static row of icon+value pairs — no click target, no popup, just always-visible numbers.

![preview](preview.png)

## Sensors

| Icon | Value |
|------|-------|
| 💧 water-thermometer | Liquid cooling reservoir temperature |
| 🚰 water-pump | Pump RPM |
| 🌀 fan | Top / bottom radiator fan bank RPM |
| 🖥 microchip | CPU temp / CPU usage % |
| 🎮 expansion-card | GPU temp / GPU usage % |
| 💾 memory | RAM usage % |
| 🗄 harddisk | Root filesystem (`/`) usage % |

Data comes from:

- **Water temp** — the `asusec` chip's `T_Sensor` reading (matched by sysfs label, not hwmon index, so it survives reboots). `asusec` comes from the [`asus-ec-sensors`](https://github.com/zeule/asus-ec-sensors) kernel module, which reads ASUS motherboards' embedded controller directly — some coolant probes are wired to EC-only headers that never show up on the board's Super I/O chip (`nct6798`/`it87`/etc.) at all, so check both. This is board-specific either way: if you clone this for your own machine, verify which sensor your coolant probe actually is with a CPU load test — a real probe rises slowly and lags behind CPU temp changes by its thermal mass, while a floating/disconnected header stays perfectly flat. Don't trust the label name alone (see `stats.py`'s `temp_by_label` calls).
- **Pump** — `nct6798`'s `fan7`. Driven by a BIOS curve keyed to water temp, same as the radiator fans.
- **Radiator fans** — `nct6798`'s `fan1` and `fan3`, one per radiator (three fans daisy-chained to each header). This chip exposes no `fanN_label` files, so channels are read by fixed index — the index-to-header mapping is set by the board wiring and doesn't shuffle across boots, but it *is* board- and build-specific. To find yours, run `sensors` and change fan curves in BIOS one header at a time to see which channel moves.
- **CPU temp** — `coretemp`'s "Package id 0".
- **GPU temp/usage** — `nvidia-smi`.
- **CPU usage** — `/proc/stat` delta.
- **RAM/disk usage** — `/proc/meminfo` and `shutil.disk_usage("/")`.

## Fan modes

Clicking the widget opens a picker with three modes:

| Mode | Radiator fans | Pump |
|------|---------------|------|
| **Silent** | floors to ~70% of the BIOS duty, knee 5°C later | ramp delayed 6°C, duty never reduced |
| **Normal** | the BIOS curves, exactly as captured at boot | same |
| **Full** | 100% everywhere | 100% everywhere |

These rewrite the chip's **SmartFan IV curve tables** and leave `pwmN_enable`
at `5`, rather than forcing a fixed duty cycle. That distinction is the whole
safety argument: the board keeps regulating against water temp on its own, so
if this plugin — or the entire shell — dies while Silent is active, the fans
keep following a curve instead of freezing at an idle duty while the loop
heats up. Two further guards: the pump's duty is never scaled down (only its
ramp delayed, and never below the BIOS floor), and every curve in every mode
is pinned to 100% by 55°C water, so a quiet mode still ramps out of trouble.

Modes are runtime-only — the BIOS reapplies its own tables at boot, and the
baseline that "Normal" restores is re-snapshotted each boot (keyed on
`boot_id`) so a mode left active before a reboot can never be mistaken for
the BIOS default.

### Granting write access

The curve files are root-owned, so the widget shows the modes greyed out
until a udev rule hands them to your user:

```sh
sudo install -m 0644 udev/99-nct6798-fancurve.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=hwmon --action=change
```

The rule matches the chip by `name` rather than hwmon index (which is not
stable across boots) and opens up only `pwm*`. **Edit the username in it
first** — it is hardcoded. On a multi-user machine, prefer a `pkexec` helper
over this; write access to `pwm*` means any process running as you can stop
the pump.

## Requirements

- Omarchy running on Hyprland
- Python 3
- `nvidia-smi` on `PATH` (NVIDIA GPU)
- A motherboard sensor chip exposed under `/sys/class/hwmon/` for CPU/water temps — on some ASUS boards this requires loading the out-of-tree [`asus-ec-sensors`](https://github.com/zeule/asus-ec-sensors) module (via DKMS) and possibly adding a DMI board-name entry for your exact model if it's not already supported upstream

## Installation

```sh
omarchy plugin add https://github.com/marionuevo/omarchy-minimal-liquid-stats.git --enable
omarchy bar put marionuevo.minimal-liquid-stats --section left
```

Refreshes every 2 seconds via a small `stats.py` helper process.
