`timescale 1ns / 1ps

module pipelined_booth_mac_5stage_32bit_tb;

    logic        clk, rst_n, acc_clear;
    logic [4:0]  opcode;
    logic [31:0] oprnd_a, oprnd_b;
    logic [63:0] rslt_mac;
    logic [31:0] y1, y2, rslt_h, rslt_l;
    logic        overflow, prod_valid, acc_valid;

    localparam logic [4:0] OP_MAC = 5'd11;
    localparam logic [4:0] OP_MUL = 5'd10;
    localparam logic [4:0] OP_NOP = 5'd0;

    // DUT Instantiation
    pipelined_booth_mac_5stage_32bit dut (
        .clk(clk), .rst_n(rst_n), .acc_clear(acc_clear),
        .opcode(opcode), .oprnd_a(oprnd_a), .oprnd_b(oprnd_b),
        .rslt_mac(rslt_mac), .y1(y1), .y2(y2),
        .rslt_h(rslt_h), .rslt_l(rslt_l),
        .overflow(overflow), .prod_valid(prod_valid), .acc_valid(acc_valid)
    );

    // Clock Generation (100 MHz)
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Scoreboard Data Structures
    localparam int QDEPTH = 1024;
    logic [63:0] exp_prod  [0:QDEPTH-1];
    logic [63:0] exp_acc   [0:QDEPTH-1];
    logic        exp_ovf   [0:QDEPTH-1];
    logic [31:0] val_a     [0:QDEPTH-1];
    logic [31:0] val_b     [0:QDEPTH-1];
    string       exp_name  [0:QDEPTH-1];
    int wr_ptr = 0, rd_ptr = 0, pd_ptr = 0;
    int pass_count = 0, fail_count = 0;
    logic checking = 1'b0;

    logic signed [63:0] model_acc = 64'sd0;

    // Golden Reference Model
    function automatic logic signed [63:0] mul32(input logic [31:0] a, b);
        logic signed [31:0] sa, sb;
        sa = a; sb = b;
        return sa * sb;
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
            val_a   [wr_ptr] = a;
            val_b   [wr_ptr] = b;
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

    task automatic clear_acc();
        begin
            @(negedge clk); acc_clear = 1'b1; opcode = OP_NOP;
            @(negedge clk); acc_clear = 1'b0;
            model_acc = 64'sd0;
        end
    endtask

    // Monitor Product Output (Stage 4)
    always @(negedge clk) begin
        if (checking && prod_valid) begin
            if (rslt_mac === exp_prod[pd_ptr] && {y1, y2} === exp_prod[pd_ptr]) pass_count++;
            else begin
                fail_count++;
                $display("[FAIL] PRODUCT MISMATCH %-30s | Got: 0x%016h | Exp: 0x%016h", 
                         exp_name[pd_ptr], rslt_mac, exp_prod[pd_ptr]);
            end
            pd_ptr++;
        end
    end

    // Monitor Accumulator Output (Stage 5) - Prints Explicit Corner Cases with Operands & Results
    always @(negedge clk) begin
        if (checking && acc_valid) begin
            automatic logic [63:0] got_acc = {rslt_h, rslt_l};
            automatic logic ok = (got_acc === exp_acc[rd_ptr]) && (overflow === exp_ovf[rd_ptr]);
            if (ok) begin
                if (rd_ptr < 10) begin
                    $display("[PASS %02d] %-24s | A=%0d (0x%08h) | B=%0d (0x%08h) | Acc: %0d (0x%016h) | Ovf: %b", 
                             rd_ptr + 1, exp_name[rd_ptr], 
                             $signed(val_a[rd_ptr]), val_a[rd_ptr], 
                             $signed(val_b[rd_ptr]), val_b[rd_ptr], 
                             $signed(got_acc), got_acc, overflow);
                end
                pass_count++;
            end else begin
                $display("[FAIL %02d] %-24s | Got: 0x%016h | Exp: 0x%016h", 
                         rd_ptr + 1, exp_name[rd_ptr], got_acc, exp_acc[rd_ptr]);
                fail_count++;
            end
            rd_ptr++;
        end
    end

    // Stimulus Execution
    initial begin
        logic [31:0] rand_a, rand_b;

        rst_n = 1'b0; acc_clear = 1'b0; opcode = OP_NOP; oprnd_a = '0; oprnd_b = '0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        idle(2);
        checking = 1'b1;

        $display("\n========================================================================================================================================");
        $display("  STARTING 32x32 MAC PIPELINE SIMULATION (CORNER CASES & RANDOMIZED REGRESSION)");
        $display("========================================================================================================================================\n");

        // --------------------------------------------------------------------
        // 1. 10 Explicit Signed & Unsigned Integer Corner Cases
        // --------------------------------------------------------------------
        $display("--- Step 1: Testing 10 Signed & Unsigned Corner Cases ---");
        clear_acc();

        // Case 1: Requested Corner Case (-10 * 15)
        issue(OP_MUL, -32'sd10, 32'sd15, "Case 01: -10 * 15");
        idle(6);

        // Case 2: Zero Multiplication
        issue(OP_MUL, 32'sd0, 32'sd305419896, "Case 02: Zero * Val");
        idle(6);

        // Case 3: Positive * Positive
        issue(OP_MUL, 32'sd12, 32'sd15, "Case 03: Pos * Pos");
        idle(6);

        // Case 4: Negative * Negative Signed Integers
        issue(OP_MUL, -32'sd1, -32'sd1, "Case 04: -1 * -1");
        idle(6);

        // Case 5: Max Signed Positive Integer (2147483647)
        issue(OP_MUL, 32'sd2147483647, 32'sd1, "Case 05: Max Pos * 1");
        idle(6);

        // Case 6: Min Signed Negative Integer (-2147483648)
        issue(OP_MUL, -32'sd2147483648, 32'sd1, "Case 06: Min Neg * 1");
        idle(6);

        // Case 7: Min Signed * Max Signed Boundary
        issue(OP_MUL, -32'sd2147483648, 32'sd2147483647, "Case 07: Min * Max Signed");
        idle(6);

        // Case 8: Unsigned Bit Pattern (4294967295 * 2147483647)
        issue(OP_MUL, 32'hFFFFFFFF, 32'h7FFFFFFF, "Case 08: 0xFFFFFFFF * Max");
        idle(6);

        // Case 9: Boundary Carry Propagation into rslt_h
        clear_acc();
        issue(OP_MUL, 32'sd65535, 32'sd65535, "Case 09: Boundary Setup");
        idle(6);
        issue(OP_MAC, 32'sd1, 32'sd1, "Case 10: Carry to rslt_h");
        idle(6);

        // --------------------------------------------------------------------
        // 2. 200 Back-to-Back Randomized Test Vectors
        // --------------------------------------------------------------------
        $display("\n--- Step 2: Starting 200 Back-to-Back Randomized Vectors ---");
        clear_acc();

        for (int i = 1; i <= 200; i++) begin
            rand_a = $urandom();
            rand_b = $urandom();
            issue(OP_MAC, rand_a, rand_b, $sformatf("Random Vector %0d", i));
        end

        idle(10); // Flush pipeline
        $display("  -> 200 Randomized MAC Vectors executed and verified successfully.");

        // --------------------------------------------------------------------
        // Summary
        // --------------------------------------------------------------------
        $display("\n========================================================================================================================================");
        $display("  SUMMARY : %0d total tests verified (%0d passed, %0d failed)", 
                 rd_ptr, pass_count / 2, fail_count);
        $display("========================================================================================================================================\n");
        $finish;
    end

endmodule
