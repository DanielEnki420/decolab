#!/usr/bin/env bash
# guard.sh - keep personal data out of the Decolab repository
#
#   guard.sh --staged         check what is staged for the next commit
#   guard.sh --tree           check tracked and untracked (not ignored) files
#   guard.sh --history        check every commit, commit message, author, tag and ref name
#   guard.sh --text FILE...   check plain files (used for commit messages)
#   --show                    print findings in full (default: masked, so CI
#                             logs never repeat what was found)
#
# Finds IPv4 addresses outside documentation, loopback, netmask and multicast
# ranges; global and unique-local IPv6; MAC addresses; UUIDs; /home/<name> and
# /Users/<name> paths; e-mail addresses outside example and reserved domains;
# and words from a private list. The list is personal itself, so it lives
# outside the repository: $DECOLAB_GUARD_WORDS or
# ~/.config/decolab/guard-words.txt (one word per line, case-insensitive).
#
# Reviewed exceptions: tools/guard-allow.txt, "<path glob><TAB><exact match>".
# Exit codes: 0 clean, 1 findings, 2 usage or tool error.
set -euo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "guard: not inside a git repository" >&2; exit 2; }
allow_file=${DECOLAB_GUARD_ALLOW:-$root/tools/guard-allow.txt}
words_file=${DECOLAB_GUARD_WORDS:-$HOME/.config/decolab/guard-words.txt}

usage() { sed -n '2,9s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2; exit 2; }

mode="" show=0 texts=()
while [ $# -gt 0 ]; do
  case $1 in
    --staged | --tree | --history) [ -z "$mode" ] || usage; mode=${1#--} ;;
    --text) [ -z "$mode" ] || usage; mode=text; shift; [ $# -gt 0 ] || usage; texts=("$@"); break ;;
    --show) show=1 ;;
    *) usage ;;
  esac
  shift
done
[ -n "$mode" ] || usage

tmp=$(mktemp -d "${TMPDIR:-/tmp}/decolab-guard.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- patterns (PCRE, run by git grep -P) -------------------------------------
oct='(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
pat_names=(ipv4 ipv6 mac uuid path email)
pattern_for() {
  case $1 in
    ipv4) printf '%s' "(?<![0-9.])$oct\\.$oct\\.$oct\\.$oct(?![0-9]|\\.[0-9])" ;;
    ipv6) printf '%s' '(?i)(?<![0-9a-f:])(?:[23][0-9a-f]{3}|f[cd][0-9a-f]{2}):(?:[0-9a-f]{0,4}:){1,6}[0-9a-f]{0,4}(?![0-9a-f:])' ;;
    mac) printf '%s' '(?i)(?<![0-9a-f:-])[0-9a-f]{2}([:-])(?:[0-9a-f]{2}\1){4}[0-9a-f]{2}(?![0-9a-f:-])' ;;
    uuid) printf '%s' '(?i)(?<![0-9a-f-])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f-])' ;;
    path) printf '%s' '/(?:home|Users)/[A-Za-z0-9_][A-Za-z0-9_.-]*' ;;
    email) printf '%s' '(?i)(?<![a-z0-9._%+-])[a-z0-9._%+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}(?![a-z0-9-])' ;;
  esac
}

# --- allow list --------------------------------------------------------------
allow_globs=() allow_values=()
if [ -f "$allow_file" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in '' | '#'*) continue ;; esac
    case $line in *$'\t'*) ;; *) echo "guard: $allow_file: line without TAB: $line" >&2; exit 2 ;; esac
    allow_globs+=("${line%%$'\t'*}")
    allow_values+=("${line#*$'\t'}")
  done < "$allow_file"
fi

allow_rel=${allow_file#"$root"/}
allowed_by_list() { # PATH VALUE
  local i
  for ((i = 0; i < ${#allow_globs[@]}; i++)); do
    # the allow list may contain its own entries, nothing else
    [ "$1" = "$allow_rel" ] && [ "$2" = "${allow_values[$i]}" ] && return 0
    # shellcheck disable=SC2254  # the glob is meant to match
    case $1 in ${allow_globs[$i]}) [ "$2" = "${allow_values[$i]}" ] && return 0 ;; esac
  done
  return 1
}

# --- classification ------------------------------------------------------------
# Prints the finding class, or nothing if the match is harmless.
classify() { # KIND VALUE
  local v=$2 a b lower
  case $1 in
    ipv4)
      a=${v%%.*} b=${v#*.} b=${b%%.*}
      if [ "$a" -eq 127 ] || [ "$a" -ge 224 ] || [ "$v" = 0.0.0.0 ]; then return; fi
      case $v in 192.0.2.* | 198.51.100.* | 203.0.113.*) return ;; esac
      if [ "$a" -eq 10 ] || { [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } \
        || { [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; }; then
        echo private-ipv4
      elif [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; then
        echo tailnet-ipv4
      elif [ "$a" -eq 169 ] && [ "$b" -eq 254 ]; then
        echo link-local-ipv4
      else
        echo public-ipv4
      fi ;;
    ipv6)
      lower=$(printf '%s' "$v" | tr 'A-F' 'a-f')
      case $lower in 2001:db8:* | 2001:0db8:*) return ;; esac
      echo ipv6 ;;
    mac)
      lower=$(printf '%s' "$v" | tr 'A-F-' 'a-f:')
      case $lower in 00:00:00:00:00:00 | ff:ff:ff:ff:ff:ff) return ;; esac
      echo mac-address ;;
    uuid)
      [ "$v" = 00000000-0000-0000-0000-000000000000 ] && return
      echo uuid ;;
    path) echo personal-path ;;
    email)
      lower=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
      case $lower in
        noreply@anthropic.com | git@github.com | *@users.noreply.github.com) return ;;
        *@example.com | *@example.org | *@example.net | *.example.com | *.example.org | *.example.net) return ;;
        *.example | *.test | *.invalid | *.localhost) return ;;
      esac
      echo e-mail ;;
    word) echo personal-word ;;
  esac
}

mask() {
  if [ "$show" -eq 1 ]; then printf '%s' "$1"; else printf '%s…(%d)' "${1:0:2}" "${#1}"; fi
}

# Findings go to a file so that scans in subshells are counted too.
: > "$tmp/findings"
report() { # CLASS LOCATION LINE VALUE
  printf 'guard: %-16s %s:%s  %s\n' "$1" "$2" "$3" "$(mask "$4")" | tee -a "$tmp/findings"
}

# Reads git grep -z -n -o records "loc\0line\0match\n" from FILE.
evaluate() { # KIND FILE [LABEL]
  local kind=$1 loc lineno match path shown class re_rev='^[0-9a-f]{40}:'
  while IFS= read -r -d '' loc && IFS= read -r -d '' lineno && IFS= read -r match; do
    path=$loc shown=$loc
    if [ "$mode" = history ] && [[ $loc =~ $re_rev ]]; then
      path=${loc:41} shown="${loc:0:7}:${loc:41}"
    fi
    if [ -n "${3:-}" ]; then path=$3 shown=$3; fi
    class=$(classify "$kind" "$match")
    [ -n "$class" ] || continue
    allowed_by_list "$path" "$match" && continue
    report "$class" "$shown" "$lineno" "$match"
  done < "$2"
}

# Runs git grep with the given scope; stops on tool errors instead of
# mistaking them for a clean result.
search() { # OUTFILE PATTERN-ARGS... -- SCOPE-ARGS...
  local out=$1 rc=0
  shift
  git grep -z -n -o -I "$@" > "$out" || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "guard: git grep failed (rc $rc)" >&2
    exit 2
  fi
}

scan() { # LABEL SCOPE-ARGS...   (LABEL empty: use real paths)
  local label=$1 name n=0
  shift
  for name in "${pat_names[@]}"; do
    n=$((n + 1))
    search "$tmp/hits.$n" -P -e "$(pattern_for "$name")" "$@"
    evaluate "$name" "$tmp/hits.$n" "$label"
  done
  if [ -n "$words_args" ]; then
    n=$((n + 1))
    search "$tmp/hits.$n" -i -F -f "$tmp/words" "$@"
    evaluate word "$tmp/hits.$n" "$label"
  fi
}

# --- private word list -------------------------------------------------------
words_args=""
if [ -f "$words_file" ]; then
  grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$words_file" | sed 's/[[:space:]]*$//' > "$tmp/words" || true
  [ -s "$tmp/words" ] && words_args=yes
fi
[ -n "$words_args" ] || echo "guard: note: no private word list ($words_file); only generic patterns are checked" >&2

# noreply_out - drop identities "Name <N+login@users.noreply.github.com>"
noreply_out() { grep -vE '^[^<>]* <[0-9]+\+[A-Za-z0-9-]+@users\.noreply\.github\.com>$' || true; }

# --- text files are scanned from a scratch directory -------------------------
scan_text() { # LABEL FILE
  local dir
  dir=$(mktemp -d "$tmp/text.XXXXXX")
  cp "$2" "$dir/content"
  (cd "$dir" && scan "$1" --no-index -- content)
}

cd "$root"
case $mode in
  staged) scan "" --cached ;;
  tree) scan "" --untracked ;;
  history)
    revs=$(git rev-list --all)
    if [ -n "$revs" ]; then
      # shellcheck disable=SC2086  # one argument per revision
      scan "" $revs
      git log --all --format='%H%n%B' > "$tmp/messages"
      scan_text commit-message "$tmp/messages"
      # Authors and committers become public with each commit. A GitHub
      # noreply address is the identity of the account that publishes, so
      # public anyway: exempt. Any other name or address is checked.
      git log --all --format='%an <%ae>%n%cn <%ce>' | sort -u | noreply_out > "$tmp/authors"
      scan_text author "$tmp/authors"
    fi
    git for-each-ref --format='%(refname)' > "$tmp/refs"
    scan_text ref-name "$tmp/refs"
    # annotated tags: their tagger and message are published too
    git for-each-ref refs/tags --format='%(refname)%0a%(contents)' > "$tmp/tags"
    scan_text tag "$tmp/tags"
    git for-each-ref refs/tags --format='%(taggername) %(taggeremail)' | grep -v '^ $' | sort -u | noreply_out > "$tmp/taggers" || true
    scan_text tagger "$tmp/taggers"
    ;;
  text)
    for f in "${texts[@]}"; do
      [ -r "$f" ] || { echo "guard: cannot read $f" >&2; exit 2; }
      scan_text "$(basename "$f")" "$f"
    done
    ;;
esac

count=$(grep -c . "$tmp/findings" || true)
if [ "$count" -gt 0 ]; then
  echo "guard: $count finding(s) in --$mode. Remove them, or add a reviewed exception to tools/guard-allow.txt." >&2
  [ "$show" -eq 1 ] || echo "guard: run with --show to see the values." >&2
  exit 1
fi
echo "guard: clean (--$mode)"
