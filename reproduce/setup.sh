#!/usr/bin/env bash
# One-time environment setup for the CyberGym-E2E Codex arm (gpt-5).
# Run from the repo root:  bash reproduce/setup.sh
#
# Does everything the official README's one-time setup does, scoped to the 30
# tasks in reproduce/tasks_30.txt. Idempotent where possible. Needs: docker,
# python3, an HF token (HF_TOKEN) for the dataset, and sudo for sysctl.
set -euo pipefail
cd "$(dirname "$0")/.."                 # repo root
LIST="reproduce/tasks_30.txt"

echo "== 1. python venv + deps =="
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q tomli tomli_w anthropic openai boto3 httpx huggingface_hub docker

echo "== 2. download the 30 tasks' dataset from HuggingFace =="
: "${HF_TOKEN:?export HF_TOKEN=... (https://huggingface.co/settings/tokens)}"
# Restrict the download to the sampled tasks' project dirs.
PATTERNS=()
while read -r t; do
  [ -z "$t" ] && continue
  PATTERNS+=(--include "projects/${t%/*}/*")
done < "$LIST"
.venv/bin/hf download sunblaze-ucb/cybergym-e2e --repo-type dataset \
  --local-dir data/ "${PATTERNS[@]}"

echo "== 3. pull docker images for the 30 tasks only =="
# Each task's build_image = project.toml's build_image, optionally overridden by
# the task's config.toml. Collect those for the 30 tasks and pull just them
# (pulling all 511 referenced images would be wasteful).
.venv/bin/python - "$LIST" <<'PY'
import sys, tomli, subprocess
from pathlib import Path
tasks = [l.strip() for l in open(sys.argv[1]) if l.strip()]
imgs = set()
for t in tasks:
    d = Path("projects") / t
    cfg = {}
    for f in (d / "../project.toml", d / "config.toml"):
        if f.exists():
            cfg.update(tomli.loads(f.read_text()))
    img = cfg.get("build_image")
    if img:
        imgs.add(img)
    else:
        print(f"  WARN: no build_image for {t}")
print(f"pulling {len(imgs)} images for {len(tasks)} tasks")
for img in sorted(imgs):
    print(f"  docker pull {img}")
    subprocess.run(["docker", "pull", img], check=False)
PY

echo "== 4. host sysctl for ASan/sanitizers =="
sudo sysctl -w vm.mmap_rnd_bits=28

echo "== 5. network isolation (squid firewall), allowing the litellm host =="
docker pull ubuntu/squid:latest
# The agent runs on the internal (no-internet) network and can only egress via
# squid. The LiteLLM proxy listens on the host; squid reaches it at the Docker
# BRIDGE gateway, so that IP must be in squid's IP allowlist. (Direct agent->host
# is blocked by the internal network; routing LiteLLM through squid is the path.)
BRIDGE_GW="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo 172.17.0.1)"
( cd scripts && ../.venv/bin/python -m firewall start --ip "$BRIDGE_GW" ) \
  || ( cd scripts && ../.venv/bin/python -m firewall update --ip "$BRIDGE_GW" ) || true
echo "   squid allows litellm host $BRIDGE_GW ; use LITELLM_BASE_URL=http://$BRIDGE_GW:4000"

echo
echo "Setup done. Next:"
echo "  1) cd reproduce/litellm && cp .env.example .env  (fill in), then ./up.sh"
echo "  2) add the printed proxy host to scripts/firewall/default_allowlist.txt"
echo "  3) export LITELLM_BASE_URL / LITELLM_MASTER_KEY (from up.sh)"
echo "  4) bash reproduce/run_codex_gpt5.sh"
