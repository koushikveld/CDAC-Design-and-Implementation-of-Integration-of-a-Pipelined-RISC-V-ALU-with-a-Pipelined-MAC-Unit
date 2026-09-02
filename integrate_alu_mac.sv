`timescale 1ns / 1ps
//=============================================================================
// Integrated 5-Stage RISC-V Processor with ALU + MAC Execution Stage
//
// MODIFIED VERSION:
//   - Real 5-stage logarithmic barrel shifter used by the ALU
//   - Real radix-4 signed Booth recoding multiplier used by MAC/MUL
//   - ALU and MAC/MUL remain integrated in the same EX stage
//
// Architecture:
//   IF -> ID -> EX (ALU/MAC Parallel) -> MEM -> WB
//
// Architectural width : 32 bits
// Product/accumulator : 64 bits
//=============================================================================


//=============================================================================
// 1. 5-STAGE LOGARITHMIC BARREL SHIFTER
//
// Five 2:1 mux stages implement shifts by:
//   1, 2, 4, 8, 16
//
// Therefore an arbitrary 0..31 bit shift completes in one combinational
// network with log2(32) = 5 stages.
//=============================================================================
module barrel_shifter_32 (
    input  logic [31:0] data_in,
    input  logic [4:0]  shamt,
    input  logic        dir_right,   // 0 = left, 1 = right
    input  logic        arithmetic,  // valid for right shifts
    output logic [31:0] data_out
);

    logic [31:0] stage [0:5];

    assign stage[0] = data_in;

    genvar g;
    generate
        for (g = 0; g < 5; g++) begin : GEN_SHIFT_STAGE
            localparam int SHIFT = (1 << g);

            always_comb begin
                if (!dir_right) begin
                    // Left shift stage
                    if (shamt[g])
                        stage[g+1] = stage[g] << SHIFT;
                    else
                        stage[g+1] = stage[g];
                end
                else begin
                    // Right shift stage
                    if (shamt[g]) begin
                        if (arithmetic)
                            stage[g+1] = $signed(stage[g]) >>> SHIFT;
                        else
                            stage[g+1] = stage[g] >> SHIFT;
                    end
                    else
                        stage[g+1] = stage[g];
                end
            end
        end
    endgenerate

    assign data_out = stage[5];

endmodule


//=============================================================================
// 2. ALU WITH INTEGRATED BARREL SHIFTER
//=============================================================================
module alu_unit #(
    parameter int XLEN = 32,
    parameter int RLEN = 64
)(
    input  logic [XLEN-1:0] op_a,
    input  logic [XLEN-1:0] op_b,

    input logic [3:0] exec_op,

    output logic [RLEN-1:0] result
);

    localparam logic [3:0] ALU_ADD  = 4'd0;
    localparam logic [3:0] ALU_SUB  = 4'd1;
    localparam logic [3:0] ALU_SLL  = 4'd2;
    localparam logic [3:0] ALU_SLT  = 4'd3;
    localparam logic [3:0] ALU_SLTU = 4'd4;
    localparam logic [3:0] ALU_XOR  = 4'd5;
    localparam logic [3:0] ALU_SRL  = 4'd6;
    localparam logic [3:0] ALU_SRA  = 4'd7;
    localparam logic [3:0] ALU_OR   = 4'd8;
    localparam logic [3:0] ALU_AND  = 4'd9;

    logic [31:0] shift_result;

    logic shift_right;
    logic shift_arithmetic;

    always_comb begin
        shift_right     = 1'b0;
        shift_arithmetic = 1'b0;

        case (exec_op)
            ALU_SRL: begin
                shift_right      = 1'b1;
                shift_arithmetic = 1'b0;
            end

            ALU_SRA: begin
                shift_right      = 1'b1;
                shift_arithmetic = 1'b1;
            end

            default: begin
                shift_right      = 1'b0;
                shift_arithmetic = 1'b0;
            end
        endcase
    end

    barrel_shifter_32 u_barrel_shifter (
        .data_in    (op_a),
        .shamt      (op_b[4:0]),
        .dir_right  (shift_right),
        .arithmetic (shift_arithmetic),
        .data_out   (shift_result)
    );

    logic [31:0] a_signed_ext;
    assign a_signed_ext = op_a;

    always_comb begin
        case (exec_op)

            ALU_ADD:
                result = {{XLEN{1'b0}}, op_a}
                       + {{XLEN{1'b0}}, op_b};

            ALU_SUB:
                result = {{XLEN{1'b0}}, op_a}
                       - {{XLEN{1'b0}}, op_b};

            ALU_AND:
                result = {{XLEN{1'b0}}, (op_a & op_b)};

            ALU_OR:
                result = {{XLEN{1'b0}}, (op_a | op_b)};

            ALU_XOR:
                result = {{XLEN{1'b0}}, (op_a ^ op_b)};

            ALU_SLL:
                result = {{XLEN{1'b0}}, shift_result};

            ALU_SRL:
                result = {{XLEN{1'b0}}, shift_result};

            ALU_SRA:
                result = {{XLEN{1'b0}}, shift_result};

            ALU_SLT:
                result = ($signed(op_a) < $signed(op_b))
                       ? 64'd1 : 64'd0;

            ALU_SLTU:
                result = (op_a < op_b)
                       ? 64'd1 : 64'd0;

            default:
                result = '0;

        endcase
    end

endmodule


//=============================================================================
// 3. REAL RADIX-4 MODIFIED BOOTH MULTIPLIER
//
// Signed 32 x 32 -> signed 64.
//
// Booth recoding examines overlapping groups of three multiplier bits:
//       {y[2i+1], y[2i], y[2i-1]}
//
// Recoding:
//
//       000 ->  0
//       001 -> +M
//       010 -> +M
//       011 -> +2M
//       100 -> -2M
//       101 -> -M
//       110 -> -M
//       111 ->  0
//
// Each partial product is shifted by 2*i and accumulated.
//
// This is actual radix-4 Booth recoding, rather than using the '*' operator.
//=============================================================================
module booth_multiplier_radix4 #(
    parameter int N = 32
)(
    input  logic signed [N-1:0] a,
    input  logic signed [N-1:0] b,
    output logic signed [(2*N)-1:0] product
);

    localparam int PW = 2*N + 2;

    logic signed [PW-1:0] multiplicand_ext;
    logic signed [PW-1:0] partial_product;
    logic signed [PW-1:0] accumulated;

    logic [N:0] multiplier_ext;

    integer i;
    logic [2:0] booth_bits;

    always_comb begin
        // Append one zero below the multiplier for Booth recoding.
        multiplier_ext = {b, 1'b0};

        multiplicand_ext = '0;
        multiplicand_ext[N-1:0] = a;

        accumulated = '0;

        for (i = 0; i < (N+1)/2; i = i + 1) begin

            if (2*i+1 <= N)
                booth_bits = multiplier_ext[2*i +: 3];
            else
                booth_bits = {multiplier_ext[N], multiplier_ext[N-1:0]};

            case (booth_bits)

                3'b000,
                3'b111: begin
                    partial_product = '0;
                end

                3'b001,
                3'b010: begin
                    partial_product = multiplicand_ext;
                end

                3'b011: begin
                    partial_product = multiplicand_ext <<< 1;
                end

                3'b100: begin
                    partial_product = -(multiplicand_ext <<< 1);
                end

                3'b101,
                3'b110: begin
                    partial_product = -multiplicand_ext;
                end

                default: begin
                    partial_product = '0;
                end

            endcase

            accumulated =
                accumulated + (partial_product <<< (2*i));
        end

        product = accumulated[(2*N)-1:0];

    end

endmodule


//=============================================================================
// 4. MAC UNIT
//
// Integrates:
//   - 32x32 radix-4 Booth multiplier
//   - 64-bit accumulator
//   - signed overflow detection
//
// MUL:
//   result = A * B
//
// MAC:
//   result = accumulator + (A * B)
//=============================================================================
module mac_unit #(
    parameter int XLEN = 32,
    parameter int RLEN = 64
)(
    input  logic                   clk,
    input  logic                   reset,
    input  logic                   acc_clear,

    input  logic                   valid,
    input  logic                   do_mac,       // 1 = MAC, 0 = MUL

    input  logic signed [XLEN-1:0] op_a,
    input  logic signed [XLEN-1:0] op_b,

    output logic [RLEN-1:0]        result,
    output logic                   overflow
);

    logic signed [RLEN-1:0] booth_product;
    logic signed [RLEN-1:0] accumulator;
    logic signed [RLEN-1:0] next_accumulator;

    booth_multiplier_radix4 #(
        .N(XLEN)
    ) u_booth_multiplier (
        .a       (op_a),
        .b       (op_b),
        .product (booth_product)
    );

    always_comb begin
        if (do_mac)
            next_accumulator = accumulator + booth_product;
        else
            next_accumulator = booth_product;
    end

    logic signed overflow_calc;

    always_comb begin
        if (do_mac) begin
            overflow_calc =
                (booth_product[RLEN-1] == accumulator[RLEN-1]) &&
                (next_accumulator[RLEN-1] != accumulator[RLEN-1]);
        end
        else begin
            overflow_calc = 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (reset || acc_clear) begin
            accumulator <= '0;
            overflow    <= 1'b0;
        end
        else if (valid) begin
            accumulator <= next_accumulator;
            overflow    <= overflow_calc;
        end
    end

    assign result = next_accumulator;

endmodule


//=============================================================================
// 5. INTEGRATED 5-STAGE RISC-V PROCESSOR
//=============================================================================
module riscv_alu_mac_5stage #(
    parameter int XLEN = 32,
    parameter int RLEN = 2 * XLEN
)(
    input  logic            clk,
    input  logic            reset,

    input  logic [31:0]     instr,
    input  logic            instr_valid,
    input  logic            acc_clear,

    output logic [RLEN-1:0] result,
    output logic [4:0]      result_rd,
    output logic            result_valid,
    output logic            illegal_instr,
    output logic            mac_overflow,

    input  logic            init_en,
    input  logic [4:0]      init_addr,
    input  logic [XLEN-1:0] init_data
);

    //-------------------------------------------------------------------------
    // Opcodes
    //-------------------------------------------------------------------------
    localparam logic [6:0] OPC_OP     = 7'b0110011;
    localparam logic [6:0] OPC_OP_IMM = 7'b0010011;
    localparam logic [6:0] OPC_MAC_OP = 7'b0001011;
    localparam logic [6:0] OPC_MUL_OP = 7'b0001010;

    localparam logic [6:0] F7_BASE = 7'b0000000;
    localparam logic [6:0] F7_ALT  = 7'b0100000;

    typedef enum logic [3:0] {
        ALU_ADD,
        ALU_SUB,
        ALU_SLL,
        ALU_SLT,
        ALU_SLTU,
        ALU_XOR,
        ALU_SRL,
        ALU_SRA,
        ALU_OR,
        ALU_AND,
        UNIT_MAC,
        UNIT_MUL
    } exec_op_e;

    //-------------------------------------------------------------------------
    // Register file
    //-------------------------------------------------------------------------
    logic [XLEN-1:0] regbank [0:31];

    //-------------------------------------------------------------------------
    // Pipeline registers
    //-------------------------------------------------------------------------
    logic [RLEN-1:0] m_result;
    logic [4:0]      m_rd;
    logic            m_valid, m_illegal;

    logic [RLEN-1:0] w_result;
    logic [4:0]      w_rd;
    logic            w_valid, w_illegal;

    //-------------------------------------------------------------------------
    // STAGE 1: IF
    //-------------------------------------------------------------------------
    logic [31:0] d_instr;
    logic        d_valid;

    always_ff @(posedge clk) begin
        if (reset) begin
            d_instr <= 32'h0000_0013;
            d_valid <= 1'b0;
        end
        else begin
            d_instr <= instr;
            d_valid <= instr_valid;
        end
    end

    //-------------------------------------------------------------------------
    // STAGE 2: ID / Decode / Register Read
    //-------------------------------------------------------------------------
    logic [6:0] d_opcode, d_funct7;
    logic [2:0] d_funct3;
    logic [4:0] d_rs1, d_rs2, d_rd;
    logic [XLEN-1:0] d_imm_i;

    assign d_opcode = d_instr[6:0];
    assign d_rd     = d_instr[11:7];
    assign d_funct3 = d_instr[14:12];
    assign d_rs1    = d_instr[19:15];
    assign d_rs2    = d_instr[24:20];
    assign d_funct7 = d_instr[31:25];

    assign d_imm_i = {{(XLEN-12){d_instr[31]}}, d_instr[31:20]};

    logic d_is_r, d_is_i, d_is_mac, d_is_mul;

    assign d_is_r   = (d_opcode == OPC_OP);
    assign d_is_i   = (d_opcode == OPC_OP_IMM);
    assign d_is_mac = (d_opcode == OPC_MAC_OP);
    assign d_is_mul = (d_opcode == OPC_MUL_OP);

    logic [XLEN-1:0] d_rs1_val;
    logic [XLEN-1:0] d_rs2_val;
    logic [XLEN-1:0] d_operand_b;

    assign d_rs1_val =
        (d_rs1 == 5'd0) ? '0 :
        (w_valid && (w_rd == d_rs1) && (w_rd != 0))
        ? w_result[XLEN-1:0]
        : regbank[d_rs1];

    assign d_rs2_val =
        (d_rs2 == 5'd0) ? '0 :
        (w_valid && (w_rd == d_rs2) && (w_rd != 0))
        ? w_result[XLEN-1:0]
        : regbank[d_rs2];

    assign d_operand_b =
        (d_is_r || d_is_mac || d_is_mul)
        ? d_rs2_val
        : d_imm_i;

    exec_op_e d_exec_op;
    logic d_illegal;

    always_comb begin

        d_illegal = 1'b0;
        d_exec_op = ALU_ADD;

        if (d_is_mac) begin
            d_exec_op = UNIT_MAC;
        end
        else if (d_is_mul) begin
            d_exec_op = UNIT_MUL;
        end
        else if (d_is_r) begin

            case (d_funct3)
                3'b000: d_exec_op = d_funct7[5] ? ALU_SUB  : ALU_ADD;
                3'b001: d_exec_op = ALU_SLL;
                3'b010: d_exec_op = ALU_SLT;
                3'b011: d_exec_op = ALU_SLTU;
                3'b100: d_exec_op = ALU_XOR;
                3'b101: d_exec_op = d_funct7[5] ? ALU_SRA  : ALU_SRL;
                3'b110: d_exec_op = ALU_OR;
                3'b111: d_exec_op = ALU_AND;
                default: begin
                    d_exec_op = ALU_ADD;
                    d_illegal = 1'b1;
                end
            endcase

            if (!((d_funct7 == F7_BASE) ||
                  ((d_funct7 == F7_ALT) &&
                   ((d_funct3 == 3'b000) ||
                    (d_funct3 == 3'b101)))))
                d_illegal = 1'b1;

        end
        else if (d_is_i) begin

            case (d_funct3)
                3'b000: d_exec_op = ALU_ADD;
                3'b001: d_exec_op = ALU_SLL;
                3'b010: d_exec_op = ALU_SLT;
                3'b011: d_exec_op = ALU_SLTU;
                3'b100: d_exec_op = ALU_XOR;
                3'b101: d_exec_op = d_funct7[5] ? ALU_SRA : ALU_SRL;
                3'b110: d_exec_op = ALU_OR;
                3'b111: d_exec_op = ALU_AND;

                default: begin
                    d_exec_op = ALU_ADD;
                    d_illegal = 1'b1;
                end
            endcase

        end
        else begin
            d_exec_op = ALU_ADD;
            d_illegal = 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // ID/EX
    //-------------------------------------------------------------------------
    logic [XLEN-1:0] e_a, e_b;
    logic [4:0] e_rs1, e_rs2, e_rd;
    exec_op_e e_exec_op;
    logic e_valid, e_illegal, e_uses_rs2;

    always_ff @(posedge clk) begin

        if (reset) begin
            e_a <= '0;
            e_b <= '0;
            e_rs1 <= '0;
            e_rs2 <= '0;
            e_rd <= '0;
            e_exec_op <= ALU_ADD;
            e_valid <= 1'b0;
            e_illegal <= 1'b0;
            e_uses_rs2 <= 1'b0;
        end
        else begin
            e_a <= d_rs1_val;
            e_b <= d_operand_b;

            e_rs1 <= d_rs1;
            e_rs2 <= d_rs2;
            e_rd <= d_rd;

            e_exec_op <= d_exec_op;

            e_valid <= d_valid && !d_illegal;
            e_illegal <= d_valid && d_illegal;

            e_uses_rs2 <= d_is_r || d_is_mac || d_is_mul;
        end
    end

    //-------------------------------------------------------------------------
    // STAGE 3: EX
    //
    // ALU and MAC/MUL are integrated here and receive the same forwarded
    // operands. Only one result is selected for the instruction currently in
    // the EX stage.
    //-------------------------------------------------------------------------
    logic [XLEN-1:0] op_a, op_b;

    always_comb begin

        op_a = e_a;

        if (e_valid && (e_rs1 != 5'd0)) begin
            if (m_valid && (m_rd == e_rs1) && (m_rd != 0))
                op_a = m_result[XLEN-1:0];

            else if (w_valid && (w_rd == e_rs1) && (w_rd != 0))
                op_a = w_result[XLEN-1:0];
        end

        op_b = e_b;

        if (e_valid && e_uses_rs2 && (e_rs2 != 5'd0)) begin
            if (m_valid && (m_rd == e_rs2) && (m_rd != 0))
                op_b = m_result[XLEN-1:0];

            else if (w_valid && (w_rd == e_rs2) && (w_rd != 0))
                op_b = w_result[XLEN-1:0];
        end

    end

    //-------------------------------------------------------------------------
    // ALU instance
    //-------------------------------------------------------------------------
    logic [RLEN-1:0] alu_result;

    alu_unit #(
        .XLEN(XLEN),
        .RLEN(RLEN)
    ) u_alu (
        .op_a    (op_a),
        .op_b    (op_b),
        .exec_op (e_exec_op),
        .result  (alu_result)
    );

    //-------------------------------------------------------------------------
    // MAC instance
    //-------------------------------------------------------------------------
    logic [RLEN-1:0] mac_result;

    logic mac_unit_overflow;

    mac_unit #(
        .XLEN(XLEN),
        .RLEN(RLEN)
    ) u_mac (
        .clk       (clk),
        .reset     (reset),
        .acc_clear (acc_clear),

        .valid     (e_valid &&
                    ((e_exec_op == UNIT_MAC) ||
                     (e_exec_op == UNIT_MUL))),

        .do_mac    (e_exec_op == UNIT_MAC),

        .op_a      ($signed(op_a)),
        .op_b      ($signed(op_b)),

        .result    (mac_result),
        .overflow  (mac_unit_overflow)
    );

    assign mac_overflow = mac_unit_overflow;

    //-------------------------------------------------------------------------
    // ALU/MAC Result MUX
    //-------------------------------------------------------------------------
    logic [RLEN-1:0] ex_stage_result;

    always_comb begin
        if ((e_exec_op == UNIT_MAC) ||
            (e_exec_op == UNIT_MUL))
            ex_stage_result = mac_result;
        else
            ex_stage_result = alu_result;
    end

    //-------------------------------------------------------------------------
    // EX/MEM
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin

        if (reset) begin
            m_result <= '0;
            m_rd <= '0;
            m_valid <= 1'b0;
            m_illegal <= 1'b0;
        end
        else begin
            m_result <= ex_stage_result;
            m_rd <= e_rd;
            m_valid <= e_valid;
            m_illegal <= e_illegal;
        end

    end

    //-------------------------------------------------------------------------
    // STAGE 4: MEM / pipeline latch
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin

        if (reset) begin
            w_result <= '0;
            w_rd <= '0;
            w_valid <= 1'b0;
            w_illegal <= 1'b0;
        end
        else begin
            w_result <= m_result;
            w_rd <= m_rd;
            w_valid <= m_valid;
            w_illegal <= m_illegal;
        end

    end

    assign result = w_result;
    assign result_rd = w_rd;
    assign result_valid = w_valid;
    assign illegal_instr = w_illegal;

    //-------------------------------------------------------------------------
    // STAGE 5: WB
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin

        if (reset) begin
            for (int k = 0; k < 32; k = k + 1)
                regbank[k] <= '0;
        end
        else if (init_en) begin
            regbank[init_addr] <= init_data;
        end
        else if (w_valid && (w_rd != 5'd0)) begin
            regbank[w_rd] <= w_result[XLEN-1:0];
        end

        // Keep x0 architecturally zero.
        regbank[0] <= '0;

    end

endmodule
