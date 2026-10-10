#!/usr/bin/env bash
# default_model_vllm.sh — TURNKEY: bring up (or ensure) the default vLLM model on
# the 2-node GX10 cluster, optionally swap models, and refresh the head node's /etc/motd.
#
# This is the DEEPSEEK default launcher (uses the recipe stack). It drives the
# podman-aware run-recipe.py launcher
# (relocated to /opt/vllm-recipe, NOT /tmp) so it survives reboots.
#
# DEFAULT_MODEL is defined here. It is currently deepseek; change it by editing
# this line (and MODEL_DIR below) when the default model changes.
#
# Idempotent: if the model is already serving on :8000, it does nothing but
# update motd. Safe to run from a boot unit or cron.
#
# Call: default_model_vllm.sh [--health] [--swap <model|DEFAULT_MODEL>]
#   (no arg)   ensure the default model is serving (skip if already up) + motd
#   --health   just report serving status / health
#   --swap <m> stop current, launch <m>, update motd (HEAD-first; ~5-10 min)
set -euo pipefail

# ---------- configurable ----------
DEFAULT_MODEL=deepseek
RUNTIME_USER="${RUNTIME_USER:-vllm}"   # user that owns the rootless podman containers
RECIPE_ROOT=/opt/vllm-recipe
RECIPE="$RECIPE_ROOT/recipes/orcarouter-eugr-1m.yaml"   # live recipe (1M ctx, T4, b12x)
LAUNCHER="$RECIPE_ROOT/.build/spark-vllm-docker/run-recipe.py"
LEO="<HEAD_IP>"             # head node (set to your head node IP)
RAPH="<WORKER_IP>"          # worker node (set to your worker node IP)
HEALTH_URL=http://127.0.0.1:8000/health
MODELS_URL=http://127.0.0.1:8000/v1/models
# ----------------------------------

log() { echo "[default_model_vllm] $*"; }
die() { echo "[default_model_vllm] ERROR: $*" >&2; exit 1; }

# Write an accurate /etc/motd describing the LIVE recipe stack and this tool.
# Called on every run (ensure + swap) so motd always reflects reality.
write_motd() {
  local m="$1"
  local broad
  case "$m" in
    deepseek) broad="DeepSeek-V4-Flash-Vision-Uncensored (b12x, 1M ctx, T4 tuning)" ;;
    *)        broad="$m" ;;
  esac
  sudo tee /etc/motd >/dev/null <<EOF

  GX10 2-node cluster -- HEAD node (rank 0 / front door)

  Serving (live vLLM on head :8000):
    model   = orcarouter/DeepSeek-V4-Flash-Vision-Uncensored
    ctx     = 1M (max_model_len 1048576), TP=2, b12x load format
    litellm = http://127.0.0.1:4000/v1/models  (forwards to vLLM :8000)

  Access:
    https://<head-host>/           -> landing page
    https://<head-host>/sparkdash/ -> sparkDash dashboard
    https://<head-host>/ups/       -> UPS web UI

  Stack management (on this host):
    default_model_vllm.sh            # ensure default (deepseek) is serving + motd
    default_model_vllm.sh --health   # report serving status / health
    default_model_vllm.sh --swap deepseek   # (re)launch deepseek recipe stack (HEAD-first)
    podman ps --filter name=b12x-vllm-node  # serving containers (head/worker)

  NOTE — GLM-5.3 is a SEPARATE stack, NOT this recipe. It uses the vllm_glm53
  container + launch-glm.sh (different image/tuning) and has NOT been re-tested
  on kernel 6.17.0-1032. Do NOT use it unless you intend to run GLM.
  Qwen is untested on this cluster.

  Active default model: $broad
  Model swap / launcher lives at /opt/vllm-recipe (persists across reboots).

  NUT / UPS:  sudo upsc cyberpower@localhost | head
  Models:     /models (DeepSeek, GLM)
  Thermal:    nvidia-smi --query-gpu=temperature.gpu  (GPU); board zone = max /sys/class/thermal/thermal_zone*/temp

EOF
  log "motd updated for model: $m"
}

case "${1:-}" in
  --health) ;; # fall through to health check below
  --swap) ;; # handled below
  "") ;;
  *) log "unknown arg '${1:-}' (ignoring; ensuring default)" ;;
esac

command -v podman >/dev/null || die "podman not found"
[ -x "$LAUNCHER" ] || die "launcher missing: $LAUNCHER (is /opt/vllm-recipe present?)"

# Boot-timing hardening: at cold boot, rootless podman (owned by ${RUNTIME_USER}, linger on)
# may not be ready when this service fires right after network.target. Wait a bounded
# time for podman to come up before launching. Non-invasive: exits 0 with a notice if
# it never becomes ready (the next timer/reboot will retry), so boot isn't blocked.
_podman_ready() {
  # rootless podman socket (${RUNTIME_USER}) comes up with the user session
  sudo -u "$RUNTIME_USER" podman info >/dev/null 2>&1 || podman info >/dev/null 2>&1
}
for i in $(seq 1 30); do
  if _podman_ready; then log "podman ready (attempt $i)"; break; fi
  sleep 2
done
_podman_ready || log "WARN: podman not ready after 60s; continuing anyway (may fail and be retried)"

# ---------- health / serving check ----------
service_up() { curl -fsS "$MODELS_URL" >/dev/null 2>&1; }
model_serving() { curl -fsS "$MODELS_URL" 2>/dev/null | grep -qi "$2"; }

if [ "${1:-}" = "--health" ]; then
  if service_up; then
    echo "serving: $(curl -s "$MODELS_URL" | tr -d '\n')"
    echo "health:  $(curl -s -o /dev/null -w '%{http_code}' "$HEALTH_URL")"
  else
    echo "NOT serving on :8000"
  fi
  [ -f /etc/motd ] && echo "--- /etc/motd ---" && cat /etc/motd
  exit 0
fi

# ---------- --swap <deepseek|glm> ----------
SWAP_TARGET=""
case "${1:-}" in
  --swap)
    SWAP_TARGET="${2:-}"
    # Stop the recipe stack's container on both nodes (it owns :8000) so the swap
    # stack can reuse the port. launch-glm.sh also stops its own vllm_glm53.
    echo "==> stopping recipe stack (b12x-vllm-node) on head + worker"
    sudo -u "$RUNTIME_USER" podman rm -f b12x-vllm-node 2>/dev/null || true
    sudo -u "$RUNTIME_USER" ssh -o BatchMode=yes -o ConnectTimeout=10 "$RAPH" \
      'podman rm -f b12x-vllm-node 2>/dev/null || true' 2>/dev/null || true

    case "$SWAP_TARGET" in
      deepseek)
        log "swapping to default ($SWAP_TARGET) via recipe stack"
        ;; # fall through to the recipe launch below
      glm)
        log "swapping to GLM via launch-glm.sh (SEPARATE vllm_glm53 stack, NOT the deepseek recipe)"
        log "NOTE: GLM has NOT been re-tested on kernel 6.17.0-1032"
        sudo -u "$RUNTIME_USER" launch-glm.sh   # GLM-only stack (see README)
        write_motd "$SWAP_TARGET"
        log "done. Swapped to $SWAP_TARGET (served-name dgx_hobo_default)."
        exit 0
        ;;
      *)
        die "unknown swap target '$SWAP_TARGET' (use deepseek or glm; qwen is untested)"
        ;;
    esac
    ;;
esac

# Stop the recipe container on both nodes. The ensure path MUST do this before
# launching: if a previous attempt left b12x-vllm-node running (but the model
# never reached health=200, e.g. the cold-boot rendezvous race), launcher's
# check_cluster_running() would see the container up, skip exec_no_ray_cluster,
# and never dispatch vllm serve again - so a systemd Restart=on-failure would
# spin forever without ever bringing the model up. Removing the container (and
# its orphaned worker vllm serve procs) forces a clean recreate + dispatch every
# time. Settings/tunings come from the recipe yaml + env, NOT container state.
stop_recipe_stack() {
  echo "==> stopping recipe stack (b12x-vllm-node) on head + worker"
  sudo -u "$RUNTIME_USER" podman rm -f b12x-vllm-node 2>/dev/null || true
  sudo -u "$RUNTIME_USER" ssh -o BatchMode=yes -o ConnectTimeout=10 "$RAPH" \
    'podman rm -f b12x-vllm-node 2>/dev/null || true' 2>/dev/null || true
}

# ---------- ensure default model ----------
if service_up; then
  if model_serving "$DEFAULT_MODEL"; then
    log "default model ($DEFAULT_MODEL) already serving. Updating motd only."
    write_motd "$DEFAULT_MODEL"
    exit 0
  fi
  log "a model is serving but not the default ($DEFAULT_MODEL). Launching default."
fi

# Always clean the stale recipe stack before launching so start_cluster() sees a
# fresh slate and dispatches vllm serve (see stop_recipe_stack comment). Idempotent
# if already clean; prevents the orphan-accumulation / never-re-dispatch races.
log "preparing clean launch: stopping any stale b12x-vllm-node container"
stop_recipe_stack

log "launching default model '$DEFAULT_MODEL' via run-recipe.py -d"
log "  recipe: $RECIPE"
log "  launcher: $LAUNCHER"

# HEAD-first handled by run-recipe.py/launch-cluster.sh for the 2-node recipe.
sudo -u "$RUNTIME_USER" "$LAUNCHER" "$RECIPE" -d   # -d = daemon (persists across SSH exit)

log "waiting for /health on head :8000 (model load ~5-7 min)..."
for i in $(seq 1 60); do
  sleep 10
  c=$(curl -s -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null)
  [ "$c" = "200" ] && { log "READY after ~$((i*10))s."; break; }
  [ $((i % 6)) -eq 0 ] && log "  still loading ($((i*10))s)..."
done
service_up || { die "did not come up in time. Check: podman logs b12x-vllm-node"; }

log "updating /etc/motd for active model '$DEFAULT_MODEL'"
write_motd "$DEFAULT_MODEL"

log "done. Model: $DEFAULT_MODEL serving on :8000."
