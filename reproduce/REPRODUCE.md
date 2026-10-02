# Reproduce — CyberGym-E2E Codex arm (gpt-5), detection-only (S1)

This is the **Codex baseline** used in the FBv2/ZBH paper's RQ3 (CyberGym-E2E).
It runs the **official** CyberGym-E2E Codex agent on 30 tasks and scores **S1**
(the agent's PoC crashes the unpatched build) — the detection-only comparison
with FBv2, which has no patch stage.

## What is and isn't modified

Everything is the upstream benchmark **unchanged**, except:

- **One source edit** in `scripts/run_agent.py`: the minted per-task LiteLLM
  budget key reads `CYBERGYM_MAX_BUDGET` (default **$20**) instead of the
  hardcoded `$10`, to match the FBv2 envelope ($20 / task). One key is minted
  per `run_agent.py` invocation and shared across all `--max-attempts`, so this
  is a true **shared task budget**.
- **Added, under `reproduce/`** (no change to the agent or validator): the task
  list, a LiteLLM proxy config, the runner, and an S1 scorer.

The agent is the official `run_agent.py --agent codex --mode e2e` → `codex exec`.
S1 is scored with the official `scripts/validate.py --only-stage 1 --poc-file …`
(the benchmark's native PoC-only Stage-1 mode). We only decouple **when** S1 is
read: on every attempt's PoC, instead of the e2e loop's patch-gated path.

## Model (pinned)

`gpt-5-2025-08-07` — the dated snapshot, not the floating `gpt-5` alias.
The `-codex` variants (`gpt-5.2-codex`, `gpt-5-codex`) are shut down
(`model_not_found`). The model is pinned in three places and asserted by the
scorer; `reproduce/litellm/config.yaml` defines only this model, so a wrong
`--litellm-model-id` fails loud.

## Budget / protocol (same envelope as FBv2)

- `$20` shared budget per task and a **90 min total wall-clock** deadline per
  task (`CYBERGYM_DEADLINE_S`, enforced inside `run_agent.py`): within that one
  envelope the runner restarts the agent until S1 (up to `MAXA=20` attempts, each
  capped to the remaining time) under a single shared budget key — matching the
  FBv2 "restart until S1 / \$20 / 90 min" protocol. No further spend once the
  key's budget is exhausted.
- Network isolation ON (squid firewall). Mode `e2e` (source only).
- Evaluation stops / is counted at the **first PoC that reproduces** (S1);
  reported time is the agent-exec time accumulated up to that attempt.

## Steps

```bash
# 0. clone this fork, cd into it
git clone https://github.com/fuzzingbrain/cybergym-e2e.git && cd cybergym-e2e

# 1. one-time setup: venv, dataset for the 30 tasks, images, firewall, sysctl
export HF_TOKEN=hf_...            # https://huggingface.co/settings/tokens
bash reproduce/setup.sh

# 2. LiteLLM proxy (gpt-5 pricing + budget keys)
cd reproduce/litellm && cp .env.example .env    # fill OPENAI_API_KEY, LITELLM_MASTER_KEY, gpt-5 prices
./up.sh                                          # prints LITELLM_BASE_URL (bridge gw) + master key
cd ../..
# NOTE on networking: the agent runs on an internal (no-internet) network and can
# only egress through squid. setup.sh already started the firewall with
#   python -m firewall start --ip <bridge-gw>
# so squid forwards the agent's LLM calls to LiteLLM on the host. Use the Docker
# BRIDGE gateway as the host (e.g. 172.17.0.1), NOT the internal gateway. If you
# restart litellm, re-run: (cd scripts && ../.venv/bin/python -m firewall update --ip <bridge-gw>)

# 3. run the 30 tasks (parallel optional, e.g. 3)
export LITELLM_BASE_URL=http://<bridge-gw>:4000   # e.g. http://172.17.0.1:4000
export LITELLM_MASTER_KEY=<from up.sh>
bash reproduce/run_codex_gpt5.sh 3

# 4. score S1 (official PoC-only validation, in the build containers)
.venv/bin/python reproduce/score_s1.py --out reproduce/out/codex_gpt5
```

Outputs: `reproduce/out/codex_gpt5/<task>/<ts>_e2e*/` (agent runs, PoCs,
trajectories, `summary.json`) and `reproduce/out/codex_gpt5/s1_scores.json`
(per-task S1, aggregate S1 + Wilson 95% CI, cost, snapshot time, model check).

## The 30 tasks

`reproduce/tasks_30.txt` — a fixed-seed (seed 42) uniform draw of 30 from the
666 libFuzzer C/C++ CyberGym-E2E tasks. The same 30 are used by the FBv2 and
pure-fuzzing arms.
