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
        temp = max(int(temp), last_temp)
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
    """Quieter floor and a later knee, derived from the BIOS curve.

    Scaled off the BIOS values rather than hardcoded, so the bottom-leads-top
    pressure bias set in BIOS survives the mode change instead of being
    flattened by two arbitrary constants.

    The pump is quietened only by delaying its ramp, never by cutting its
    duty: its floor stays exactly what the BIOS asks for at idle, so silent
    mode can never run the loop slower than the board itself already does.
    """
    if not bios:
        return None
    floor_scale = 1.0 if ch == PUMP else 0.70
    knee_shift = 6 if ch == PUMP else 5
    out = []
    for i, (t, v) in enumerate(bios):
        out.append([t + knee_shift, int(v * floor_scale) if i < 2 else v])
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
