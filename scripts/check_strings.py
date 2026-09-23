#!/usr/bin/env python3
"""Fails unless every user-visible Chinese string can show in English.

The compiler lists every localization key the app uses (Text, Button,
String(localized:) ...). Against that list this checks:

1. every Chinese string literal in Sources/TimeSinkKit is one of those keys;
   anything else is a plain String that will stay Chinese in English
   (mark genuine data, such as a title-matching regex, with `// l10n: data`
   on its line);
2. every key has an English translation in packaging/Localizable.xcstrings,
   with no Chinese left in it;
3. each translation has the same format placeholders as its key;
4. the catalog holds no key the code no longer uses.

Run from the repository root: python3 scripts/check_strings.py
"""
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

CJK = re.compile(r"[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]")
CATALOG = "packaging/Localizable.xcstrings"
ESCAPES = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": "\0", "r": "\r"}


def compiler_keys():
    """Returns ({key}, {(relative path, line): {key}}) as the compiler sees them."""
    with tempfile.TemporaryDirectory() as out:
        build = subprocess.run(
            ["swift", "build", "--target", "TimeSinkKit",
             "-Xswiftc", "-emit-localized-strings",
             "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", out],
            capture_output=True, text=True,
        )
        if build.returncode:
            sys.exit(build.stdout + build.stderr)
        keys, at = set(), {}
        for path in glob.glob(f"{out}/*.stringsdata"):
            data = json.load(open(path))
            source = os.path.relpath(data["source"])
            for entries in data.get("tables", {}).values():
                for e in entries:
                    keys.add(e["key"])
                    at.setdefault((source, e["location"]["startingLine"]), set()).add(e["key"])
        return keys, at


def literals(src):
    """Yields (line, fragments) for each string literal outside comments.

    `fragments` are the literal's text pieces between interpolations,
    escapes decoded. Literals nested inside an interpolation are yielded
    on their own.
    """
    i, n, line = 0, len(src), 1

    def read_literal(i, line):
        multi = src.startswith('"""', i)
        i += 3 if multi else 1
        start_line, frags, cur = line, [], []
        while i < n:
            c = src[i]
            if (multi and src.startswith('"""', i)) or (not multi and c == '"'):
                frags.append("".join(cur))
                return i + (3 if multi else 1), line, (start_line, frags)
            if c == "\\" and i + 1 < n:
                nxt = src[i + 1]
                if nxt == "(":
                    frags.append("".join(cur))
                    cur = []
                    i, line = read_interpolation(i + 2, line)
                    continue
                cur.append(ESCAPES.get(nxt, nxt))
                i += 2
                continue
            if c == "\n":
                line += 1
            cur.append(c)
            i += 1
        raise SyntaxError(f"unterminated literal at line {start_line}")

    nested = []

    def read_interpolation(i, line):
        depth = 1
        while i < n:
            c = src[i]
            if c == '"':
                i, line, lit = read_literal(i, line)
                nested.append(lit)
                continue
            if c == "\n":
                line += 1
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    return i + 1, line
            i += 1
        raise SyntaxError("unterminated interpolation")

    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i)
            line += src.count("\n", i, j)
            i = j + 2
        elif c == '"':
            i, line, lit = read_literal(i, line)
            yield lit
            yield from nested
            nested.clear()
        else:
            if c == "\n":
                line += 1
            i += 1


def key_pattern(frags):
    # Interpolations become format specifiers (%@, %lld, %1$@ ...); a
    # literal % in source is %% in the key.
    spec = r"%(?:\d+\$)?[-+ #0-9.]*(?:ll|l|h)?[@dDiuUxXoOfeEgGcCsSpaA]"
    return re.compile(spec.join(re.escape(f.replace("%", "%%")) for f in frags) + r"\Z", re.S)


def specifiers(text):
    """The format specifiers in order, `%%` excluded. A translation whose
    list differs from its key's garbles the text or crashes at runtime."""
    return re.findall(r"%(?:\d+\$)?[-+ #0-9.]*(?:ll|l|h)?[@dDiuUxXoOfeEgGcCsSpaA]", text.replace("%%", ""))


def main():
    keys, at = compiler_keys()
    problems = []

    for path in sorted(glob.glob("Sources/TimeSinkKit/**/*.swift", recursive=True)):
        src = open(path, encoding="utf-8").read()
        lines = src.split("\n")
        for line, frags in literals(src):
            if not any(CJK.search(f) for f in frags):
                continue
            if "// l10n: data" in lines[line - 1]:
                continue
            pattern = key_pattern(frags)
            # The same text used as a key elsewhere does not count: only a key
            # the compiler found on this very line means this literal is one.
            if not any(pattern.match(k) for k in at.get((path, line), ())):
                text = "\\(…)".join(frags).replace("\n", "\\n")
                problems.append(f"{path}:{line}: not localized: \"{text}\"")

    catalog = json.load(open(CATALOG, encoding="utf-8"))["strings"]
    for key in sorted(keys):
        if not CJK.search(key) and key not in catalog:
            continue  # "--", "%lld%%" and the like read the same in English
        en = catalog.get(key, {}).get("localizations", {}).get("en")
        if en is None:
            problems.append(f"{CATALOG}: no English for \"{key}\"")
            continue
        units = [en["stringUnit"]] if "stringUnit" in en else [
            v["stringUnit"] for v in en["variations"]["plural"].values()]
        for unit in units:
            if unit["state"] != "translated" or CJK.search(unit["value"]):
                problems.append(f"{CATALOG}: English for \"{key}\" is not finished: \"{unit['value']}\"")
            elif specifiers(unit["value"]) != specifiers(key):
                problems.append(f"{CATALOG}: English for \"{key}\" has placeholders {specifiers(unit['value'])}, "
                                f"the key has {specifiers(key)}")
    for key in sorted(set(catalog) - keys):
        problems.append(f"{CATALOG}: \"{key}\" is no longer used by the code")

    for p in problems:
        print(p)
    print(f"{len(keys)} keys, {len(catalog)} catalog entries, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
