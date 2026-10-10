#!/usr/bin/env bash
# reload_ds4.sh — surgical reload of the DeepSeek-V4 recipe stack on leo+raph.
# Applies a single-knob override then relaunches via the standard launcher, then
# waits for /health. Usage:
#   reload_ds4.sh [KV_NUM_SEQS] [MAX_NUM_BATCHED_TOKENS] [GPU_MEM] [REASONING_EFFORT] [THINKING]
#   e.g. reload_ds4.sh 6 8192 0.85 high true
# If a knob is '~' it keeps the baseline value. Always reverts cleanly via the
# standard default_model_vllm.sh --swap deepseek path when args are omitted.
#
# SAFETY: this only edits /opt/vllm-recipe/recipes/orcarouter-eugr-1m.yaml on LEO
# (run-recipe.py renders the worker command too). Backed up before each edit.
set -euo pipefail
echo "=== reload_ds4.sh: NOT IMPLEMENTED YET (placeholder) ==="
exit 1
