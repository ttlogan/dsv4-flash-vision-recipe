#!/usr/bin/env python3
"""Deterministic benchmark for the 2-node DGX DeepSeek-V4-Flash-Vision lane.
Measures completion_tokens/wall_time (non-streaming) at c=1,4,8 + records ACPI temps.
Usage: bench.py --out /path/results.json [--label label] [--prompts N] 
prints JSON summary; no changes to the server.
"""
import json, time, urllib.request, sys, argparse, statistics, concurrent.futures, subprocess

BASE = "http://192.168.0.226:8000/v1"
MODEL = "orcarouter/DeepSeek-V4-Flash-Vision-Uncensored"

# Standardized, mixed, ~short prompt (the community's typical shape). Not code-heavy.
PROMPT = ("Explain what makes a city feel historic to a first-time visitor, "
          "mentioning three concrete details, in about four sentences.")

def one_call(max_tokens=320):
    body = {"model": MODEL, "messages": [{"role": "user", "content": PROMPT}],
            "max_tokens": max_tokens, "stream": False}
    req = urllib.request.Request(BASE + "/chat/completions",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=300) as r:
        d = json.load(r)
    dt = time.time() - t0
    u = d.get("usage", {})
    ct = u.get("completion_tokens") or 0
    return {"secs": dt, "completion_tokens": ct,
            "tps": (ct / dt if ct else 0.0),
            "finish": d["choices"][0].get("finish_reason")}

def load_temps():
    """Read ACPI thermal zones from leo via ssh. Returns dict zone->C and max."""
    try:
        out = subprocess.run(
            ["ssh", "-i", "/home/ttlogan/.ssh/id_ed25519_hermes_jump",
             "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
             "-o", "ConnectTimeout=15", "wfoster@192.168.0.226",
             "for z in /sys/class/thermal/thermal_zone*/temp; do cat $z; done"],
            capture_output=True, text=True, timeout=30)
        temps = [int(x.strip()) / 1000 for x in out.stdout.split() if x.strip().isdigit()]
        return {"zones_c": temps, "max_c": (max(temps) if temps else None)}
    except Exception as e:
        return {"error": str(e)}

def run_concurrency(c, reps, warmup_secs=8):
    # warm up engine (let dispatch + cudagraph settle), then measure
    time.sleep(warmup_secs)
    temps_before = load_temps()
    start = time.time()
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=c) as ex:
        futs = [ex.submit(one_call) for _ in range(c)]
        for f in concurrent.futures.as_completed(futs):
            results.append(f.result())
    wall = time.time() - start
    total_tok = sum(r["completion_tokens"] for r in results)
    aggr = total_tok / wall if wall else 0
    indiv = [r["tps"] for r in results]
    temps_after = load_temps()
    return {
        "concurrency": c,
        "wall_s": round(wall, 3),
        "total_tokens": total_tok,
        "aggregate_tps": round(aggr, 2),
        "per_stream": [round(x, 2) for x in indiv],
        "per_stream_max": round(max(indiv), 2),
        "temps_before": temps_before,
        "temps_after": temps_after,
    }

def run_soak(c, duration_secs, max_tokens=128, sample_interval=10):
    """Sustained load for duration_secs at concurrency c (short max_tokens, ~rufus's 88.8 tok/s run).
    Dispatches continuously; samples SoC temp every sample_interval. Returns agg tok/s + temp series."""
    import threading
    start = time.time()
    stop_at = start + duration_secs
    temps = []   # (t_off, max_c)
    completed = []  # resp dicts
    lock = threading.Lock()

    def sampler():
        while time.time() < stop_at:
            t = load_temps()
            with lock:
                temps.append((round(time.time() - start, 1), t.get("max_c")))
            time.sleep(sample_interval)

    def driver():
        # keep a pool of c in-flight requests until the window elapses
        with concurrent.futures.ThreadPoolExecutor(max_workers=c) as ex:
            futs = set()
            while time.time() < stop_at:
                # top up to c in-flight
                futs = {f for f in futs if not f.done()}
                while len(futs) < c and time.time() < stop_at:
                    futs.add(ex.submit(one_call, max_tokens=max_tokens))
                done, _ = concurrent.futures.wait(futs, timeout=1.0,
                                                  return_when=concurrent.futures.FIRST_COMPLETED)
                for f in done:
                    try:
                        completed.append(f.result())
                    except Exception:
                        pass
                    futs.discard(f)

    st = threading.Thread(target=sampler, daemon=True)
    dv = threading.Thread(target=driver, daemon=True)
    st.start(); dv.start()
    dv.join()
    wall = time.time() - start
    total_tok = sum(r["completion_tokens"] for r in completed)
    aggr = total_tok / wall if wall else 0
    temp_series = [t for t in temps if t[1] is not None]
    return {
        "mode": "soak",
        "concurrency": c,
        "duration_s": round(wall, 1),
        "requests": len(completed),
        "total_tokens": total_tok,
        "aggregate_tps": round(aggr, 2),
        "temp_series": [(round(a, 1), b) for a, b in temp_series],
        "temp_max": round(max((b for _, b in temp_series), default=0), 1),
        "temp_steady_hi": round(max((b for _, b in temp_series[-5:]), default=0), 1) if temp_series else None,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--label", default="baseline")
    ap.add_argument("--concs", default="1,4,8")
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--soak", action="store_true", help="sustained soak at 12 concurrent, 128-token")
    ap.add_argument("--soak-secs", type=int, default=600)
    args = ap.parse_args()
    if args.soak:
        r = run_soak(12, args.soak_secs)
        results = {"label": args.label, "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
                   "model": MODEL, "mode": "soak", "run": r}
        with open(args.out, "w") as f:
            json.dump(results, f, indent=2)
        print(f"SOAK c=12 for {args.soak_secs}s: agg={r['aggregate_tps']} tok/s, "
              f"reqs={r['requests']}, temp_max={r['temp_max']}C, "
              f"steady_hi={r['temp_steady_hi']}C")
        print(f"WROTE {args.out}")
        return
    concs = [int(x) for x in args.concs.split(",")]
    results = {"label": args.label, "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
               "model": MODEL, "prompt_chars": len(PROMPT), "runs": []}
    for c in concs:
        r = run_concurrency(c, args.reps)
        results["runs"].append(r)
        print(f"c={c}: agg={r['aggregate_tps']} tok/s, per-stream={r['per_stream']}, "
              f"max_temp_after={r['temps_after'].get('max_c')}C")
    with open(args.out, "w") as f:
        json.dump(results, f, indent=2)
    print(f"WROTE {args.out}")

if __name__ == "__main__":
    main()
