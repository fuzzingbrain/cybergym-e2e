#!/usr/bin/env bash
# CyberGym-E2E Codex arm, gpt-5 — the official runner, unchanged.
#
# For each of the 30 tasks it runs the official scripts/run_agent.py with
#   --agent codex --mode e2e --litellm-model-id gpt-5 --max-attempts 3
# so Codex gets up to 3 attempts under ONE shared per-task budget key
# (max_budget = $CYBERGYM_MAX_BUDGET, default 20 = the FBv2 envelope). Network
# isolation stays ON. We score S1 separately (reproduce/score_s1.py); here we
# only produce the agent runs + PoCs.
#
# Prereqs: reproduce/setup.sh done, and the LiteLLM proxy up with its env set:
#   export LITELLM_BASE_URL=http://<bridge-gw>:4000
#   export LITELLM_MASTER_KEY=<master key from reproduce/litellm/up.sh>
#
# Usage:
#   bash reproduce/run_codex_gpt5.sh [parallel]      # default parallel=1
set -uo pipefail
cd "$(dirname "$0")/.."                               # repo root

: "${LITELLM_BASE_URL:?export LITELLM_BASE_URL (see reproduce/litellm/up.sh)}"
: "${LITELLM_MASTER_KEY:?export LITELLM_MASTER_KEY (see reproduce/litellm/up.sh)}"
export CYBERGYM_MAX_BUDGET="${CYBERGYM_MAX_BUDGET:-20}"   # per-task shared budget ($)

PAR="${1:-1}"
PY="$(pwd)/.venv/bin/python"
LIST="${CG_LIST:-reproduce/tasks_30.txt}"   # override with CG_LIST to run a subset
OUT="reproduce/out/codex_gpt5"
mkdir -p "$OUT"
LOG="$OUT/batch.log"

# MODEL is the Codex backbone, PINNED to the dated snapshot gpt-5-2025-08-07
# (not the floating gpt-5 alias). The -codex variants gpt-5.2-codex/gpt-5-codex
# are shut down (model_not_found). MODEL MUST exist in
# reproduce/litellm/config.yaml, or litellm errors (fail-loud).
MODEL="${MODEL:-gpt-5-2025-08-07}"
# Fair envelope (matches FBv2): shared $ budget + TOTAL wall-clock per task;
# restart until S1 / budget / time. MAXA is a high safety cap on restarts.
TOTAL_MIN="${TOTAL_MIN:-90}"
MAXA="${MAXA:-20}"
echo "[$(date +%T)] MODEL=$MODEL  budget=\$${CYBERGYM_MAX_BUDGET} total=${TOTAL_MIN}m maxattempts=${MAXA}" | tee -a "$LOG"

run_one() {
  local t="$1" tn
  tn="$(echo "$t" | tr '/' '_')"
  # skip if this task already has a completed run
  if find "$OUT/$tn" -name summary.json 2>/dev/null | grep -q .; then
    echo "[$(date +%T)] skip (done): $t" | tee -a "$LOG"; return 0
  fi
  echo "[$(date +%T)] start: $t (shared budget=\$$CYBERGYM_MAX_BUDGET, total ${TOTAL_MIN}m, restart until S1/budget/time)" | tee -a "$LOG"
  # Fair envelope = same as FBv2: ONE shared $CYBERGYM_MAX_BUDGET key + a TOTAL
  # wall-clock deadline enforced INSIDE run_agent (CYBERGYM_DEADLINE_S), so an
  # unsolved task stops at the deadline and still writes summary.json. The agent
  # restarts (up to MAXA fresh attempts under the one key) until S1, $ budget, or
  # the deadline -- whichever first. The outer `timeout` is only a generous
  # safety net (deadline + 30 min) for a single hung attempt.
  CYBERGYM_DEADLINE_S="$((TOTAL_MIN*60))" CYBERGYM_STOP_AT_S1=1 \
  timeout -k 60 "$(((TOTAL_MIN+30)*60))" \
  "$PY" scripts/run_agent.py "$t" \
      --mode e2e --agent codex --prompt-style iterative \
      --model-provider litellm --litellm-model-id "$MODEL" \
      --max-attempts "$MAXA" --timeout "$((TOTAL_MIN*60))" \
      --use-firewall --agent-output "$OUT" >> "$OUT/$tn.log" 2>&1
  # hard check: the run must have used MODEL, not run_agent's default
  local sj; sj="$(find "$OUT/$tn" -name summary.json 2>/dev/null | sort | tail -1)"
  if [ -n "$sj" ] && ! grep -q "\"model\": \"$MODEL\"" "$sj"; then
    echo "[$(date +%T)] !! WARNING wrong model in $sj (expected $MODEL)" | tee -a "$LOG"
  fi
  echo "[$(date +%T)] done ($?): $t" | tee -a "$LOG"
}
export -f run_one; export OUT LOG PY CYBERGYM_MAX_BUDGET MODEL TOTAL_MIN MAXA LITELLM_BASE_URL LITELLM_MASTER_KEY

echo "[$(date +%T)] Codex/gpt-5 over $(grep -c . "$LIST") tasks, parallel=$PAR" | tee -a "$LOG"
if [ "$PAR" -gt 1 ]; then
  grep . "$LIST" | xargs -P "$PAR" -I{} bash -c 'run_one "$@"' _ {}
else
  while read -r t; do [ -n "$t" ] && run_one "$t"; done < "$LIST"
fi
echo "[$(date +%T)] batch finished" | tee -a "$LOG"
echo "Now score S1:  .venv/bin/python reproduce/score_s1.py --out $OUT"
