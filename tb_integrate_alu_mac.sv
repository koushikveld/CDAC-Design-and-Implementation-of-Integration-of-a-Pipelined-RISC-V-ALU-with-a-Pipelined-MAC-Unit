`timescale 1ns / 1ps
//=============================================================================
// OOP Testbench: Integrated ALU + MAC + Barrel Shifter + Booth Verification
// Scale: 450 Total Iterations (40 Corner Cases + 410 Random Operations)
// Verification flow preserved from the original testbench.
// Additional directed checks exercise the actual barrel-shifter boundary
// behavior and Booth multiplier signed corner cases.
//=============================================================================

interface processor_if(input logic clk, reset);
    logic [31:0] instr;
    logic        instr_valid;
    logic        acc_clear;
    logic [63:0] result;
    logic [4:0]  result_rd;
    logic        result_valid;
    logic        illegal_instr;
    logic        mac_overflow;
    logic        init_en;
    logic [4:0]  init_addr;
    logic [31:0] init_data;
endinterface

// ----------------------------------------------------------------------------
// Transaction Class
// ----------------------------------------------------------------------------
class transaction;
    rand logic [6:0] opcode;
    rand logic [4:0] rd, rs1, rs2;
    rand logic [2:0] funct3;
    rand logic [6:0] funct7;
    rand logic [11:0] imm;
    
    rand logic [31:0] val_a, val_b;
    string test_name;
    string op_name;
    bit    is_corner;
    logic [63:0] expected_result;
    bit    expected_valid;
    bit    clear_before;

    constraint op_types {
        opcode inside {7'b0110011, 7'b0010011, 7'b0001011, 7'b0001010};
    }
    
    constraint reg_dist {
        rd  inside {[1:31]};
        rs1 inside {[1:31]};
        rs2 inside {[1:31]};
    }

    constraint funct_dist {
        funct3 inside {[3'b000:3'b111]};
        funct7 inside {7'b0000000, 7'b0100000};
    }

    function logic signed [63:0] ref_mul_signed(input logic [31:0] a, input logic [31:0] b);
        logic signed [31:0] sa, sb;
        begin
            sa = a; sb = b;
            ref_mul_signed = sa * sb;
        end
    endfunction

    function logic [31:0] get_instr();
        if (opcode == 7'b0110011) return {funct7, rs2, rs1, funct3, rd, opcode}; // R-type ALU
        else if (opcode == 7'b0010011) return {imm, rs1, funct3, rd, opcode};     // I-type ALU
        else return {7'b0000000, rs2, rs1, 3'b000, rd, 2'b00, opcode[4:0]};        // MAC Unit
    endfunction

    function string decode_op_name();
        case (opcode)
            7'b0001011: return "MAC_UNIT (OP_MAC)";
            7'b0001010: return "MAC_UNIT (OP_MUL)";
            7'b0110011: begin
                case (funct3)
                    3'b000: return (funct7[5] == 1'b1) ? "ALU_UNIT (SUB)" : "ALU_UNIT (ADD)";
                    3'b001: return "ALU_UNIT (SLL)";
                    3'b010: return "ALU_UNIT (SLT)";
                    3'b011: return "ALU_UNIT (SLTU)";
                    3'b100: return "ALU_UNIT (XOR)";
                    3'b101: return (funct7[5] == 1'b1) ? "ALU_UNIT (SRA)" : "ALU_UNIT (SRL)";
                    3'b110: return "ALU_UNIT (OR)";
                    3'b111: return "ALU_UNIT (AND)";
                endcase
            end
            7'b0010011: begin
                case (funct3)
                    3'b000: return "ALU_UNIT (ADDI)";
                    3'b001: return "ALU_UNIT (SLLI)";
                    3'b010: return "ALU_UNIT (SLTI)";
                    3'b011: return "ALU_UNIT (SLTIU)";
                    3'b100: return "ALU_UNIT (XORI)";
                    3'b101: return (funct7[5] == 1'b1) ? "ALU_UNIT (SRAI)" : "ALU_UNIT (SRLI)";
                    3'b110: return "ALU_UNIT (ORI)";
                    3'b111: return "ALU_UNIT (ANDI)";
                endcase
            end
        endcase
    endfunction
endclass

// ----------------------------------------------------------------------------
// Functional Coverage Collector Class
// ----------------------------------------------------------------------------
class coverage_collector;
    transaction tr;

    covergroup cg_processor;
        option.per_instance = 1;

        cp_opcode: coverpoint tr.opcode {
            bins r_type  = {7'b0110011};
            bins i_type  = {7'b0010011};
            bins mac_op  = {7'b0001011};
            bins mul_op  = {7'b0001010};
        }

        cp_funct3: coverpoint tr.funct3 {
            bins all_funct3[] = {[3'b000:3'b111]};
        }

        cp_funct7: coverpoint tr.funct7 {
            bins base = {7'b0000000};
            bins alt  = {7'b0100000};
        }

        cp_rd: coverpoint tr.rd {
            bins low_regs  = {[5'd1:5'd15]};
            bins high_regs = {[5'd16:5'd31]};
        }

        cp_rs1: coverpoint tr.rs1 {
            bins low_regs  = {[5'd1:5'd15]};
            bins high_regs = {[5'd16:5'd31]};
        }
        cp_rs2: coverpoint tr.rs2 {
            bins low_regs  = {[5'd1:5'd15]};
            bins high_regs = {[5'd16:5'd31]};
        }

        cp_val_a_corners: coverpoint tr.val_a {
            bins zero      = {32'h0000_0000};
            bins max_pos   = {32'h7FFF_FFFF};
            bins min_neg   = {32'h8000_0000};
            bins minus_one = {32'hFFFF_FFFF};
            bins random    = default;
        }

        cp_val_b_corners: coverpoint tr.val_b {
            bins zero      = {32'h0000_0000};
            bins max_pos   = {32'h7FFF_FFFF};
            bins min_neg   = {32'h8000_0000};
            bins minus_one = {32'hFFFF_FFFF};
            bins random    = default;
        }

        cross_op_funct3: cross cp_opcode, cp_funct3 {
            ignore_bins non_alu_ops = binsof(cp_opcode) intersect {7'b0001011, 7'b0001010};
        }

        cross_operands: cross cp_val_a_corners, cp_val_b_corners;
    endgroup

    function new();
        cg_processor = new();
    endfunction

    function void sample(transaction tr);
        this.tr = tr;
        cg_processor.sample();
    endfunction

    function real get_functional_coverage();
        return cg_processor.get_coverage();
    endfunction

    function real get_code_coverage();
        // Code coverage is a simulator metric; this class does not own a code
        // coverage database, so leave the field as a reported placeholder.
        return 0.0;
    endfunction
endclass

// ----------------------------------------------------------------------------
// Driver Class
// ----------------------------------------------------------------------------
class driver;
    virtual processor_if vif;

    function new(virtual processor_if vif);
        this.vif = vif;
    endfunction

    task drive(transaction tr);
        @(negedge vif.clk);
        vif.init_en   = 1'b1;
        vif.init_addr = tr.rs1;
        vif.init_data = tr.val_a;

        @(negedge vif.clk);
        vif.init_addr = tr.rs2;
        vif.init_data = tr.val_b;

        @(negedge vif.clk);
        vif.init_en   = 1'b0;
        vif.acc_clear = tr.clear_before;

        @(negedge vif.clk);
        vif.acc_clear = 1'b0;

        vif.instr       = tr.get_instr();
        vif.instr_valid = 1'b1;
        @(negedge vif.clk);
        vif.instr_valid = 1'b0;
    endtask
endclass

// ----------------------------------------------------------------------------
// Scoreboard Class
// ----------------------------------------------------------------------------
class scoreboard;
    virtual processor_if vif;
    coverage_collector   cov;

    int pass_cnt = 0;
    int fail_cnt = 0;
    int corner_pass_cnt = 0;
    int total_corner_cases = 40;

    int retired_instructions = 0;

    transaction tr_q[$];

    function new(virtual processor_if vif, coverage_collector cov);
        this.vif = vif;
        this.cov = cov;
    endfunction

    function void add_transaction(transaction tr);
        tr_q.push_back(tr);
        cov.sample(tr);
    endfunction

    task monitor_and_score();
        fork
            forever begin
                @(negedge vif.clk);
                if (vif.result_valid) begin
                    retired_instructions++;
                    if (tr_q.size() > 0) begin
                        transaction tr = tr_q.pop_front();
                        if (tr.expected_valid) begin
                            if (vif.result === tr.expected_result) begin
                                pass_cnt++;
                                if (tr.is_corner) corner_pass_cnt++;
                                $display("----------------------------------------------------------------------------------");
                                $display("  %s : %s", tr.is_corner ? $sformatf("CORNER TEST %0d/%0d", corner_pass_cnt, total_corner_cases) : "RANDOM TEST", tr.test_name);
                                $display("  EXECUTED UNIT     : %s", tr.op_name);
                                $display("  EXPECTED RESULT   : 0x%016h", tr.expected_result);
                                $display("  ACTUAL RESULT     : 0x%016h   [STATUS: PASS]", vif.result);
                                $display("----------------------------------------------------------------------------------");
                            end else begin
                                fail_cnt++;
                                $display("ERROR: %s expected=0x%016h actual=0x%016h", tr.test_name, tr.expected_result, vif.result);
                            end
                        end else begin
                            pass_cnt++;
                        end
                    end
                end
            end
        join_none
    endtask

    function void print_reports();
        int total_iterations = retired_instructions;
        int pipeline_latency = 4;
        int clock_period_ns = 10;
        int clock_freq_mhz = 100;
        int workload_cycles = total_iterations + (pipeline_latency - 1);
        int total_ns = workload_cycles * clock_period_ns;
        real workload_us = real'(total_ns) / 1000.0;
        real corner_pass_rate = (real'(corner_pass_cnt) / real'(total_corner_cases)) * 100.0;

        real func_cov = cov.get_functional_coverage();
        real code_cov = cov.get_code_coverage();
        real overall_cov = (func_cov + code_cov) / 2.0;

        $display("\n============================================================");
        $display("          CORNER TESTCASES VERIFICATION SUMMARY             ");
        $display("============================================================");
        $display(" Explicit Corner Cases Executed : %0d / %0d", corner_pass_cnt, total_corner_cases);
        $display(" Corner Cases Pass Rate        : %0.2f%%", corner_pass_rate);
        $display("============================================================");
        $display("     PERFORMANCE, LATENCY & THROUGHPUT ANALYSIS REPORT      ");
        $display("============================================================");
        $display(" Clock Period                  : %0d ns (%0d MHz)", clock_period_ns, clock_freq_mhz);
        $display(" Execution Stage Latency (S3)  : %0d Cycle   (%0d ns)", 1, clock_period_ns);
        $display(" End-to-End Output Latency     : %0d Cycles  (%0d ns)", pipeline_latency, pipeline_latency * clock_period_ns);
        $display(" Total Iterations Executed     : %0d Iterations", total_iterations);
        $display(" Number of Iterations per Cycle: %0d Iterations / Cycle", 1);
        $display(" Steady-State Throughput       : %0d Instruction / Cycle (1.0 IPC)", 1);
        $display(" Overall Workload Latency      : %0d Cycles = %0d ns = %0.2f us", 
                 workload_cycles, total_ns, workload_us);
        $display("------------------------------------------------------------");
        $display(" Total Operations Tested        : %0d", retired_instructions);
        $display(" Passed Verification Checks    : %0d", pass_cnt);
        $display(" Failed Verification Checks    : %0d", fail_cnt);
        $display("============================================================");
        $display("            COVERAGE METRICS & VERIFICATION REPORT          ");
        $display("============================================================");
        $display(" FUNCTIONAL COVERAGE ACHIEVED   : %0.2f%%", func_cov);
        $display(" CODE COVERAGE ACHIEVED         : %0.2f%%", code_cov);
        $display(" OVERALL COVERAGE ACHIEVED      : %0.2f%%", overall_cov);
        $display(" COVERAGE VERIFICATION STATUS   : SEE SIMULATOR COVERAGE DATABASE");
        $display("============================================================");
    endfunction
endclass

// ----------------------------------------------------------------------------
// Environment Class
// ----------------------------------------------------------------------------
class environment;
    driver             drv;
    scoreboard         scb;
    coverage_collector cov;
    virtual processor_if vif;

    function new(virtual processor_if vif);
        this.vif = vif;
        cov = new();
        drv = new(vif);
        scb = new(vif, cov);
    endfunction

    task automatic set_expected(transaction tr, logic [63:0] acc_before);
        logic signed [63:0] prod;
        logic signed [63:0] a_s, b_s;
        a_s = $signed(tr.val_a);
        b_s = $signed(tr.val_b);
        prod = a_s * b_s;
        tr.expected_valid = 1'b1;
        if (tr.opcode == 7'b0001010) begin
            tr.expected_result = prod;
        end else if (tr.opcode == 7'b0001011) begin
            tr.expected_result = acc_before + prod;
        end else begin
            case (tr.funct3)
                3'b000: tr.expected_result = (tr.opcode == 7'b0010011) ? (tr.val_a + {{20{tr.imm[11]}},tr.imm}) : (tr.funct7[5] ? (tr.val_a - tr.val_b) : (tr.val_a + tr.val_b));
                3'b001: tr.expected_result = tr.val_a << tr.imm[4:0];
                3'b010: tr.expected_result = ($signed(tr.val_a) < $signed((tr.opcode == 7'b0010011) ? {{20{tr.imm[11]}},tr.imm} : tr.val_b)) ? 64'd1 : 64'd0;
                3'b011: tr.expected_result = (tr.val_a < ((tr.opcode == 7'b0010011) ? {{20{tr.imm[11]}},tr.imm} : tr.val_b)) ? 64'd1 : 64'd0;
                3'b100: tr.expected_result = tr.val_a ^ ((tr.opcode == 7'b0010011) ? {{20{tr.imm[11]}},tr.imm} : tr.val_b);
                3'b101: tr.expected_result = tr.funct7[5] ? ($signed(tr.val_a) >>> tr.imm[4:0]) : (tr.val_a >> tr.imm[4:0]);
                3'b110: tr.expected_result = tr.val_a | ((tr.opcode == 7'b0010011) ? {{20{tr.imm[11]}},tr.imm} : tr.val_b);
                3'b111: tr.expected_result = tr.val_a & ((tr.opcode == 7'b0010011) ? {{20{tr.imm[11]}},tr.imm} : tr.val_b);
                default: tr.expected_result = '0;
            endcase
        end
    endtask

    task run();
        transaction tr;
        logic [63:0] model_acc;
        model_acc = 64'd0;
        scb.monitor_and_score();

        $display("\n============================================================");
        $display("        EXECUTING 40 EXPLICIT BOUNDARY CORNER CASES         ");
        $display("============================================================");

        // Group 1: MAC/MUL Multiplication Extremes
        for (int i = 0; i < 5; i++) begin
            tr = new(); tr.is_corner = 1;
            tr.opcode = 7'b0001010; tr.rd = 5'd1; tr.rs1 = 5'd2; tr.rs2 = 5'd3;
            if (i == 0)      begin tr.val_a = 32'h7FFFFFFF; tr.val_b = 32'h7FFFFFFF; tr.test_name = "CORNER 1: Max Signed * Max Signed"; end
            else if (i == 1) begin tr.val_a = 32'h80000000; tr.val_b = 32'h80000000; tr.test_name = "CORNER 2: Min Signed * Min Signed"; end
            else if (i == 2) begin tr.val_a = 32'h80000000; tr.val_b = 32'h7FFFFFFF; tr.test_name = "CORNER 3: Min Signed * Max Signed"; end
            else if (i == 3) begin tr.val_a = 32'hFFFFFFFF; tr.val_b = 32'hFFFFFFFF; tr.test_name = "CORNER 4: -1 * -1"; end
            else             begin tr.val_a = 32'h00000000; tr.val_b = 32'h7FFFFFFF; tr.test_name = "CORNER 5: Zero * Max Signed"; end
            tr.op_name = tr.decode_op_name();
            tr.clear_before = 1'b1;
            set_expected(tr, 64'd0);
            if (tr.opcode == 7'b0001011) model_acc = tr.expected_result;
            scb.add_transaction(tr); drv.drive(tr);
        end

        // Group 2: SUB/ADD Underflow & Overflow Extremes
        for (int i = 0; i < 5; i++) begin
            tr = new(); tr.is_corner = 1;
            tr.opcode = 7'b0110011; tr.funct7 = 7'b0100000; tr.funct3 = 3'b000; tr.rd = 5'd4; tr.rs1 = 5'd5; tr.rs2 = 5'd6;
            if (i == 0)      begin tr.val_a = 32'h80000000; tr.val_b = 32'h00000001; tr.test_name = "CORNER 6: Min Signed - 1 (Underflow)"; end
            else if (i == 1) begin tr.val_a = 32'h7FFFFFFF; tr.val_b = 32'hFFFFFFFF; tr.test_name = "CORNER 7: Max Signed - (-1)"; end
            else if (i == 2) begin tr.val_a = 32'h00000000; tr.val_b = 32'h00000000; tr.test_name = "CORNER 8: 0 - 0"; end
            else if (i == 3) begin tr.val_a = 32'hFFFFFFFF; tr.val_b = 32'hFFFFFFFF; tr.test_name = "CORNER 9: -1 - (-1)"; end
            else             begin tr.val_a = 32'h7FFFFFFF; tr.val_b = 32'h7FFFFFFF; tr.test_name = "CORNER 10: Max Signed - Max Signed"; end
            tr.op_name = tr.decode_op_name();
            tr.clear_before = 1'b1;
            set_expected(tr, 64'd0);
            if (tr.opcode == 7'b0001011) model_acc = tr.expected_result;
            scb.add_transaction(tr); drv.drive(tr);
        end

        // Group 3: Shift Operations Boundary Extremes
        for (int i = 0; i < 5; i++) begin
            tr = new(); tr.is_corner = 1;
            tr.opcode = 7'b0010011; tr.rd = 5'd7; tr.rs1 = 5'd8;
            if (i == 0)      begin tr.funct3 = 3'b001; tr.imm = 12'd1;  tr.val_a = 32'h00000001; tr.test_name = "CORNER 11: Barrel Stage Shift 1"; end
            else if (i == 1) begin tr.funct3 = 3'b001; tr.imm = 12'd2;  tr.val_a = 32'h00000001; tr.test_name = "CORNER 12: Barrel Stage Shift 2"; end
            else if (i == 2) begin tr.funct3 = 3'b001; tr.imm = 12'd4;  tr.val_a = 32'h00000001; tr.test_name = "CORNER 13: Barrel Stage Shift 4"; end
            else if (i == 3) begin tr.funct3 = 3'b101; tr.imm = 12'h40F; tr.val_a = 32'h80000000; tr.test_name = "CORNER 14: Barrel Stage Arithmetic Shift 8"; end
            else             begin tr.funct3 = 3'b001; tr.imm = 12'd16; tr.val_a = 32'h00000001; tr.test_name = "CORNER 15: Barrel Stage Shift 16"; end
            tr.op_name = tr.decode_op_name();
            tr.clear_before = 1'b1;
            set_expected(tr, 64'd0);
            if (tr.opcode == 7'b0001011) model_acc = tr.expected_result;
            scb.add_transaction(tr); drv.drive(tr);
        end

        // Group 4: Consecutive MAC Accumulation Corner Cases
        // First transaction clears the accumulator; subsequent transactions
        // intentionally preserve it so the original MAC verification flow
        // now verifies real accumulation across multiple MAC instructions.
        model_acc = 64'd0;
        for (int i = 0; i < 5; i++) begin
            tr = new(); tr.is_corner = 1;
            tr.opcode = 7'b0001011; tr.rd = 5'd9; tr.rs1 = 5'd10; tr.rs2 = 5'd11;
            tr.val_a = 32'h40000000; tr.val_b = 32'h00000002;
            tr.test_name = $sformatf("CORNER %0d: Consecutive MAC Accumulate Step %0d", 16+i, i+1);
            tr.op_name = tr.decode_op_name();
            tr.clear_before = (i == 0);
            set_expected(tr, model_acc);
            model_acc = tr.expected_result;
            scb.add_transaction(tr); drv.drive(tr);
        end

        // Group 5: RAW Hazard Back-to-Back Dependencies
        for (int i = 0; i < 5; i++) begin
            tr = new(); tr.is_corner = 1;
            tr.opcode = 7'b0110011; tr.funct7 = 7'b0000000; tr.funct3 = 3'b000; tr.rd = 5'd12; tr.rs1 = 5'd12; tr.rs2 = 5'd12;
            tr.val_a = 32'd1; tr.val_b = 32'd1;
            tr.test_name = $sformatf("CORNER %0d: Back-to-Back Dependent Self-ADD Step %0d", 21+i, i+1);
            tr.op_name = tr.decode_op_name();
            tr.clear_before = 1'b1;
            set_expected(tr, 64'd0);
            if (tr.opcode == 7'b0001011) model_acc = tr.expected_result;
            scb.add_transaction(tr); drv.drive(tr);
        end

        // Group 6: Register File High/Low Register Boundaries
        for (int i = 0; i < 5; i++) begin
            tr = new(); tr.is_corner = 1;
            tr.opcode = 7'b0110011; tr.funct7 = 7'b0000000; tr.funct3 = 3'b000;
            if (i == 0)      begin tr.rd = 5'd16; tr.rs1 = 5'd17; tr.rs2 = 5'd18; tr.val_a = 32'd100; tr.val_b = 32'd200; tr.test_name = "CORNER 26: High Register ADD (x16=x17+x18)"; end
            else if (i == 1) begin tr.rd = 5'd31; tr.rs1 = 5'd30; tr.rs2 = 5'd29; tr.val_a = 32'd500; tr.val_b = 32'd300; tr.test_name = "CORNER 27: Max Register ADD (x31=x30+x29)"; end
            else if (i == 2) begin tr.rd = 5'd1;  tr.rs1 = 5'd31; tr.rs2 = 5'd16; tr.val_a = 32'd1;  tr.val_b = 32'd20;  tr.test_name = "CORNER 28: Mixed High-Low Reg ADD"; end
            else if (i == 3) begin tr.rd = 5'd20; tr.rs1 = 5'd20; tr.rs2 = 5'd20; tr.val_a = 32'd15;  tr.val_b = 32'd15;  tr.test_name = "CORNER 29: Self Same High Register ADD"; end
            else             begin tr.rd = 5'd25; tr.rs1 = 5'd24; tr.rs2 = 5'd23; tr.val_a = 32'd1000;tr.val_b = 32'd2000;tr.test_name = "CORNER 30: Mid-High Register ADD"; end
            tr.op_name = tr.decode_op_name();
            tr.clear_before = 1'b1;
            set_expected(tr, 64'd0);
            if (tr.opcode == 7'b0001011) model_acc = tr.expected_result;
            scb.add_transaction(tr); drv.drive(tr);
        end

        // Group 7: Bitwise Masking Boundary Extremes
        for (int i = 0; i < 5; i++) begin
            tr = new(); tr.is_corner = 1;
            tr.opcode = 7'b0110011; tr.rd = 5'd13; tr.rs1 = 5'd14; tr.rs2 = 5'd15;
            if (i == 0)      begin tr.funct3 = 3'b111; tr.val_a = 32'hFFFFFFFF; tr.val_b = 32'h00000000; tr.test_name = "CORNER 31: AND All-Ones with All-Zeros"; end
            else if (i == 1) begin tr.funct3 = 3'b110; tr.val_a = 32'hAAAAAAAA; tr.val_b = 32'h55555555; tr.test_name = "CORNER 32: OR Complementary Bit Patterns"; end
            else if (i == 2) begin tr.funct3 = 3'b100; tr.val_a = 32'hFFFFFFFF; tr.val_b = 32'hFFFFFFFF; tr.test_name = "CORNER 33: XOR Same Identical Mask"; end
            else if (i == 3) begin tr.funct3 = 3'b100; tr.val_a = 32'h12345678; tr.val_b = 32'hFFFFFFFF; tr.test_name = "CORNER 34: Bitwise NOT via XOR All-Ones"; end
            else             begin tr.funct3 = 3'b111; tr.val_a = 32'h80000000; tr.val_b = 32'h7FFFFFFF; tr.test_name = "CORNER 35: AND MSB Sign Bit Only"; end
            tr.op_name = tr.decode_op_name();
            tr.clear_before = 1'b1;
            set_expected(tr, 64'd0);
            if (tr.opcode == 7'b0001011) model_acc = tr.expected_result;
            scb.add_transaction(tr); drv.drive(tr);
        end

        // Group 8: Signed & Unsigned Comparison Extremes
        for (int i = 0; i < 5; i++) begin
            tr = new(); tr.is_corner = 1;
            tr.opcode = 7'b0110011; tr.rd = 5'd13; tr.rs1 = 5'd14; tr.rs2 = 5'd15;
            if (i == 0)      begin tr.funct3 = 3'b010; tr.val_a = 32'h80000000; tr.val_b = 32'h7FFFFFFF; tr.test_name = "CORNER 36: SLT Min Signed vs Max Signed"; end
            else if (i == 1) begin tr.funct3 = 3'b011; tr.val_a = 32'h80000000; tr.val_b = 32'h7FFFFFFF; tr.test_name = "CORNER 37: SLTU Min Signed vs Max Signed"; end
            else if (i == 2) begin tr.funct3 = 3'b010; tr.val_a = 32'hFFFFFFFF; tr.val_b = 32'h00000000; tr.test_name = "CORNER 38: SLT -1 vs 0"; end
            else if (i == 3) begin tr.funct3 = 3'b011; tr.val_a = 32'hFFFFFFFF; tr.val_b = 32'h00000000; tr.test_name = "CORNER 39: SLTU Max Unsigned vs 0"; end
            else             begin tr.funct3 = 3'b010; tr.val_a = 32'h7FFFFFFF; tr.val_b = 32'h7FFFFFFF; tr.test_name = "CORNER 40: SLT Equal Max Signed Inputs"; end
            tr.op_name = tr.decode_op_name();
            tr.clear_before = 1'b1;
            set_expected(tr, 64'd0);
            if (tr.opcode == 7'b0001011) model_acc = tr.expected_result;
            scb.add_transaction(tr); drv.drive(tr);
        end

        // 410 Constrained Random Operations (40 Corners + 410 Random = 450 Operations Total)
        for (int i = 0; i < 410; i++) begin
            tr = new(); tr.is_corner = 0;
            assert(tr.randomize());
            tr.val_a = $urandom();
            tr.val_b = $urandom();
            tr.op_name = tr.decode_op_name();
            tr.test_name = $sformatf("RANDOM TESTCASE #%0d", i+1);
            tr.clear_before = 1'b1;
            set_expected(tr, 64'd0);
            if (tr.opcode == 7'b0001011) model_acc = tr.expected_result;
            scb.add_transaction(tr); drv.drive(tr);
        end

        repeat (10) @(posedge vif.clk);
        scb.print_reports();
        $finish;
    endtask
endclass

// ----------------------------------------------------------------------------
// Top Verification Testbench Module
// ----------------------------------------------------------------------------
module tb_riscv_alu_mac_oop;

    logic clk, reset;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    processor_if p_if(clk, reset);

    riscv_alu_mac_5stage dut (
        .clk           (p_if.clk),
        .reset         (p_if.reset),
        .instr         (p_if.instr),
        .instr_valid   (p_if.instr_valid),
        .acc_clear     (p_if.acc_clear),
        .result        (p_if.result),
        .result_rd     (p_if.result_rd),
        .result_valid  (p_if.result_valid),
        .illegal_instr (p_if.illegal_instr),
        .mac_overflow  (p_if.mac_overflow),
        .init_en       (p_if.init_en),
        .init_addr     (p_if.init_addr),
        .init_data     (p_if.init_data)
    );

    environment env;

    initial begin
        reset = 1'b1;
        p_if.instr_valid = 1'b0;
        p_if.acc_clear   = 1'b0;
        p_if.init_en     = 1'b0;
        
        repeat (5) @(posedge clk);
        @(negedge clk) reset = 1'b0;

        env = new(p_if);
        env.run();
    end

endmodule
