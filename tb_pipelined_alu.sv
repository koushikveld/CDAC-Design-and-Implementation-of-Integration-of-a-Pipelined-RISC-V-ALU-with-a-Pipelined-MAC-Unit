`timescale 1ns / 1ps
//=============================================================================
// Testbench for riscv_alu_5stage
//
//   Builds real RV32I instruction words (no custom opcodes), issues them
//   back-to-back at one per clock, and checks every writeback result against
//   a hand-computed expected value using a scoreboard queue.
//=============================================================================

module riscv_alu_5stage_tb;

    localparam int XLEN = 32;
    localparam int RLEN = 64;

    logic            clk, reset;
    logic [31:0]     instr;
    logic            instr_valid;
    logic [RLEN-1:0] result;
    logic [4:0]      result_rd;
    logic            result_valid;
    logic            illegal_instr;
    logic            init_en;
    logic [4:0]      init_addr;
    logic [XLEN-1:0] init_data;

    riscv_alu_5stage dut (
        .clk(clk), .reset(reset),
        .instr(instr), .instr_valid(instr_valid),
        .result(result), .result_rd(result_rd),
        .result_valid(result_valid), .illegal_instr(illegal_instr),
        .init_en(init_en), .init_addr(init_addr), .init_data(init_data)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    //-------------------------------------------------------------------------
    // RV32I instruction encoders
    //-------------------------------------------------------------------------
    localparam logic [6:0] OPC_OP     = 7'b0110011;
    localparam logic [6:0] OPC_OP_IMM = 7'b0010011;

    function automatic logic [31:0] enc_r(input logic [6:0] f7,
                                          input logic [4:0] rs2, rs1,
                                          input logic [2:0] f3,
                                          input logic [4:0] rd);
        return {f7, rs2, rs1, f3, rd, OPC_OP};
    endfunction

    function automatic logic [31:0] enc_i(input logic [11:0] imm,
                                          input logic [4:0]  rs1,
                                          input logic [2:0]  f3,
                                          input logic [4:0]  rd);
        return {imm, rs1, f3, rd, OPC_OP_IMM};
    endfunction

    // R-type
    function automatic logic [31:0] i_add (input logic [4:0] rd, rs1, rs2);
        return enc_r(7'b0000000, rs2, rs1, 3'b000, rd); endfunction
    function automatic logic [31:0] i_sub (input logic [4:0] rd, rs1, rs2);
        return enc_r(7'b0100000, rs2, rs1, 3'b000, rd); endfunction
    function automatic logic [31:0] i_sll (input logic [4:0] rd, rs1, rs2);
        return enc_r(7'b0000000, rs2, rs1, 3'b001, rd); endfunction
    function automatic logic [31:0] i_slt (input logic [4:0] rd, rs1, rs2);
        return enc_r(7'b0000000, rs2, rs1, 3'b010, rd); endfunction
    function automatic logic [31:0] i_sltu(input logic [4:0] rd, rs1, rs2);
        return enc_r(7'b0000000, rs2, rs1, 3'b011, rd); endfunction
    function automatic logic [31:0] i_xor (input logic [4:0] rd, rs1, rs2);
        return enc_r(7'b0000000, rs2, rs1, 3'b100, rd); endfunction
    function automatic logic [31:0] i_srl (input logic [4:0] rd, rs1, rs2);
        return enc_r(7'b0000000, rs2, rs1, 3'b101, rd); endfunction
    function automatic logic [31:0] i_sra (input logic [4:0] rd, rs1, rs2);
        return enc_r(7'b0100000, rs2, rs1, 3'b101, rd); endfunction
    function automatic logic [31:0] i_or  (input logic [4:0] rd, rs1, rs2);
        return enc_r(7'b0000000, rs2, rs1, 3'b110, rd); endfunction
    function automatic logic [31:0] i_and (input logic [4:0] rd, rs1, rs2);
        return enc_r(7'b0000000, rs2, rs1, 3'b111, rd); endfunction

    // I-type
    function automatic logic [31:0] i_addi (input logic [4:0] rd, rs1, input logic [11:0] imm);
        return enc_i(imm, rs1, 3'b000, rd); endfunction
    function automatic logic [31:0] i_slti (input logic [4:0] rd, rs1, input logic [11:0] imm);
        return enc_i(imm, rs1, 3'b010, rd); endfunction
    function automatic logic [31:0] i_sltiu(input logic [4:0] rd, rs1, input logic [11:0] imm);
        return enc_i(imm, rs1, 3'b011, rd); endfunction
    function automatic logic [31:0] i_xori (input logic [4:0] rd, rs1, input logic [11:0] imm);
        return enc_i(imm, rs1, 3'b100, rd); endfunction
    function automatic logic [31:0] i_ori  (input logic [4:0] rd, rs1, input logic [11:0] imm);
        return enc_i(imm, rs1, 3'b110, rd); endfunction
    function automatic logic [31:0] i_andi (input logic [4:0] rd, rs1, input logic [11:0] imm);
        return enc_i(imm, rs1, 3'b111, rd); endfunction
    function automatic logic [31:0] i_slli (input logic [4:0] rd, rs1, input logic [4:0] sh);
        return enc_i({7'b0000000, sh}, rs1, 3'b001, rd); endfunction
    function automatic logic [31:0] i_srli (input logic [4:0] rd, rs1, input logic [4:0] sh);
        return enc_i({7'b0000000, sh}, rs1, 3'b101, rd); endfunction
    function automatic logic [31:0] i_srai (input logic [4:0] rd, rs1, input logic [4:0] sh);
        return enc_i({7'b0100000, sh}, rs1, 3'b101, rd); endfunction

    //-------------------------------------------------------------------------
    // Scoreboard
    //-------------------------------------------------------------------------
    localparam int QDEPTH = 128;
    logic [RLEN-1:0] exp_val  [0:QDEPTH-1];
    logic [4:0]      exp_rd   [0:QDEPTH-1];
    string           exp_name [0:QDEPTH-1];
    int wr_ptr = 0;
    int rd_ptr = 0;
    int pass_count = 0;
    int fail_count = 0;
    logic checking = 1'b0;

    task automatic issue(input logic [31:0] inst,
                         input logic [RLEN-1:0] expv,
                         input logic [4:0] rdx,
                         input string nm);
        begin
            @(negedge clk);
            instr           = inst;
            instr_valid     = 1'b1;
            exp_val[wr_ptr] = expv;
            exp_rd[wr_ptr]  = rdx;
            exp_name[wr_ptr]= nm;
            wr_ptr++;
        end
    endtask

    task automatic idle(input int n);
        begin
            for (int i = 0; i < n; i++) begin
                @(negedge clk);
                instr_valid = 1'b0;
                instr       = 32'h0000_0013;   // NOP
            end
        end
    endtask

    // Monitor: one comparison per valid writeback
    always @(negedge clk) begin
        if (checking && result_valid) begin
            $display("%-18s  rd=x%0d", exp_name[rd_ptr], result_rd);
            $display("     Out = %b", result);
            $display("     Out = 0x%h   unsigned %0d   signed %0d",
                     result, result, $signed(result));
            if ((result === exp_val[rd_ptr]) && (result_rd === exp_rd[rd_ptr])) begin
                pass_count++;
                $display("     Exp = 0x%h   rd=x%0d   [PASS]\n",
                         exp_val[rd_ptr], exp_rd[rd_ptr]);
            end else begin
                fail_count++;
                $display("     Exp = 0x%h   rd=x%0d   [FAIL]\n",
                         exp_val[rd_ptr], exp_rd[rd_ptr]);
            end
            rd_ptr++;
        end
    end

    task automatic preload(input logic [4:0] addr, input logic [XLEN-1:0] data);
        begin
            @(negedge clk);
            init_en = 1'b1; init_addr = addr; init_data = data;
            @(negedge clk);
            init_en = 1'b0;
        end
    endtask

    task automatic banner(input string text);
        begin
            $display("============================================================");
            $display("  %s", text);
            $display("============================================================");
        end
    endtask

    //-------------------------------------------------------------------------
    initial begin
        reset = 1'b1; instr = 32'h0000_0013; instr_valid = 1'b0;
        init_en = 1'b0; init_addr = '0; init_data = '0;
        repeat (3) @(posedge clk);
        @(negedge clk) reset = 1'b0;

        preload(5'd1,  32'hFFFFFFFF);
        preload(5'd2,  32'hFFFFFFFF);
        preload(5'd3,  32'h00000005);
        preload(5'd4,  32'h00000003);
        preload(5'd5,  32'hF0F0F0F0);
        preload(5'd6,  32'h0FF00FF0);
        preload(5'd7,  32'hFFFFFFF0);   // -16
        preload(5'd8,  32'h00000002);
        preload(5'd9,  32'h80000000);   // most negative
        preload(5'd10, 32'h7FFFFFFF);   // most positive
        idle(2);
        checking = 1'b1;

        $display("");
        banner("R-TYPE : register-register operations (opcode 0110011)");
        issue(i_add (5'd11, 5'd1, 5'd2 ), 64'h0000_0001_FFFF_FFFE, 5'd11, "ADD  x11,x1,x2");
        issue(i_add (5'd12, 5'd3, 5'd4 ), 64'h0000_0000_0000_0008, 5'd12, "ADD  x12,x3,x4");
        issue(i_sub (5'd13, 5'd3, 5'd4 ), 64'h0000_0000_0000_0002, 5'd13, "SUB  x13,x3,x4");
        issue(i_sub (5'd14, 5'd4, 5'd3 ), 64'hFFFF_FFFF_FFFF_FFFE, 5'd14, "SUB  x14,x4,x3");
        issue(i_and (5'd16, 5'd5, 5'd6 ), 64'h0000_0000_00F0_00F0, 5'd16, "AND  x16,x5,x6");
        issue(i_or  (5'd17, 5'd5, 5'd6 ), 64'h0000_0000_FFF0_FFF0, 5'd17, "OR   x17,x5,x6");
        issue(i_xor (5'd18, 5'd5, 5'd6 ), 64'h0000_0000_FF00_FF00, 5'd18, "XOR  x18,x5,x6");
        issue(i_sll (5'd20, 5'd1, 5'd4 ), 64'h0000_0007_FFFF_FFF8, 5'd20, "SLL  x20,x1,x4");
        issue(i_srl (5'd22, 5'd1, 5'd4 ), 64'h0000_0000_1FFF_FFFF, 5'd22, "SRL  x22,x1,x4");
        issue(i_sra (5'd24, 5'd7, 5'd8 ), 64'hFFFF_FFFF_FFFF_FFFC, 5'd24, "SRA  x24,x7,x8");
        issue(i_sra (5'd25, 5'd9, 5'd4 ), 64'hFFFF_FFFF_F000_0000, 5'd25, "SRA  x25,x9,x4");
        issue(i_slt (5'd26, 5'd7, 5'd3 ), 64'h0000_0000_0000_0001, 5'd26, "SLT  x26,x7,x3");
        issue(i_slt (5'd27, 5'd9, 5'd10), 64'h0000_0000_0000_0001, 5'd27, "SLT  x27,x9,x10");
        issue(i_sltu(5'd28, 5'd7, 5'd3 ), 64'h0000_0000_0000_0000, 5'd28, "SLTU x28,x7,x3");
        issue(i_sltu(5'd29, 5'd9, 5'd10), 64'h0000_0000_0000_0000, 5'd29, "SLTU x29,x9,x10");
        idle(6);

        banner("I-TYPE : register-immediate operations (opcode 0010011)");
        issue(i_addi (5'd11, 5'd3, 12'd10  ), 64'h0000_0000_0000_000F, 5'd11, "ADDI  x11,x3,10");
        issue(i_slti (5'd12, 5'd7, 12'd5   ), 64'h0000_0000_0000_0001, 5'd12, "SLTI  x12,x7,5");
        issue(i_sltiu(5'd13, 5'd7, 12'd5   ), 64'h0000_0000_0000_0000, 5'd13, "SLTIU x13,x7,5");
        issue(i_xori (5'd14, 5'd1, 12'hFFF ), 64'h0000_0000_0000_0000, 5'd14, "XORI  x14,x1,-1");
        issue(i_ori  (5'd15, 5'd3, 12'd8   ), 64'h0000_0000_0000_000D, 5'd15, "ORI   x15,x3,8");
        issue(i_andi (5'd16, 5'd5, 12'h0FF ), 64'h0000_0000_0000_00F0, 5'd16, "ANDI  x16,x5,0xFF");
        issue(i_slli (5'd17, 5'd3, 5'd4    ), 64'h0000_0000_0000_0050, 5'd17, "SLLI  x17,x3,4");
        issue(i_srli (5'd18, 5'd1, 5'd4    ), 64'h0000_0000_0FFF_FFFF, 5'd18, "SRLI  x18,x1,4");
        issue(i_srai (5'd19, 5'd7, 5'd2    ), 64'hFFFF_FFFF_FFFF_FFFC, 5'd19, "SRAI  x19,x7,2");
        idle(6);

        banner("FORWARDING : back-to-back dependent instructions, no stalls");
        // x11 = 100, then read it at distances 1, 2, 3 and 4
        issue(i_addi(5'd11, 5'd0,  12'd100), 64'h0000_0000_0000_0064, 5'd11, "ADDI x11,x0,100");
        issue(i_addi(5'd12, 5'd11, 12'd1  ), 64'h0000_0000_0000_0065, 5'd12, "ADDI x12,x11,1  d=1");
        issue(i_addi(5'd13, 5'd11, 12'd2  ), 64'h0000_0000_0000_0066, 5'd13, "ADDI x13,x11,2  d=2");
        issue(i_addi(5'd14, 5'd11, 12'd3  ), 64'h0000_0000_0000_0067, 5'd14, "ADDI x14,x11,3  d=3");
        issue(i_addi(5'd15, 5'd11, 12'd4  ), 64'h0000_0000_0000_0068, 5'd15, "ADDI x15,x11,4  d=4");
        idle(6);

        banner("FORWARDING : dependency chain, every instruction feeds the next");
        issue(i_addi(5'd20, 5'd0,  12'd1), 64'h0000_0000_0000_0001, 5'd20, "ADDI x20,x0,1");
        issue(i_add (5'd20, 5'd20, 5'd20), 64'h0000_0000_0000_0002, 5'd20, "ADD  x20,x20,x20");
        issue(i_add (5'd20, 5'd20, 5'd20), 64'h0000_0000_0000_0004, 5'd20, "ADD  x20,x20,x20");
        issue(i_add (5'd20, 5'd20, 5'd20), 64'h0000_0000_0000_0008, 5'd20, "ADD  x20,x20,x20");
        idle(6);

        banner("x0 : writes to the zero register are discarded");
        issue(i_add (5'd0,  5'd1, 5'd2), 64'h0000_0001_FFFF_FFFE, 5'd0,  "ADD  x0,x1,x2");
        idle(6);
        issue(i_addi(5'd21, 5'd0, 12'd0), 64'h0000_0000_0000_0000, 5'd21, "ADDI x21,x0,0");
        idle(6);

        banner("ILLEGAL INSTRUCTION DETECTION");
        checking = 1'b0;
        @(negedge clk); instr = 32'hFFFF_FFFF; instr_valid = 1'b1;  // bad opcode
        @(negedge clk); instr_valid = 1'b0;
        repeat (3) @(posedge clk); #1;
        if (illegal_instr && !result_valid) begin
            pass_count++;
            $display("  0xFFFFFFFF flagged illegal, no writeback   [PASS]\n");
        end else begin
            fail_count++;
            $display("  illegal_instr=%b result_valid=%b   [FAIL]\n",
                     illegal_instr, result_valid);
        end
        idle(6);

        //---------------------------------------------------------------------
        $display("============================================================");
        if (wr_ptr != rd_ptr) begin
            fail_count++;
            $display("  ERROR: %0d issued but %0d retired", wr_ptr, rd_ptr);
        end
        $display("  SUMMARY : %0d passed, %0d failed, %0d total",
                 pass_count, fail_count, pass_count + fail_count);
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else                 $display("  *** THERE ARE FAILURES ***");
        $display("============================================================");
        $finish;
    end

endmodule
