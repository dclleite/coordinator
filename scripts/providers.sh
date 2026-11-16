#!/bin/bash
# providers.sh list | account <provider> | detect [--write]
# detect is read-only: it runs --version, --help and sign-in status commands, and asks local model
# servers that already listen. It never starts a server, never loads a model, never prints an email.
set -u
. "$(dirname "$0")/lib.sh"
TABLE=$DATA/config/providers.tsv
APPS=${COORD_APPS_DIR:-/Applications}

# name<TAB>binary names, for every agent program the probe knows.
AGENTS='claude	claude
codex	codex
gemini	gemini
opencode	opencode
cursor	agent cursor-agent
aider	aider
goose	goose
amp	amp
qwen	qwen
pi	pi
kiro	kiro-cli
copilot	copilot
droid	droid
grok	grok
crush	crush
cline	cline
auggie	auggie'

# Headless launch template and the flags its --help must show; agents not listed stay "-".
template() { # <name> <quoted bin>
  case "$1" in
    claude) echo "cd {dir} && $2 -p --model {model} --effort {effort} < {brief}|--print --model --effort|" ;;
    codex) echo "$2 exec -C {dir} -m {model} -c model_reasoning_effort={effort} - < {brief}|--cd --model --config|exec" ;;
    gemini) echo "cd {dir} && $2 -m {model} -p '' < {brief}|--model --prompt|" ;;
    qwen) echo "cd {dir} && $2 -m {model} --reasoning-effort {effort} < {brief}|--model --reasoning-effort|" ;;
    copilot) echo "cd {dir} && $2 -p \"\$(cat {brief})\" --model {model} --reasoning-effort {effort} --allow-all-tools -s|--prompt --model --reasoning-effort --allow-all-tools|" ;;
    amp) echo "cd {dir} && $2 -x --model {model} --effort {effort} < {brief}|--execute --model --effort|" ;;
    grok) echo "cd {dir} && $2 -p \"\$(cat {brief})\" -m {model} --effort {effort}|--prompt --model --effort|" ;;
    *) echo "-||" ;;
  esac
}

# The id and effort option name T3 Code uses, when T3 Code is installed.
t3_names() {
  [ -d "$HOME/.t3" ] || { printf -- '-\t-'; return; }
  case "$1" in claude) printf 'claudeAgent\teffort' ;; codex) printf 'codex\treasoningEffort' ;; *) printf -- '-\t-' ;; esac
}

# run_capped <seconds> <cmd...>: output of a command that gets no stdin and is killed past the limit.
run_capped() {
  local secs=$1 out pid i=0; shift
  out=$(mktemp "${TMPDIR:-/tmp}/providers.XXXXXX") || return 1
  "$@" < /dev/null > "$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    [ $i -ge $((secs * 10)) ] && { kill "$pid" 2>/dev/null; break; }
    sleep 0.1; i=$((i + 1))
  done
  wait "$pid" 2>/dev/null
  cat "$out"; rm -f "$out"
}

# Notes go to stderr; anything that could carry an address is dropped.
note() { printf '%s\n' "$*" | LC_ALL=C tr -cd '[:print:]\n' | grep -v '@' | sed 's/^/note: /' >&2; }

find_bin() { # <name> <binary names...>
  local name=$1 b c; shift
  for b in "$@"; do
    c=$(command -v "$b" 2>/dev/null) && [ -x "$c" ] && { echo "$c"; return; }
  done
  for b in "$@"; do
    for c in "$HOME/.local/bin/$b" "$HOME/.npm-global/bin/$b" "$HOME"/.nvm/versions/node/*/bin/"$b"; do
      [ -f "$c" ] && [ -x "$c" ] && { echo "$c"; return; }
    done
  done
  [ "$name" = codex ] || return 1
  # Codex ships inside other apps and is often on no PATH at all.
  local last=""
  for c in "$HOME"/.t3/tools/codex/*/bin/codex; do [ -f "$c" ] && [ -x "$c" ] && last=$c; done
  [ -n "$last" ] && { echo "$last"; return; }
  for c in "$APPS/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" \
           "$HOME"/.vscode/extensions/openai.chatgpt-*/bin/*/codex; do
    [ -f "$c" ] && [ -x "$c" ] && { echo "$c"; return; }
  done
  return 1
}

sign_in() { # <name> <bin>
  local out
  case "$1" in
    claude)
      out=$(run_capped 5 "$2" auth status)
      note "$1: loggedIn=$(printf '%s' "$out" | sed -n 's/.*"loggedIn": *\([a-z]*\).*/\1/p' | head -1)" \
        "authMethod=$(printf '%s' "$out" | sed -n 's/.*"authMethod": *"\([A-Za-z0-9_.-]*\)".*/\1/p' | head -1)" ;;
    codex)
      out=$(run_capped 5 "$2" login status | grep -E '^Logged in using [A-Za-z ]+$' | head -1)
      note "$1: ${out:-sign-in unknown}" ;;
  esac
}

detect() {
  local name bins bin q t launch flags sub help f v
  while IFS='	' read -r name bins; do
    # shellcheck disable=SC2086
    bin=$(find_bin "$name" $bins) || continue
    case "$bin" in *"'"*|*'	'*) note "$name: skipped, its path has a quote or a tab"; continue ;; esac
    v=$(run_capped 5 "$bin" --version | head -1 | cut -c1-80)
    note "$name: $bin ${v:-version unknown}"
    q="'$bin'"
    t=$(template "$name" "$q")
    launch=${t%%|*}; t=${t#*|}; flags=${t%%|*}; sub=${t#*|}
    if [ "$launch" != - ]; then
      if [ -n "$sub" ]; then help=$(run_capped 5 "$bin" "$sub" --help); else help=$(run_capped 5 "$bin" --help); fi
      for f in $flags; do
        printf '%s' "$help" | grep -qF -e "$f" || { note "$name: --help shows no $f, launch left empty"; launch=-; break; }
      done
    fi
    sign_in "$name" "$bin"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" unknown "$(t3_names "$name")" "$bin" "$launch"
  done <<< "$AGENTS"
  probe_local
  local mem
  mem=$(sysctl -n hw.memsize 2>/dev/null || awk '/^MemTotal:/ { print $2 * 1024 }' /proc/meminfo 2>/dev/null)
  [ -z "$mem" ] || note "memory: $((mem / 1073741824)) GB (a local model for agent work needs 14 GB or more)"
}

# A local server is not a provider: an agent pointed at it is one of kind local.
probe_local() {
  local b spec
  for b in ollama lms llama-server; do
    command -v "$b" >/dev/null 2>&1 && note "local runtime installed: $b"
  done
  [ -z "${COORD_NO_NET_PROBE:-}" ] && command -v curl >/dev/null 2>&1 || return 0
  for spec in 'ollama 11434 /api/version' 'lm-studio 1234 /v1/models' 'llama.cpp 9931 /v1/models' 'llama.cpp 8080 /v1/models'; do
    set -- $spec
    curl -s -o /dev/null -m 1 "http://127.0.0.1:$2$3" && note "local server answers: $1 on port $2"
  done
  return 0
}

merge() { # <detected rows file>
  mkdir -p "$(dirname "$TABLE")" || die 1 "cannot create $(dirname "$TABLE")"
  [ -f "$TABLE" ] || : > "$TABLE"
  local tmp; tmp=$(mktemp "$TABLE.XXXXXX") || die 1 "cannot write next to $TABLE"
  # An existing row keeps its account and every column already set; detect only fills the "-" ones.
  awk -F'\t' -v OFS='\t' 'NR==FNR { new[$1]=$0; order[++n]=$1; next }
    $1 in new { split(new[$1], d, "\t"); for (i=3; i<=6; i++) if ($i=="" || $i=="-") $i=d[i]
                seen[$1]=1; print "kept " $1 > "/dev/stderr" }
    { print }
    END { for (i=1; i<=n; i++) if (!(order[i] in seen)) { print new[order[i]]; print "added " order[i] > "/dev/stderr" } }' \
    "$1" "$TABLE" > "$tmp" && mv "$tmp" "$TABLE"
}

case "${1:-}" in
  list)
    [ $# -eq 1 ] || die 2 "usage: providers.sh list"
    [ -f "$TABLE" ] || die 2 "no providers table: run providers.sh detect --write, then set each account kind in $TABLE"
    cat "$TABLE" ;;
  account)
    [ $# -eq 2 ] && [ -n "$2" ] || die 2 "usage: providers.sh account <provider>"
    k=""
    [ -f "$TABLE" ] && k=$(P=$2 awk -F'\t' '$1==ENVIRON["P"] { print $2; exit }' "$TABLE")
    echo "${k:-unknown}" ;;
  detect)
    case "${2:-}" in
      "") [ $# -eq 1 ] || die 2 "usage: providers.sh detect [--write]"; detect ;;
      --write)
        rows=$(mktemp "${TMPDIR:-/tmp}/providers.XXXXXX") || die 1 "cannot create a temporary file"
        detect > "$rows"
        merge "$rows" 2>&1 | sed 's/^/providers.tsv: /'
        rm -f "$rows" ;;
      *) die 2 "usage: providers.sh detect [--write]" ;;
    esac ;;
  *) die 2 "usage: providers.sh list | account <provider> | detect [--write]" ;;
esac
