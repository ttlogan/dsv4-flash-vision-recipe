# DeepSeek V4 Flash — Launch Wedge / "Cannot Launch" Troubleshooting

The one page to read when deepseek won't come up on the 2-node GX10. Every symptom
below has been hit and root-caused on this exact cluster.

## The single most important rule

**The recipe args are almost never the problem.** The proven-working config (see
`recipes/orcarouter-eugr-1m.yaml`, T4) served healthy, then "stopped working"
with NO change to the recipe. The actual cause was a stale container on the
worker node holding an old render. **Always clear the container on BOTH nodes
before re-launching.**

## Symptom → cause → fix

### 1. `Model Runner V1 does not support: dspark speculative decoding`

The engine fell back to V1 model runner. V2 is **required** for DSpark spec-decode.

- **Cause:** `VLLM_USE_V2_MODEL_RUNNER` rendered as `0`. Either the recipe set it
  to 0, or (the common case) a **stale container** from an earlier launch has
  `VLLM_USE_V2_MODEL_RUNNER="0"` baked into its `/workspace/exec-script.sh`.
- **Why `run-recipe.py` reuses the stale one:** on a 2-node launch it checks the
  **worker** node. If it sees `b12x-vllm-node` still running there, it prints
  `Warning: Container 'b12x-vllm-node' is already running on worker node ... Skipping launch`
  and **re-renders nothing** — reusing the old (wrong) exec-script.
- **Fix:** stop the container on **both** head and worker, then relaunch:
  ```bash
  sudo -u wfoster podman rm -f b12x-vllm-node            # on leo (head)
  sudo -u wfoster ssh 192.168.0.143 "podman rm -f b12x-vllm-node"   # on raph (worker)
  # then relaunch; confirm the new render has V2=1:
  sudo -u wfoster podman exec b12x-vllm-node grep VLLM_USE_V2_MODEL_RUNNER /workspace/exec-script.sh
  ```

### 2. `Error: no container with name or ID "b12x-vllm-node" found` after launch

The head container was removed but the worker launch failed. Check the worker is
reachable over SSH and has the image. `run-recipe.py` skips the launch if it
believes the containers are already up, so a half-cleaned 2-node state produces
this.

- **Fix:** confirm both nodes have no `b12x-vllm-node`, confirm `eugr/spark-vllm-b12x:latest`
  is present on both, then relaunch.

### 3. Wedged at CUDA-graph warmup / `shm_broadcast.py:813 No available shared memory broadcast block found`

- **If the log keeps advancing and GPU util is climbing → it's just the normal
  ~15-17 min warmup. LEAVE IT.** GPU mem grows past the 77.5 GiB weight plateau
  toward the KV pool (~85-101 GiB), worker CPU sits near 100% compiling. Health
  stays 000 until it's done.
- **Only** if the log is **frozen** (same timestamp for minutes) AND GPU util is
  a flat 0% AND GPU mem is flat → it is genuinely wedged. Do NOT chase this with
  arg changes; it is almost always the stale-container problem from #1, which puts
  the engine on a V1/V2 mismatch that never converges.

### 4. `ValueError: DeepseekV4 fp8_ds_mla layout only supports fp8 kv-cache, got nvfp4_ds_mla`

- **Cause:** this container's `deepseek_v4` attention class only supports **`fp8`**
  KV. `--kv-cache-dtype nvfp4_ds_mla` is incompatible (it's for a different image).
- **Fix:** `--kv-cache-dtype fp8`. Never change this to `nvfp4_ds_mla` in `eugr/spark-vllm-b12x:latest`.

### 5. `RuntimeError: Engine core initialization failed`

Usually a downstream effect of the above (wrong KV dtype, or V1/V2 mismatch). Fix
the root cause first; don't treat this in isolation.

## The confirmed-working config (all fields)

Captured from a live, healthy, serving instance (T4 default):

- `--kv-cache-dtype fp8`
- `--block-size 256`, `--max-model-len 1048576` (1M)
- `--max-num-seqs 6`, `--max-num-batched-tokens 8192`
- `--gpu-memory-utilization 0.85`
- `--max-cudagraph-capture-size 48`
- `--compilation-config '{"cudagraph_mode":"FULL_AND_PIECEWISE","custom_ops":["all"]}'`
- `--speculative-config '{"method":"dspark","num_speculative_tokens":6,...,"attention_backend":"B12X"}'`
- `--load-format b12x`, `--moe-backend b12x`, `--linear-backend b12x`, `--attention-backend B12X`
- Env: `VLLM_USE_V2_MODEL_RUNNER=1` (required), `VLLM_USE_AOT_COMPILE=1`,
  `VLLM_USE_BREAKABLE_CUDAGRAPH=0`, `VLLM_USE_MEGA_AOT_ARTIFACT=1`,
  `VLLM_MEMORY_PROFILE_INCLUDE_ATTN=1`, `VLLM_ENABLE_ROCE_ALLREDUCE=1`,
  `CUTE_DSL_ARCH=sm_121a`, `B12X_MLA_SM120_UNIFIED=1`, `B12X_MOE_FORCE_A8=1`,
  `VLLM_USE_FLASHINFER_SAMPLER=1`, `VLLM_USE_B12X_WO_PROJECTION=1`,
  `VLLM_USE_B12X_MHC=1`, `VLLM_USE_B12X_FP8_GEMM=1`, `VLLM_USE_B12X_MOE=1`,
  `VLLM_USE_B12X_SPARSE_INDEXER=1`, `VLLM_MOE_SKIP_PADDING=0`

## What did NOT help (dead ends, do not re-try)

- `--kv-cache-dtype nvfp4_ds_mla` → hard `ValueError` (different image).
- `cudagraph_mode: PIECEWISE` + `num_speculative_tokens 5` + `gpu-mem 0.78` → the
  args were never the issue; the wedge came from the stale container.
- `VLLM_USE_V2_MODEL_RUNNER=0` → `Model Runner V1 does not support dspark` (V2 required).
- Removing the literal `--max-cudagraph-capture-size` → the real config needs it at 48.
- `VLLM_ENABLE_ROCE_ALLREDUCE` → perf knob only, not a convergence fix.

## Orchestration checklist

- `swap-model.sh restart` must clear `b12x-vllm-node` on BOTH head and worker
  (a stale worker container is what blocks the re-render).
- `launch_lane` must call `run-recipe.py <recipe> -d` plainly (no shell redirect —
  a `>log 2>&1 </dev/null` leaks into the `vllm serve` argv and crashes it with
  `unrecognized arguments`).
- The worker node holds the copy of the container that `run-recipe.py` inspects.
  If the worker rm fails, the launch silently reuses stale state.
- `served_name deepseek` must match the actual `/v1/models` id. The engine serves
  `orcarouter/DeepSeek-V4-Flash-Vision-Uncensored`; use the substring
  `deepseek-v4-flash-vision` so `model_serving` stays idempotent.
