# 5-Stage Pipelined RV32I ALU Core
A fully synthesizable 5-stage pipelined integer ALU implementing the RISC-V RV32I Base Integer Instruction Set.

Designed with complete data-hazard forwarding, the pipeline runs seamlessly with zero stall cycles across back-to-back dependent instructions. Additionally, it features a 64-bit wide internal result datapath that preserves arithmetic carry outputs during 32-bit addition/subtraction.
