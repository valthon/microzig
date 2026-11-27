#!/usr/bin/env bash
# Scenario test for touched_docs.py in a throwaway repository. Each case builds the merge commit
# CI would check out (the PR branch merged into main) and lists docs for main..merge.
set -euo pipefail
# Inside a git hook GIT_DIR points at the caller's repository; never write there.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
SCRIPT="$(cd "$(dirname "$0")" && pwd)/touched_docs.py"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T"
g() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
g init -q -b main
mkdir -p docs/design core/src port/x
printf '# IRQ\n\nCovers: core/src/interrupt.zig, port/x/\n\n## Evidence\n' > docs/design/irq.md
printf 'Covers: other.zig\n' > docs/design/TEMPLATE.md
echo a > core/src/interrupt.zig; echo a > port/x/a.zig; echo a > other.zig; echo a > code.zig
g add -A; g commit -qm base

fail=0
# pr NAME: start a PR branch NAME from main.
pr() { g checkout -q main; g checkout -qb "$1"; }
# expect NAME EXPECTED: merge the current branch into main as CI would, compare the whole output.
expect() {
  local branch; branch=$(git rev-parse --abbrev-ref HEAD)
  g checkout -q --detach main
  g merge -q --no-ff --no-edit "$branch" >/dev/null
  out=$(python3 "$SCRIPT" "$(git rev-parse HEAD^1)" "$(git rev-parse HEAD)")
  g checkout -q "$branch"
  if [[ "$out" != "$2" ]]; then
    echo "FAIL $1"; echo "  got:  $out"; echo "  want: $2"; fail=1
  else
    echo "ok $1"
  fi
}
IRQ='This PR touches code described by `docs/design/irq.md`.'

pr p1; echo b > other.zig; g commit -qam c
expect "uncovered change lists nothing; TEMPLATE.md is skipped" ""
pr p2; echo b > port/x/a.zig; echo b > core/src/interrupt.zig; g commit -qam c
expect "covered changes, one line per doc" "$IRQ"
pr p3; echo b > port/x/a.zig; echo x >> docs/design/irq.md; g commit -qam c
expect "listed even when the PR edits the doc" "$IRQ"
pr p4; g mv port/x/a.zig moved.zig; g commit -qm c
expect "rename out of a covered directory" "$IRQ"

# Changes on main after the PR branched are not the PR's, but main's docs apply.
pr p5; echo c > code.zig; g commit -qam c
g checkout -q main; echo c > port/x/a.zig; g commit -qam main-change
g checkout -q p5
expect "main's own change to covered code is not listed" ""
g checkout -q main
printf 'Covers: code.zig\n' > docs/design/code.md; g add -A; g commit -qm main-adds-doc
g checkout -q p5
expect "doc added on main after branching" 'This PR touches code described by `docs/design/code.md`.'

# main broadens Covers: while the PR edits another part of the same doc: the merged copy counts.
pr p6
g checkout -q main
printf '# IRQ\n\nCovers: core/src/interrupt.zig, port/x/, other.zig\n\n## Evidence\n' > docs/design/irq.md
g commit -qam main-broadens
g checkout -q p6
printf '# IRQ\n\nCovers: core/src/interrupt.zig, port/x/\n\n## Evidence\n\n- a test\n' > docs/design/irq.md
echo d > other.zig; g commit -qam pr-edits-evidence
expect "coverage broadened on main, doc edited by the PR" "$IRQ"

# A doc main deleted no longer applies.
pr p7; echo e > code.zig; g commit -qam c
g checkout -q main; g rm -q docs/design/code.md; g commit -qm main-deletes-doc
g checkout -q p7
expect "doc deleted on main" ""

# Only the doc's head is metadata, and paths git would quote still match.
g checkout -q main
printf '# Doc\n\n## Example\n\n```\nCovers: fenced.zig\n```\n' > docs/design/fenced.md
echo a > fenced.zig
echo a > café.zig; printf 'Covers: café.zig\n' > docs/design/uni.md
g add -A; g commit -qm docs
pr p8; echo f > fenced.zig; echo f > café.zig; g commit -qam c
expect "fenced example ignored; non-ASCII path matches" 'This PR touches code described by `docs/design/uni.md`.'

# Odd names neither crash the listing nor forge a line.
pr p9
echo a > "$(printf 'bad\377.bin')"
printf 'Covers: core/src/\n' > "$(printf 'docs/design/x\nforged.md')"
echo g > core/src/interrupt.zig
g add -A; g commit -qm c
expect "non-UTF-8 and newline names" "$IRQ"$'\n''This PR touches code described by `docs/design/x\nforged.md`.'

# Missing arguments are a note, never a failure.
out=$(python3 "$SCRIPT" "" HEAD) && grep -q "needs BASE and MERGED" <<<"$out" && echo "ok empty base" \
  || { echo "FAIL empty base"; fail=1; }

exit $fail
