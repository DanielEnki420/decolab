#!/usr/bin/env bash
# Contract tests for tools/guard.sh, in a throw-away git repository.
# Single quotes around $… are intended: the code runs in a child shell.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Real-looking values are built from halves (see tests/lib.sh).
priv="192.168"; priv="$priv.31.7"
tailnet="100.78"; tailnet="$tailnet.1.2"
public="9.9"; public="$public.9.9"
mac="02:00"; mac="$mac:5e:10:00:01"
v6="2a00"; v6="$v6:1450:4001::1"
uuid="123e4567-e89b"; uuid="$uuid-12d3-a456-426614174000"
upath="/Use"; upath="${upath}rs/alice/notes"
hpath="/ho"; hpath="${hpath}me/alice"
mail="alice@"; mail="${mail}mail.de"

repo=$t_tmp/repo
mkdir -p "$repo/tools"
cp "$t_root/tools/guard.sh" "$repo/tools/"
git -C "$repo" init -q
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.com
git -C "$repo" config commit.gpgsign false
export DECOLAB_GUARD_WORDS=$t_tmp/words.txt DECOLAB_GUARD_ALLOW=$t_tmp/allow.txt
printf '# test words\nzebrafink\n' > "$DECOLAB_GUARD_WORDS"
: > "$DECOLAB_GUARD_ALLOW"
guard() { (cd "$repo" && tools/guard.sh "$@"); }

# stage FILE CONTENT - write a file and stage it (replacing the index)
stage() {
  git -C "$repo" rm -q --cached -r . >/dev/null 2>&1 || true
  printf '%s\n' "$2" > "$repo/$1"
  git -C "$repo" add "$1"
}

echo "harmless values pass"
stage ok.txt "lan 192.0.2.10 v6 2001:db8::1 mail user@example.com home /home/\$USER mask 255.255.255.0 local 127.0.0.1 any 0.0.0.0 nil 00000000-0000-0000-0000-000000000000"
check "documentation and loopback values" 0 "guard: clean (--staged)" -- guard --staged

echo "each class is found"
for case in "private-ipv4|$priv" "tailnet-ipv4|$tailnet" "public-ipv4|$public" "mac-address|$mac" \
  "ipv6|$v6" "uuid|$uuid" "personal-path|$upath" "personal-path|$hpath" "e-mail|$mail" "personal-word|ZebraFink"; do
  class=${case%%|*} value=${case#*|}
  stage bad.txt "value: $value"
  check "$class is found" 1 "$class" -- guard --staged
done
stage end.txt "address at the end of a sentence: $priv."
check "address before a full stop" 1 "private-ipv4" -- guard --staged

echo "findings are masked unless asked"
stage bad.txt "x $priv y"
check "masked by default" 1 "bad.txt:1" -- guard --staged
refute "value not printed" "$priv"
check "--show prints the value" 1 "$priv" -- guard --staged --show

echo "allow list"
printf 'bad.txt\t%s\n' "$public" > "$DECOLAB_GUARD_ALLOW"
stage bad.txt "dns $public"
check "allowed in its file" 0 "clean" -- guard --staged
stage other.txt "dns $public"
check "not allowed in another file" 1 "public-ipv4" -- guard --staged
printf 'bad.txt %s\n' "$public" > "$DECOLAB_GUARD_ALLOW"
check "allow line without TAB is an error" 2 "line without TAB" -- guard --staged
: > "$DECOLAB_GUARD_ALLOW"

echo "history, messages and text"
git -C "$repo" rm -q --cached -r . >/dev/null 2>&1 || true
rm -f "$repo"/*.txt
printf 'secret place %s\n' "$priv" > "$repo/old.txt"
git -C "$repo" add old.txt tools/guard.sh
git -C "$repo" commit -q --no-verify -m "first"
git -C "$repo" rm -q old.txt
git -C "$repo" commit -q --no-verify -m "remove it again"
check "removed file passes the tree check" 0 "clean (--tree)" -- guard --tree
check "removed file is still in history" 1 "old.txt:1" -- guard --history
printf 'ok\n' > "$repo/n.txt"
git -C "$repo" add n.txt
git -C "$repo" commit -q --no-verify -m "fix for $mail"
check "commit message is checked" 1 "commit-message" -- guard --history
printf 'note %s\n' "$tailnet" > "$t_tmp/msg.txt"
check "text mode" 1 "tailnet-ipv4" -- guard --text "$t_tmp/msg.txt"

echo "tool errors are not a clean result"
check "outside a repository" 2 "not inside a git repository" -- bash -c 'cd "$1" && "$2"/tools/guard.sh --tree' _ "$t_tmp" "$t_root"
check "unknown option" 2 "" -- guard --everything
cp "$repo/.git/index" "$t_tmp/index.ok"
printf 'broken' > "$repo/.git/index"
check "git failure is an error, not clean" 2 "git grep failed" -- guard --staged
cp "$t_tmp/index.ok" "$repo/.git/index"
mv "$DECOLAB_GUARD_WORDS" "$t_tmp/words.off"
check "missing word list is announced" 0 "no private word list" -- guard --tree
mv "$t_tmp/words.off" "$DECOLAB_GUARD_WORDS"

t_finish
