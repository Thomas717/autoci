#!/usr/bin/env python3

import datetime
import json
import os
import re
import subprocess
import sys
import time

ROWS = ("diagnosticd", "logd", "apsd", "log", "launchd_sim")
PREFIXES = ("provjobd",)
DAEMONS = ("diagnosticd", "logd", "apsd")
HOST_DIAG = "/var/db/diagnostics"
LOOK_BACK = 3600
TOP = 12
UTC = datetime.timezone.utc
CLIENT = re.compile(r"^(\S+ \S+) diagnosticd\[\d+\]: (.*?) ?client (started|stopped) - (.+?) \(\d+\)")


def utc_text(ts):
    return datetime.datetime.fromtimestamp(ts, UTC).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def clean_name(name, n=32):
    return re.sub(r"[^A-Za-z0-9._+-]+", "_", name.strip())[:n] or "?"


def output(cmd, timeout=20):
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout,
                           universal_newlines=True)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def cpu_seconds(text):
    days = 0
    if "-" in text:
        d, text = text.split("-", 1)
        days = int(d)
    total = 0.0
    for part in text.split(":"):
        total = total * 60 + float(part)
    return days * 86400 + total


def mb(n):
    return "%.1f MB" % (n / 1048576.0)


def sudo_allowed(flags):
    return "sudo" in flags and os.environ.get("GITHUB_ACTIONS") == "true"


def read_text(path, flags):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace"), ""
    except FileNotFoundError:
        return None, "none"
    except OSError as e:
        why = "unreadable (%s)" % e.__class__.__name__
    if not sudo_allowed(flags):
        return None, why
    try:
        r = subprocess.run(["sudo", "-n", "cat", path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None, why + ", sudo -n failed"
    if r.returncode != 0:
        return None, why + ", sudo -n cat exit %d" % r.returncode
    return r.stdout.decode("utf-8", "replace"), "sudo"


def ps_table():
    text = output(["ps", "-A", "-o", "pid=,ppid=,etime=,time=,ucomm="])
    if text is None:
        return None
    table = {}
    for line in text.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 4:
            continue
        try:
            table[int(parts[0])] = (int(parts[1]), parts[2], parts[3], parts[4].strip() if len(parts) > 4 else "")
        except ValueError:
            continue
    return table


def sim_root(pid, table, sims):
    seen = 0
    while pid in table and seen < 64:
        pid = table[pid][0]
        if pid in sims:
            return pid
        if pid <= 1:
            return None
        seen += 1
    return None


def wanted(name):
    return name in ROWS or name.startswith(PREFIXES)


def probe_ps(out, udid):
    table = ps_table()
    if table is None:
        out.append("# ps: failed")
        return "ps failed"
    sims = set(pid for pid, r in table.items() if r[3] == "launchd_sim")
    device = {}
    for pid in sims:
        cmd = output(["ps", "-o", "command=", "-p", str(pid)]) or ""
        device[pid] = "run" if udid and udid in cmd else "other"
    groups = {}
    out.append("# ps (pid ppid etime cputime ucomm where device):")
    for pid in sorted(table):
        ppid, etime, cputime, name = table[pid]
        if not wanted(name):
            continue
        root = sim_root(pid, table, sims)
        where = "host" if root is None else "sim"
        dev = device.get(root if root is not None else pid, "-")
        out.append("%d\t%d\t%s\t%s\t%s\t%s\t%s" % (pid, ppid, etime, cputime, clean_name(name), where, dev))
        try:
            secs = cpu_seconds(cputime)
        except ValueError:
            secs = 0.0
        key = ("provjobd" if name.startswith(PREFIXES) else name, where)
        g = groups.setdefault(key, [0, 0.0, 0, 0.0])
        g[0] += 1
        g[1] += secs
        if dev == "other":
            g[2] += 1
            g[3] += secs
    parts = []
    for name in DAEMONS:
        cells = []
        for where in ("host", "sim"):
            n, secs, n_other, secs_other = groups.get((name, where), [0, 0.0, 0, 0.0])
            cell = "%s %d %.1f s" % (where, n, secs)
            if n_other:
                cell += " (other devices %d %.1f s)" % (n_other, secs_other)
            cells.append(cell)
        parts.append("%s %s" % (name, ", ".join(cells)))
    n_log = sum(groups.get(("log", w), [0])[0] for w in ("host", "sim"))
    n_prov, secs_prov = groups.get(("provjobd", "host"), [0, 0.0])[:2]
    n_run = sum(1 for d in device.values() if d == "run")
    parts.append("log %d; launchd_sim %d (the run's %d); provjobd %d %.1f s" % (n_log, len(sims), n_run, n_prov, secs_prov))
    return "; ".join(parts)


def device_data(udid):
    text = output(["xcrun", "simctl", "list", "devices", "-j"], timeout=60)
    if text is not None:
        try:
            for devices in json.loads(text).get("devices", {}).values():
                for d in devices:
                    if d.get("udid") == udid and d.get("dataPath"):
                        return d["dataPath"]
        except (ValueError, AttributeError):
            pass
    return os.path.join(os.path.expanduser("~"), "Library/Developer/CoreSimulator/Devices", udid, "data")


def probe_clients(out, what, directory, flags):
    lines = 0
    counts = {}
    last = None
    read = []
    failed = []
    for f in ("diagnosticd.1.log", "diagnosticd.0.log"):
        text, how = read_text(os.path.join(directory, f), flags)
        if text is None:
            if how != "none":
                failed.append("%s %s" % (f, how))
            continue
        read.append(f + (" (sudo)" if how else ""))
        for line in text.splitlines():
            if not line.strip():
                continue
            lines += 1
            m = CLIENT.match(line)
            if m:
                key = "%s %s %s" % (m.group(3), clean_name(m.group(2)) if m.group(2) else "-", clean_name(m.group(4)))
                counts[key] = counts.get(key, 0) + 1
                last = m.group(1)
    if not read:
        out.append("# diagnosticd log, %s: %s" % (what, ", ".join(failed) or "none"))
        return "%s %s" % (what, "unreadable" if failed else "no log")
    started = sum(n for k, n in counts.items() if k.startswith("started "))
    listing = ", ".join("%s %d" % kv for kv in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))) or "none"
    out.append("# diagnosticd log, %s: %s; %d lines; client lines: %s%s" % (
        what, ", ".join(read + failed), lines, listing, "; the last at %s" % last if last else ""))
    names = sorted(set(k.split(" ", 2)[2] for k in counts if k.startswith("started ")))
    return "%s %d%s" % (what, started, " (%s)" % ", ".join(names) if names else "")


def probe_stats(out, what, directory, since, now, flags):
    records = 0
    total = 0
    types = {}
    procs = {}
    snapshots = {}
    listed = 0
    first = last = None
    read = []
    for f in ("logdata.statistics.1.jsonl", "logdata.statistics.0.jsonl"):
        text, how = read_text(os.path.join(directory, f), flags)
        if text is None:
            if how != "none":
                read.append("%s %s" % (f, how))
            continue
        read.append(f + (" (sudo)" if how else ""))
        for line in text.splitlines():
            try:
                r = json.loads(line)
                t = float(r.get("unixTime", 0))
            except (ValueError, TypeError, AttributeError):
                continue
            if not since < t <= now:
                continue
            if r.get("record") == "logd snapshot":
                name = clean_name(os.path.basename(str(r.get("client", "?"))))
                snapshots[name] = snapshots.get(name, 0) + 1
                continue
            records += 1
            total += int(r.get("totalBytes", 0) or 0)
            types[r.get("type", "?")] = types.get(r.get("type", "?"), 0) + 1
            first = t if first is None else min(first, t)
            last = t if last is None else max(last, t)
            for p in r.get("processList", []) or []:
                name = clean_name(os.path.basename(str(p.get("process", "?"))))
                size = int(p.get("sizeBytes", 0) or 0)
                procs[name] = procs.get(name, 0) + size
                listed += size
    head = "# logd statistics, %s, since %s: " % (what, utc_text(since))
    if not read:
        out.append(head + "none")
        return "%s none" % what
    snaps = "; snapshots (a reader such as log show): %s" % top(snapshots, TOP) if snapshots else ""
    if not records:
        out.append(head + "%s; no record%s" % (", ".join(read), snaps))
        return "%s 0 MB" % what
    best = sorted(procs.items(), key=lambda kv: -kv[1])[:TOP]
    out.append(head + "%s; %d records (%s) from %s to %s, %s; the processes listed hold %d%%: %s%s" % (
        ", ".join(read), records, ", ".join("%s %d" % kv for kv in sorted(types.items())), utc_text(first),
        utc_text(last), mb(total), round(100.0 * listed / total) if total else 0,
        ", ".join("%s %s" % (n, mb(s)) for n, s in best), snaps))
    return "%s %s (%s)" % (what, mb(total), ", ".join("%s %s" % (n, mb(s)) for n, s in best[:2]))


def top(counter, n):
    best = sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))[:n]
    return ", ".join("%s %d" % kv for kv in best) or "none"


def main(argv):
    if len(argv) < 5:
        sys.stderr.write("usage: diag-probe.py LABEL OUT STATE UDID|- [sudo]\n")
        return 2
    label, path, state, udid = argv[1:5]
    flags = set(argv[5:])
    udid = "" if udid == "-" else udid
    if udid and not re.match(r"^[0-9A-Fa-f-]{36}$", udid):
        udid = ""
    t_start = time.monotonic()
    now = time.time()
    since = None
    try:
        with open(state) as f:
            since = float(f.read().strip())
    except (OSError, ValueError):
        pass
    if since is None:
        try:
            since = float(os.environ.get("RUN_T0", "")) - LOOK_BACK
        except ValueError:
            since = now - LOOK_BACK
    out = ["## %s %s" % (label, utc_text(now))]
    notes = []
    try:
        notes.append(probe_ps(out, udid))
    except Exception as e:
        out.append("# ps: failed (%s)" % e.__class__.__name__)
        notes.append("ps failed (%s)" % e.__class__.__name__)
    data = None
    if udid:
        try:
            data = device_data(udid)
        except Exception as e:
            out.append("# the run's device: no data directory (%s)" % e.__class__.__name__)
    else:
        out.append("# the run's device: none yet")
    places = [("host", HOST_DIAG, flags)]
    if data:
        places.append(("sim", os.path.join(data, "var", "db", "diagnostics"), set()))
    clients = []
    stats = []
    for what, directory, fl in places:
        try:
            clients.append(probe_clients(out, what, directory, fl))
        except Exception as e:
            out.append("# diagnosticd log, %s: failed (%s)" % (what, e.__class__.__name__))
            clients.append("%s failed" % what)
        try:
            stats.append(probe_stats(out, what, directory, since, now, fl))
        except Exception as e:
            out.append("# logd statistics, %s: failed (%s)" % (what, e.__class__.__name__))
            stats.append("%s failed" % what)
    notes.append("diagnosticd clients started: " + ", ".join(clients))
    notes.append("logd stats " + ", ".join(stats))
    try:
        with open(state, "w") as f:
            f.write("%.3f\n" % now)
    except OSError:
        pass
    times = os.times()
    out.append("# probe: %.1f s, own CPU %.2f s, children %.2f s" % (
        time.monotonic() - t_start, times[0] + times[1], times[2] + times[3]))
    with open(path, "a") as f:
        f.write("\n".join(out) + "\n\n")
    print("; ".join(notes) + " (diag-probe.txt)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

