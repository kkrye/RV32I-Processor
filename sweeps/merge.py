import csv
import glob
import os

def combine_cache_results(output_filename="final_results.csv", input_pattern="*.csv"):
    # Updated header to include the Benchmark name
    header = [
        "Benchmark", "I_WAYS", "I_INDEX", "I_POLICY",
        "D_WAYS", "D_INDEX", "D_POLICY",
        "Cycles", "Instr_Fetched",
        "D_Hits", "D_Misses", "D_Evictions",
        "I_Hits", "I_Misses", "I_Evictions",
        "Conflicts", "Rewinds",
        "D_Mem_Reqs", "I_Mem_Reqs"
    ]

    all_data = []
    files = glob.glob(input_pattern)
    files = [f for f in files if f != output_filename]

    if not files:
        print("No CSV files found.")
        return

    print(f"Processing {len(files)} files...")

    for file_path in files:
        # Get filename (e.g., 'fft_2_4_1_2_6_2.csv')
        filename = os.path.basename(file_path)
        # Extract benchmark name (e.g., 'fft')
        benchmark_name = filename.split('_')[0]

        with open(file_path, 'r') as f:
            reader = csv.reader(f)
            for row in reader:
                if row:
                    # Prepend the benchmark name to the data row
                    row_with_bench = [benchmark_name] + row
                    all_data.append(row_with_bench)

    # Write to master file
    with open(output_filename, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(header)
        writer.writerows(all_data)

    print(f"Done! Results combined into {output_filename}")

if __name__ == "__main__":
    combine_cache_results()
