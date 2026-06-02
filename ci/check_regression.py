#!/usr/bin/env python3
"""Check benchmark output against a baseline. Fails on >5% regression."""
import json, sys

def load_baseline(path):
    with open(path) as f:
        return json.load(f)

def load_results(path):
    out = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line.startswith("{"):
                continue
            obj = json.loads(line)
            name = obj.get("benchmark")
            if name:
                out[name] = obj
    return out

def main():
    baseline = load_baseline(sys.argv[1])
    actual = load_results(sys.argv[2])
    failed = False
    for name, base in baseline.items():
        act = actual.get(name)
        if not act:
            print(f"FAIL: missing benchmark {name}")
            failed = True
            continue
        base_pps = base.get("points_per_sec", 0)
        act_pps = act.get("points_per_sec", 0)
        if base_pps > 0 and act_pps > 0:
            ratio = act_pps / base_pps
            if ratio < 0.95:
                print(f"FAIL: {name} throughput regressed to {ratio*100:.1f}% "
                      f"({act_pps:.0f} vs {base_pps:.0f} pps)")
                failed = True
            else:
                print(f"OK:  {name} throughput {ratio*100:.1f}%")
        else:
            base_us = base.get("us_per_scan", 0)
            act_us = act.get("us_per_scan", 0)
            if base_us > 0 and act_us > base_us * 1.05:
                print(f"FAIL: {name} latency regressed {act_us:.2f} vs {base_us:.2f} us/scan")
                failed = True
            else:
                print(f"OK:  {name} latency")
    sys.exit(1 if failed else 0)

if __name__ == "__main__":
    main()
