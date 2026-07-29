5-Stage Pipelined RV32I ALU Core
A fully synthesizable 5-stage pipelined integer ALU implementing the RISC-V RV32I Base Integer Instruction Set.

Designed with complete data-hazard forwarding, the pipeline runs seamlessly with zero stall cycles across back-to-back dependent instructions. Additionally, it features a 64-bit wide internal result datapath that preserves arithmetic carry outputs during 32-bit addition/subtraction.

Key Features
Standard RV32I ISA Compliance: Supports all standard integer R-type and I-type computational instructions.

Full Forwarding Network: Eliminates data hazard stalls for distances 1, 2, and 3 via EX/MEM forwarding, MEM/WB forwarding, and ID-stage write-through register bypass.

Extended 64-Bit Datapath: Produces 64-bit wide results (RLEN = 64) to preserve overflow/carry bits while remaining compliant with 32-bit architectural registers (XLEN = 32).

Hardware Illegal Instruction Detection: Automatically identifies unmapped opcodes or invalid funct3/funct7 combinations and flags illegal_instr without updating the register file.

Self-Checking Scoreboard Testbench: Includes a comprehensive test suite with automated test verification, back-to-back dependency chains, and register preload capabilities.
