#!/bin/bash

# adapted from https://github.com/laude-institute/terminal-bench/blob/main/terminal_bench/agents/installed_agents/codex/codex-setup.sh.j2

apt-get update
apt-get install -y curl

# Repro env fix: the build image rewrites github.com -> a local mirror /deps/git
# (git insteadOf), broken in our setup so nvm's `git clone` fails
# ("/deps/git/.../nvm.git does not appear to be a git repository"). Clear any
# insteadOf rewrites so nvm clones from real github (install network has
# internet). Only affects node install, not the agent.
git config --global --get-regexp 'insteadof' 2>/dev/null | awk '{print $1}' | sort -u | \
  while read -r k; do git config --global --unset-all "$k" 2>/dev/null || true; done

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh | bash

source "$HOME/.nvm/nvm.sh"

nvm install 22
npm -v

npm install -g @openai/codex@0.118.0

mkdir -p "$HOME/.codex"
