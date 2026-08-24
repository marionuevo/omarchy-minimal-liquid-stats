#!/usr/bin/env python3
"""Switch the radiator fans and pump between silent / normal / full.

These are not manual PWM overrides. Every mode rewrites the nct6798's
SmartFan IV curve tables and leaves pwmN_enable at 5, so the chip keeps
doing closed-loop control against water temp on its own. If this script —
or the whole shell — dies, the fans keep following the last curve written
instead of freezing at a fixed duty. That property is the reason this is
built as curve edits rather than the simpler pwmN writes.

"normal" restores the BIOS tables captured at boot, so the BIOS remains the
source of truth for what normal means; a reboot reverts everything anyway.
"""
import glob
import json
import os
import sys

CHIP = "nct6798"
STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
    "minimal-liquid-stats",
)
STATE_FILE = os.path.join(STATE_DIR, "fanmode.json")

TOP, BOTTOM, PUMP = 1, 3, 7

# The pump must never be curved below what the BIOS itself asks for at idle.
# Silent mode is allowed to quieten the rads a lot and the pump not at all —
# a slow pump on a hot loop is how you cook a block, and the noise win is
# negligible anyway.
PUMP_FLOOR_PWM = 51  # 20%, the BIOS point-1 value on this board

# The chip's auto-point temperature register is 7-bit. Write 130 and it wraps
# to 2, so the chip decides the loop is far past the top of the curve and
# slams every fan to 100% — while the driver's cached sysfs readback still
# cheerfully reports 130. Verified on this board: 130 -> full speed, 127 -> fine.
MAX_POINT_TEMP = 127

# Measured on this build: both radiator banks hold ~650 rpm at duty 51 and
# stall dead at 47. Stalled PWM fans need a good deal more duty to restart
# than to keep turning, so "silent" must never park them below this — with a
# little margin over the measured cliff for dust and bearing wear.
MIN_FAN_PWM = 56

# How much later silent mode lets the loop get before the fans wake up.
RAD_KNEE_SHIFT = 5
PUMP_KNEE_SHIFT = 6

# Whatever mode is on, water this hot means something is wrong: every curve
# is pinned to 100% by here so a quiet mode still ramps out of trouble.
# Sits at the top of the BIOS curves' own ramp (they reach full at 55-60°C)
# rather than below it — pin this too low and a shifted silent knee collides
# with it, which turns "silent" into "full blast at idle".
PANIC_TEMP = 55
PANIC_PWM = 255


def chip_path(name=CHIP):
    for f in glob.glob("/sys/class/hwmon/hwmon*/name"):
        try:
            if open(f).read().strip() == name:
                return os.path.dirname(f)
        except OSError:
            pass
    return None


def read_attr(base, attr):
    try:
        return int(open(os.path.join(base, attr)).read().strip())
    except (OSError, ValueError):
        return None


def write_attr(base, attr, value):
    try:
        with open(os.path.join(base, attr), "w") as f:
            f.write(str(int(value)))
        return True
    except (OSError, ValueError):
        return False


def read_curve(base, ch):
    points = []
    for p in range(1, 6):
        t = read_attr(base, "pwm%d_auto_point%d_temp" % (ch, p))
        v = read_attr(base, "pwm%d_auto_point%d_pwm" % (ch, p))
        if t is None or v is None:
            break
        points.append([t // 1000, v])
    return points


def write_curve(base, ch, points):
    ok = True
    last_temp = -273
    for i, (temp, pwm) in enumerate(points, start=1):
        pwm = max(0, min(255, int(pwm)))
        if ch == PUMP:
            pwm = max(PUMP_FLOOR_PWM, pwm)
        # The chip interpolates between adjacent points, so a table whose
        # temperatures step backwards produces nonsense. Clamp rather than
        # reject: a shifted knee should never be able to invert an ordering.
        temp = min(max(int(temp), last_temp), MAX_POINT_TEMP)
        last_temp = temp
        ok &= write_attr(base, "pwm%d_auto_point%d_temp" % (ch, i), int(temp) * 1000)
        ok &= write_attr(base, "pwm%d_auto_point%d_pwm" % (ch, i), pwm)
    # Belt and braces: the chip only honours the table while in SmartFan IV.
    if read_attr(base, "pwm%d_enable" % ch) != 5:
        ok &= write_attr(base, "pwm%d_enable" % ch, 5)
    return ok


def boot_id():
    try:
        return open("/proc/sys/kernel/random/boot_id").read().strip()
    except OSError:
        return "unknown"


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE_FILE)


def baseline(base):
    """The BIOS curves, captured once per boot before anything is written.

    Keyed on boot_id because the BIOS reapplies its own tables at every boot:
    a snapshot from a previous boot taken while silent mode was active would
    otherwise get frozen in as "normal" forever.
    """
    state = load_state()
    current = boot_id()
    if state.get("bootId") == current and "baseline" in state:
        return state["baseline"], state
    snap = {str(ch): read_curve(base, ch) for ch in (TOP, BOTTOM, PUMP)}
    state = {"bootId": current, "baseline": snap, "mode": "normal"}
    save_state(state)
    return snap, state


def pinned(points):
    """Force the tail of a curve to full speed at PANIC_TEMP and beyond."""
    out = [[t, v] for t, v in points]
    while len(out) < 5:
        out.append([PANIC_TEMP, PANIC_PWM])
    for i, (t, _) in enumerate(out):
        if t >= PANIC_TEMP:
            out[i] = [t, PANIC_PWM]
    out[-1] = [max(out[-1][0], PANIC_TEMP), PANIC_PWM]
    return out


def silent_curve(bios, ch):
    """Studio mode: top radiator stopped, bottom at its lowest stable duty.

    Built for tracking audio, where the rads have far more capacity than
    idle desktop work needs. The pump keeps circulating, the bottom bank
    keeps a trickle of air moving through the case, and the PANIC_TEMP pin
    still puts everything to 100% if the loop actually starts climbing.

    Only the knee moves on the temperature axis — the tail points sit near
    the register's 127 ceiling and shifting them overflows it (see
    MAX_POINT_TEMP).
    """
    if not bios:
        return None

    if ch == PUMP:
        # Quietened by delaying the ramp, never by cutting duty: the floor
        # stays exactly what the BIOS asks for at idle, so silent mode can
        # never run the loop slower than the board itself already does.
        out = [[t + PUMP_KNEE_SHIFT if t < PANIC_TEMP else t, v] for t, v in bios]
        return pinned(out)

    if ch == TOP:
        # Off completely. The step to MIN_FAN_PWM is deliberate rather than a
        # ramp: interpolating up from 0 would crawl through the dead band
        # below the stall threshold, leaving the fans commanded-on but not
        # actually turning. One step clears the threshold in a single move.
        knee = bios[0][0] + RAD_KNEE_SHIFT
        return pinned([[knee, 0], [knee + 1, MIN_FAN_PWM]] + [[t, v] for t, v in bios[2:]])

    # BOTTOM: lowest duty that reliably spins, knee pushed later. Keeping this
    # bank alive while the top is stopped also means the case stays firmly at
    # positive pressure, which is the whole point of the BIOS bias.
    out = []
    for i, (t, v) in enumerate(bios):
        shifted = t + RAD_KNEE_SHIFT if t < PANIC_TEMP else t
        out.append([shifted, MIN_FAN_PWM if i < 2 else v])
    return pinned(out)


def full_curve(bios, ch):
    base_points = bios or [[30, 255], [40, 255], [50, 255], [60, 255], [70, 255]]
    return [[t, PANIC_PWM] for t, _ in base_points]


def apply(mode):
    base = chip_path()
    if not base:
        return False, "nct6798 not found"
    bios, state = baseline(base)

    ok = True
    for ch in (TOP, BOTTOM, PUMP):
        b = bios.get(str(ch)) or []
        if mode == "normal":
            points = b
        elif mode == "silent":
            points = silent_curve(b, ch)
        elif mode == "full":
            points = full_curve(b, ch)
        else:
            return False, "unknown mode: %s" % mode
        if not points:
            ok = False
            continue
        ok &= write_curve(base, ch, points)

    if not ok:
        return False, "write failed (is the udev rule installed?)"

    state["mode"] = mode
    save_state(state)
    return True, mode


def status():
    base = chip_path()
    if not base:
        return {"mode": None, "writable": False}
    state = load_state()
    probe = os.path.join(base, "pwm%d_auto_point1_pwm" % TOP)
    return {
        "mode": state.get("mode") if state.get("bootId") == boot_id() else "normal",
        "writable": os.access(probe, os.W_OK),
    }


if __name__ == "__main__":
    arg = sys.argv[1] if len(sys.argv) > 1 else "--status"
    if arg == "--status":
        print(json.dumps(status()))
    else:
        good, msg = apply(arg)
        print(json.dumps({"ok": good, "message": msg}))
        sys.exit(0 if good else 1)
