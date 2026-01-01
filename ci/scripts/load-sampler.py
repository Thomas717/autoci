#!/usr/bin/env python3

import ctypes
import datetime
import os
import platform
import re
import signal
import subprocess
import sys
import time

INTERVAL = 1.0
AFTER_LOGIN = 15.0
CONTROL_WAIT = 30.0
BEFORE_WINDOW = 5.0
TOP = 8
DAEMONS = ("diagnosticd", "logd", "apsd")
SIM_PREFIX = "sim."
COLUMNS = ["utc", "t", "load1", "load5", "load15", "usr", "sys", "free_pct", "pressure", "free_mb", "compr_mb",
           "swap_mb", "pageins", "pageouts", "swapins", "swapouts", "compressions", "decompressions", "top"]
COUNTERS = [("pageins", "Pageins"), ("pageouts", "Pageouts"), ("swapins", "Swapins"), ("swapouts", "Swapouts"),
            ("compressions", "Compressions"), ("decompressions", "Decompressions")]
PRESSURE = {1: "normal", 2: "warn", 4: "critical"}
PRESSURE_ORDER = {"normal": 1, "warn": 2, "critical": 4}
UTC = datetime.timezone.utc


class Stop(Exception):
    pass


def on_signal(signum, frame):
    raise Stop("signal %d" % signum)


def utc_text(ts):
    return datetime.datetime.fromtimestamp(ts, UTC).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def parse_utc(text):
    return datetime.datetime.strptime(text.rstrip("Z"), "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=UTC).timestamp()


def parse_login(text):
    try:
        t = datetime.datetime.fromisoformat(text.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=UTC)
    return t.timestamp()


def output(cmd):
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5,
                           universal_newlines=True)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


class Host:

    def __init__(self):
        self.libc = None
        self.host = None
        try:
            self.libc = ctypes.CDLL(None)
            self.libc.sysctlbyname.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t),
                                               ctypes.c_void_p, ctypes.c_size_t]
            self.libc.sysctlbyname.restype = ctypes.c_int
        except (OSError, AttributeError):
            self.libc = None
        try:
            self.libc.mach_host_self.restype = ctypes.c_uint
            self.libc.host_statistics.argtypes = [ctypes.c_uint, ctypes.c_int, ctypes.c_void_p,
                                                  ctypes.POINTER(ctypes.c_uint)]
            self.libc.host_statistics.restype = ctypes.c_int
            self.host = self.libc.mach_host_self()
        except AttributeError:
            self.host = None

    def sysctl(self, name, ctype):
        if self.libc is None:
            return None
        value = ctype()
        size = ctypes.c_size_t(ctypes.sizeof(value))
        if self.libc.sysctlbyname(name.encode(), ctypes.byref(value), ctypes.byref(size), None, 0) != 0:
            return None
        return value

    def number(self, name, ctype=ctypes.c_int):
        v = self.sysctl(name, ctype)
        return None if v is None else v.value

    def ticks(self):
        if self.host is None:
            return None
        info = (ctypes.c_uint * 4)()
        count = ctypes.c_uint(4)
        if self.libc.host_statistics(self.host, 3, info, ctypes.byref(count)) != 0:
            return None
        return list(info)

    def swap_used_mb(self):
        class Swap(ctypes.Structure):
            _fields_ = [("total", ctypes.c_uint64), ("avail", ctypes.c_uint64), ("used", ctypes.c_uint64),
                        ("pagesize", ctypes.c_uint32), ("encrypted", ctypes.c_int)]

        v = self.sysctl("vm.swapusage", Swap)
        return None if v is None else v.used / 1048576.0


def vm_stat():
    text = output(["vm_stat"])
    if text is None:
        return None
    m = re.search(r"page size of (\d+) bytes", text)
    page = int(m.group(1)) if m else 4096
    values = {}
    for line in text.splitlines()[1:]:
        key, _, value = line.rpartition(":")
        value = value.strip().rstrip(".")
        if value.isdigit():
            values[key.strip().strip('"')] = int(value)
    return page, values


def cpu_seconds(text):
    days = 0
    if "-" in text:
        d, text = text.split("-", 1)
        days = int(d)
    total = 0.0
    for part in text.split(":"):
        total = total * 60 + float(part)
    return days * 86400 + total


def clean_name(name):
    return re.sub(r"[^A-Za-z0-9._+-]+", "_", name.strip())[:24] or "?"


def in_simulator(pid, parents, sims, memo):
    chain = []
    answer = False
    while pid in parents and len(chain) < 64:
        if pid in memo:
            answer = memo[pid]
            break
        chain.append(pid)
        pid = parents[pid]
        if pid in sims:
            answer = True
            break
        if pid <= 1:
            break
    for p in chain:
        memo[p] = answer
    return answer


def processes():
    text = output(["ps", "-A", "-o", "pid=,ppid=,cputime=,ucomm="])
    if text is None:
        return None
    rows = {}
    parents = {}
    for line in text.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 3:
            continue
        try:
            pid, ppid, secs = int(parts[0]), int(parts[1]), cpu_seconds(parts[2])
        except ValueError:
            continue
        rows[pid] = (secs, parts[3].strip() if len(parts) > 3 else "")
        parents[pid] = ppid
    sims = set(pid for pid, (_, name) in rows.items() if name == "launchd_sim")
    memo = {}
    table = {}
    for pid, (secs, name) in rows.items():
        name = clean_name(name)
        if sims and in_simulator(pid, parents, sims, memo):
            name = SIM_PREFIX + name
        table[pid] = (secs, name)
    return table


def daemons_line(procs, ts):
    if procs is None:
        return "# daemons: %s; no ps listing\n" % utc_text(ts)
    parts = []
    for daemon in DAEMONS:
        counts = {"host": [0, 0.0], "sim": [0, 0.0]}
        for secs, name in procs.values():
            where = "sim" if name == SIM_PREFIX + daemon else "host" if name == daemon else None
            if where is not None:
                counts[where][0] += 1
                counts[where][1] += secs
        parts.append("%s host %d %s %.2f s, sim %d %s %.2f s" % (
            daemon, counts["host"][0], "pid" if counts["host"][0] == 1 else "pids", counts["host"][1],
            counts["sim"][0], "pid" if counts["sim"][0] == 1 else "pids", counts["sim"][1]))
    return "# daemons: %s; %s\n" % (utc_text(ts), "; ".join(parts))


def snapshot(host):
    begin = time.monotonic()
    wall = time.time()
    snap = {}
    try:
        snap["load"] = os.getloadavg()
    except OSError:
        snap["load"] = None
    snap["level"] = host.number("kern.memorystatus_level")
    snap["pressure"] = host.number("kern.memorystatus_vm_pressure_level")
    snap["swap"] = host.swap_used_mb()
    snap["vm"] = vm_stat()
    start = time.monotonic()
    before = host.ticks()
    snap["procs"] = processes()
    after = host.ticks()
    end = time.monotonic()
    if before is not None and after is not None:
        snap["ticks"] = [(a + b) / 2.0 for a, b in zip(before, after)]
    else:
        snap["ticks"] = after if after is not None else before
    snap["mono"] = (start + end) / 2
    snap["ts"] = wall + (snap["mono"] - begin)
    snap["ps_took"] = end - start
    return snap


def fmt(v, digits=0):
    if v is None:
        return "-"
    if digits:
        return "%.*f" % (digits, v)
    return "%d" % round(v)


def top_text(prev, cur, dt, ncpu=None):
    if prev is None or cur is None or dt <= 0:
        return "-"
    by_name = {}
    used = 0.0
    for pid, (secs, name) in cur.items():
        before = prev.get(pid)
        d = secs - before[0] if before is not None and before[1] == name and secs >= before[0] else secs
        if d > 0:
            total, n = by_name.get(name, (0.0, 0))
            by_name[name] = (total + d, n + 1)
            used += d
    if ncpu and used > ncpu * dt:
        dt = used / ncpu
    best = sorted(by_name.items(), key=lambda kv: -kv[1][0])[:TOP]
    parts = []
    for name, (secs, n) in best:
        pct = round(100.0 * secs / dt)
        if pct < 1:
            continue
        parts.append("%s%s=%d" % (name, "(%d)" % n if n > 1 else "", pct))
    return ",".join(parts) or "-"


def row(prev, cur, t0, ncpu=None):
    load = cur["load"] or (None, None, None)
    usr = sys_ = None
    if prev["ticks"] is not None and cur["ticks"] is not None:
        d = [b - a for a, b in zip(prev["ticks"], cur["ticks"])]
        total = sum(d)
        if total > 0 and min(d) >= 0:
            usr = 100.0 * (d[0] + d[3]) / total
            sys_ = 100.0 * d[1] / total
    free_mb = compr_mb = None
    counters = [None] * len(COUNTERS)
    if cur["vm"] is not None:
        page, values = cur["vm"]
        if "Pages free" in values:
            free_mb = values["Pages free"] * page / 1048576.0
        if "Pages occupied by compressor" in values:
            compr_mb = values["Pages occupied by compressor"] * page / 1048576.0
        if prev["vm"] is not None:
            before = prev["vm"][1]
            for i, (_, key) in enumerate(COUNTERS):
                if key in values and key in before and values[key] >= before[key]:
                    counters[i] = values[key] - before[key]
    pressure = cur["pressure"]
    fields = [utc_text(cur["ts"]), fmt(cur["mono"] - t0, 3), fmt(load[0], 2), fmt(load[1], 2), fmt(load[2], 2),
              fmt(usr), fmt(sys_), fmt(cur["level"]), "-" if pressure is None else PRESSURE.get(pressure, str(pressure)),
              fmt(free_mb), fmt(compr_mb), fmt(cur["swap"])]
    fields += [fmt(c) for c in counters]
    fields.append(top_text(prev["procs"], cur["procs"], cur["mono"] - prev["mono"], ncpu))
    return "\t".join(fields)


def sample(path, control, max_seconds):
    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(s, on_signal)
    parent = os.getppid()
    host = Host()
    t0 = time.monotonic()
    written = 0
    reason = "?"
    prev = None
    took = []
    with open(path, "w") as out:
        try:
            ncpu = host.number("hw.ncpu")
            mem = host.number("hw.memsize", ctypes.c_uint64)
            prev = snapshot(host)
            took.append(prev["ps_took"])
            page = prev["vm"][0] if prev["vm"] is not None else None
            out.write("# load sampler: one line a second, from %s\n" % utc_text(prev["ts"]))
            out.write("# host: macOS %s, %s CPUs, %s MB memory, page %s bytes\n" % (
                platform.mac_ver()[0] or "?", fmt(ncpu), fmt(None if mem is None else mem / 1048576.0), fmt(page)))
            out.write("# usr, sys: % of all CPUs since the line before; free_pct, pressure: the kernel's memory"
                      " status; free_mb, compr_mb, swap_mb: free, compressor, swap used; pageins to decompressions:"
                      " vm_stat's counts since the line before; top: name[(processes)]=% of one CPU, sim.name for"
                      " a process inside a simulator\n")
            out.write(daemons_line(prev["procs"], prev["ts"]))
            out.write("\t".join(COLUMNS) + "\n")
            out.flush()
            k = 0
            login_end = None
            control_seen = None
            while True:
                k += 1
                delay = t0 + k * INTERVAL - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                else:
                    k = int((time.monotonic() - t0) / INTERVAL)
                cur = snapshot(host)
                took.append(cur["ps_took"])
                out.write(row(prev, cur, t0, ncpu) + "\n")
                out.flush()
                written += 1
                prev = cur
                if os.getppid() != parent:
                    reason = "its parent was gone"
                    break
                if cur["mono"] - t0 >= max_seconds:
                    reason = "%d s passed" % max_seconds
                    break
                if control_seen is None and os.path.exists(control):
                    control_seen = cur["mono"]
                    try:
                        with open(control) as f:
                            login = parse_login(f.read())
                    except OSError:
                        login = None
                    login_end = None if login is None else login + AFTER_LOGIN
                if control_seen is not None:
                    if login_end is None or cur["ts"] >= login_end:
                        reason = "told to stop, %s" % ("its login time unreadable" if login_end is None
                                                       else "the samples %d s past the login" % AFTER_LOGIN)
                        break
                    if cur["mono"] - control_seen >= CONTROL_WAIT:
                        reason = "told to stop, %d s after it was" % CONTROL_WAIT
                        break
        except Stop as e:
            reason = str(e)
        finally:
            if prev is not None:
                out.write(daemons_line(prev["procs"], prev["ts"]))
            times = os.times()
            took.sort()
            out.write("# end: %s; %d samples; own CPU %.2f s, ps and vm_stat %.2f s; ps ran %s\n" % (
                reason, written, times[0] + times[1], times[2] + times[3],
                "%.0f ms median, %.0f ms at most" % (1000 * took[len(took) // 2], 1000 * took[-1]) if took
                else "never"))


def number(text):
    if text in ("", "-"):
        return None
    try:
        return float(text)
    except ValueError:
        return None


def read_rows(path):
    rows = []
    last_t = 0.0
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or line.startswith("utc\t"):
                continue
            parts = line.split("\t")
            if len(parts) != len(COLUMNS):
                continue
            r = dict(zip(COLUMNS, parts))
            try:
                r["ts"] = parse_utc(r["utc"])
            except ValueError:
                continue
            t = number(r["t"])
            r["w"] = t - last_t if t is not None and t > last_t else INTERVAL
            if t is not None:
                last_t = max(last_t, t)
            rows.append(r)
    return rows


def column(rows, name):
    return [v for v in (number(r[name]) for r in rows) if v is not None]


def busy(rows):
    out = []
    for r in rows:
        u, s = number(r["usr"]), number(r["sys"])
        if u is not None and s is not None:
            out.append((u + s, r["w"]))
    return out


def weighted_mean(pairs):
    weight = sum(w for _, w in pairs)
    return sum(v * w for v, w in pairs) / weight if weight > 0 else None


def top_names(rows, n):
    totals = {}
    weight = sum(r["w"] for r in rows if r["top"] != "-")
    for r in rows:
        if r["top"] == "-":
            continue
        for item in r["top"].split(","):
            name, _, pct = item.rpartition("=")
            name = re.sub(r"\(\d+\)$", "", name)
            try:
                totals[name] = totals.get(name, 0.0) + float(pct) * r["w"]
            except ValueError:
                continue
    if weight <= 0:
        return "none"
    best = sorted(totals.items(), key=lambda kv: -kv[1])[:n]
    return ", ".join("%s %d%%" % (name, round(total / weight)) for name, total in best) or "none"


def read_daemons(path):
    out = []
    with open(path) as f:
        for line in f:
            m = re.match(r"^# daemons: (\S+); (.*)$", line.rstrip("\n"))
            if not m:
                continue
            try:
                ts = parse_utc(m.group(1))
            except ValueError:
                continue
            values = {}
            for part in m.group(2).split("; "):
                p = re.match(r"^(\S+) host (\d+) pids? ([\d.]+) s, sim (\d+) pids? ([\d.]+) s$", part)
                if p:
                    values[p.group(1)] = {"host": (int(p.group(2)), float(p.group(3))),
                                          "sim": (int(p.group(4)), float(p.group(5)))}
            if values:
                out.append((ts, values))
    return out


def daemons_part(path):
    try:
        lines = read_daemons(path)
    except OSError:
        lines = []
    if len(lines) < 2:
        return "daemons: %s" % ("no '# daemons:' lines" if not lines else "no end line")
    (t0, first), (t1, last) = lines[0], lines[-1]
    dt = t1 - t0
    parts = []
    for daemon in DAEMONS:
        if daemon not in first or daemon not in last:
            continue
        cells = []
        for where in ("host", "sim"):
            (n0, s0), (n1, s1) = first[daemon][where], last[daemon][where]
            if n0 == 0 and n1 == 0:
                cells.append("-")
                continue
            d = s1 - s0
            cells.append("%.1f (%s%%)%s" % (d, fmt(100.0 * d / dt) if dt > 0 else "-", "*" if n0 != n1 or d < 0 else ""))
        parts.append("%s %s" % (daemon, " / ".join(cells)))
    return "daemons over %d s, CPU s (%% of one CPU), host / sim: %s" % (round(dt), ", ".join(parts) or "none")


def most(values, digits=0):
    return fmt(max(values), digits) if values else "-"


def least(values):
    return fmt(min(values)) if values else "-"


def total(values):
    return fmt(sum(values)) if values else "-"


def summary(path, login_text):
    try:
        rows = read_rows(path)
    except OSError:
        rows = []
    name = "%s/%s" % (os.path.basename(os.path.dirname(os.path.abspath(path))) or "?", os.path.basename(path))
    if not rows:
        return "no samples (%s; the sampler's errors are in the step's log)" % name
    ts = [r["ts"] for r in rows]
    gaps = [b - a for a, b in zip(ts, ts[1:])]
    head = "%d samples in %d s (gaps up to %.1f s)" % (len(rows), round(ts[-1] - ts[0]), max(gaps) if gaps else 0)
    login = parse_login(login_text) if login_text and login_text != "-" else None
    if login_text == "-":
        window = rows
        where = "the whole file"
    elif login is not None:
        window = [r for r in rows if login - BEFORE_WINDOW <= r["ts"] <= login + AFTER_LOGIN]
        where = "login -%d..+%d s (%d, the last at %+.0f s)" % (BEFORE_WINDOW, AFTER_LOGIN, len(window), ts[-1] - login)
    else:
        window = rows
        where = "no login time: the whole file" if not login_text else "login time unreadable: the whole file"
    if not window:
        return "%s; %s: none (%s)" % (head, where, name)
    b = busy(window)
    pressures = [PRESSURE_ORDER[r["pressure"]] for r in window if r["pressure"] in PRESSURE_ORDER]
    worst = PRESSURE.get(max(pressures), "-") if pressures else "-"
    parts = [
        head,
        "%s: load1 max %s, busy max %s%% mean %s%%, top %s" % (
            where, most(column(window, "load1"), 1), most([v for v, _ in b]), fmt(weighted_mean(b)),
            top_names(window, 3)),
        "free min %s%% (%s) %s MB, compressor max %s MB, swap max %s MB, pagein/out %s/%s, swapin/out %s/%s" % (
            least(column(window, "free_pct")), worst, least(column(window, "free_mb")), most(column(window, "compr_mb")),
            most(column(window, "swap_mb")), total(column(window, "pageins")), total(column(window, "pageouts")),
            total(column(window, "swapins")), total(column(window, "swapouts"))),
        daemons_part(path),
        "whole: load1 max %s, busy max %s%%, swapin %s (%s)" % (
            most(column(rows, "load1"), 1), most([v for v, _ in busy(rows)]), total(column(rows, "swapins")), name),
    ]
    return "; ".join(parts)


def main(argv):
    if len(argv) >= 4 and argv[1] == "sample":
        sample(argv[2], argv[3], float(argv[4]) if len(argv) > 4 else 2400.0)
        return 0
    if len(argv) in (3, 4) and argv[1] == "summary":
        login_text = argv[3] if len(argv) == 4 else ""
        note = summary(argv[2], login_text)
        try:
            with open(argv[2], "a") as out:
                out.write("# login: %s\n# summary: %s\n" % (login_text or "-", note))
        except OSError:
            pass
        print(note)
        return 0
    sys.stderr.write("usage: load-sampler.py sample OUT CONTROL [MAX_SECONDS] | summary OUT [LOGIN|-]\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

