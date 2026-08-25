import subprocess
import os
import shutil
import argparse

# Constants for fixed parameters as per your requirements
FIXED_WAYS = 2
FIXED_INDEX = 4
FIXED_POLICY = 1 # LRU

'''
To simulate a single icache config (will use fixed dcache params):
python3 sweep_single.py --mode icache --bench perf_benchmarks/fft.c --w 4 --i 6 --p 2
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
    print(f"\nRunning Single Test: {os.path.basename(bench)}")
    print(f"   I-Cache: W{iw} I{idx} P{ipol} | D-Cache: W{dw} I{ddx} P{dpol}")

    result = subprocess.run(
        ["make", "verify", f"TEST={bench}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True
    )

    if result.returncode != 0:
        print("Simulation failed!")
        return

    # 3. Rename and move
    #  file
    bench_clean = os.path.basename(bench).replace(".c", "")
    result_filename = f"{bench_clean}_{iw}_{idx}_{ipol}_{dw}_{ddx}_{dpol}.csv"

    target_dir = os.path.join("sweeps")
    target_path = os.path.join(target_dir, result_filename)
    os.makedirs(target_dir, exist_ok=True)

    temp_path = os.path.join("output", "simulation", "temp_results.csv")

    if os.path.exists(temp_path):
        shutil.move(temp_path, target_path)
        print(f"Result saved to: {target_path}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run a single simulation with fixed defaults for the opposite cache.")

    # Required setup
    parser.add_argument("--mode", choices=["icache", "dcache"], required=True,
                        help="Which cache parameters you are providing.")
    parser.add_argument("--bench", type=str, required=True, help="Path to benchmark")

    # Parameters for the active cache
    parser.add_argument("--w", type=int, required=True, help="Ways (2 or 4)")
    parser.add_argument("--i", type=int, required=True, help="Index Bits (2, 4, or 6)")
    parser.add_argument("--p", type=int, required=True, help="Policy (1:LRU, 2:MRU)")

    args = parser.parse_args()

    if args.mode == "icache":
        # User provides I-cache params; D-cache is fixed
        run_simulation(args.bench, args.w, args.i, args.p, FIXED_WAYS, FIXED_INDEX, FIXED_POLICY)
    else:
        # User provides D-cache params; I-cache is fixed
        run_simulation(args.bench, FIXED_WAYS, FIXED_INDEX, FIXED_POLICY, args.w, args.i, args.p)
