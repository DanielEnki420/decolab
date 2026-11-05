"""render.py TEMPLATE - print TEMPLATE with its declared variables filled in.

A template declares its variables in one header line:
    install.sh renders this file with exactly these variables: ${A} ${B}
Only those are replaced, with the values from the environment. Fails (exit 1)
if a declared variable is not set, or if any other ${...} would be left in
the output: a literal "${X}" in /etc is a bug that would only show at night.

Values come through the environment, never through argv: a password in the
argument list is visible to every user (ps).
"""
import os
import re
import sys

MARK = "with exactly these variables:"
VAR = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: render.py TEMPLATE")
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        text = f.read()
    header = next((l for l in text.splitlines() if MARK in l), None)
    if header is None:
        sys.exit(f"{path}: no line '{MARK} ...'")
    names = VAR.findall(header.split(MARK, 1)[1])
    missing = [n for n in names if n not in os.environ]
    if missing:
        sys.exit(f"{path}: not set: {' '.join(missing)}")

    def fill(m):
        return os.environ[m.group(1)] if m.group(1) in names else m.group(0)

    lines = []
    for line in text.splitlines(keepends=True):
        lines.append(line if MARK in line else VAR.sub(fill, line))
    out = "".join(lines)
    left = sorted({m for l in out.splitlines() if MARK not in l for m in VAR.findall(l)})
    if left:
        sys.exit(f"{path}: undeclared variables left: {' '.join(left)}")
    sys.stdout.write(out)


if __name__ == "__main__":
    main()
