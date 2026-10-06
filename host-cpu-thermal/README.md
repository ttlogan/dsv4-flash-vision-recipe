# Host CPU Thermal — governor + performance-core cap

Host-level thermal relief for the GB10 SoC during vLLM inference. Unlike the
container-level `mods/busy-loop-fix` (patches the spin-wait in `shm_broadcast.py`),
this runs on the **host** node and persists across reboots as a systemd unit.

The GB10's CPU ACPI zones (0/5, the SoC package) run hot under TP=2 decode
because the 10 Cortex-X925 performance cores boost to 3.9GHz and get pinned by
the IPC/NCCL work. Capping the performance cores to 2.8GHz (same as the
efficiency cores) drops the SoC ~9C and the performance-core cluster ~14C with
~no single-stream token cost (memory-bandwidth-bound inference).

## Files

| Path | Purpose |
|---|---|
| `cpu-governor.service` | systemd unit: set `schedutil` governor, then cap X925 cores to 2.8GHz |
| `gx10-cpu-cap.sh` | caps CPUs 5-9,15-19 to 2.8GHz (idempotent; A725 cores untouched) |

## Install (both nodes)

```bash
sudo install -m 0755 gx10-cpu-cap.sh /usr/local/sbin/gx10-cpu-cap.sh
sudo cp cpu-governor.service /etc/systemd/system/cpu-governor.service
sudo systemctl daemon-reload
sudo systemctl enable --now cpu-governor.service
```

## Apply immediately (no reboot)

```bash
sudo systemctl restart cpu-governor.service
```

## Verify

```bash
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort | uniq -c   # 20 schedutil
for c in 5 6 7 8 9 15 16 17 18 19; do cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq; done | sort -u   # 2800000
```

## Revert

```bash
sudo systemctl disable --now cpu-governor.service
sudo cpupower frequency-set -g performance
```

## Notes

- Governor driver is `cppc_cpufreq`; both `schedutil` and `performance` are in
  `scaling_available_governors`.
- `scaling_max_freq` is a sysfs write that resets on reboot, so it **must** be
  re-applied by the boot unit (the `ExecStart` does this).
- `nvidia-smi -pl` is a NO-OP on the GB10 ("not supported in current scope") —
  do not use a power-limit service.
- Do not cap below 2.8GHz; throughput starts to drop noticeably around 2.15GHz.

## Thermal safety watchdog (clean poweroff at 95°C)

The GB10's EC **hard power-cuts** (log-less) when the SoC/acpitz package zone
crosses ~96°C — the node just goes dark with no journal entry. To protect
against that, `gx10-thermal-watch` monitors the hottest ACPI zone and, on a
sustained 95°C trip, issues a **clean** `systemctl poweroff` (and powers off a
designated cluster peer first, if one is set). Zero performance impact — it
only reads temps and only acts on an actual overheat.

| File | Purpose |
|---|---|
| `gx10-thermal-watch.sh` | reads hottest `/sys/class/thermal/thermal_zone*/temp`; on sustained 95°C fires ordered shutdown |
| `gx10-thermal-watch.service` | systemd unit: `THRESHOLD=95000`, `CONSECUTIVE=3`, `INTERVAL=30`, `PEER_HOST=<other rank>` |

Defaults give a **90s sustained window** (30s × 3 samples) so transient spikes
don't false-trigger, but a real sustained overheat still trips it with margin
before the EC's ~96°C cut.

Install on the **hottest node only** (the head/rank-0). Set `PEER_HOST` to the
other cluster rank so a trip shuts both nodes down cleanly (peer first, confirm
it's down, then this node).

```bash
sudo install -m 0755 gx10-thermal-watch.sh /usr/local/sbin/gx10-thermal-watch.sh
sudo cp gx10-thermal-watch.service /etc/systemd/system/gx10-thermal-watch.service
sudo systemctl daemon-reload
sudo systemctl enable --now gx10-thermal-watch.service
```

If you want the peer powered off too, edit `PEER_HOST=` in the unit (or the
`[Service]` env) to the other node's hostname and restart.

Dry-run test (watch it report without shutting down):

```bash
sudo THRESHOLD=20000 CONSECUTIVE=1 INTERVAL=1 DRY_RUN=1 /usr/local/sbin/gx10-thermal-watch.sh
```

> **Note:** do NOT run the live (non-dry-run) watchdog with a fake-low threshold
> or while a real trip is pending — it will genuinely power off the node(s).
> Also the GB10 ignores `nvidia-smi -lgc` on some units, so the clock cap is
> not a reliable cooling lever; this watchdog is the safety net.
