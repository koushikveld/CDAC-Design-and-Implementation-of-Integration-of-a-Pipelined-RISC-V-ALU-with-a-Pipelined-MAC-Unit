# Design and Implementation of Pipelining of ALU with MAC unit of RISC-V Processor

## Architecture of the Project
<img width="1537" height="1023" alt="WhatsApp Image 2026-07-21 at 20 50 38" src="https://github.com/user-attachments/assets/290a8ea0-2596-447f-aaf6-31e158ad58f7" />

# 5-Stage Pipelined RV32I ALU Core
A fully synthesizable 5-stage pipelined integer ALU implementing the RISC-V RV32I Base Integer Instruction Set.

Designed with complete data-hazard forwarding, the pipeline runs seamlessly with zero stall cycles across back-to-back dependent instructions. Additionally, it features a 64-bit wide internal result datapath that preserves arithmetic carry outputs during 32-bit addition/subtraction.

### Key Features
1. Standard RV32I ISA Compliance: Supports all standard integer R-type and I-type computational instructions.

2. Full Forwarding Network: Eliminates data hazard stalls for distances 1, 2, and 3 via EX/MEM forwarding, MEM/WB forwarding, and ID-stage write-through register bypass.

3. Extended 64-Bit Datapath: Produces 64-bit wide results (RLEN = 64) to preserve overflow/carry bits while remaining compliant with 32-bit architectural registers (XLEN = 32).

4. Hardware Illegal Instruction Detection: Automatically identifies unmapped opcodes or invalid funct3/funct7 combinations and flags illegal_instr without updating the register file.

5. Self-Checking Scoreboard Testbench: Includes a comprehensive test suite with automated test verification, back-to-back dependency chains, and register preload capabilities.

### Simulation and Verification
1. The provided testbench (riscv_alu_5stage_tb.sv) verifies functional correctness through automated verification tasks:

2. Preload Task: Populates architectural registers with test data (x1 through x10).

3. Exhaustive Testing: Tests all supported R-Type and I-Type instruction encodings.

4. Hazard Verification: Tests tight instruction sequences with back-to-back dependencies at distances 1, 2, 3, and 4.

5. Zero-Register Guard: Verifies that writes to register x0 are ignored.

6. Exception Handling: Verifies that illegal instruction patterns trigger illegal_instr without modifying register state.
<img width="1882" height="334" alt="Screenshot 2026-07-29 121406" src="https://github.com/user-attachments/assets/7dd71dbd-8998-471b-9a34-c6aad8736d08" />

# 5-Stage Pipelined 32x32-Bit Multiply-Accumulate (MAC) Unit
A high-performance 5-stage pipelined 32x32-bit Multiply-Accumulate (MAC) Unit implemented in SystemVerilog. Extended from the architecture proposed by HE Jing-yu et al. (Lanzhou University, IEEE IMSNA 2013), this module scales the original 16-bit concept up to a full 32x32-bit input datapath with a 64-bit result and accumulator.

It leverages Radix-4 Modified Booth Encoding, a 5-layer Wallace Tree Carry-Save Compressor Array, and an Explicit Split 64-bit Accumulator to achieve single-cycle throughput for intensive DSP computations and RISC processor execution units.

### Technical Features
1. High Throughput & Latency Balance:
  i. Throughput: 1 operation per clock cycle (pipelined).  
  ii. Latency: 4 clock cycles to product output (rslt_mac), 5 clock cycles to accumulator update (rslt_h, rslt_l). 
2. Radix-4 Modified Booth Algorithm: Encodes 32-bit multipliers into 16 partial products (down from 32 standard vectors), significantly reducing area and combinational path delay.
3. 5-Layer Wallace Tree Compressor Array: Compresses 16 partial product vectors down to 2 vectors (Sum and Carry) using Carry-Save Adders (CSAs) without carry-propagation delay.
5. Pipelined Carry-Propagate Addition: Performs the final 64-bit vector addition in Stage 4 prior to accumulation.
6. Split 64-bit Accumulator with Signed Overflow: Accumulates results across two 32-bit register halves (rslt_h, rslt_l) with explicit inter-stage carry propagation and signed overflow detection.

### Verification and Testbench Features :
The included self-checking SystemVerilog testbench (pipelined_booth_mac_5stage_32bit_tb.sv) provides thorough regression testing against an automated software golden reference model:
1. Explicit Corner Cases (Signed & Unsigned):
  i. Mixed signed multiplication (e.g., $-10 \times 15 = -150$)
  ii. Zero multiplication ($0 \times \text{value}$)
  iii. Positive and negative maximum boundary limits ($MaxSigned \times MaxSigned$, $MinSigned \times MinSigned$)
  iv. Boundary carry propagation across 32-bit halves into rslt_h
  v. Signed overflow flag activation test
2. 200-Vector Randomized Suite:
  i. Issues 200 randomized 32-bit signed inputs using $urandom() back-to-back at full pipeline speed (1 MAC per clock cycle) to test pipelining throughput and corner stability.
