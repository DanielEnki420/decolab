#!/usr/bin/env bash
# setup-dev.sh - prepare a clone of Decolab for development
#
# Installs the git hooks (guard + gitleaks on every commit and commit message,
# and over the whole history before every push)
# creates an empty private word list for tools/guard.sh if none exists, and
# installs ruff and mypy into .lint/ (versions and checksums from
# tools/requirements-lint.txt).
set -euo pipefail
root=$(git rev-parse --show-toplevel)
words=${DECOLAB_GUARD_WORDS:-$HOME/.config/decolab/guard-words.txt}
missing=0

for tool in git gitleaks shellcheck; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "setup-dev: $tool is missing" >&2
    missing=1
  fi
done

git -C "$root" config core.hooksPath githooks
echo "setup-dev: git hooks active (core.hooksPath=githooks)"

if [ ! -f "$words" ]; then
  mkdir -p "$(dirname "$words")"
  (umask 077 && cat > "$words" <<'EOF'
# Private word list for tools/guard.sh: one word per line, case-insensitive.
# Put here what must never appear in the public repository: your user name,
# real name, host names, tailnet name, Wi-Fi name, device names, provider
# account names. This file stays on your machine; do not commit it.
EOF
  )
  echo "setup-dev: created $words; add your personal words to it"
else
  echo "setup-dev: private word list found: $words"
fi

req=$root/tools/requirements-lint.txt
stamp=$root/.lint/requirements-lint.txt
if [ -f "$stamp" ] && cmp -s "$req" "$stamp"; then
  echo "setup-dev: ruff and mypy in .lint/ are current"
else
  rm -rf "$root/.lint"
  python3 -m venv "$root/.lint"
  "$root/.lint/bin/pip" install --quiet --disable-pip-version-check \
    --only-binary :all: --require-hashes -r "$req"
  cp "$req" "$stamp"
  echo "setup-dev: ruff and mypy installed in .lint/"
fi

[ "$missing" -eq 0 ] || { echo "setup-dev: install the missing tools, then run this again" >&2; exit 1; }
