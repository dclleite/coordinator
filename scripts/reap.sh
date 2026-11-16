#!/bin/bash
# reap.sh [--dry-run]  ->  stops what no open task owns when over its limit (browsers also when too old)
#                          and a panel left idle past twice its idle time,
#                          deletes old browser temporary files; never touches a confirm-class row
# reap.sh install | uninstall  ->  adds or removes the scheduler entry (launchd; on Linux prints the cron line)
set -u
. "$(dirname "$0")/lib.sh"
. "$ROOT/config/health.conf"
export BROWSER_HOME
LABEL=${REAP_LABEL:-local.coordinator.reap}
OS=${REAP_OS:-$(uname -s)}
whole() { case "$2" in ''|*[!0-9]*) die 2 "config/health.conf: $1 must be a whole number" ;; esac; }
whole REAP_BROWSER_MAX_HOURS "${REAP_BROWSER_MAX_HOURS:-}"; whole REAP_TMP_MAX_DAYS "${REAP_TMP_MAX_DAYS:-}"
whole REAP_INTERVAL_MIN "${REAP_INTERVAL_MIN:-}"

plist() { echo "${REAP_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}/$LABEL.plist"; }
cron_line() { echo "*/$REAP_INTERVAL_MIN * * * * /bin/bash $SCRIPTS/reap.sh >/dev/null 2>&1"; }
xml() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

case "${1:-}" in
install)
  if [ "$OS" != Darwin ]; then echo "add this line with crontab -e:"; cron_line; exit 0; fi
  p=$(plist); mkdir -p "$(dirname "$p")"
  # launchd starts jobs with a bare PATH; keep the current one so the browser tool and node are found.
  cat > "$p" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$(xml "$LABEL")</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$(xml "$SCRIPTS/reap.sh")</string></array>
<key>StartInterval</key><integer>$((REAP_INTERVAL_MIN * 60))</integer>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>$(xml "$PATH")</string></dict>
<key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>/dev/null</string>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  launchctl bootstrap "gui/$(id -u)" "$p" || die 1 "launchctl refused $p"
  echo "installed: $LABEL every $REAP_INTERVAL_MIN min"; exit 0 ;;
uninstall)
  if [ "$OS" != Darwin ]; then echo "remove this line with crontab -e:"; cron_line; exit 0; fi
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  rm -f "$(plist)"; echo "uninstalled: $LABEL"; exit 0 ;;
--dry-run|'') ;;
*) die 2 "usage: reap.sh [--dry-run] | install | uninstall" ;;
esac
dry=0; [ "${1:-}" = --dry-run ] && dry=1
S=$SCRIPTS/sweep.sh
orphans=$("$S" --orphans 2>/dev/null) || die 1 "could not list orphans"
max_age=$((REAP_BROWSER_MAX_HOURS * 3600)); stopped=0; failed=0

act() { # <kind> <id> <why>
  if [ $dry -eq 1 ]; then echo "would stop $1 $2: $3"; return 0; fi
  if "$S" --run "$1" stop "$2" >/dev/null 2>&1; then echo "stopped $1 $2: $3"; stopped=$((stopped+1))
  else echo "stop failed $1 $2"; failed=$((failed+1)); return 1; fi
}

while IFS= read -r r; do
  [ -n "$r" ] || continue
  split_row "$r"; kind=$F1 count=$F2 limit=$F3
  [ "$("$S" --run "$kind" class)" = auto ] || continue
  [ "$count" != unknown ] || continue
  ids=$(awk -F'\t' -v k="$kind" '$1==k {print $2}' <<< "$orphans")
  [ -n "$ids" ] || continue
  if [ "$kind" = browsers ]; then # oldest first, so the over-limit cut keeps the newest
    ids=$(while IFS= read -r id; do printf '%s\t%s\n' "$("$SCRIPTS/browser.sh" age "$id")" "$id"; done <<< "$ids" \
      | sort -rn | cut -f2-)
  fi
  while IFS= read -r id; do
    if [ "$limit" != "-" ] && [ "$count" -gt "$limit" ]; then
      act "$kind" "$id" "no open task owns it and $count are running (limit $limit)" && count=$((count-1))
    elif [ "$kind" = browsers ] && [ "$("$SCRIPTS/browser.sh" age "$id")" -gt "$max_age" ]; then
      act "$kind" "$id" "no open task owns it and it is older than $REAP_BROWSER_MAX_HOURS h" && count=$((count-1))
    fi
  done <<< "$ids"
done <<< "$("$S" --readings)"

# A panel nobody stopped and whose idle exit never came.
if [ -x "$SCRIPTS/panel.sh" ]; then
  if [ $dry -eq 1 ]; then "$SCRIPTS/panel.sh" reap --dry-run
  else out=$("$SCRIPTS/panel.sh" reap); [ -z "$out" ] || { echo "$out"; stopped=$((stopped+1)); }; fi
fi
if [ $dry -eq 1 ]; then tmp=$("$SCRIPTS/browser.sh" tmp-clean "$REAP_TMP_MAX_DAYS" --dry-run)
else tmp=$("$SCRIPTS/browser.sh" tmp-clean "$REAP_TMP_MAX_DAYS"); fi
case "$tmp" in tmp_old=0|tmp_old=0\ *) ;; *) echo "$tmp" ;; esac
summary="stopped=$stopped failed=$failed ${tmp%% *}"
echo "$summary"
[ $dry -eq 1 ] || { mkdir -p "$DATA"; printf '%s\t%s\n' "$(now)" "$summary" >> "$DATA/reap.log"; }
[ $failed -eq 0 ]
