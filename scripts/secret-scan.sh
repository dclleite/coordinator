#!/bin/bash
# secret-scan.sh <file>  ->  exit 1 and "line <n>: <kind>" per hit; never prints the matched text
set -u
. "$(dirname "$0")/lib.sh"
[ $# -eq 1 ] && [ -f "$1" ] || die 2 "usage: secret-scan.sh <file>"
file=$1
export LC_ALL=C
hits=$(
  # scan <pattern> <kind> [second pattern the same line must also match]
  scan() { grep -nE -e "$1" "$file" | { if [ -n "${3:-}" ]; then grep -E -e "$3"; else cat; fi; } | cut -d: -f1 | sed "s/.*/line &: $2/"; }
  scan '-----BEGIN [A-Z ]*PRIVATE KEY-----' "private key"
  scan 'glpat-[A-Za-z0-9_-]{20,}' "gitlab token"
  scan '(ghp_|github_pat_)[A-Za-z0-9_]{20,}' "github token"
  scan 'xox[bpa]-[A-Za-z0-9-]{20,}|xapp-[A-Za-z0-9-]{20,}' "slack token"
  # A digit is required so that dashed prose and branch names are not taken for keys.
  scan '(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}' "api key" 'sk-[A-Za-z_-]*[0-9]'
  scan 'AKIA[A-Z0-9]{16}' "aws key"
  scan 'hooks\.slack\.com/services/[A-Za-z0-9/]{20,}' "chat webhook"
  scan 'Bearer [A-Za-z0-9._-]{20,}' "bearer token" 'Bearer [A-Za-z._-]*[0-9]'
  scan 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}' "jwt"
  scan '://[^/[:space:]:@]+:[^/[:space:]@]+@' "credentials in a url"
  scan '[A-Z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|ACCESS_KEY)[A-Z0-9_]*=[^[:space:]"'"'"']{8,}' "credential assignment"
  scan '([Pp]assword|[Ss]ecret|[Tt]oken|[Aa]pi_?[Kk]ey)["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"'][^"'"'"'[:space:]]{8,}["'"'"']' "credential assignment"
)
[ -z "$hits" ] && exit 0
hits=$(printf '%s\n' "$hits" | sort -t' ' -k2,2n -u)
printf '%s\n' "$hits"
echo "secret scan: $(printf '%s\n' "$hits" | grep -c .) hit(s) in $file" >&2
exit 1
