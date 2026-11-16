. "$(dirname "$0")/lib.sh"; mktask; P="$ROOT/scripts/providers.sh"
H=$(dirname "$FIX")/home; B=$H/bin; A=$(dirname "$FIX")/apps; mkdir -p "$B" "$A"
SYS=/usr/bin:/bin:/usr/sbin:/sbin
run() { HOME=$H PATH=$B:$SYS COORD_APPS_DIR=$A COORD_NO_NET_PROBE=1 "$P" "$@"; }
eq "account of a listed provider" company "$($P account claude)"
eq "account of a missing provider" unknown "$($P account nobody)"
ok "list prints the table" sh -c "'$P' list | grep -q '^codex	personal'"
fails 2 "usage" $P launch

eq "nothing installed: no rows" "" "$(run detect 2>/dev/null)"
ok "nothing installed: exit 0" run detect

# A fake agent on PATH that prints an address when asked for its sign-in status.
fake() { printf '#!/bin/sh\ncase "$*" in\n  --version) echo "%s 1.0" ;;\n  *--help*) echo "%s" ;;\n  "auth status") echo '"'"'{"loggedIn": true, "authMethod": "claude.ai", "email": "dev@example.invalid"}'"'"' ;;\n  "login status") echo "Logged in using ChatGPT" ;;\nesac\n' "$2" "$3" > "$1"; chmod +x "$1"; }
fake "$B/claude" claude "-p, --print  --model <m>  --effort <e>"
O=$(dirname "$FIX")/out; run detect > "$O" 2>&1
ok "claude found on PATH" grep -qxF "claude	unknown	-	-	$B/claude	cd {dir} && '$B/claude' -p --model {model} --effort {effort} < {brief}" "$O"
fails 1 "no address printed" grep -q '@' "$O"
ok "sign-in reported without the address" grep -q 'loggedIn=true authMethod=claude.ai' "$O"

# Codex installed only where another app keeps it, never on PATH.
mkdir -p "$H/.t3/tools/codex/0.1.0/bin"; fake "$H/.t3/tools/codex/0.1.0/bin/codex" codex "-C, --cd  -m, --model  -c, --config"
row=$(run detect 2>/dev/null | grep '^codex')
eq "codex found off PATH" "codex	unknown	codex	reasoningEffort	$H/.t3/tools/codex/0.1.0/bin/codex" "$(printf '%s' "$row" | cut -f1-5)"
rm -r "$H/.t3"
# An agent in a known install place that is not on PATH: found, with the line that puts it there.
mkdir -p "$H/.local/bin"; fake "$H/.local/bin/qwen" qwen "--model --reasoning-effort"
O2=$(run detect 2>&1)
ok "found in a known place off PATH" grep -q "^qwen	unknown	-	-	$H/.local/bin/qwen	" <<< "$O2"
ok "says it is not on PATH, with the profile line" grep -qF "note: qwen: found at $H/.local/bin/qwen, not on PATH; add to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\"" <<< "$O2"
rm -r "$H/.local"
mkdir -p "$A/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS"
fake "$A/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" codex "--cd --model --config"
ok "codex found inside the desktop app" sh -c "HOME='$H' PATH='$B:$SYS' COORD_APPS_DIR='$A' COORD_NO_NET_PROBE=1 '$P' detect 2>/dev/null | grep -q '^codex	unknown	-	-	$A/'"

# A launch flag the installed version does not show is never guessed.
fake "$B/gemini" gemini "-m, --model"
eq "missing flag leaves launch empty" "-" "$(run detect 2>/dev/null | awk -F'\t' '$1=="gemini" {print $6}')"
fake "$B/aider" aider "--model"
eq "agent without a known template" "-" "$(run detect 2>/dev/null | awk -F'\t' '$1=="aider" {print $6}')"

# --write merges: new rows are unknown, an existing account never changes, set columns stay.
printf 'claude\tcompany\t-\t-\t/opt/claude\t-\ncodex\tpersonal\tx\ty\t-\tmine\n' > "$COORD_DATA/config/providers.tsv"
run detect --write >/dev/null 2>&1
T=$COORD_DATA/config/providers.tsv
eq "existing account kept" "company" "$(awk -F'\t' '$1=="claude" {print $2}' "$T")"
eq "set column kept" "/opt/claude" "$(awk -F'\t' '$1=="claude" {print $5}' "$T")"
ok "empty column filled" sh -c "awk -F'\t' '\$1==\"claude\" {print \$6}' '$T' | grep -q '^cd {dir}'"
eq "other existing row untouched" "codex	personal	x	y	$A/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex	mine" "$(grep '^codex' "$T")"
eq "new provider added as unknown" "unknown" "$(awk -F'\t' '$1=="gemini" {print $2}' "$T")"
eq "one row per provider" 4 "$(wc -l < "$T" | tr -d ' ')"
run detect --write >/dev/null 2>&1
eq "a second write adds nothing" 4 "$(wc -l < "$T" | tr -d ' ')"
rm "$T"; run detect --write >/dev/null 2>&1
eq "write creates the table" "unknown" "$(awk -F'\t' '$1=="claude" {print $2}' "$T")"
rm "$T"
fails 2 "list without a table" $P list
eq "unknown account without a table" unknown "$($P account claude)"
