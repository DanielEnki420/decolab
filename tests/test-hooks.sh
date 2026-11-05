#!/usr/bin/env bash
# Contract tests for the git hooks: what reaches a commit and what does not.
# Single quotes around $… are intended: the code runs in a child shell.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

priv="192.168"; priv="$priv.31.7"
# Fake GitHub token in the documented format (ghp_ + 36 characters); built
# from halves so the repository itself never contains one.
token="ghp_"; token="${token}R7mQ2xVb9KpL4sWn8TzY3cHd6FjA1uEo5GiN"

repo=$t_tmp/repo
mkdir -p "$repo"
cp -R "$t_root/tools" "$t_root/githooks" "$repo/"
: > "$repo/tools/guard-allow.txt"
# The VM probe names Docker's example pool, an exception in the real list
rm -rf "$repo/tools/vm-probe"
git -C "$repo" init -q
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.com
git -C "$repo" config commit.gpgsign false
git -C "$repo" config core.hooksPath githooks
export DECOLAB_GUARD_WORDS=$t_tmp/words.txt
printf 'zebrafink\n' > "$DECOLAB_GUARD_WORDS"
git -C "$repo" add tools githooks
git -C "$repo" commit -q -m "tools" >/dev/null 2>&1 \
  || { t_fail "setup commit" "hooks refused the tools themselves"; t_finish; exit 1; }

commits() { git -C "$repo" rev-list --count HEAD; }
attempt() { # FILE CONTENT MESSAGE
  printf '%s\n' "$2" > "$repo/$1"
  git -C "$repo" add "$1"
  git -C "$repo" commit -q -m "$3"
}

before=$(commits)
check "private address is refused" 1 "private-ipv4" -- attempt a.txt "lan $priv" "add a"
same "nothing was committed" "$(commits)" "$before"
git -C "$repo" reset -q

if command -v gitleaks >/dev/null 2>&1; then
  check "secret token is refused" 1 "leaks found" -- attempt t.txt "token = $token" "add t"
  same "token was not committed" "$(commits)" "$before"
  git -C "$repo" reset -q
  rm -f "$repo/t.txt"
else
  t_fail "secret token is refused" "gitleaks is not installed"
fi

check "personal word in message is refused" 1 "personal-word" -- attempt b.txt "fine" "for Zebrafink"
git -C "$repo" reset -q
check "clean commit passes" 0 "" -- attempt c.txt "lan 192.0.2.10" "add c"
same "clean commit is in history" "$(commits)" $((before + 1))

check "missing gitleaks blocks the commit" 1 "gitleaks is not installed" -- \
  env DECOLAB_GITLEAKS=/nonexistent/gitleaks bash -c 'cd "$1" && printf "x\n" > d.txt && git add d.txt && git commit -q -m "add d"' _ "$repo"
git -C "$repo" reset -q

# pre-push: what the commit hooks did not see (--no-verify) is caught here
bare=$t_tmp/remote.git
git init -q --bare "$bare"
git -C "$repo" remote add origin "$bare"
push() { git -C "$repo" push -q origin HEAD:refs/heads/main; }
check "a clean history is pushed" 0 "" -- push
printf 'lan %s\n' "$priv" > "$repo/e.txt"
git -C "$repo" add e.txt && git -C "$repo" commit -q --no-verify -m "add e"
check "a commit past the hooks (--no-verify) is refused at push" 1 "private-ipv4" -- push
git -C "$repo" reset -q --hard HEAD~1
git -C "$repo" -c user.email=zebrafink@example.com commit -q --no-verify --allow-empty -m "empty"
check "a personal word in the author is refused at push" 1 "personal-word" -- push
git -C "$repo" reset -q --hard HEAD~1
git -C "$repo" -c user.name=Zebrafink -c user.email=4711+zebrafink@users.noreply.github.com commit -q --no-verify --allow-empty -m "empty"
check "the publishing account's noreply identity is public anyway: pushed" 0 "" -- push
git -C "$repo" -c user.email=zebrafink@users.noreply.github.com commit -q --no-verify --allow-empty -m "empty"
check "  ... a look-alike without the account number is not" 1 "personal-word" -- push
git -C "$repo" reset -q --hard HEAD~1
git -C "$repo" -c user.name=Zebrafink tag -a v0.0.2 -m "release"
check "a personal word in the tagger is refused at push" 1 "personal-word" -- push
git -C "$repo" tag -d v0.0.2 >/dev/null
git -C "$repo" tag -a v0.0.1 -m "for Zebrafink"
check "a personal word in a tag message is refused at push" 1 "personal-word" -- push
git -C "$repo" tag -d v0.0.1 >/dev/null
DECOLAB_GUARD_WORDS=/nonexistent check "no private word list: refused" 1 "no private word list" -- push
DECOLAB_GITLEAKS=/nonexistent/gitleaks check "missing gitleaks blocks the push" 1 "gitleaks is not installed" -- push
check "  ... and still clean otherwise" 0 "" -- push

t_finish
