`timescale 1ns / 1ps
//=============================================================================
// Testbench for riscv_alu_5stage (400+ Testcases, Exact Original Operations)
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
    // Scoreboard & Reference Model
    //-------------------------------------------------------------------------
    localparam int QDEPTH = 1024;
    logic [RLEN-1:0] exp_val  [0:QDEPTH-1];
    logic [4:0]      exp_rd   [0:QDEPTH-1];
    string           exp_name [0:QDEPTH-1];
    int wr_ptr = 0;
    int rd_ptr = 0;
    int pass_count = 0;
    int fail_count = 0;
    logic checking = 1'b0;

    logic [31:0] ref_regs [0:31];

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

    // Monitor: Outputs 32-bit formatted results
    always @(negedge clk) begin
        if (checking && result_valid) begin
            $display("%-24s  rd=x%0d", exp_name[rd_ptr], result_rd);
            $display("     Out = %b", result[31:0]);
            $display("     Out = 0x%08h   unsigned %0d   signed %0d",
                     result[31:0], result[31:0], $signed(result[31:0]));
            if ((result[31:0] === exp_val[rd_ptr][31:0]) && (result_rd === exp_rd[rd_ptr])) begin
                pass_count++;
                $display("     Exp = 0x%08h   rd=x%0d   [PASS]\n",
                         exp_val[rd_ptr][31:0], exp_rd[rd_ptr]);
            end else begin
                fail_count++;
                $display("     Exp = 0x%08h   rd=x%0d   [FAIL]\n",
                         exp_val[rd_ptr][31:0], exp_rd[rd_ptr]);
            end
            rd_ptr++;
        end
    end

    task automatic preload(input logic [4:0] addr, input logic [XLEN-1:0] data);
        begin
            @(negedge clk);
            init_en = 1'b1; init_addr = addr; init_data = data;
            if (addr != 0) ref_regs[addr] = data;
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

    // Helper task to compute expectations dynamically for loop iterations
    task automatic issue_and_compute(input logic [31:0] inst,
                                     input logic [4:0] rdx,
                                     input string nm,
                                     input int op_type,
                                     input logic [4:0] rs1_idx,
                                     input logic [4:0] rs2_idx,
                                     input logic [11:0] imm_val);
        logic [31:0] op1, op2, exp_32;
        op1 = ref_regs[rs1_idx];
        op2 = ref_regs[rs2_idx];

        case (op_type)
            0: exp_32 = op1 + op2;
            1: exp_32 = op1 - op2;
            2: exp_32 = op1 & op2;
            3: exp_32 = op1 | op2;
            4: exp_32 = op1 ^ op2;
            5: exp_32 = op1 << op2[4:0];
            6: exp_32 = op1 >> op2[4:0];
            7: exp_32 = $signed(op1) >>> op2[4:0];
            8: exp_32 = ($signed(op1) < $signed(op2)) ? 32'd1 : 32'd0;
            9: exp_32 = (op1 < op2) ? 32'd1 : 32'd0;
            10: exp_32 = op1 + {{(20){imm_val[11]}}, imm_val};
            11: exp_32 = ($signed(op1) < $signed({{(20){imm_val[11]}}, imm_val})) ? 32'd1 : 32'd0;
            12: exp_32 = (op1 < {{(20){imm_val[11]}}, imm_val}) ? 32'd1 : 32'd0;
            13: exp_32 = op1 ^ {{(20){imm_val[11]}}, imm_val};
            14: exp_32 = op1 | {{(20){imm_val[11]}}, imm_val};
            15: exp_32 = op1 & {{(20){imm_val[11]}}, imm_val};
            16: exp_32 = op1 << imm_val[4:0];
            17: exp_32 = op1 >> imm_val[4:0];
            18: exp_32 = $signed(op1) >>> imm_val[4:0];
        endcase

        issue(inst, {32'd0, exp_32}, rdx, nm);
        if (rdx != 0) ref_regs[rdx] = exp_32;
    endtask

    // Task executing the complete set of exact operations from your images
    task automatic run_exact_operations_suite(input int iteration_num);
        string suffix;
        if (iteration_num == 0) suffix = "";
        else                    suffix = $sformatf(" [RUN %0d]", iteration_num);

        banner($sformatf("R-TYPE : register-register operations (opcode 0110011)%s", suffix));
        issue_and_compute(i_add (5'd11, 5'd1, 5'd2 ), 5'd11, $sformatf("ADD  x11,x1,x2%s", suffix), 0, 5'd1, 5'd2, 12'd0);
        issue_and_compute(i_add (5'd12, 5'd3, 5'd4 ), 5'd12, $sformatf("ADD  x12,x3,x4%s", suffix), 0, 5'd3, 5'd4, 12'd0);
        issue_and_compute(i_sub (5'd13, 5'd3, 5'd4 ), 5'd13, $sformatf("SUB  x13,x3,x4%s", suffix), 1, 5'd3, 5'd4, 12'd0);
        issue_and_compute(i_sub (5'd14, 5'd4, 5'd3 ), 5'd14, $sformatf("SUB  x14,x4,x3%s", suffix), 1, 5'd4, 5'd3, 12'd0);
        issue_and_compute(i_and (5'd16, 5'd5, 5'd6 ), 5'd16, $sformatf("AND  x16,x5,x6%s", suffix), 2, 5'd5, 5'd6, 12'd0);
        issue_and_compute(i_or  (5'd17, 5'd5, 5'd6 ), 5'd17, $sformatf("OR   x17,x5,x6%s", suffix), 3, 5'd5, 5'd6, 12'd0);
        issue_and_compute(i_xor (5'd18, 5'd5, 5'd6 ), 5'd18, $sformatf("XOR  x18,x5,x6%s", suffix), 4, 5'd5, 5'd6, 12'd0);
        issue_and_compute(i_sll (5'd20, 5'd1, 5'd4 ), 5'd20, $sformatf("SLL  x20,x1,x4%s", suffix), 5, 5'd1, 5'd4, 12'd0);
        issue_and_compute(i_srl (5'd22, 5'd1, 5'd4 ), 5'd22, $sformatf("SRL  x22,x1,x4%s", suffix), 6, 5'd1, 5'd4, 12'd0);
        issue_and_compute(i_sra (5'd24, 5'd7, 5'd8 ), 5'd24, $sformatf("SRA  x24,x7,x8%s", suffix), 7, 5'd7, 5'd8, 12'd0);
        issue_and_compute(i_sra (5'd25, 5'd9, 5'd4 ), 5'd25, $sformatf("SRA  x25,x9,x4%s", suffix), 7, 5'd9, 5'd4, 12'd0);
        issue_and_compute(i_slt (5'd26, 5'd7, 5'd3 ), 5'd26, $sformatf("SLT  x26,x7,x3%s", suffix), 8, 5'd7, 5'd3, 12'd0);
        issue_and_compute(i_slt (5'd27, 5'd9, 5'd10), 5'd27, $sformatf("SLT  x27,x9,x10%s", suffix), 8, 5'd9, 5'd10, 12'd0);
        issue_and_compute(i_sltu(5'd28, 5'd7, 5'd3 ), 5'd28, $sformatf("SLTU x28,x7,x3%s", suffix), 9, 5'd7, 5'd3, 12'd0);
        issue_and_compute(i_sltu(5'd29, 5'd9, 5'd10), 5'd29, $sformatf("SLTU x29,x9,x10%s", suffix), 9, 5'd9, 5'd10, 12'd0);
        idle(6);

        banner($sformatf("I-TYPE : register-immediate operations (opcode 0010011)%s", suffix));
        issue_and_compute(i_addi (5'd11, 5'd3, 12'd10  ), 5'd11, $sformatf("ADDI  x11,x3,10%s", suffix), 10, 5'd3, 5'd0, 12'd10);
        issue_and_compute(i_slti (5'd12, 5'd7, 12'd5   ), 5'd12, $sformatf("SLTI  x12,x7,5%s", suffix),  11, 5'd7, 5'd0, 12'd5);
        issue_and_compute(i_sltiu(5'd13, 5'd7, 12'd5   ), 5'd13, $sformatf("SLTIU x13,x7,5%s", suffix),  12, 5'd7, 5'd0, 12'd5);
        issue_and_compute(i_xori (5'd14, 5'd1, 12'hFFF ), 5'd14, $sformatf("XORI  x14,x1,-1%s", suffix), 13, 5'd1, 5'd0, 12'hFFF);
        issue_and_compute(i_ori  (5'd15, 5'd3, 12'd8   ), 5'd15, $sformatf("ORI   x15,x3,8%s", suffix),  14, 5'd3, 5'd0, 12'd8);
        issue_and_compute(i_andi (5'd16, 5'd5, 12'h0FF ), 5'd16, $sformatf("ANDI  x16,x5,0xFF%s", suffix), 15, 5'd5, 5'd0, 12'h0FF);
        issue_and_compute(i_slli (5'd17, 5'd3, 5'd4    ), 5'd17, $sformatf("SLLI  x17,x3,4%s", suffix),  16, 5'd3, 5'd0, 12'd4);
        issue_and_compute(i_srli (5'd18, 5'd1, 5'd4    ), 5'd18, $sformatf("SRLI  x18,x1,4%s", suffix),  17, 5'd1, 5'd0, 12'd4);
        issue_and_compute(i_srai (5'd19, 5'd7, 5'd2    ), 5'd19, $sformatf("SRAI  x19,x7,2%s", suffix),  18, 5'd7, 5'd0, 12'd2);
        idle(6);

        banner($sformatf("FORWARDING : back-to-back dependent instructions, no stalls%s", suffix));
        issue_and_compute(i_addi(5'd11, 5'd0,  12'd100), 5'd11, $sformatf("ADDI x11,x0,100%s", suffix), 10, 5'd0, 5'd0, 12'd100);
        issue_and_compute(i_addi(5'd12, 5'd11, 12'd1  ), 5'd12, $sformatf("ADDI x12,x11,1  d=1%s", suffix), 10, 5'd11, 5'd0, 12'd1);
        issue_and_compute(i_addi(5'd13, 5'd11, 12'd2  ), 5'd13, $sformatf("ADDI x13,x11,2  d=2%s", suffix), 10, 5'd11, 5'd0, 12'd2);
        issue_and_compute(i_addi(5'd14, 5'd11, 12'd3  ), 5'd14, $sformatf("ADDI x14,x11,3  d=3%s", suffix), 10, 5'd11, 5'd0, 12'd3);
        issue_and_compute(i_addi(5'd15, 5'd11, 12'd4  ), 5'd15, $sformatf("ADDI x15,x11,4  d=4%s", suffix), 10, 5'd11, 5'd0, 12'd4);
        idle(6);

        banner($sformatf("FORWARDING : dependency chain, every instruction feeds the next%s", suffix));
        issue_and_compute(i_addi(5'd20, 5'd0,  12'd1), 5'd20, $sformatf("ADDI x20,x0,1%s", suffix), 10, 5'd0, 5'd0, 12'd1);
        issue_and_compute(i_add (5'd20, 5'd20, 5'd20), 5'd20, $sformatf("ADD  x20,x20,x20%s", suffix), 0, 5'd20, 5'd20, 12'd0);
        issue_and_compute(i_add (5'd20, 5'd20, 5'd20), 5'd20, $sformatf("ADD  x20,x20,x20%s", suffix), 0, 5'd20, 5'd20, 12'd0);
        issue_and_compute(i_add (5'd20, 5'd20, 5'd20), 5'd20, $sformatf("ADD  x20,x20,x20%s", suffix), 0, 5'd20, 5'd20, 12'd0);
        idle(6);

        banner($sformatf("x0 : writes to the zero register are discarded%s", suffix));
        issue_and_compute(i_add (5'd0,  5'd1, 5'd2), 5'd0, $sformatf("ADD  x0,x1,x2%s", suffix), 0, 5'd1, 5'd2, 12'd0);
        idle(6);
        issue_and_compute(i_addi(5'd21, 5'd0, 12'd0), 5'd21, $sformatf("ADDI x21,x0,0%s", suffix), 10, 5'd0, 5'd0, 12'd0);
        idle(6);
    endtask

    //-------------------------------------------------------------------------
    initial begin
        for (int i = 0; i < 32; i++) ref_regs[i] = 32'd0;

        reset = 1'b1; instr = 32'h0000_0013; instr_valid = 1'b0;
        init_en = 1'b0; init_addr = '0; init_data = '0;
        repeat (3) @(posedge clk);
        @(negedge clk) reset = 1'b0;

        // Initial preloads for Run 0 (exact initial image values)
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

        // Run 12 iterations of the exact suite (12 x 35 = 420 testcases)
        for (int k = 0; k < 12; k++) begin
            if (k > 0) begin
                for (int i = 1; i <= 10; i++) begin
                    preload(i[4:0], $urandom());
                end
                idle(2);
            end
            run_exact_operations_suite(k);
        end

        // Final Illegal Instruction Check
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
