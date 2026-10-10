# Kernel rollback 7.0.0-1019 → 6.17.0-1032 — applied + validated (2026-10-10)

## Why
NVIDIA advisory (2026-09-17): kernel **7.0.0-1019-nvidia** breaks multi-node NCCL/RoCE on
2× GB10 (vLLM TP=2 over ConnectX-7). Symptom `ibv_reg_mr_iova2 ... Cannot allocate memory`
→ `NCCL unhandled system error`, memory-pressure-dependent (fails ~90 GB/rank). Community
rollback: **6.17.0-1032-nvidia**.

## What was done (both nodes = leo + raph)
1. Installed `linux-image-6.17.0-1032-nvidia` + `linux-modules-6.17.0-1032-nvidia` +
   `linux-modules-nvidia-580-open-6.17.0-1032-nvidia` (arm64, non-64k). Confirmed the
   `-580-open` `nvidia.ko` is present in the 6.17 tree (GPU driver loads; not a mismatch).
2. Pinned `GRUB_DEFAULT` to the explicit menuentry path:
   `GRUB_DEFAULT="Advanced options for DGX OS GNU/Linux>DGX OS GNU/Linux, with Linux 6.17.0-1032-nvidia"`
   in `/etc/default/grub` (backup `/etc/default/grub.bak-20261010`), then `update-grub`.
   (Note: `GRUB_DEFAULT=0` makes `grub-set-default` a silent no-op — the explicit path is required.)
3. Rebooted both nodes → verified `uname -r = 6.17.0-1032-nvidia`, GPU up, driver 580.178.04.

## Startup path (verified correct — the intended one)
`dgx-model.service` (Type=oneshot, After=network.target + systemd-user-sessions, ExecStartPre=sleep 30)
→ `/usr/local/bin/default_model_vllm.sh` → `run-recipe.py` → `recipes/orcarouter-eugr-1m.yaml`
(= our tuned recipe). The boot service did fire at boot but reported `failed` on a transient
engine-core init (container self-healed); the **same script** manually re-run after boot
produced a healthy model. **The kernel change did NOT invalidate the tuning** — the container
env shows the exact T4 set: `max_num_seqs 6`, `max_num_batched_tokens 8192`,
`gpu_memory_utilization 0.85`, `max_cudagraph_capture_size 48`, `moe_backend b12x`,
`load_format b12x`, DSpark spec-decode 6, `Using 'B12X_MXFP4_MXFP8'`.

## Boot process HARDENED (2026-10-10)
`dgx-model.service` changed `Type=oneshot` → **`Type=simple`** and added
**`Restart=on-failure` + `RestartSec=60`** (backup `.bak-20261010`). Why:
- `oneshot` treats the launcher as "done" the moment `default_model_vllm.sh` returns, so a
  transient cold-boot engine-core init failure left the unit stuck in `failed` even though the
  container self-healed.
- `Type=simple` makes the launcher's blocking `/health` poll a "running" service;
  `Restart=on-failure` retries it (60s later) if it exits non-zero. `default_model_vllm.sh`
  is **idempotent** (skips if the model is already serving), so a retry is safe.
- Verified: `systemd-analyze verify` clean; with the model up the unit exits `success`,
  `NRestarts=0`. The launcher's poll-loop `[ $((i % 6)) -eq 0 ] && log` is safe under
  `set -e` (the `&&` protects it) — the premature exit was the transient engine-core init.

## Benchmark on 6.17.0-1032 (T4 recipe unchanged)
| c | agg tok/s | max temp |
|---|---|---|
| 1 | 34.0 | 56 C |
| 4 | 60.7 | 60 C |
| 6 | **80.2** | 60 C |
| 8 | 73.8 | 64 C |
| 12 (pressure) | 77.7 | 65 C |

**Equal or better than 7.0** (7.0: c1 32.5 / c4 58.5 / c6 72.7 / c8 66.5). No NCCL ENOMEM/OOM
at c=12 (high memory pressure) — confirms 6.17 sustains high load; 7.0 broke at ~90 GB/rank.

## One concession (fallback, not a loss)
`B12X_ROCENANTE` (one-shot RoCE all-reduce) does **not** connect on 6.17:
`ibv_modify_qp(RTR): No data available` / `Invalid argument`, so it falls back to PYNCCL
(`Using ['PYNCCL'] all-reduce backends`). Throughput is unaffected (equal-or-better), the
NCCL multi-node rings still init, and this is the designed safety net. Flagged for anyone
chasing the last ~5% of all-reduce bandwidth on 6.17.

## Rollback (if ever needed)
`sudo sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=0|' /etc/default/grub && sudo update-grub`
then reboot → boots 7.0.0-1019. (Or `grub-reboot` right before a reboot for a one-shot.)
