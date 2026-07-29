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
