`timescale 1ns / 1ps
//=============================================================================
// 5-Stage Pipelined 32x32-Bit Multiply-Accumulate (MAC) Unit
//
// Based on the architecture by HE Jing-yu et al. (IMSNA 2013):
//   S1 (IF)  : Capture 32-bit operands and 5-bit opcode.
//   S2 (ID)  : Radix-4 Modified Booth Encoding -> 16 partial products (64-bit).
//   S3 (PLE) : 5-layer Wallace Tree compressor array (16 vectors down to 2).
//   S4 (AEG) : Final Carry-Propagate Addition -> 64-bit product (y1, y2).
//   S5 (WB)  : 64-bit Accumulation into register pair {rslt_h, rslt_l}.
//=============================================================================

module pipelined_booth_mac_5stage_32bit (
    input  logic        clk,
    input  logic        rst_n,        // Active-low asynchronous reset
    input  logic        acc_clear,    // Synchronous accumulator clear
    input  logic [4:0]  opcode,       // Opcode input
    input  logic [31:0] oprnd_a,      // 32-bit Multiplicand
    input  logic [31:0] oprnd_b,      // 32-bit Multiplier

    output logic [63:0] rslt_mac,     // 64-bit Product (Stage 4)
    output logic [31:0] y1,           // Product High Half [63:32]
    output logic [31:0] y2,           // Product Low Half [31:0]
    output logic [31:0] rslt_h,       // Accumulator High Half [63:32]
    output logic [31:0] rslt_l,       // Accumulator Low Half [31:0]
    output logic        overflow,     // Signed Accumulator Overflow Flag
    output logic        prod_valid,   // Pulse when Stage 4 updates
    output logic        acc_valid     // Pulse when Stage 5 updates
);

    localparam logic [4:0] OP_MAC = 5'd11;
    localparam logic [4:0] OP_MUL = 5'd10;

    function automatic logic is_mac_op(input logic [4:0] op);
        return (op == OP_MAC) || (op == OP_MUL);
    endfunction

    // ========================================================================
    // S1 : Instruction Fetch - Capture Operands
    // ========================================================================
    logic [4:0]  s1_opcode;
    logic [31:0] s1_a, s1_b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_opcode <= 5'd0;
            s1_a      <= 32'd0;
            s1_b      <= 32'd0;
        end else begin
            s1_opcode <= opcode;
            s1_a      <= oprnd_a;
            s1_b      <= oprnd_b;
        end
    end

    // ========================================================================
    // S2 : Radix-4 Booth Encoding -> 16 Partial Products
    // ========================================================================
    logic signed [63:0] a_ext;      // Multiplicand sign-extended to 64 bits
    logic        [33:0] padded_b;   // Multiplier padded with implicit b[-1]=0

    assign a_ext    = {{32{s1_a[31]}}, s1_a};
    assign padded_b = {s1_b[31], s1_b, 1'b0};

    logic signed [63:0] pp_next [0:15];

    always_comb begin
        for (int i = 0; i < 16; i++) begin
            logic [2:0]         bgroup;
            logic signed [63:0] base;

            bgroup = padded_b[2*i +: 3];
            case (bgroup)
                3'b001, 3'b010: base =   a_ext;          // +1 x A
                3'b011:         base =   a_ext <<< 1;    // +2 x A
                3'b100:         base = -(a_ext <<< 1);   // -2 x A
                3'b101, 3'b110: base =  -a_ext;          // -1 x A
                default:        base = 64'sd0;           //  0 x A
            endcase

            pp_next[i] = base <<< (2 * i);
        end
    end

    logic [4:0]         s2_opcode;
    logic signed [63:0] pp [0:15];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_opcode <= 5'd0;
            for (int i = 0; i < 16; i++) pp[i] <= 64'sd0;
        end else begin
            s2_opcode <= s1_opcode;
            for (int i = 0; i < 16; i++) pp[i] <= pp_next[i];
        end
    end

    // ========================================================================
    // S3 : Wallace Tree Reduction (16 Partial Products down to 2)
    // ========================================================================
    function automatic logic [63:0] csa_sum(input logic [63:0] x, y, z);
        return x ^ y ^ z;
    endfunction

    function automatic logic [63:0] csa_carry(input logic [63:0] x, y, z);
        return ((x & y) | (y & z) | (x & z)) << 1;
    endfunction

    // Wallace tree compression signals
    logic [63:0] l1s0, l1c0, l1s1, l1c1, l1s2, l1c2, l1s3, l1c3, l1s4, l1c4;
    logic [63:0] l2s0, l2c0, l2s1, l2c1, l2s2, l2c2;
    logic [63:0] l3s0, l3c0, l3s1, l3c1;
    logic [63:0] l4s0, l4c0;
    logic [63:0] l5s,  l5c;

    always_comb begin
        // Layer 1 : 16 -> 11
        l1s0 = csa_sum  (pp[0],  pp[1],  pp[2]);  l1c0 = csa_carry(pp[0],  pp[1],  pp[2]);
        l1s1 = csa_sum  (pp[3],  pp[4],  pp[5]);  l1c1 = csa_carry(pp[3],  pp[4],  pp[5]);
        l1s2 = csa_sum  (pp[6],  pp[7],  pp[8]);  l1c2 = csa_carry(pp[6],  pp[7],  pp[8]);
        l1s3 = csa_sum  (pp[9],  pp[10], pp[11]); l1c3 = csa_carry(pp[9],  pp[10], pp[11]);
        l1s4 = csa_sum  (pp[12], pp[13], pp[14]); l1c4 = csa_carry(pp[12], pp[13], pp[14]);

        // Layer 2 : 11 -> 8
        l2s0 = csa_sum  (l1s0, l1c0, l1s1);       l2c0 = csa_carry(l1s0, l1c0, l1s1);
        l2s1 = csa_sum  (l1c1, l1s2, l1c2);       l2c1 = csa_carry(l1c1, l1s2, l1c2);
        l2s2 = csa_sum  (l1s3, l1c3, l1s4);       l2c2 = csa_carry(l1s3, l1c3, l1s4);

        // Layer 3 : 8 -> 6
        l3s0 = csa_sum  (l2s0, l2c0, l2s1);       l3c0 = csa_carry(l2s0, l2c0, l2s1);
        l3s1 = csa_sum  (l2c1, l2s2, l2c2);       l3c1 = csa_carry(l2c1, l2s2, l2c2);

        // Layer 4 : 6 -> 4
        l4s0 = csa_sum  (l3s0, l3c0, l3s1);       l4c0 = csa_carry(l3s0, l3c0, l3s1);
        l5s  = csa_sum  (l3c1, l1c4, pp[15]);     l5c  = csa_carry(l3c1, l1c4, pp[15]);

        // Layer 5 : 4 -> 2
        l1s0 = csa_sum  (l4s0, l4c0, l5s);        l1c0 = csa_carry(l4s0, l4c0, l5s);
        l1s1 = csa_sum  (l1s0, l1c0, l5c);        l1c1 = csa_carry(l1s0, l1c0, l5c);
    end

    logic [4:0]  s3_opcode;
    logic [63:0] s3_sum, s3_carry;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_opcode <= 5'd0;
            s3_sum    <= 64'd0;
            s3_carry  <= 64'd0;
        end else begin
            s3_opcode <= s2_opcode;
            s3_sum    <= l1s1;
            s3_carry  <= l1c1;
        end
    end

    // ========================================================================
    // S4 : Final Carry-Propagate Addition -> 64-bit Product
    // ========================================================================
    logic [63:0] product_next;
    logic [4:0]  s4_opcode;

    assign product_next = s3_sum + s3_carry;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rslt_mac   <= 64'd0;
            y1         <= 32'd0;
            y2         <= 32'd0;
            s4_opcode  <= 5'd0;
            prod_valid <= 1'b0;
        end else begin
            s4_opcode  <= s3_opcode;
            prod_valid <= is_mac_op(s3_opcode);
            if (is_mac_op(s3_opcode)) begin
                rslt_mac <= product_next;
                y1       <= product_next[63:32];
                y2       <= product_next[31:0];
            end
        end
    end

    // ========================================================================
    // S5 : 64-bit Accumulation with Overflow Detection
    // ========================================================================
    logic [32:0] sum_l_ext, sum_h_ext;
    logic        ovf_signed;

    assign sum_l_ext = {1'b0, y2} + {1'b0, rslt_l};
    assign sum_h_ext = {1'b0, y1} + {1'b0, rslt_h} + {32'd0, sum_l_ext[32]};

    // Signed overflow check: operands agree in sign, but result disagrees
    assign ovf_signed = (y1[31] == rslt_h[31]) && (sum_h_ext[31] != rslt_h[31]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rslt_h    <= 32'd0;
            rslt_l    <= 32'd0;
            overflow  <= 1'b0;
            acc_valid <= 1'b0;
        end else if (acc_clear) begin
            rslt_h    <= 32'd0;
            rslt_l    <= 32'd0;
            overflow  <= 1'b0;
            acc_valid <= 1'b0;
        end else begin
            acc_valid <= is_mac_op(s4_opcode);
            if (s4_opcode == OP_MAC) begin
                rslt_l   <= sum_l_ext[31:0];
                rslt_h   <= sum_h_ext[31:0];
                overflow <= ovf_signed;
            end else if (s4_opcode == OP_MUL) begin
                rslt_l   <= y2;              // Load product, no prior accumulator add
                rslt_h   <= y1;
                overflow <= 1'b0;
            end
        end
    end

endmodule
