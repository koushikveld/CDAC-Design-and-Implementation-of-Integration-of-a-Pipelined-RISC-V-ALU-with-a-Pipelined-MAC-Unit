`timescale 1ns / 1ps
//=============================================================================
// alu_mac_fpga_core.sv
//
// The integration layer. Instantiates the DUT unmodified, the command
// controller, and the BIST; arbitrates between BIST and manual commands; does
// the rising-edge detect on the VIO controls; and maintains the telemetry
// counters.
//
// Every DUT interface wire is brought out as a port so the ILA can be attached
// in fpga_top without hierarchical references. Contains no Xilinx IP, which is
// what makes it directly simulatable by FPGA/sim/tb_alu_mac_core.sv.
//=============================================================================

module alu_mac_fpga_core (
    input  logic        clk,
    input  logic        rst,            // active high, synchronous

    // ---- Controls (levels from the VIO; edges are detected here) -----------
    input  logic [31:0] ctl_a,
    input  logic [31:0] ctl_b,
    input  logic [3:0]  ctl_op,
    input  logic        ctl_use_imm,
    input  logic [11:0] ctl_imm,
    input  logic [4:0]  ctl_rs1,
    input  logic [4:0]  ctl_rs2,
    input  logic [4:0]  ctl_rd,
    input  logic        ctl_start,      // rising edge issues one instruction
    input  logic        ctl_selftest,   // rising edge runs the BIST
    input  logic        ctl_acc_clear,  // rising edge clears the accumulator

    // ---- Status (to the VIO) ----------------------------------------------
    output logic [63:0] sts_result,
    output logic [4:0]  sts_result_rd,
    output logic [31:0] sts_last_instr,
    output logic        sts_txn_done,   // sticky, cleared by the next start
    output logic        sts_busy,
    output logic        sts_illegal,
    output logic        sts_ovf,
    output logic        sts_timeout,
    output logic [15:0] sts_txn_count,
    output logic [15:0] sts_err_count,
    output logic [15:0] sts_ovf_count,
    output logic        sts_st_done,
    output logic        sts_st_pass,
    output logic [15:0] sts_st_fail_mask,
    output logic [7:0]  sts_st_step,

    // ---- ILA taps ----------------------------------------------------------
    output logic [31:0] dbg_instr,
    output logic        dbg_instr_valid,
    output logic        dbg_acc_clear,
    output logic        dbg_init_en,
    output logic [4:0]  dbg_init_addr,
    output logic [31:0] dbg_init_data,
    output logic [63:0] dbg_result,
    output logic [4:0]  dbg_result_rd,
    output logic        dbg_result_valid,
    output logic        dbg_illegal_instr,
    output logic        dbg_mac_overflow,
    output logic [7:0]  dbg_status
);

    // ------------------------------------------------------------------------
    // Edge detect on the VIO controls
    //
    // VIO output probes are levels. Without an edge detect a held control would
    // re-fire every clock and you would never capture a single clean
    // transaction on the ILA.
    // ------------------------------------------------------------------------
    logic ctl_start_q, ctl_selftest_q, ctl_acc_clear_q;
    logic start_pulse, selftest_pulse, acc_clear_pulse;

    always_ff @(posedge clk) begin
        if (rst) begin
            ctl_start_q     <= 1'b0;
            ctl_selftest_q  <= 1'b0;
            ctl_acc_clear_q <= 1'b0;
        end else begin
            ctl_start_q     <= ctl_start;
            ctl_selftest_q  <= ctl_selftest;
            ctl_acc_clear_q <= ctl_acc_clear;
        end
    end

    assign start_pulse     = ctl_start     & ~ctl_start_q;
    assign selftest_pulse  = ctl_selftest  & ~ctl_selftest_q;
    assign acc_clear_pulse = ctl_acc_clear & ~ctl_acc_clear_q;

    // ------------------------------------------------------------------------
    // Command arbitration: the BIST owns the command port while it runs
    // ------------------------------------------------------------------------
    logic        bist_cmd_valid;
    logic [3:0]  bist_cmd_op;
    logic        bist_cmd_use_imm;
    logic [11:0] bist_cmd_imm;
    logic [4:0]  bist_cmd_rs1, bist_cmd_rs2, bist_cmd_rd;
    logic [31:0] bist_cmd_a, bist_cmd_b;
    logic        bist_busy, bist_acc_clear;

    logic        mst_cmd_valid;
    logic [3:0]  mst_cmd_op;
    logic        mst_cmd_use_imm;
    logic [11:0] mst_cmd_imm;
    logic [4:0]  mst_cmd_rs1, mst_cmd_rs2, mst_cmd_rd;
    logic [31:0] mst_cmd_a, mst_cmd_b;

    logic        mst_busy, rsp_valid, rsp_illegal, rsp_ovf, rsp_timeout;
    logic [63:0] rsp_data;
    logic [4:0]  rsp_rd;
    logic [31:0] rsp_instr;

    always_comb begin
        if (bist_busy) begin
            mst_cmd_valid   = bist_cmd_valid;
            mst_cmd_op      = bist_cmd_op;
            mst_cmd_use_imm = bist_cmd_use_imm;
            mst_cmd_imm     = bist_cmd_imm;
            mst_cmd_rs1     = bist_cmd_rs1;
            mst_cmd_rs2     = bist_cmd_rs2;
            mst_cmd_rd      = bist_cmd_rd;
            mst_cmd_a       = bist_cmd_a;
            mst_cmd_b       = bist_cmd_b;
        end else begin
            mst_cmd_valid   = start_pulse;
            mst_cmd_op      = ctl_op;
            mst_cmd_use_imm = ctl_use_imm;
            mst_cmd_imm     = ctl_imm;
            mst_cmd_rs1     = ctl_rs1;
            mst_cmd_rs2     = ctl_rs2;
            mst_cmd_rd      = ctl_rd;
            mst_cmd_a       = ctl_a;
            mst_cmd_b       = ctl_b;
        end
    end

    // ------------------------------------------------------------------------
    // Command controller (replaces the class-based driver)
    // ------------------------------------------------------------------------
    logic [31:0] dut_instr, dut_init_data;
    logic        dut_instr_valid, dut_init_en;
    logic [4:0]  dut_init_addr;
    logic [63:0] dut_result;
    logic [4:0]  dut_result_rd;
    logic        dut_result_valid, dut_illegal, dut_mac_ovf;

    alu_mac_cmd_ctrl #(.TIMEOUT_CYCLES(32)) u_mst (
        .clk              (clk),
        .rst              (rst),
        .cmd_valid        (mst_cmd_valid),
        .cmd_op           (mst_cmd_op),
        .cmd_use_imm      (mst_cmd_use_imm),
        .cmd_imm          (mst_cmd_imm),
        .cmd_rs1          (mst_cmd_rs1),
        .cmd_rs2          (mst_cmd_rs2),
        .cmd_rd           (mst_cmd_rd),
        .cmd_a            (mst_cmd_a),
        .cmd_b            (mst_cmd_b),
        .busy             (mst_busy),
        .rsp_valid        (rsp_valid),
        .rsp_data         (rsp_data),
        .rsp_rd           (rsp_rd),
        .rsp_illegal      (rsp_illegal),
        .rsp_ovf          (rsp_ovf),
        .rsp_timeout      (rsp_timeout),
        .rsp_instr        (rsp_instr),
        .dut_instr        (dut_instr),
        .dut_instr_valid  (dut_instr_valid),
        .dut_init_en      (dut_init_en),
        .dut_init_addr    (dut_init_addr),
        .dut_init_data    (dut_init_data),
        .dut_result       (dut_result),
        .dut_result_rd    (dut_result_rd),
        .dut_result_valid (dut_result_valid),
        .dut_illegal      (dut_illegal),
        .dut_mac_ovf      (dut_mac_ovf)
    );

    // ------------------------------------------------------------------------
    // Built-in self test
    // ------------------------------------------------------------------------
    alu_mac_selftest u_bist (
        .clk          (clk),
        .rst          (rst),
        .start        (selftest_pulse),
        .st_busy      (bist_busy),
        .st_done      (sts_st_done),
        .st_pass      (sts_st_pass),
        .st_fail_mask (sts_st_fail_mask),
        .st_step      (sts_st_step),
        .st_acc_clear (bist_acc_clear),
        .cmd_valid    (bist_cmd_valid),
        .cmd_op       (bist_cmd_op),
        .cmd_use_imm  (bist_cmd_use_imm),
        .cmd_imm      (bist_cmd_imm),
        .cmd_rs1      (bist_cmd_rs1),
        .cmd_rs2      (bist_cmd_rs2),
        .cmd_rd       (bist_cmd_rd),
        .cmd_a        (bist_cmd_a),
        .cmd_b        (bist_cmd_b),
        .rsp_valid    (rsp_valid),
        .rsp_data     (rsp_data),
        .rsp_illegal  (rsp_illegal),
        .rsp_timeout  (rsp_timeout)
    );

    // ------------------------------------------------------------------------
    // Device under test - RTL/alu_mac_integrate.sv, unmodified
    // ------------------------------------------------------------------------
    logic dut_acc_clear;
    assign dut_acc_clear = acc_clear_pulse | bist_acc_clear;

    riscv_alu_mac_5stage #(
        .XLEN (32)
    ) u_dut (
        .clk           (clk),
        .reset         (rst),
        .instr         (dut_instr),
        .instr_valid   (dut_instr_valid),
        .acc_clear     (dut_acc_clear),
        .result        (dut_result),
        .result_rd     (dut_result_rd),
        .result_valid  (dut_result_valid),
        .illegal_instr (dut_illegal),
        .mac_overflow  (dut_mac_ovf),
        .init_en       (dut_init_en),
        .init_addr     (dut_init_addr),
        .init_data     (dut_init_data)
    );

    // ------------------------------------------------------------------------
    // Telemetry
    // ------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            sts_result     <= 64'd0;
            sts_result_rd  <= 5'd0;
            sts_last_instr <= 32'd0;
            sts_txn_done   <= 1'b0;
            sts_illegal    <= 1'b0;
            sts_ovf        <= 1'b0;
            sts_timeout    <= 1'b0;
            sts_txn_count  <= 16'd0;
            sts_err_count  <= 16'd0;
            sts_ovf_count  <= 16'd0;
        end else begin
            if (start_pulse || selftest_pulse) sts_txn_done <= 1'b0;

            if (rsp_valid) begin
                sts_result     <= rsp_data;
                sts_result_rd  <= rsp_rd;
                sts_last_instr <= rsp_instr;
                sts_illegal    <= rsp_illegal;
                sts_ovf        <= rsp_ovf;
                sts_timeout    <= rsp_timeout;
                sts_txn_done   <= 1'b1;
                sts_txn_count  <= sts_txn_count + 16'd1;
                if (rsp_illegal || rsp_timeout)
                    sts_err_count <= sts_err_count + 16'd1;
                if (rsp_ovf)
                    sts_ovf_count <= sts_ovf_count + 16'd1;
            end
        end
    end

    assign sts_busy = mst_busy | bist_busy;

    // ------------------------------------------------------------------------
    // ILA taps
    // ------------------------------------------------------------------------
    assign dbg_instr         = dut_instr;
    assign dbg_instr_valid   = dut_instr_valid;
    assign dbg_acc_clear     = dut_acc_clear;
    assign dbg_init_en       = dut_init_en;
    assign dbg_init_addr     = dut_init_addr;
    assign dbg_init_data     = dut_init_data;
    assign dbg_result        = dut_result;
    assign dbg_result_rd     = dut_result_rd;
    assign dbg_result_valid  = dut_result_valid;
    assign dbg_illegal_instr = dut_illegal;
    assign dbg_mac_overflow  = dut_mac_ovf;

    // LSB first: cmd_valid, rsp_valid, mst_busy, bist_busy,
    //            st_done, st_pass, err_seen, ovf_seen
    assign dbg_status = { (sts_ovf_count != 16'd0),
                          (sts_err_count != 16'd0),
                          sts_st_pass,
                          sts_st_done,
                          bist_busy,
                          mst_busy,
                          rsp_valid,
                          mst_cmd_valid };

endmodule
