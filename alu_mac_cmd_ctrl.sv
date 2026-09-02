`timescale 1ns / 1ps
//=============================================================================
// alu_mac_cmd_ctrl.sv
//
// Synthesizable instruction-issue controller for riscv_alu_mac_5stage.
//
// Replaces the class-based driver in TEST_BENCH/tb_alu_mac_integrate.sv, which
// cannot be synthesised. Turns one cmd_valid pulse into the full sequence the
// DUT needs:
//
//     preload rs1 via the init port
//  -> preload rs2 via the init port
//  -> encode and issue the instruction for exactly one cycle
//  -> wait for result_valid or illegal_instr (4-cycle pipeline latency)
//  -> return rsp_data / rsp_illegal / rsp_ovf
//
// A timeout guards against the pipeline never retiring, so a wedged DUT
// reports an error instead of hanging the harness.
//=============================================================================

module alu_mac_cmd_ctrl #(
    parameter int TIMEOUT_CYCLES = 32
)(
    input  logic        clk,
    input  logic        rst,          // active high, synchronous

    // ---- Command interface -------------------------------------------------
    input  logic        cmd_valid,    // 1-cycle pulse, ignored while busy
    input  logic [3:0]  cmd_op,       // see OP_* encoding below
    input  logic        cmd_use_imm,  // 1 = I-type, 0 = R-type
    input  logic [11:0] cmd_imm,
    input  logic [4:0]  cmd_rs1,
    input  logic [4:0]  cmd_rs2,
    input  logic [4:0]  cmd_rd,
    input  logic [31:0] cmd_a,        // value preloaded into rs1
    input  logic [31:0] cmd_b,        // value preloaded into rs2
    output logic        busy,

    // ---- Response ----------------------------------------------------------
    output logic        rsp_valid,    // 1-cycle pulse
    output logic [63:0] rsp_data,
    output logic [4:0]  rsp_rd,
    output logic        rsp_illegal,
    output logic        rsp_ovf,
    output logic        rsp_timeout,
    output logic [31:0] rsp_instr,    // instruction word actually issued

    // ---- DUT connections ---------------------------------------------------
    output logic [31:0] dut_instr,
    output logic        dut_instr_valid,
    output logic        dut_init_en,
    output logic [4:0]  dut_init_addr,
    output logic [31:0] dut_init_data,
    input  logic [63:0] dut_result,
    input  logic [4:0]  dut_result_rd,
    input  logic        dut_result_valid,
    input  logic        dut_illegal,
    input  logic        dut_mac_ovf
);

    // ------------------------------------------------------------------------
    // Operation encoding driven by the VIO / BIST
    // ------------------------------------------------------------------------
    localparam logic [3:0] OP_ADD  = 4'd0;
    localparam logic [3:0] OP_SUB  = 4'd1;   // R-type only
    localparam logic [3:0] OP_SLL  = 4'd2;
    localparam logic [3:0] OP_SLT  = 4'd3;
    localparam logic [3:0] OP_SLTU = 4'd4;
    localparam logic [3:0] OP_XOR  = 4'd5;
    localparam logic [3:0] OP_SRL  = 4'd6;
    localparam logic [3:0] OP_SRA  = 4'd7;
    localparam logic [3:0] OP_OR   = 4'd8;
    localparam logic [3:0] OP_AND  = 4'd9;
    localparam logic [3:0] OP_MAC  = 4'd10;
    localparam logic [3:0] OP_MUL  = 4'd11;
    localparam logic [3:0] OP_ILL  = 4'd15;

    localparam logic [6:0] OPC_OP     = 7'b0110011;
    localparam logic [6:0] OPC_OP_IMM = 7'b0010011;
    localparam logic [6:0] OPC_MAC_OP = 7'b0001011;
    localparam logic [6:0] OPC_MUL_OP = 7'b0001010;
    localparam logic [6:0] F7_BASE    = 7'b0000000;
    localparam logic [6:0] F7_ALT     = 7'b0100000;

    localparam logic [31:0] NOP = 32'h0000_0013;   // addi x0, x0, 0

    // ------------------------------------------------------------------------
    // Instruction encoder
    // ------------------------------------------------------------------------
    function automatic logic [31:0] encode_instr(
        input logic [3:0]  op,
        input logic        use_imm,
        input logic [11:0] imm,
        input logic [4:0]  rs1,
        input logic [4:0]  rs2,
        input logic [4:0]  rd
    );
        logic [2:0] f3;
        logic [6:0] f7;
        logic       is_shift;
        begin
            f7 = F7_BASE;
            case (op)
                OP_ADD  : f3 = 3'b000;
                OP_SUB  : begin f3 = 3'b000; f7 = F7_ALT; end
                OP_SLL  : f3 = 3'b001;
                OP_SLT  : f3 = 3'b010;
                OP_SLTU : f3 = 3'b011;
                OP_XOR  : f3 = 3'b100;
                OP_SRL  : f3 = 3'b101;
                OP_SRA  : begin f3 = 3'b101; f7 = F7_ALT; end
                OP_OR   : f3 = 3'b110;
                OP_AND  : f3 = 3'b111;
                default : f3 = 3'b000;
            endcase

            is_shift = (op == OP_SLL) || (op == OP_SRL) || (op == OP_SRA);

            if (op == OP_MAC)
                encode_instr = {F7_BASE, rs2, rs1, 3'b000, rd, OPC_MAC_OP};
            else if (op == OP_MUL)
                encode_instr = {F7_BASE, rs2, rs1, 3'b000, rd, OPC_MUL_OP};
            else if (op == OP_ILL)
                encode_instr = 32'hFFFF_FFFF;
            else if (use_imm && is_shift)
                encode_instr = {f7, imm[4:0], rs1, f3, rd, OPC_OP_IMM};
            else if (use_imm)
                encode_instr = {imm, rs1, f3, rd, OPC_OP_IMM};
            else
                encode_instr = {f7, rs2, rs1, f3, rd, OPC_OP};
        end
    endfunction

    // ------------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------------
    localparam logic [2:0] S_IDLE  = 3'd0;
    localparam logic [2:0] S_PRE1  = 3'd1;
    localparam logic [2:0] S_PRE2  = 3'd2;
    localparam logic [2:0] S_ISSUE = 3'd3;
    localparam logic [2:0] S_WAIT  = 3'd4;
    localparam logic [2:0] S_DONE  = 3'd5;

    logic [2:0]  state;
    logic [31:0] instr_r, a_r, b_r;
    logic [4:0]  rs1_r, rs2_r, rd_r;
    logic        use_imm_r;
    logic [7:0]  to_cnt;

    assign busy = (state != S_IDLE);

    // Outputs to the DUT are decoded from the (registered) state, so they are
    // stable for the whole cycle the DUT samples them on.
    always_comb begin
        dut_init_en     = 1'b0;
        dut_init_addr   = 5'd0;
        dut_init_data   = 32'd0;
        dut_instr       = NOP;
        dut_instr_valid = 1'b0;

        case (state)
            S_PRE1: if (rs1_r != 5'd0) begin
                        dut_init_en   = 1'b1;
                        dut_init_addr = rs1_r;
                        dut_init_data = a_r;
                    end
            S_PRE2: if ((rs2_r != 5'd0) && !use_imm_r) begin
                        dut_init_en   = 1'b1;
                        dut_init_addr = rs2_r;
                        dut_init_data = b_r;
                    end
            S_ISSUE: begin
                        dut_instr       = instr_r;
                        dut_instr_valid = 1'b1;
                    end
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            instr_r     <= NOP;
            a_r         <= 32'd0;
            b_r         <= 32'd0;
            rs1_r       <= 5'd0;
            rs2_r       <= 5'd0;
            rd_r        <= 5'd0;
            use_imm_r   <= 1'b0;
            to_cnt      <= 8'd0;
            rsp_valid   <= 1'b0;
            rsp_data    <= 64'd0;
            rsp_rd      <= 5'd0;
            rsp_illegal <= 1'b0;
            rsp_ovf     <= 1'b0;
            rsp_timeout <= 1'b0;
            rsp_instr   <= NOP;
        end else begin
            rsp_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (cmd_valid) begin
                        instr_r   <= encode_instr(cmd_op, cmd_use_imm, cmd_imm,
                                                  cmd_rs1, cmd_rs2, cmd_rd);
                        a_r       <= cmd_a;
                        b_r       <= cmd_b;
                        rs1_r     <= cmd_rs1;
                        rs2_r     <= cmd_rs2;
                        rd_r      <= cmd_rd;
                        use_imm_r <= cmd_use_imm;
                        state     <= S_PRE1;
                    end
                end

                S_PRE1: state <= S_PRE2;

                S_PRE2: state <= S_ISSUE;

                S_ISSUE: begin
                    rsp_instr   <= instr_r;
                    rsp_illegal <= 1'b0;
                    rsp_timeout <= 1'b0;
                    to_cnt      <= 8'd0;
                    state       <= S_WAIT;
                end

                S_WAIT: begin
                    to_cnt <= to_cnt + 8'd1;
                    if (dut_result_valid || dut_illegal) begin
                        rsp_data    <= dut_result;
                        rsp_rd      <= dut_result_rd;
                        rsp_illegal <= dut_illegal;
                        rsp_ovf     <= dut_mac_ovf;
                        state       <= S_DONE;
                    end else if (to_cnt == TIMEOUT_CYCLES[7:0]) begin
                        rsp_data    <= 64'd0;
                        rsp_rd      <= rd_r;
                        rsp_illegal <= 1'b0;
                        rsp_timeout <= 1'b1;
                        state       <= S_DONE;
                    end
                end

                S_DONE: begin
                    rsp_valid <= 1'b1;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
