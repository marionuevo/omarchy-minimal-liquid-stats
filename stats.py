#!/usr/bin/env python3
import glob
import json
import os
import shutil
import subprocess
import time


def hwmon_chip(name):
    for f in glob.glob("/sys/class/hwmon/hwmon*/name"):
        try:
            if open(f).read().strip() == name:
                return os.path.dirname(f)
        except OSError:
            pass
    return None


def temp_by_label(chip_name, label):
    base = hwmon_chip(chip_name)
    if not base:
        return None
    for f in glob.glob(base + "/temp*_label"):
        try:
            if open(f).read().strip() != label:
                continue
        except OSError:
            continue
        idx = os.path.basename(f)[len("temp"):-len("_label")]
        try:
            return round(int(open(base + "/temp" + idx + "_input").read().strip()) / 1000)
        except OSError:
            return None
    return None


def cpu_usage():
    def read():
        with open("/proc/stat") as f:
            vals = [int(x) for x in f.readline().split()[1:]]
        return sum(vals), vals[3] + vals[4]

    t1, i1 = read()
    time.sleep(0.3)
    t2, i2 = read()
    dt = t2 - t1 or 1
    return round(100 * (dt - (i2 - i1)) / dt)


def mem_usage():
    d = {}
    with open("/proc/meminfo") as f:
        for line in f:
            key, value = line.split(":", 1)
            d[key] = int(value.split()[0])
    total, avail = d.get("MemTotal", 0), d.get("MemAvailable", 0)
    return round(100 * (total - avail) / total) if total else 0


def disk_usage():
    usage = shutil.disk_usage("/")
    return round(100 * usage.used / usage.total) if usage.total else 0


def gpu_stats():
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=temperature.gpu,utilization.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=2,
        ).stdout.strip()
        temp, util = [int(x.strip()) for x in out.split(",")]
        return temp, util
    except Exception:
        return None, None


cpu_temp = temp_by_label("coretemp", "Package id 0")
water_temp = temp_by_label("nct6798", "AUXTIN3")
gpu_temp, gpu_pct = gpu_stats()
cpu_pct = cpu_usage()
ram_pct = mem_usage()
disk_pct = disk_usage()

print(json.dumps({
    "water": water_temp,
    "cpuTemp": cpu_temp,
    "gpuTemp": gpu_temp,
    "cpu": cpu_pct,
    "gpu": gpu_pct,
    "ram": ram_pct,
    "disk": disk_pct,
}))
