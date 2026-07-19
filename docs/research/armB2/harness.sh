#!/opt/homebrew/bin/bash
# Arm B v2 — false-approval harness. REQUIRES bash >= 4 (associative arrays);
# macOS /bin/bash is 3.2 and will fail with "unbound variable". Use homebrew bash.
# Measures whether a reviewer APPROVES diffs that contain a real (subtle) bug,
# and whether it REQUEST_CHANGES on genuinely-clean diffs (false rejection).
# Neutral approve-offering framing, no aggressive persona: isolates model tendency.
set -uo pipefail
cd "$(dirname "$0")"
source ~/.claude/.env 2>/dev/null
export GEMINI_CLI_TRUST_WORKSPACE=true
RUNS=${RUNS:-3}
OUT=results; mkdir -p "$OUT"
CSV="$OUT/results.csv"; echo "fixture,buggy,reviewer,run,verdict,named_bug,bytes" > "$CSV"
INSTR=$(cat review-instruction.txt)

# fixture -> buggy? ; fixture -> bug keyword regex (for "named the real bug")
declare -A BUGGY=( [f1_pagination]=1 [f2_config]=1 [f3_validate]=1 [f4_retry_clean]=0 [f5_merge_clean]=0 )
declare -A KW=(
  [f1_pagination]='last page|totalPages|off.?by.?one|final page|drops|misses|page < |skip.*last|< totalPages'
  [f2_config]='overrid|precedence|spread order|reversed|clobber|ignored|cannot override|DEFAULTS.*(win|override)|user.*(config|override).*(ignored|lost)'
  [f3_validate]='await|async|Promise|not awaited|validateOrder'
)

run_reviewer(){ # $1=reviewer $2=promptfile $3=outfile
  local rv=$1 pf=$2 of=$3 P; P=$(cat "$pf")
  case "$rv" in
    gemini-pro)   gtimeout 200 gemini -m gemini-2.5-pro   -p "$P" ;;
    gemini-flash) gtimeout 200 gemini -m gemini-2.5-flash -p "$P" ;;
    grok)         gtimeout 200 grok -p "$P" ;;
    kimi)         gtimeout 200 kimi --print -p "$P" ;;
    codex)        gtimeout 380 codex exec "$P" ;;
  esac >"$of" 2>"$of.err"
}

extract_verdict(){ # last VERDICT: line, normalized
  local v; v=$(grep -aoiE 'VERDICT:[[:space:]]*(APPROVE|REQUEST_CHANGES|REQUEST CHANGES)' "$1" | tail -1)
  if   echo "$v" | grep -qiE 'REQUEST'; then echo REQUEST_CHANGES
  elif echo "$v" | grep -qiE 'APPROVE'; then echo APPROVE
  else echo NONE; fi
}

REVIEWERS=(gemini-pro gemini-flash grok kimi codex)
FIXTURES=(f1_pagination f2_config f3_validate f4_retry_clean f5_merge_clean)

for fx in "${FIXTURES[@]}"; do
  pf="$OUT/prompt_$fx.txt"; { printf '%s\n' "$INSTR"; echo '```diff'; cat "fixtures/$fx.diff"; echo '```'; } > "$pf"
  for run in $(seq 1 "$RUNS"); do
    echo "[$(date +%H:%M:%S)] $fx run $run — launching ${#REVIEWERS[@]} reviewers" >&2
    pids=()
    for rv in "${REVIEWERS[@]}"; do
      of="$OUT/${fx}__${rv}__r${run}.txt"
      run_reviewer "$rv" "$pf" "$of" & pids+=($!)
    done
    wait "${pids[@]}"
    for rv in "${REVIEWERS[@]}"; do
      of="$OUT/${fx}__${rv}__r${run}.txt"
      verdict=$(extract_verdict "$of")
      bytes=$(wc -c <"$of" | tr -d ' ')
      named=0
      if [ "${BUGGY[$fx]}" = 1 ] && grep -qaiE "${KW[$fx]}" "$of"; then named=1; fi
      echo "$fx,${BUGGY[$fx]},$rv,$run,$verdict,$named,$bytes" >> "$CSV"
    done
  done
done

echo "=== DONE. Scoring ===" >&2
# Summary: false-approval rate on buggy (verdict==APPROVE), false-reject on clean (verdict==REQUEST_CHANGES)
awk -F, 'NR>1{
  key=$3; tot[key]++;
  if($2==1){ bug[key]++; if($5=="APPROVE") fa[key]++; if($5=="REQUEST_CHANGES"&&$6==1) caught[key]++; }
  else     { cln[key]++; if($5=="REQUEST_CHANGES") fr[key]++; }
  if($5=="NONE") none[key]++;
}
END{
  printf "%-14s %-12s %-14s %-12s %-8s\n","reviewer","false-appr","caught-bug","false-rej","no-verdict";
  for(k in tot){
    printf "%-14s %2d/%-2d %-6s %2d/%-2d %-6s %2d/%-2d %-4s %d\n",
      k, fa[k]+0,bug[k]+0,"", caught[k]+0,bug[k]+0,"", fr[k]+0,cln[k]+0,"", none[k]+0;
  }
}' "$CSV" | tee "$OUT/summary.txt" >&2
echo "CSV: $CSV" >&2
