`timescale 1ns / 1ps
//=============================================================================
// riscv_alu_5stage
//
//   A genuine RV32I integer-ALU pipeline. It accepts real 32-bit RISC-V
//   instruction words and decodes them per the unprivileged ISA spec.
//
//   Supported instructions
//     OP     (opcode 0110011, R-type) : ADD  SUB  SLL  SLT  SLTU
//                                       XOR  SRL  SRA  OR   AND
//     OP-IMM (opcode 0010011, I-type) : ADDI SLTI SLTIU XORI ORI ANDI
//                                       SLLI SRLI SRAI
//
//   Pipeline
//     S1 IF/ID  : capture the instruction word
//     S2 ID/EX  : decode fields, read register file, sign-extend immediate
//     S3 EX/MEM : 64-bit ALU
//     S4 MEM/WB : result transport (placeholder for a future LSU)
//     S5 WB     : register file update
//
//   Hazard handling: full forwarding, no stalls required.
//     distance 1 -> forwarded from MEM at the ALU input
//     distance 2 -> forwarded from WB  at the ALU input
//     distance 3 -> write-through bypass on the register read
//     distance 4+ -> ordinary register file read
//
//   Project extension: the result bus is 64 bits so a 32+32 addition keeps
//   its carry. Architectural registers remain 32 bits per RV32I, so the
//   writeback stores only result[31:0].
//=============================================================================

module riscv_alu_5stage #(
    parameter int XLEN = 32,
    parameter int RLEN = 2 * XLEN
)(
    input  logic            clk,
    input  logic            reset,

    // instruction issue
    input  logic [31:0]     instr,
    input  logic            instr_valid,

    // writeback-stage result
    output logic [RLEN-1:0] result,
    output logic [4:0]      result_rd,
    output logic            result_valid,
    output logic            illegal_instr,

    // debug / simulation register preload (tie init_en low for synthesis)
    input  logic            init_en,
    input  logic [4:0]      init_addr,
    input  logic [XLEN-1:0] init_data
);

    // ------------------------------------------------------------------------
    // RV32I encoding constants
    // ------------------------------------------------------------------------
    localparam logic [6:0] OPC_OP     = 7'b0110011;  // register-register
    localparam logic [6:0] OPC_OP_IMM = 7'b0010011;  // register-immediate

    localparam logic [6:0] F7_BASE    = 7'b0000000;
    localparam logic [6:0] F7_ALT     = 7'b0100000;  // selects SUB and SRA

    typedef enum logic [3:0] {
        ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
        ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR,  ALU_AND
    } alu_op_e;

    // ------------------------------------------------------------------------
    // Architectural state
    // ------------------------------------------------------------------------
    logic [XLEN-1:0] regbank [0:31];

    // Pipeline-register declarations hoisted here: the ID-stage read bypass
    // and the EX forwarding network both reference the MEM and WB stages.
    logic [RLEN-1:0] m_result;
    logic [4:0]      m_rd;
    logic            m_valid, m_illegal;

    logic [RLEN-1:0] w_result;
    logic [4:0]      w_rd;
    logic            w_valid, w_illegal;

    // ------------------------------------------------------------------------
    // S1: IF/ID
    // ------------------------------------------------------------------------
    logic [31:0] d_instr;
    logic        d_valid;

    always_ff @(posedge clk) begin
        if (reset) begin
            d_instr <= 32'h0000_0013;   // NOP: addi x0, x0, 0
            d_valid <= 1'b0;
        end else begin
            d_instr <= instr;
            d_valid <= instr_valid;
        end
    end

    // ------------------------------------------------------------------------
    // S2: decode + register read
    // ------------------------------------------------------------------------
    logic [6:0]      d_opcode, d_funct7;
    logic [2:0]      d_funct3;
    logic [4:0]      d_rs1, d_rs2, d_rd;
    logic [XLEN-1:0] d_imm_i;

    assign d_opcode = d_instr[6:0];
    assign d_rd     = d_instr[11:7];
    assign d_funct3 = d_instr[14:12];
    assign d_rs1    = d_instr[19:15];
    assign d_rs2    = d_instr[24:20];
    assign d_funct7 = d_instr[31:25];
    // I-type immediate: instr[31:20], sign-extended.
    // For SLLI/SRLI/SRAI the low 5 bits of this field are the shift amount,
    // so no separate shamt path is needed.
    assign d_imm_i  = {{(XLEN-12){d_instr[31]}}, d_instr[31:20]};

    logic d_is_r, d_is_i;
    assign d_is_r = (d_opcode == OPC_OP);
    assign d_is_i = (d_opcode == OPC_OP_IMM);

    // Register read, with write-through bypass of the WB stage
    // (this is what covers a distance-3 dependency).
    logic [XLEN-1:0] d_rs1_val, d_rs2_val, d_operand_b;

    assign d_rs1_val = (d_rs1 == 5'd0)                             ? '0            :
                       (w_valid && (w_rd == d_rs1) && (w_rd != 0)) ? w_result[XLEN-1:0]
                                                                   : regbank[d_rs1];
    assign d_rs2_val = (d_rs2 == 5'd0)                             ? '0            :
                       (w_valid && (w_rd == d_rs2) && (w_rd != 0)) ? w_result[XLEN-1:0]
                                                                   : regbank[d_rs2];
    assign d_operand_b = d_is_r ? d_rs2_val : d_imm_i;

    // ALU operation select
    alu_op_e d_alu_op;
    logic    d_illegal;

    always_comb begin
        // funct3 picks the operation; bit 30 of the instruction (funct7[5])
        // distinguishes ADD/SUB and SRL/SRA.
        case (d_funct3)
            3'b000: d_alu_op = (d_is_r && d_funct7[5]) ? ALU_SUB : ALU_ADD;
            3'b001: d_alu_op = ALU_SLL;
            3'b010: d_alu_op = ALU_SLT;
            3'b011: d_alu_op = ALU_SLTU;
            3'b100: d_alu_op = ALU_XOR;
            3'b101: d_alu_op = d_funct7[5] ? ALU_SRA : ALU_SRL;
            3'b110: d_alu_op = ALU_OR;
            default: d_alu_op = ALU_AND;          // 3'b111
        endcase

        // Legality: reject anything outside the two supported opcodes and
        // any reserved funct7 pattern.
        d_illegal = 1'b0;
        if (!(d_is_r || d_is_i)) begin
            d_illegal = 1'b1;
        end else if (d_is_r) begin
            if (!((d_funct7 == F7_BASE) ||
                  ((d_funct7 == F7_ALT) &&
                   ((d_funct3 == 3'b000) || (d_funct3 == 3'b101)))))
                d_illegal = 1'b1;
        end else begin
            // I-type: only the shift instructions constrain the upper bits
            if ((d_funct3 == 3'b001) && (d_funct7 != F7_BASE))
                d_illegal = 1'b1;
            if ((d_funct3 == 3'b101) &&
                !((d_funct7 == F7_BASE) || (d_funct7 == F7_ALT)))
                d_illegal = 1'b1;
        end
    end

    // ID/EX pipeline register
    logic [XLEN-1:0] e_a, e_b;
    logic [4:0]      e_rs1, e_rs2, e_rd;
    alu_op_e         e_alu_op;
    logic            e_valid, e_illegal, e_uses_rs2;

    always_ff @(posedge clk) begin
        if (reset) begin
            e_a <= '0;  e_b <= '0;
            e_rs1 <= '0; e_rs2 <= '0; e_rd <= '0;
            e_alu_op   <= ALU_ADD;
            e_valid    <= 1'b0;
            e_illegal  <= 1'b0;
            e_uses_rs2 <= 1'b0;
        end else begin
            e_a        <= d_rs1_val;
            e_b        <= d_operand_b;
            e_rs1      <= d_rs1;
            e_rs2      <= d_rs2;
            e_rd       <= d_rd;
            e_alu_op   <= d_alu_op;
            e_valid    <= d_valid && !d_illegal;
            e_illegal  <= d_valid &&  d_illegal;
            e_uses_rs2 <= d_is_r;
        end
    end

    // ------------------------------------------------------------------------
    // S3: forwarding network + 64-bit ALU
    // ------------------------------------------------------------------------
    logic [XLEN-1:0] op_a, op_b;

    always_comb begin
        op_a = e_a;
        if (e_valid && (e_rs1 != 5'd0)) begin
            if      (m_valid && (m_rd == e_rs1) && (m_rd != 0)) op_a = m_result[XLEN-1:0];
            else if (w_valid && (w_rd == e_rs1) && (w_rd != 0)) op_a = w_result[XLEN-1:0];
        end

        op_b = e_b;
        if (e_valid && e_uses_rs2 && (e_rs2 != 5'd0)) begin
            if      (m_valid && (m_rd == e_rs2) && (m_rd != 0)) op_b = m_result[XLEN-1:0];
            else if (w_valid && (w_rd == e_rs2) && (w_rd != 0)) op_b = w_result[XLEN-1:0];
        end
    end

    // Width extension before the operation, so a carry cannot be lost
    logic [RLEN-1:0] a_zext, b_zext, a_sext;
    logic [4:0]      shamt;

    assign a_zext = {{XLEN{1'b0}},        op_a};
    assign b_zext = {{XLEN{1'b0}},        op_b};
    assign a_sext = {{XLEN{op_a[XLEN-1]}}, op_a};
    assign shamt  = op_b[4:0];

    // EX/MEM pipeline register
    always_ff @(posedge clk) begin
        if (reset) begin
            m_result  <= '0;
            m_rd      <= '0;
            m_valid   <= 1'b0;
            m_illegal <= 1'b0;
        end else begin
            case (e_alu_op)
                ALU_ADD:  m_result <= a_zext + b_zext;
                ALU_SUB:  m_result <= a_zext - b_zext;
                ALU_AND:  m_result <= a_zext & b_zext;
                ALU_OR:   m_result <= a_zext | b_zext;
                ALU_XOR:  m_result <= a_zext ^ b_zext;
                ALU_SLL:  m_result <= a_zext << shamt;
                ALU_SRL:  m_result <= a_zext >> shamt;
                ALU_SRA:  m_result <= $signed(a_sext) >>> shamt;
                ALU_SLT:  m_result <= ($signed(op_a) < $signed(op_b)) ? 64'd1 : 64'd0;
                ALU_SLTU: m_result <= (op_a < op_b)                   ? 64'd1 : 64'd0;
                default:  m_result <= '0;
            endcase
            m_rd      <= e_rd;
            m_valid   <= e_valid;
            m_illegal <= e_illegal;
        end
    end

    // ------------------------------------------------------------------------
    // S4: MEM/WB  (transport stage - a load/store unit would live here)
    // ------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            w_result  <= '0;
            w_rd      <= '0;
            w_valid   <= 1'b0;
            w_illegal <= 1'b0;
        end else begin
            w_result  <= m_result;
            w_rd      <= m_rd;
            w_valid   <= m_valid;
            w_illegal <= m_illegal;
        end
    end

    assign result        = w_result;
    assign result_rd     = w_rd;
    assign result_valid  = w_valid;
    assign illegal_instr = w_illegal;

    // ------------------------------------------------------------------------
    // S5: register file writeback - the only driver of regbank.
    //     x0 is hardwired to zero, so writes to it are discarded.
    // ------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 32; i++) regbank[i] <= '0;
        end else if (init_en) begin
            regbank[init_addr] <= init_data;
        end else if (w_valid && (w_rd != 5'd0)) begin
            regbank[w_rd] <= w_result[XLEN-1:0];
        end
    end

endmodule
