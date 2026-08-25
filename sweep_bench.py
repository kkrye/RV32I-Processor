import subprocess
import os
import shutil
import argparse
import itertools

# Constants for fixed parameters
FIXED_WAYS = 2
FIXED_INDEX = 4
FIXED_POLICY = 1 # LRU

# Search space for the sweep
SWEEP_WAYS = [2, 4]
SWEEP_INDEX = [2, 4, 6]
SWEEP_POLICIES = [1, 2] # 1: LRU, 2: MRU

'''
To sweep a benchmark's icache AND dcache:
python3 sweep_bench.py --bench perf_benchmarks/fft.c
'''

def run_simulation(bench, iw, idx, ipol, dw, ddx, dpol):
    # 1. Update parameters.vh
    content = f"""`ifndef L1_POLICIES
`define L1_POLICIES
parameter INSTR_BLOCK_OFFSET_BITS = 2;
parameter INSTR_CACHE_WAYS = {iw};
parameter INSTR_CACHE_INDEX_BITS = {idx};
parameter INSTR_CACHE_POLICY = {ipol};
parameter DATA_BLOCK_OFFSET_BITS = 2;
parameter DATA_CACHE_WAYS = {dw};
parameter DATA_CACHE_INDEX_BITS = {ddx};
parameter DATA_CACHE_POLICY = {dpol};
`endif"""
    
    with open("./src/parameters.vh", "w") as f:
        f.write(content)

    # 2. Run simulation
    print(f"   Simulating -> I: W{iw} I{idx} P{ipol} | D: W{dw} I{ddx} P{dpol}")
    
    result = subprocess.run(
        ["make", "verify", f"TEST={bench}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True
    )

    if result.returncode != 0:
        print(f"      [!] Simulation failed for {os.path.basename(bench)}")
        return

    # 3. Rename and move output file
    bench_clean = os.path.basename(bench).replace(".c", "")
    result_filename = f"{bench_clean}_{iw}_{idx}_{ipol}_{dw}_{ddx}_{dpol}.csv"
    
    target_dir = os.path.join("sweeps")
    target_path = os.path.join(target_dir, result_filename)
    os.makedirs(target_dir, exist_ok=True)

    temp_path = os.path.join("output", "simulation", "temp_results.csv")

    if os.path.exists(temp_path):
        shutil.move(temp_path, target_path)
    else:
        print("      [!] Warning: temp_results.csv not found.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run independent I-cache and D-cache sweeps for a benchmark.")
    parser.add_argument("--bench", type=str, required=True, help="Path to benchmark")
    args = parser.parse_args()

    # Generate the 12 configurations (2 ways * 3 index sizes * 2 policies)
    cache_configs = list(itertools.product(SWEEP_WAYS, SWEEP_INDEX, SWEEP_POLICIES))
    
    print(f"\n=== Starting Sequential Sweeps on {os.path.basename(args.bench)} ===")

    # Phase 1: I-Cache Sweep
    print(f"\n--- Phase 1: I-Cache Sweep (D-Cache Fixed at W{FIXED_WAYS} I{FIXED_INDEX} P{FIXED_POLICY}) ---")
    for i, (w, idx, p) in enumerate(cache_configs, 1):
        print(f"[{i}/{len(cache_configs)}]", end=" ")
        run_simulation(args.bench, w, idx, p, FIXED_WAYS, FIXED_INDEX, FIXED_POLICY)

    # Phase 2: D-Cache Sweep
    print(f"\n--- Phase 2: D-Cache Sweep (I-Cache Fixed at W{FIXED_WAYS} I{FIXED_INDEX} P{FIXED_POLICY}) ---")
    for i, (w, idx, p) in enumerate(cache_configs, 1):
        # Check if this config is identical to the fixed baseline already run in Phase 1
        if w == FIXED_WAYS and idx == FIXED_INDEX and p == FIXED_POLICY:
            print(f"[{i}/{len(cache_configs)}] Skipping baseline (already simulated in Phase 1)")
            continue
            
        print(f"[{i}/{len(cache_configs)}]", end=" ")
        run_simulation(args.bench, FIXED_WAYS, FIXED_INDEX, FIXED_POLICY, w, idx, p)

    print(f"\n=== All Sweeps Complete. Check sweeps/ ===")