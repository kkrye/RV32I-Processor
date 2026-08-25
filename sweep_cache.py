import subprocess
import os
import shutil
import argparse
import itertools

# Constants for fixed parameters as per your requirements
FIXED_WAYS = 4
FIXED_INDEX = 6
FIXED_POLICY = 1 # LRU

# Search space for the sweep
SWEEP_WAYS = [2, 4]
SWEEP_INDEX = [2, 4, 6]
SWEEP_POLICIES = [1, 2] # 1: LRU, 2: MRU

'''
To sweep a benchmark's icache OR dcache (will use fixed params for other cache):
python3 sweep_cache.py --mode icache --bench perf_benchmarks/fft.c
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
    parser = argparse.ArgumentParser(description="Sweep all cache parameters for a specific benchmark.")
    
    parser.add_argument("--mode", choices=["icache", "dcache"], required=True, 
                        help="Which cache to sweep (the other remains fixed).")
    parser.add_argument("--bench", type=str, required=True, help="Path to benchmark (e.g., perf_benchmarks/fft.c)")

    args = parser.parse_args()

    print(f"\n--- Starting {args.mode} Sweep on {os.path.basename(args.bench)} ---")

    # Generate all combinations of the sweep space
    combinations = list(itertools.product(SWEEP_WAYS, SWEEP_INDEX, SWEEP_POLICIES))
    total = len(combinations)

    for i, (w, idx, p) in enumerate(combinations, 1):
        print(f"[{i}/{total}]", end=" ")
        if args.mode == "icache":
            # Sweep I-cache, D-cache stays fixed
            run_simulation(args.bench, w, idx, p, FIXED_WAYS, FIXED_INDEX, FIXED_POLICY)
        else:
            # Sweep D-cache, I-cache stays fixed
            run_simulation(args.bench, FIXED_WAYS, FIXED_INDEX, FIXED_POLICY, w, idx, p)

    print(f"\n--- Sweep Complete. Results saved in /sweeps/ ---")
