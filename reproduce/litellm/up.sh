#!/usr/bin/env bash
# Start the LiteLLM proxy + Postgres with plain `docker run` (no docker-compose
# dependency) and print the env the runner needs.
#
#   cd reproduce/litellm && cp .env.example .env && edit .env, then ./up.sh
#
# Prints LITELLM_BASE_URL (reachable from agent containers via the docker bridge
# gateway) and reminds you to add that host to the firewall allowlist.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "create reproduce/litellm/.env from .env.example first" >&2; exit 1; }
set -a; . ./.env; set +a
PORT="${LITELLM_PORT:-4000}"
NET=cybergym-litellm

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# Postgres (budget keys)
docker rm -f cybergym-litellm-db >/dev/null 2>&1 || true
docker run -d --name cybergym-litellm-db --network "$NET" \
  -e POSTGRES_DB=litellm -e POSTGRES_USER=litellm \
  -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-litellm}" \
  -v cybergym_litellm_pgdata:/var/lib/postgresql/data \
  postgres:16 >/dev/null
echo "waiting for postgres ..."
for _ in $(seq 1 30); do
  docker exec cybergym-litellm-db pg_isready -U litellm >/dev/null 2>&1 && break; sleep 2
done

# LiteLLM proxy
docker rm -f cybergym-litellm >/dev/null 2>&1 || true
docker run -d --name cybergym-litellm --network "$NET" \
  -p "${PORT}:4000" \
  -e LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:?set LITELLM_MASTER_KEY in .env}" \
  -e DATABASE_URL="postgresql://litellm:${POSTGRES_PASSWORD:-litellm}@cybergym-litellm-db:5432/litellm" \
  -e OPENAI_API_KEY="${OPENAI_API_KEY:?set OPENAI_API_KEY in .env}" \
  -e GPT5_INPUT_COST_PER_TOKEN="${GPT5_INPUT_COST_PER_TOKEN:-0.00000125}" \
  -e GPT5_OUTPUT_COST_PER_TOKEN="${GPT5_OUTPUT_COST_PER_TOKEN:-0.00001000}" \
  -v "$(pwd)/config.yaml:/app/config.yaml:ro" \
  ghcr.io/berriai/litellm:main-stable \
  --config /app/config.yaml --port 4000 >/dev/null

echo "waiting for litellm /health ..."
for _ in $(seq 1 60); do
  curl -fsS -m 3 "http://127.0.0.1:${PORT}/health/liveliness" >/dev/null 2>&1 && break; sleep 2
done

GW="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo 172.17.0.1)"
echo
echo "LiteLLM is up. Export these for the runner:"
echo "  export LITELLM_BASE_URL=http://${GW}:${PORT}"
echo "  export LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}"
echo
echo "Use the Docker BRIDGE gateway (${GW}) as the host, NOT the internal gateway:"
echo "the agent is on an internal (no-internet) network and reaches LiteLLM only"
echo "via squid, which egresses to the host over the bridge. setup.sh already ran"
echo "  python -m firewall start --ip ${GW}"
echo "so squid forwards to it. If you restarted litellm, re-run that --ip once."
