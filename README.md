# Design and Implementation of Integration of a Pipelined RISC-V ALU with a Pipelined MAC Unit
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
<img width="656" height="916" alt="image" src="https://github.com/user-attachments/assets/4aac4a85-4aa7-4e9b-b184-9065fda59b0c" />

<img width="693" height="865" alt="image" src="https://github.com/user-attachments/assets/5f6cebc5-83ca-4fc5-b3b0-436dacdbceb2" />

<img width="839" height="834" alt="image" src="https://github.com/user-attachments/assets/5bf57281-50eb-447d-b5f7-7fb686f5cf6f" />

<img width="605" height="478" alt="image" src="https://github.com/user-attachments/assets/cab7da08-28fa-469b-b9ec-54f9c70a06ba" />

<img width="570" height="394" alt="image" src="https://github.com/user-attachments/assets/7ab8b081-b5f9-4def-b9c7-be77f5060643" />

<img width="562" height="439" alt="image" src="https://github.com/user-attachments/assets/8773326f-65c2-466a-8bb2-b8b49d5cd94e" />



# 5-Stage Pipelined 32x32-Bit Multiply-Accumulate (MAC) Unit
A high-performance 5-stage pipelined 32x32-bit Multiply-Accumulate (MAC) Unit implemented in SystemVerilog. Extended from the architecture proposed by HE Jing-yu et al. (Lanzhou University, IEEE IMSNA 2013), this module scales the original 16-bit concept up to a full 32x32-bit input datapath with a 64-bit result and accumulator.

It leverages Radix-4 Modified Booth Encoding, a 5-layer Wallace Tree Carry-Save Compressor Array, and an Explicit Split 64-bit Accumulator to achieve single-cycle throughput for intensive DSP computations and RISC processor execution units.

### Technical Features
1. High Throughput & Latency Balance:

    i. Throughput: 1 operation per clock cycle (pipelined).  
  
    ii. Latency: 4 clock cycles to product output (rslt_mac), 5 clock cycles to accumulator update (rslt_h, rslt_l). 
  
3. Radix-4 Modified Booth Algorithm: Encodes 32-bit multipliers into 16 partial products (down from 32 standard vectors), significantly reducing area and combinational path delay.

4. 5-Layer Wallace Tree Compressor Array: Compresses 16 partial product vectors down to 2 vectors (Sum and Carry) using Carry-Save Adders (CSAs) without carry-propagation delay.

5. Pipelined Carry-Propagate Addition: Performs the final 64-bit vector addition in Stage 4 prior to accumulation.

6. Split 64-bit Accumulator with Signed Overflow: Accumulates results across two 32-bit register halves (rslt_h, rslt_l) with explicit inter-stage carry propagation and signed overflow detection.

### Verification and Testbench Features :
The included self-checking SystemVerilog testbench (pipelined_booth_mac_5stage_32bit_tb.sv) provides thorough regression testing against an automated software golden reference model:
1. Explicit Corner Cases (Signed & Unsigned):

    i. Mixed signed multiplication (e.g., $-10 \times 15 = -150$)
  
    ii. Zero multiplication ($0 \times \text{value}$). 
  
    iii. Positive and negative maximum boundary limits ($MaxSigned \times MaxSigned$, $MinSigned \times MinSigned$)
  
    iv. Boundary carry propagation across 32-bit halves into rslt_h
  
    v. Signed overflow flag activation test
  
2. 200-Vector Randomized Suite:

   i. Issues 200 randomized 32-bit signed inputs using $urandom() back-to-back at full pipeline speed (1 MAC per clock cycle) to test pipelining throughput and corner stability.

<img width="1107" height="896" alt="image" src="https://github.com/user-attachments/assets/82526f58-000e-491b-80a9-76865c0dd911" />

# Integration of a Pipelined RISC-V ALU with a Pipelined MAC Unit

<img width="1537" height="1023" alt="WhatsApp Image 2026-07-21 at 20 50 38" src="https://github.com/user-attachments/assets/290a8ea0-2596-447f-aaf6-31e158ad58f7" />

### Architecture Overview
The execution unit augments a standard 5-stage RISC-V integer pipeline by routing compute-intensive arithmetic operations through parallel, pipelined datapath stages. To minimize critical path delay during multi-cycle arithmetic computations while sustaining high instruction throughput, the architecture incorporates:

1. Pipelined ALU: Handles standard RV32I base integer operations (logical, shifts, arithmetic, comparisons, branching flags) across balanced pipeline sub-stages.

2. Radix-4 Modified Booth Multiplier: Reduces the number of generated partial products to [(N+1)/2], cutting dynamic switching power and routing congestion.

3. Wallace Tree Adder Matrix: Employs Carry-Save Adders (CSA) to compress partial products concurrently in logarithmic time O(log n), minimizing carry-propagation delay before the final addition.

4. Pipelined Accumulator: Integrates a registered feedback accumulation stage supporting both continuous single-cycle MAC streams (A x B + C) and standard integer multiply-low/high instructions.

5. Throughput & Latency: Sustains a steady-state throughput of 1.0 Instruction Per Clock Cycle (IPC) with fully forward-compatible hazard mitigation.

### Verification Coverage

The design was verified using a directed and constrained-random System Verilog verification suite :

1. Corner-Case test suite : Validates overflow/underflow conditions, maximum negative operands (2^31), zero operand cases, and alternating signed/unsigned bit patterns.
