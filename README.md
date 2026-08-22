# Liquid Stats

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

- **Water temp** — the `nct6798` Super I/O chip's `AUXTIN3` sensor (matched by sysfs label, not hwmon index, so it survives reboots). This is board-specific: if you clone this for your own machine, you'll need to identify which `AUXTIN`/`SYSTIN` channel your coolant probe is wired to (see `stats.py`'s `temp_by_label` calls).
- **CPU temp** — `coretemp`'s "Package id 0".
- **GPU temp/usage** — `nvidia-smi`.
- **CPU usage** — `/proc/stat` delta.
- **RAM/disk usage** — `/proc/meminfo` and `shutil.disk_usage("/")`.

## Requirements

- Omarchy running on Hyprland
- Python 3
- `nvidia-smi` on `PATH` (NVIDIA GPU)
- A motherboard sensor chip exposed under `/sys/class/hwmon/` for CPU/water temps

## Installation

```sh
omarchy plugin add https://github.com/marionuevo/omarchy-liquid-stats.git --enable
omarchy bar put marionuevo.liquid-stats --section left
```

Refreshes every 2 seconds via a small `stats.py` helper process.
