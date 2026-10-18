#!/bin/bash
# mutation-check.sh — prove the suite still catches bugs it was written for.
#
# The mutations are real: each one is a past fix commit that shipped with a
# test, reverted on top of HEAD (code hunks only — Sources/ and
# Runtime/src/; today's tests stay). ./tests.sh must go red for every one.
# A green run means the guarding test no longer guards: it was weakened,
# deleted, or the code moved out from under it.
#
#   scripts/mutation-check.sh --list            # candidates, no builds
#   scripts/mutation-check.sh                   # every candidate (~80 s each)
#   scripts/mutation-check.sh cd09c89 f4fdf49   # just these
#   scripts/mutation-check.sh --commits 400     # look further back
#
# Candidates: fix commits in the last N (default 200) that touched a
# Tests/*Tests.swift file and whose code hunks still reverse-apply cleanly.
# Headless: builds and runs .build/stackd-tests only. Needs a clean
# Sources/ and Runtime/src/ (it resets them after every mutation); results
# and logs land in .build/mutation/.
set -uo pipefail
cd "$(dirname "$0")/.."

N=200
LIST=0
SHAS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --commits) N="$2"; shift 2 ;;
    --list) LIST=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) SHAS+=("$1"); shift ;;
  esac
done

PATHS=(Sources Runtime/src)

candidates() {
  git log "-$N" --no-merges --format='%h %s' | while read -r sha subject; do
    [[ "$subject" =~ ^(fix[\(:!]|revert[\(:]) ]] || continue
    git show --name-only --format= "$sha" | grep -qE '^Tests/.*Tests\.swift$' || continue
    git show "$sha" -- "${PATHS[@]}" | git apply -R --check >/dev/null 2>&1 || continue
    echo "$sha $subject"
  done
}

if [[ $LIST == 1 ]]; then
  candidates
  exit 0
fi

if ! git diff --quiet -- "${PATHS[@]}" || ! git diff --cached --quiet -- "${PATHS[@]}"; then
  echo "mutation-check: Sources/ or Runtime/src/ has uncommitted changes; commit or stash them first" >&2
  exit 2
fi

restore() { git checkout -q -- "${PATHS[@]}"; }
trap restore EXIT INT TERM

if [[ ${#SHAS[@]} -eq 0 ]]; then
  while read -r sha _; do SHAS+=("$sha"); done < <(candidates)
fi

mkdir -p .build/mutation
SUMMARY=.build/mutation/summary.txt
: > "$SUMMARY"
missed=0
for sha in "${SHAS[@]}"; do
  subject=$(git log -1 --format=%s "$sha")
  log=".build/mutation/$sha.log"
  if ! git show "$sha" -- "${PATHS[@]}" | git apply -R >/dev/null 2>&1; then
    verdict="SKIP     (no longer reverse-applies)"
  else
    ./tests.sh >"$log" 2>&1
    status=$?
    if ! grep -qE '^[0-9]+ passed|^[0-9]+/[0-9]+ failed' "$log"; then
      verdict="NOBUILD  (the revert doesn't compile against HEAD; inconclusive)"
    elif [[ $status -ne 0 ]]; then
      verdict="CAUGHT   $(grep -c '^✗' "$log") failing: $(grep '^✗' "$log" | head -2 | sed 's/^✗ //' | paste -sd ';' -)"
    else
      verdict="MISSED   suite stayed green"
      missed=$((missed + 1))
    fi
  fi
  restore
  line="$sha $verdict  — $subject"
  echo "$line" | tee -a "$SUMMARY"
done
echo "———"
echo "$missed missed of ${#SHAS[@]} (logs: .build/mutation/)"
echo "note: .build/stackd-tests is the last mutation's build; ./tests.sh rebuilds it"
exit $((missed > 0 ? 1 : 0))
