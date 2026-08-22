# Minimal Liquid Stats

[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)
[![Omarchy](https://img.shields.io/badge/omarchy-shell%20plugin-1793d1)](https://omarchy.org)
[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/marionuevo/omarchy-minimal-liquid-stats)
[![NVIDIA GPU required](https://img.shields.io/badge/GPU-NVIDIA-76b900)](https://github.com/marionuevo/omarchy-minimal-liquid-stats)

A minimal `bar-widget` plugin for the [Omarchy](https://omarchy.org/) shell (Quickshell). Shows water reservoir temp, CPU/GPU temp, and CPU/GPU/RAM/disk usage as a static row of icon+value pairs — no click target, no popup, just always-visible numbers.

![preview](preview.png)

## Sensors

| Icon | Value |
|------|-------|
| 💧 water-thermometer | Liquid cooling reservoir temperature |
| 🖥 microchip | CPU temp / CPU usage % |
| 🎮 expansion-card | GPU temp / GPU usage % |
| 💾 memory | RAM usage % |
| 🗄 harddisk | Root filesystem (`/`) usage % |

Data comes from:

- **Water temp** — the `asusec` chip's `T_Sensor` reading (matched by sysfs label, not hwmon index, so it survives reboots). `asusec` comes from the [`asus-ec-sensors`](https://github.com/zeule/asus-ec-sensors) kernel module, which reads ASUS motherboards' embedded controller directly — some coolant probes are wired to EC-only headers that never show up on the board's Super I/O chip (`nct6798`/`it87`/etc.) at all, so check both. This is board-specific either way: if you clone this for your own machine, verify which sensor your coolant probe actually is with a CPU load test — a real probe rises slowly and lags behind CPU temp changes by its thermal mass, while a floating/disconnected header stays perfectly flat. Don't trust the label name alone (see `stats.py`'s `temp_by_label` calls).
- **CPU temp** — `coretemp`'s "Package id 0".
- **GPU temp/usage** — `nvidia-smi`.
- **CPU usage** — `/proc/stat` delta.
- **RAM/disk usage** — `/proc/meminfo` and `shutil.disk_usage("/")`.

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
