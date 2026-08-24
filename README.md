# Minimal Liquid Stats

[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)
[![Omarchy](https://img.shields.io/badge/omarchy-shell%20plugin-1793d1)](https://omarchy.org)
[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/marionuevo/omarchy-minimal-liquid-stats)
[![NVIDIA GPU required](https://img.shields.io/badge/GPU-NVIDIA-76b900)](https://github.com/marionuevo/omarchy-minimal-liquid-stats)

A minimal `bar-widget` plugin for the [Omarchy](https://omarchy.org/) shell (Quickshell). Shows water reservoir temp, pump and radiator fan RPM, CPU/GPU temp, and CPU/GPU/RAM/disk usage as a static row of icon+value pairs — always-visible numbers, no gauges, no animation. Clicking opens a [fan mode picker](#fan-modes); the row itself stays a plain read-out.

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

Clicking the widget opens a picker with three modes. Measured on this build at
34°C water:

| Mode | Top rad | Bottom rad | Pump |
|------|---------|------------|------|
| **Silent** | stopped | 693 rpm | 815 rpm |
| **Normal** | 830 rpm | 979 rpm | 1755 rpm |
| **Full** | 2205 rpm | 2166 rpm | 4770 rpm |

These rewrite the chip's **SmartFan IV curve tables** and leave `pwmN_enable`
at `5`, rather than forcing a fixed duty cycle. That distinction is the whole
safety argument: the board keeps regulating against water temp on its own, so
if this plugin — or the entire shell — dies while Silent is active, the fans
keep following a curve instead of freezing at an idle duty while the loop
heats up.

**Silent is a studio mode**, for tracking audio — not a general-purpose
profile. It stops the top radiator outright and drops the bottom to the
lowest duty it will reliably hold, on the reasoning that these rads have far
more capacity than idle desktop work needs. The pump keeps circulating, the
bottom bank keeps the case at positive pressure, and the 55°C water pin still
puts everything to 100% if the loop actually starts climbing. The pump's duty
is never scaled down at all — only its ramp delayed by 6°C, and never below
the BIOS floor.

A fan stopped at 0 has to be able to start again, and interpolating up from
zero would crawl through the dead band below the stall threshold — commanded
on, not actually turning. So the top bank's curve *steps* from 0 straight to
`MIN_FAN_PWM` rather than ramping. Verified: with the knee pulled below
current water temp, the stopped bank restarts cleanly to ~920 rpm.

Modes are runtime-only — the BIOS reapplies its own tables at boot, and the
baseline that "Normal" restores is re-snapshotted each boot (keyed on
`boot_id`) so a mode left active before a reboot can never be mistaken for
the BIOS default.

### Two hardware limits this had to learn the hard way

**The auto-point temperature register is 7-bit.** Write `130` and it wraps to
`2`, so the chip concludes the loop is far past the top of the curve and slams
every fan to 100% — while the driver's cached sysfs readback still cheerfully
reports `130`. Verified here: `130` → full speed, `127` → correct. Silent mode
originally shifted *every* point later, including the 125°C tail, and so went
full blast instead of quiet. Only the knee moves now, and `MAX_POINT_TEMP`
clamps at 127 as a net.

**These fans stall below ~20% duty.** Both banks hold ~650 rpm at duty 51 and
stop dead at 47, and a stalled PWM fan needs considerably more duty to restart
than to keep turning. `MIN_FAN_PWM` (56) sits just above that cliff with a
little margin, and is used for two things: the bottom bank's Silent floor, and
the duty the stopped top bank steps to when it wakes. Stopping a fan on
purpose is fine; leaving one commanded into the dead band is not.

If you fork this for another board, re-measure both. Neither is documented
anywhere useful, and the first one fails in the loudest possible way.

### Granting write access

The curve files are root-owned, so the picker stays greyed out (with an
explanation in the panel) until a udev rule hands them to your user:

```sh
sudo install -m 0755 udev/nct6798-fancurve-perms /usr/local/bin/
sudo install -m 0644 udev/99-nct6798-fancurve.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=hwmon --action=change
```

The rule matches the chip by `name` rather than hwmon index (which is not
stable across boots) and opens up only `pwm*`. The helper chowns by **numeric
uid** — resolving a username inside udev's sandbox silently fails on this
system — so **edit `TARGET_UID` in it first**. It logs what it did under the
`nct6798-fancurve` journal tag; check there if the picker stays greyed out:

```sh
journalctl -t nct6798-fancurve -b
```

On a multi-user machine, prefer a `pkexec` helper over this; write access to
`pwm*` means any process running as you can stop the pump.

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
