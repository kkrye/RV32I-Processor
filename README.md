# RV32I 7-Stage Pipelined Processor

A synthesizable 32-bit RISC-V processor implemented in SystemVerilog for Carnegie Mellon University's **18-447: Computer Architecture**. The design combines a seven-stage pipeline, data forwarding, dynamic branch prediction, separate instruction and data caches, and arbitration over a shared long-latency memory interface.

## Architecture

The processor uses the following seven-stage pipeline:

1. **IF1** — Generate the fetch address and access the branch predictor/BTB
2. **IF2** — Receive the instruction-cache response
3. **ID** — Decode the instruction and read the register file
4. **EX** — Execute ALU operations, evaluate branches, and calculate addresses
5. **MEM1** — Begin data-memory operations
6. **MEM2** — Receive load data and resolve cache-dependent operations
7. **WB** — Commit results to the architectural register file

Pipeline control logic preserves correctness during data hazards, cache misses, control-flow redirects, and simultaneous instruction/data memory activity. The design supports operand forwarding, targeted stalls, bubble insertion, pipeline flushing, and cancellation of wrong-path instruction requests.

## Key Features

- Seven-stage in-order RV32I pipeline written in SystemVerilog
- Forwarding and hazard detection for register and load-use dependencies
- Branch target buffer and configurable local-history branch predictor
- Pipeline recovery and instruction-fetch cancellation after mispredictions
- Separate, configurable set-associative L1 instruction and data caches
- Direct-mapped, LRU, and MRU cache replacement policies
- Arbitration between instruction- and data-cache requests over one memory port
- Data-cache prioritization for loads, stores, and miss handling
- Hardware performance counters for cycles, retired instructions, branches, cache activity, and memory conflicts
- Python scripts for cache-configuration and benchmark sweeps
- Synthesis reports for timing, power, and area analysis

## Final Cache Configuration

| Cache | Associativity | Sets | Block Size | Replacement Policy |
|---|---:|---:|---:|---|
| Instruction cache | 2-way | 64 | 4 words | LRU |
| Data cache | 2-way | 16 | 4 words | LRU |

The final configuration was selected using benchmark-driven sweeps across associativity, index size, and replacement policy. Four-way caches produced limited performance improvement for most workloads while increasing power consumption, making the two-way configuration a better overall tradeoff.

## Optimization Highlights

- Reduced the target clock period from **4.4 ns to 3.28 ns**, corresponding to an approximately **34% increase in maximum frequency**
- Pipelined instruction-cache flush and cancellation control to shorten the fetch-side critical path
- Moved selected forwarding paths toward decode to reduce execute-stage timing pressure
- Reduced cache-controller latency by bypassing unnecessary request queuing
- Evaluated local, gshare, and TAGE-style branch predictors
- Selected a compact local-history predictor for its performance-to-overhead balance
- Swept cache parameters across representative FFT and graph-processing benchmarks

## Synthesis Results

The final design was synthesized using Synopsys Design Compiler under the course ASIC timing model.

| Metric | Result |
|---|---:|
| Target clock period | 3.28 ns |
| Reported timing slack | +0.14 ns |
| Total power | 359.86 mW |
| Total cell area | 1.37 mm² |

These results are specific to the technology library, memory models, and synthesis constraints provided by the course.

## Repository Structure

```text
src/
  riscv_core.sv             Pipeline datapath and control
  riscv_core_interface.sv   Core, cache, and memory integration
  stages.sv                 Pipeline-stage logic
  core_units.sv             ALU, forwarding, hazards, and branch prediction
  riscv_decode.sv           RV32I instruction decoder
  cache_new.sv              Configurable set-associative cache
  cache_controller_new.sv   Cache request and miss controller
  parameters.vh             Instruction and data cache configuration

447inputs/                  Assembly tests and expected register states
benchmarks/                 Functional C benchmarks
perf_benchmarks/            Performance workloads
sweeps/                     Cache-sweep results
sweep_cache.py              Cache-parameter sweep utility
lab4b_timing.rpt            Final timing report
lab4b_power.rpt             Final power report
lab4b_area.rpt              Final area report
REPORT_4b.pdf               Design and optimization report
```

## Running the Project

The original build environment targets CMU ECE Linux machines and depends on the course-provided RISC-V toolchain, Synopsys VCS, and Synopsys Design Compiler.

### Set Up the Environment

```bash
source /afs/ece.cmu.edu/class/ece447/bin/447setup
```

### Run a Simulation

```bash
make sim TEST=447inputs/additest.S
```

### Verify Architectural State

```bash
make verify TEST=447inputs/additest.S
```

### Run the Functional Test Suite

```bash
make autograde
```

### Launch the DVE Waveform Viewer

```bash
make sim-gui TEST=447inputs/additest.S
```

### Run a Performance Benchmark

```bash
make verify TEST=perf_benchmarks/fft.c
```

### Sweep Cache Parameters

To sweep the instruction cache:

```bash
python3 sweep_cache.py --mode icache --bench perf_benchmarks/fft.c
```

To sweep the data cache:

```bash
python3 sweep_cache.py --mode dcache --bench perf_benchmarks/fft.c
```

Sweep results are written to the `sweeps/` directory.

### Run Synthesis

```bash
make synth CLOCK_PERIOD=3.28
```

Generated timing, power, and area reports are placed under `output/synthesis/`.

## Verification

The processor was tested using directed assembly programs covering:

- Arithmetic and logical instructions
- Shift operations
- Conditional branches
- Jumps and control flow
- Byte, halfword, and word loads
- Byte, halfword, and word stores
- System instructions
- Data dependencies and forwarding cases

Larger C benchmarks were used to validate pipeline behavior and evaluate cache and branch-prediction performance. Register-state results were compared against reference dumps, with cycle-level trace verification and waveform inspection used for debugging.

## Technologies

- SystemVerilog
- RISC-V RV32I
- Python
- Synopsys VCS
- Synopsys DVE
- Synopsys Design Compiler
- RISC-V GCC toolchain

## Acknowledgments

Developed as a team project for **18-447: Computer Architecture** at Carnegie Mellon University. Course infrastructure, testbenches, memory models, and portions of the starter code were provided by the course staff.
