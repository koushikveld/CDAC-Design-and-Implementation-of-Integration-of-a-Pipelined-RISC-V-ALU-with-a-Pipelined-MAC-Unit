`timescale 1ns / 1ps
//=============================================================================
// Testbench for pipelined_booth_mac_5stage (32-Bit Operands)
//=============================================================================

module pipelined_booth_mac_5stage_tb;

    logic        clk, rst_n, acc_clear;
    logic [4:0]  opcode;
    logic [31:0] oprnd_a, oprnd_b;
    logic [63:0] rslt_mac;
    logic [31:0] y1, y2, rslt_h, rslt_l;
    logic        overflow, prod_valid, acc_valid;

    localparam logic [4:0] OP_MAC = 5'd11;
    localparam logic [4:0] OP_MUL = 5'd10;
    localparam logic [4:0] OP_NOP = 5'd0;

    pipelined_booth_mac_5stage dut (
        .clk(clk), .rst_n(rst_n), .acc_clear(acc_clear),
        .opcode(opcode), .oprnd_a(oprnd_a), .oprnd_b(oprnd_b),
        .rslt_mac(rslt_mac), .y1(y1), .y2(y2),
        .rslt_h(rslt_h), .rslt_l(rslt_l),
        .overflow(overflow), .prod_valid(prod_valid), .acc_valid(acc_valid)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Scoreboard
    localparam int QDEPTH = 256;
    logic [63:0] exp_prod [0:QDEPTH-1];
    logic [63:0] exp_acc  [0:QDEPTH-1];
    logic        exp_ovf  [0:QDEPTH-1];
    string       exp_name [0:QDEPTH-1];
    int wr_ptr = 0, rd_ptr = 0, pd_ptr = 0;
    int pass_count = 0, fail_count = 0;
    logic checking = 1'b0;
    logic verbose  = 1'b1;

    // Golden model state
    logic signed [63:0] model_acc = 64'sd0;

    function automatic logic signed [63:0] mul32(input logic [31:0] a, b);
        logic signed [31:0] sa, sb;
        sa = a; sb = b;
        return 64'(sa) * 64'(sb);
    endfunction

    task automatic issue(input logic [4:0]  op,
                         input logic [31:0] a, b,
                         input string       nm);
        logic signed [63:0] prod;
        logic signed [63:0] newacc;
        logic               ovf;
        begin
            prod = mul32(a, b);
            if (op == OP_MAC) begin
                newacc = model_acc + prod;
                ovf    = (prod[63] == model_acc[63]) && (newacc[63] != model_acc[63]);
            end else begin
                newacc = prod;
                ovf    = 1'b0;
            end

            @(negedge clk);
            opcode  = op;
            oprnd_a = a;
            oprnd_b = b;

            exp_prod[wr_ptr] = prod;
            exp_acc [wr_ptr] = newacc;
            exp_ovf [wr_ptr] = ovf;
            exp_name[wr_ptr] = nm;
            wr_ptr++;
            model_acc = newacc;
        end
    endtask

    task automatic idle(input int n);
        begin
            for (int i = 0; i < n; i++) begin
                @(negedge clk);
                opcode = OP_NOP;
            end
        end
    endtask

    // Monitor A: product check
    always @(negedge clk) begin
        if (checking && prod_valid) begin
            if (rslt_mac === exp_prod[pd_ptr] &&
                {y1, y2}  === exp_prod[pd_ptr]) pass_count++;
            else begin
                fail_count++;
                $display("PRODUCT MISMATCH %-20s got 0x%h  exp 0x%h",
                         exp_name[pd_ptr], rslt_mac, exp_prod[pd_ptr]);
            end
            pd_ptr++;
        end
    end

    // Monitor B: accumulator check
    always @(negedge clk) begin
        if (checking && acc_valid) begin
            automatic logic [63:0] got_acc = {rslt_h, rslt_l};
            automatic logic ok = (got_acc  === exp_acc [rd_ptr]) &&
                                 (overflow === exp_ovf [rd_ptr]);
            if (verbose || !ok) begin
                $display("%-26s  product = 0x%h (%0d)",
                         exp_name[rd_ptr], exp_prod[rd_ptr], $signed(exp_prod[rd_ptr]));
                $display("   acc     = 0x%h   (%0d)   ovf=%b", got_acc, $signed(got_acc), overflow);
                $display("   expected= 0x%h   (%0d)   ovf=%b   [%s]\n",
                         exp_acc[rd_ptr], $signed(exp_acc[rd_ptr]), exp_ovf[rd_ptr],
                         ok ? "PASS" : "FAIL");
            end
            if (ok) pass_count++; else fail_count++;
            rd_ptr++;
        end
    end

    task automatic banner(input string t);
        begin
            $display("============================================================");
            $display("  %s", t);
            $display("============================================================");
        end
    endtask

    task automatic clear_acc();
        begin
            @(negedge clk); acc_clear = 1'b1; opcode = OP_NOP;
            @(negedge clk); acc_clear = 1'b0;
            model_acc = 64'sd0;
        end
    endtask

    initial begin
        rst_n = 1'b0; acc_clear = 1'b0;
        opcode = OP_NOP; oprnd_a = '0; oprnd_b = '0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        idle(2);
        checking = 1'b1;
        $display("");

        banner("SIGNED MULTIPLY CORNER CASES (32-BIT)");
        issue(OP_MUL, 32'h00000003, 32'h00000005, "3 * 5");
        idle(8);
        issue(OP_MUL, 32'hFFFFFFFF, 32'hFFFFFFFF, "-1 * -1");
        idle(8);
        issue(OP_MUL, 32'h80000000, 32'h80000000, "-2147483648 * -2147483648");
        idle(8);
        issue(OP_MUL, 32'h80000000, 32'h7FFFFFFF, "Min * Max Signed");
        idle(8);
        issue(OP_MUL, 32'h7FFFFFFF, 32'h7FFFFFFF, "Max Signed * Max Signed");
        idle(8);
        issue(OP_MUL, 32'hFFFFFFFB, 32'h00000007, "-5 * 7");
        idle(8);

        banner("ACCUMULATION (32-BIT OP_MAC)");
        clear_acc();
        issue(OP_MAC, 32'h00000002, 32'h00000003, "acc += 2*3");
        idle(8);
        issue(OP_MAC, 32'h00000004, 32'h00000005, "acc += 4*5");
        idle(8);

        banner("DOT PRODUCT, back-to-back");
        clear_acc();
        for (int k = 1; k <= 8; k++) begin
            issue(OP_MAC, 32'(k), 32'(k), $sformatf("acc += %0d*%0d", k, k));
        end
        idle(10);

        banner("CARRY ACROSS THE 32-BIT HALVES");
        clear_acc();
        issue(OP_MAC, 32'h0000FFFF, 32'h00010001, "acc += 65535*65537");
        idle(8);
        issue(OP_MAC, 32'h00000001, 32'h00000001, "acc += 1 (carry to high half)");
        idle(8);

        banner("MIXED SIGNS, RANDOM REGRESSION");
        clear_acc();
        verbose = 1'b0;
        for (int k = 0; k < 200; k++) begin
            issue(OP_MAC, $urandom(), $urandom(), "random");
        end
        idle(10);
        verbose = 1'b1;
        $display("  200 randomised 32-bit MACs issued back-to-back\n");

        $display("============================================================");
        if (wr_ptr != rd_ptr || wr_ptr != pd_ptr) begin
            fail_count++;
            $display("  ERROR: %0d issued, %0d products, %0d accumulates",
                     wr_ptr, pd_ptr, rd_ptr);
        end
        $display("  SUMMARY : %0d passed, %0d failed, %0d total",
                 pass_count, fail_count, pass_count + fail_count);
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else                 $display("  *** THERE ARE FAILURES ***");
        $display("============================================================");
        $finish;
    end

endmodule
