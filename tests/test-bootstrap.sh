. "$(dirname "$0")/lib.sh"; mktask
ok "pre-commit is executable" test -x "$ROOT/hooks/pre-commit"
ok "pre-push is executable" test -x "$ROOT/hooks/pre-push"
fails 1 "no hook blocks every push" grep -qi 'never be pushed' "$ROOT/hooks/pre-push"
printf 'AcmeCorp\n' > "$COORD_DATA/sensitive-terms.txt"
G() { git -C "$FIX" -c user.name=tester -c user.email=tester@example.invalid "$@"; }
G init -q; printf '.private/\n' > "$FIX/.gitignore"; G add -A; G commit -qm "baseline"
Z=0000000000000000000000000000000000000000
push() { (cd "$FIX" && printf '%s\n' "$1" | "$ROOT/hooks/pre-push" origin https://example.invalid/x.git); }
ok "pre-commit passes a clean tree" "$ROOT/hooks/pre-commit"
ok "pre-push lets a clean new branch through" push "refs/heads/main $(G rev-parse HEAD) refs/heads/main $Z"
echo "AcmeCorp notes" > "$FIX/n.md"
ok "pre-commit ignores what is not staged" "$ROOT/hooks/pre-commit"
G add n.md
fails 1 "pre-commit refuses a private term" "$ROOT/hooks/pre-commit"
G add -A; G commit -qm "notes"; bad=$(G rev-parse HEAD)
fails 1 "pre-push refuses an outgoing commit with a private term" push "refs/heads/main $bad refs/heads/main $Z"
G rm -q n.md; G commit -qm "drop notes"
fails 1 "a term removed later still blocks the push" push "refs/heads/main $(G rev-parse HEAD) refs/heads/main $Z"
ok "only commits the remote lacks are checked" push "refs/heads/main $(G rev-parse HEAD) refs/heads/main $bad"
ok "deleting a branch goes through" push "(delete) $Z refs/heads/old $bad"
G update-ref refs/remotes/origin/main HEAD
G tag -a t1 -m "for AcmeCorp" HEAD; G tag -a t2 -m "clean" HEAD; G tag t3 HEAD
fails 1 "pre-push refuses an annotated tag whose message has a private term" push "refs/tags/t1 $(G rev-parse t1) refs/tags/t1 $Z"
ok "pre-push lets a clean annotated tag through" push "refs/tags/t2 $(G rev-parse t2) refs/tags/t2 $Z"
ok "pre-push lets a lightweight tag through" push "refs/tags/t3 $(G rev-parse t3) refs/tags/t3 $Z"
eq "CLAUDE.md imports AGENTS.md" "@AGENTS.md" "$(cat "$ROOT/CLAUDE.md")"
COORD_NOW=2026-11-10T14:03:00-03:00; export COORD_NOW
eq "now honors override" "2026-11-10T14:03:00-03:00" "$(. "$ROOT/scripts/lib.sh"; now)"
ok "README explains setup" grep -qF "scripts/setup.sh" "$ROOT/README.md"
ok "README says the private folder is lost on a wipe" grep -q 'Everything under `.private/` is lost' "$ROOT/README.md"
ok "README covers running without T3 Code" grep -qF "runtimes/terminal.md" "$ROOT/README.md"
ok "LICENSE is MIT" grep -q '^MIT License$' "$ROOT/LICENSE"
ok "LICENSE holder is neutral" grep -q 'Copyright (c) 2026 the coordinator authors' "$ROOT/LICENSE"
CI=$ROOT/.github/workflows/test.yml
ok "CI runs the tests" grep -qF "bash tests/run.sh" "$CI"
ok "CI runs the generic check" grep -qF "public-check.sh --generic" "$CI"
ok "CI runs on Linux and macOS" grep -qF "[ubuntu-latest, macos-latest]" "$CI"
ok "setup playbook" test -s "$ROOT/playbooks/setup.md"
A=$ROOT/.agents/skills/coordinator-setup/SKILL.md; C=$ROOT/.claude/skills/coordinator-setup/SKILL.md
ok "both setup skills carry the same text" cmp "$A" "$C"
eq "skill name is its folder" "name: coordinator-setup" "$(sed -n 2p "$A")"
eq "skill description is a block scalar" "description: >-" "$(sed -n 3p "$A")"
ok "skill points at the script and the playbook" sh -c "grep -qF scripts/setup.sh '$A' && grep -qF playbooks/setup.md '$A'"
