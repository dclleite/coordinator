. "$(dirname "$0")/lib.sh"; mktask; M="$ROOT/scripts/model.sh"
eq "claude default" "claude-opus-5-5	medium" "$($M claude default)"
eq "codex planning" "gpt-6-astra	low" "$($M codex planning 2>/dev/null)"
# The developer's tier still answers, with one warning on stderr; the agent's own tiers warn nothing.
eq "planning warns that it needs the developer's word" "warning: tier planning needs the developer's explicit word for this launch, in this conversation" "$($M claude planning 2>&1 >/dev/null)"
eq "default warns nothing" "" "$($M claude default 2>&1 >/dev/null)"
eq "escalated warns nothing" "" "$($M codex escalated 2>&1 >/dev/null)"
fails 2 "unknown tier" $M claude huge
fails 2 "unknown provider" $M nobody default
fails 2 "usage" $M claude
printf 'claude\tdefault\tlocal-pick\thigh\n' > "$COORD_DATA/config/models.tsv"
eq "local override wins" "local-pick	high" "$($M claude default)"
eq "tracked table for the rest" "claude-opus-5-5	high" "$($M claude escalated)"
# A provider nobody tuned: escalated one step up from default, planning falls back to escalated.
printf 'fresh\tdefault\tfresh-1\tmedium\tuntuned\n' >> "$COORD_DATA/config/models.tsv"
eq "untuned default" "fresh-1	medium" "$($M fresh default 2>/dev/null)"
ok "untuned row warns" sh -c "'$M' fresh default 2>&1 >/dev/null | grep -q untuned"
eq "escalated derived" "fresh-1	high" "$($M fresh escalated 2>/dev/null)"
eq "planning derived" "fresh-1	high" "$($M fresh planning 2>/dev/null)"
eq "derived planning: untuned and developer's-word warnings" 2 "$($M fresh planning 2>&1 >/dev/null | grep -c warning)"
printf 'fresh2\tdefault\tf2\t-\nfresh2\tescalated\tf2-big\tmax\n' >> "$COORD_DATA/config/models.tsv"
eq "planning falls back to escalated" "f2-big	max" "$($M fresh2 planning 2>/dev/null)"
eq "no warning for a tuned row" "" "$($M claude escalated 2>&1 >/dev/null)"
fails 2 "untuned provider, unknown tier" $M fresh huge
