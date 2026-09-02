`timescale 1ns / 1ps
//=============================================================================
// alu_mac_selftest.sv
//
// 16-step built-in self test for riscv_alu_mac_5stage.
//
// A vector table in a case statement plus a small sequencer that issues each
// step through alu_mac_cmd_ctrl, compares the 64-bit response against the
// expected value IN HARDWARE, and accumulates a fail bitmap. Nothing here is
// a $display - the verdict is a wire the VIO and the LEDs can read.
//
// The expected values follow this DUT's actual arithmetic, which is not the
// textbook RV32I result: both ALU operands are ZERO-EXTENDED to 64 bits before
// the operation, so ADD carries out into the upper word instead of truncating,
// and SUB with a borrow produces a full 64-bit negative pattern. Steps 1 and 3
// exist specifically to prove that.
//=============================================================================

module alu_mac_selftest (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,          // 1-cycle pulse

    // ---- Verdict -----------------------------------------------------------
    output logic        st_busy,
    output logic        st_done,        // sticky until the next start
    output logic        st_pass,
    output logic [15:0] st_fail_mask,   // bit N set = step N failed
    output logic [7:0]  st_step,
    output logic        st_acc_clear,   // MAC accumulator clear pulse

    // ---- Command port to alu_mac_cmd_ctrl ----------------------------------
    output logic        cmd_valid,
    output logic [3:0]  cmd_op,
    output logic        cmd_use_imm,
    output logic [11:0] cmd_imm,
    output logic [4:0]  cmd_rs1,
    output logic [4:0]  cmd_rs2,
    output logic [4:0]  cmd_rd,
    output logic [31:0] cmd_a,
    output logic [31:0] cmd_b,
    input  logic        rsp_valid,
    input  logic [63:0] rsp_data,
    input  logic        rsp_illegal,
    input  logic        rsp_timeout
);

    localparam logic [3:0] OP_ADD  = 4'd0;
    localparam logic [3:0] OP_SUB  = 4'd1;
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

    localparam int LAST_STEP = 15;

    logic [3:0]  step;

    // ------------------------------------------------------------------------
    // Vector table
    // ------------------------------------------------------------------------
    logic [3:0]  v_op;
    logic [31:0] v_a, v_b;
    logic [63:0] v_exp;
    logic        v_illegal;   // this step must raise illegal_instr
    logic        v_clear;     // clear the MAC accumulator before issuing

    always_comb begin
        v_op      = OP_ADD;
        v_a       = 32'd0;
        v_b       = 32'd0;
        v_exp     = 64'd0;
        v_illegal = 1'b0;
        v_clear   = 1'b0;

        case (step)
        // ---- ALU: addition, with and without carry into the upper word -----
        4'd0 : begin v_op=OP_ADD;  v_a=32'h0000_0010; v_b=32'h0000_0020;
                     v_exp=64'h0000_0000_0000_0030; end
        4'd1 : begin v_op=OP_ADD;  v_a=32'hFFFF_FFFF; v_b=32'hFFFF_FFFF;
                     v_exp=64'h0000_0001_FFFF_FFFE; end   // no truncation
        // ---- ALU: subtraction, positive and borrowing ----------------------
        4'd2 : begin v_op=OP_SUB;  v_a=32'h0000_0030; v_b=32'h0000_0010;
                     v_exp=64'h0000_0000_0000_0020; end
        4'd3 : begin v_op=OP_SUB;  v_a=32'h0000_0010; v_b=32'h0000_0030;
                     v_exp=64'hFFFF_FFFF_FFFF_FFE0; end   // borrow, 64-bit
        // ---- ALU: logical --------------------------------------------------
        4'd4 : begin v_op=OP_AND;  v_a=32'hF0F0_F0F0; v_b=32'hFF00_FF00;
                     v_exp=64'h0000_0000_F000_F000; end
        4'd5 : begin v_op=OP_OR;   v_a=32'hF0F0_F0F0; v_b=32'h0F0F_0F0F;
                     v_exp=64'h0000_0000_FFFF_FFFF; end
        4'd6 : begin v_op=OP_XOR;  v_a=32'hAAAA_AAAA; v_b=32'hFFFF_FFFF;
                     v_exp=64'h0000_0000_5555_5555; end
        // ---- ALU: barrel shifter, all three directions ---------------------
        4'd7 : begin v_op=OP_SLL;  v_a=32'h8000_0001; v_b=32'h0000_0004;
                     v_exp=64'h0000_0008_0000_0010; end
        4'd8 : begin v_op=OP_SRL;  v_a=32'h8000_0001; v_b=32'h0000_0004;
                     v_exp=64'h0000_0000_0800_0000; end
        4'd9 : begin v_op=OP_SRA;  v_a=32'h8000_0001; v_b=32'h0000_0004;
                     v_exp=64'hFFFF_FFFF_F800_0000; end   // sign-extended
        // ---- ALU: signed vs unsigned compare on the same operands ----------
        4'd10: begin v_op=OP_SLT;  v_a=32'h8000_0000; v_b=32'h0000_0001;
                     v_exp=64'h0000_0000_0000_0001; end   // -2^31 <  1
        4'd11: begin v_op=OP_SLTU; v_a=32'h8000_0000; v_b=32'h0000_0001;
                     v_exp=64'h0000_0000_0000_0000; end   // 2^31   >= 1
        // ---- MAC unit ------------------------------------------------------
        4'd12: begin v_op=OP_MUL;  v_a=32'hFFFF_FFFF; v_b=32'h7FFF_FFFF;
                     v_exp=64'hFFFF_FFFF_8000_0001; end   // -1 * 2147483647
        4'd13: begin v_op=OP_MAC;  v_a=32'h0000_0010; v_b=32'h0000_0010;
                     v_exp=64'h0000_0000_0000_0100; v_clear=1'b1; end
        4'd14: begin v_op=OP_MAC;  v_a=32'h0000_0002; v_b=32'h0000_0003;
                     v_exp=64'h0000_0000_0000_0106; end   // 256 + 6
        // ---- Decode: illegal instruction trap ------------------------------
        4'd15: begin v_op=OP_ILL;  v_a=32'h0000_000A; v_b=32'h0000_0014;
                     v_illegal=1'b1; end
        default: ;
        endcase
    end

    assign cmd_op      = v_op;
    assign cmd_a       = v_a;
    assign cmd_b       = v_b;
    assign cmd_use_imm = 1'b0;
    assign cmd_imm     = 12'd0;
    assign cmd_rs1     = 5'd1;
    assign cmd_rs2     = 5'd2;
    assign cmd_rd      = 5'd3;
    assign st_step     = {4'd0, step};

    // ------------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------------
    localparam logic [2:0] S_IDLE  = 3'd0;
    localparam logic [2:0] S_CLEAR = 3'd1;
    localparam logic [2:0] S_ISSUE = 3'd2;
    localparam logic [2:0] S_WAIT  = 3'd3;
    localparam logic [2:0] S_NEXT  = 3'd4;

    logic [2:0] state;
    logic       step_ok;

    assign st_busy = (state != S_IDLE);

    // In-hardware comparison. A timeout never counts as a pass.
    always_comb begin
        if (rsp_timeout)      step_ok = 1'b0;
        else if (v_illegal)   step_ok =  rsp_illegal;
        else                  step_ok = !rsp_illegal && (rsp_data == v_exp);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= S_IDLE;
            step         <= 4'd0;
            st_fail_mask <= 16'd0;
            st_done      <= 1'b0;
            st_pass      <= 1'b0;
            st_acc_clear <= 1'b0;
            cmd_valid    <= 1'b0;
        end else begin
            cmd_valid    <= 1'b0;
            st_acc_clear <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        step         <= 4'd0;
                        st_fail_mask <= 16'd0;
                        st_done      <= 1'b0;
                        st_pass      <= 1'b0;
                        state        <= S_CLEAR;
                    end
                end

                // Held one cycle whether or not a clear is needed, so every
                // step has identical issue timing.
                S_CLEAR: begin
                    st_acc_clear <= v_clear;
                    state        <= S_ISSUE;
                end

                S_ISSUE: begin
                    cmd_valid <= 1'b1;
                    state     <= S_WAIT;
                end

                S_WAIT: begin
                    if (rsp_valid) begin
                        if (!step_ok) st_fail_mask[step] <= 1'b1;
                        state <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    if (step == LAST_STEP[3:0]) begin
                        st_done <= 1'b1;
                        st_pass <= (st_fail_mask == 16'd0);
                        state   <= S_IDLE;
                    end else begin
                        step  <= step + 4'd1;
                        state <= S_CLEAR;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
