# DeepSeek V4 Flash Vision (Uncensored) — 2-node GX10 Serve Recipe

Production recipe for serving **`orcarouter/DeepSeek-V4-Flash-Vision-Uncensored`**
(b12x load format, 1M context, T3-tuned) across a **2-node NVIDIA GB10 / DGX Spark
cluster** with **tensor-parallel 2**, a **CPU thermal (busy-loop) fix**, a
**boot autostart** launcher, and the **launch-orchestration fixes** that make it
idempotent across reboots.

This repo is the **sanitized configuration + documentation** for a working setup.
Internal IPs/hostnames are replaced with placeholders; no secrets are included.

---

## What's in this repo

| Path | What it is | Source |
|---|---|---|
| `recipes/orcarouter-eugr-1m.yaml` | The **tuned recipe**: 1M ctx, TP=2, b12x, T3 (max-num-seqs 4, max-num-batched-tokens 8192), dspark speculative 6, fp8 KV | **Own work** (tuned from the friend's recipe) |
| `mods/busy-loop-fix/` | Apply-on-launch **thermal fix**: `busy_loop_s` 1 → 0.002 in vLLM `shm_broadcast.py` (CPU spin-wait fix). See [`README`](mods/busy-loop-fix/README.md) | **Own work** |
| `host-cpu-thermal/` | **Host-level** thermal fix: `schedutil` governor + cap X925 P-cores to 2.8GHz (systemd, persists across boot) | **Own work** |
| `scripts/default_model_vllm.sh` | **Boot/swaap launcher**: idempotently ensure the default model is serving, refresh `/etc/motd`, `--swap` between models | **Own work** |
| `launcher/run-recipe.py` | Launcher that turns a YAML recipe into a 2-node container launch | Third-party (see Attribution) |
| `launcher/launch-cluster.sh` | Low-level cluster orchestration (container create, mod apply, RAFT/NCCL) | Third-party (see Attribution) |

---

## The model

- **`orcarouter/DeepSeek-V4-Flash-Vision-Uncensored`** — DeepSeek V4 Flash with
  vision, uncensored/abliterated. A strict superset of the text-only abliterated
  release (vision tower included), so it replaces the smaller text-only variant.
  **HF repo:** [https://huggingface.co/orcarouter/DeepSeek-V4-Flash-Vision-Uncensored](https://huggingface.co/orcarouter/DeepSeek-V4-Flash-Vision-Uncensored)
- **Served name** (API `id`) = the model id above.
- Loaded with **`--load-format b12x`** (the B12X-optimized kernel path), not
  `instanttensor` (PyPI `instanttensor` lacks `_determine_buffer_size` → fails).

---

## Cluster topology (sanitized)

| Role | Host (placeholder) | RoCE IP (placeholder) | Rank |
|---|---|---|---|
| Head (server) | `<HEAD_IP>` | `<HEAD_ROCE_IP>` | 0 |
| Worker | `<WORKER_IP>` | `<WORKER_ROCE_IP>` | 1 |

- 2 nodes, TP=2, API exposed on the **head** only (`:8000`).
- The launcher config (`.env`) pins the RoCE fabric: `ETH_IF`, `IB_IF`, `LOCAL_IP`,
  `MASTER_PORT=29501`, `CLUSTER_NODES`, `COPY_HOSTS`.
- `CONTAINER_RT=podman`, `VLLM_SPARK_NOFILE_LIMIT=500000`.

---

## Tuning (why these values)

Batched-token/seq tuning for the 305B model at 500k–1M ctx on 2× GB10:

| Config | max-num-seqs | max-num-batched-tokens | Decode (short) | Decode (long) | Acceptance |
|---|---|---|---|---|---|
| baseline | 8 | 4096 | ~31 t/s | — | 19.6% |
| T1 | — | — | ~30 t/s | — | 39.2% |
| **T3** | **4** | **8192** | **~32 t/s** | **~43 t/s** | **40.2% / 47.6%** |
| 1M (T3, ctx 1048576) | 4 | 8192 | ~31 t/s | ~37 t/s | 44.6% / 38.1% |

- **T3 (`max-num-seqs 4`, `max-num-batched-tokens 8192`) is the winner** and is the
  recipe default. Lower batch (4096) raises acceptance but caps tokens/step (lowers
  t/s); high batch + low seqs is the sweet spot.
- **1M context is stable** and near-500k perf; the only cost is VRAM (~113-116 Gi/121 Gi
  used, ~8.5 GiB free — the OOM risk window). `max_model_len: 1048576` in the recipe.

---

## The thermal fix (why `busy_loop_s`)

On GB10 the CPU and GPU share one die/heatsink. Under TP≥2 decode, vLLM's
inter-process queue (`shm_broadcast.py`) **spins for up to 1 second**
(`busy_loop_s: float = 1`) instead of sleeping, holding 3-4 P-cores at 3.9 GHz
continuously — roughly **half the thermal budget millimeters from the GPU**.

`mods/busy-loop-fix/run.sh` patches it to **0.002** on every container launch
(idempotent; survives container recreation because it's applied as a mod, not
baked in):

```
busy_loop_s: float = 1,  ->  busy_loop_s: float = 0.002,
```

**Measured effect:** vLLM idle CPU from ~57-79% → **4%**; board (acpitz) temp from
~85°C → **~51°C**; GPU from ~70°C → **~48°C**. Use 0.002, not 0 — 0 forces
idle-poll/wakeups and can raise CPU.

### Host-level: governor + performance-core cap (`host-cpu-thermal/`)

The `busy_loop_s` mod fixes the container spin-wait, but under sustained TP=2
decode the 10 Cortex-X925 P-cores still boost to 3.9GHz and get pinned by the
IPC/NCCL work, pushing the SoC ACPI zones (0/5) to ~90-92°C. This is a **host**
fix (not a container mod) and persists across reboots as a systemd unit.

- **Governor:** `performance` → `schedutil` (all 20 cores; idle cores drop to
  ~338MHz instead of sitting at max).
- **Cap:** the 10 X925 P-cores (CPUs 5-9, 15-19) to **2.8GHz** (the same as the
  A725 efficiency cores). This is the single biggest lever.
- **Measured effect (community, dual-GB10 TP2):** SoC −9°C, P-core cluster −14°C,
  GPU −1.7°C. Single-stream token rate unchanged; 8 concurrent streams ≈ −5%.
- `nvidia-smi -pl` is a **NO-OP** on the GB10 ("not supported in current scope") —
  do not use a power-limit service.

See [`host-cpu-thermal/README.md`](host-cpu-thermal/README.md) for the install,
immediate-apply, verify, and revert commands. Files: `cpu-governor.service`
(systemd unit) + `gx10-cpu-cap.sh` (caps the X925 cores, idempotent).

---

## Launch-orchestration fixes (the non-obvious parts)

These were the traps that broke the tuned setup on a **fresh relaunch or boot**.
Both are fixed in this repo / documented here so a rebuild works first try.

### 1. `vLLM_SPARK_NOFILE_LIMIT` was being ignored (crun crash)
`launch-cluster.sh` read `NOFILE_LIMIT="${VLLM_SPARK_NOFILE_LIMIT:-1048576}"`
**before** the `.env` was loaded, but the `.env` loader exports keys with a
`DOTENV_` prefix (`DOTENV_VLLM_SPARK_NOFILE_LIMIT`). So the configured value was
never seen → fell back to 1048576 → rootless podman/crun could not raise the nofile
limit:

```
crun: setrlimit `RLIMIT_NOFILE`: Operation not permitted: OCI permission denied
```

**Fix:** re-read `NOFILE_LIMIT` **after** the `.env` load block, picking up the
`DOTENV_` value. Now `VLLM_SPARK_NOFILE_LIMIT=500000` is honored on every launch.

### 2. Missing `/models` mount → HF re-download hang
The HuggingFace cache snapshot's weight shards are **symlinks into `/models`**
(e.g. `model-00002-of-00048.safetensors -> /models/<repo>/...`). If the container
does **not** mount `/models`, those symlinks **dangle** inside the container →
`snapshot_download` thinks the files are missing → it starts an `xet_get`
**re-download from HF Hub and stalls on the network** (the model never comes up).

**Fix:** mount it:
```yaml
volumes:
  - /models:/models
```
The recipe carries this in `volumes:` and `run-recipe.py` now forwards recipe
`volumes` to `launch-cluster.sh` as `-v /models:/models`. With the mount, the model
loads from local disk in **~150s** instead of stalling >15 min on the network.

---

## Boot autostart

`scripts/default_model_vllm.sh`:
- `DEFAULT_MODEL=deepseek` at the top (edit to change the default).
- **Idempotent**: if the default model is already serving, it only updates `/etc/motd`.
- Writes an accurate `/etc/motd` describing the live stack (model, ctx, TP, tool, thermal).
- `--swap <qwen|glm|deepseek>`: stops the recipe stack on both nodes, delegates GLM/Qwen
  to the legacy `launch-model.sh` stack, or relaunches the recipe for `deepseek`.
- `--health`: reports serving status.

**Boot timer example** (systemd, oneshot):
```ini
[Unit]
Description=Bring up the default vLLM model on the 2-node GX10 cluster
After=network.target systemd-user-sessions.service
Wants=network.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 30
ExecStart=/usr/local/bin/default_model_vllm.sh
TimeoutStartSec=1200
User=root

[Install]
WantedBy=multi-user.target
```

---

## How the launcher applies the mod

`launch-cluster.sh`/`run-recipe.py` apply a recipe's `mods:` by copying the mod dir
to the container and running its `run.sh` **inside** the container (via
`--apply-mod <path>`). The mod's `run.sh` does an idempotent `sed` on the
site-packages file, then the change is confirmed. Because it's applied on every
launch, it **survives container recreation** without rebuilding the image.

---

## Attribution / provenance

- **Launcher scripts** (`launcher/run-recipe.py`, `launcher/launch-cluster.sh`) are
  third-party from the **`spark-vllm-docker`** project. This repo carries the B12X
  fork's **podman-aware** variant (`CONTAINER_RT` configurable, `CLUSTER_NODES`
  driven); the podman support is from the community PR that swapped `docker` →
  `$CONTAINER_RT`. See the upstream repos for the canonical source.
- **Container image** `eugr/spark-vllm-b12x:latest` — the B12X-optimized vLLM image
  (registers the `B12xModelLoader` for `--load-format b12x`).
- **Model** `orcarouter/DeepSeek-V4-Flash-Vision-Uncensored` — community uncensored
  DeepSeek V4 Flash Vision.
- The **`busy_loop_s` fix** and the **`/models` mount** gotcha follow community
  reports (NVIDIA dev forums / ServeTheHome / StorageReview) on GB10 thermal.
- The **orchestration fixes** in this repo are the author's own work.

> No API keys, tokens, passwords, real hostnames, or internal IPs are present in this
> repo. Replace the `<HEAD_IP>`/`<WORKER_IP>` placeholders and set
> `HF_TOKEN` in the launcher's `.env` (only where you deploy it) to reproduce.

---

## Quick reproduce (docs)

1. Clone the upstream `spark-vllm-docker` launcher (provenance above) and drop this
   repo's `recipes/` + `mods/` into it.
2. Configure the launcher `.env`: `CLUSTER_NODES`, `LOCAL_IP`, `ETH_IF`, `IB_IF`,
   `MASTER_PORT`, `CONTAINER_RT=podman`, `VLLM_SPARK_NOFILE_LIMIT=500000`.
3. Ensure `/models` exists on both nodes and contains the model; ensure the recipe's
   `volumes: [- /models:/models]` is in effect.
4. Launch:
   ```
   run-recipe.py recipes/orcarouter-eugr-1m.yaml -d
   ```
5. Wait for `/health` → 200, then check the thermal win
   (`nvidia-smi` + `cat /sys/class/thermal/thermal_zone*/temp`).
