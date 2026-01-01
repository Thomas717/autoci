#!/usr/bin/env python3

import os
import shutil
import sys
from urllib.parse import quote

MIN_LENGTH = 8

SCANNABLE = (".txt", ".log", ".json", ".md", ".yaml", ".yml", ".ips", ".crash", ".png", ".jpg", ".jpeg")


def forms(literal):
    out = {literal, quote(literal, safe=""), literal.replace("/", "\\/")}
    return sorted((f for f in out if len(f) >= MIN_LENGTH), key=len, reverse=True)


def remove(path):
    try:
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.remove(path)
    except OSError:
        pass
    if os.path.lexists(path):
        sys.stderr.write("masking: could not remove %s\n" % os.path.basename(path))
        return False
    return True


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: mask-secrets.py <mask list> <dir> [<dir> ...]\n")
        return 2
    with open(argv[1], encoding="utf-8") as f:
        literals = {line.strip() for line in f if len(line.strip()) >= MIN_LENGTH}
    patterns = []
    for literal in literals:
        patterns.extend(forms(literal))
    patterns = sorted(set(patterns), key=len, reverse=True)
    byte_patterns = [p.encode("utf-8") for p in patterns]

    dirs = [d for d in argv[2:] if os.path.isdir(d)]
    files = []
    removed = []
    for d in dirs:
        for base, subdirs, names in os.walk(d):
            for name in list(subdirs):
                path = os.path.join(base, name)
                if os.path.islink(path) or ("." in name and not name.lower().endswith(SCANNABLE)):
                    if not remove(path):
                        return 2
                    removed.append(path)
                    subdirs.remove(name)
            for name in names:
                path = os.path.join(base, name)
                if os.path.islink(path) or not os.path.isfile(path) or not name.lower().endswith(SCANNABLE):
                    if not remove(path):
                        return 2
                    removed.append(path)
                else:
                    files.append(path)

    replaced_files = replacements = 0
    deleted = []
    for path in files:
        try:
            with open(path, "rb") as f:
                raw = f.read()
            text = raw.decode("utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        count = 0
        for p in patterns:
            n = text.count(p)
            if n:
                text = text.replace(p, "***")
                count += n
        if count:
            try:
                with open(path, "wb") as f:
                    f.write(text.encode("utf-8"))
            except OSError:
                if not remove(path):
                    return 2
                deleted.append(path)
                continue
            replaced_files += 1
            replacements += count

    for path in files:
        if path in deleted:
            continue
        try:
            with open(path, "rb") as f:
                raw = f.read()
        except OSError:
            if not remove(path):
                return 2
            removed.append(path)
            continue
        if any(p in raw for p in byte_patterns):
            if not remove(path):
                return 2
            deleted.append(path)

    report = os.path.join(dirs[0], "masking.txt") if dirs else None
    if report:
        with open(report, "a", encoding="utf-8") as f:
            f.write("masking: %d literal(s) in %d form(s); %d file(s) scanned; %d replacement(s) in %d file(s); "
                    "%d file(s) deleted because a secret was or might be still in them; %d removed unread\n"
                    % (len(literals), len(patterns), len(files), replacements, replaced_files, len(deleted),
                       len(removed)))
            for path in deleted:
                f.write("  deleted: %s\n" % os.path.relpath(path, os.path.dirname(dirs[0])))
            for path in removed:
                f.write("  removed unread: %s\n" % os.path.relpath(path, os.path.dirname(dirs[0])))
    print("masking: %d file(s) scanned, %d replacement(s) in %d file(s), %d file(s) deleted, %d removed unread"
          % (len(files), replacements, replaced_files, len(deleted), len(removed)))
    return 1 if deleted else 0


if __name__ == "__main__":
    try:
        status = main(sys.argv)
    except BaseException as e:
        if isinstance(e, SystemExit):
            raise
        sys.stderr.write("masking: stopped by %s; nothing may leave the runner\n" % type(e).__name__)
        status = 2
    sys.exit(status)

