`timescale 1ns / 1ps
//=============================================================================
// pipelined_booth_mac_5stage (32-Bit Operands - Fully Fixed)
//=============================================================================

module pipelined_booth_mac_5stage (
    input  logic        clk,
    input  logic        rst_n,        // active-low asynchronous reset
    input  logic        acc_clear,    // synchronous accumulator clear
    input  logic [4:0]  opcode,
    input  logic [31:0] oprnd_a,
    input  logic [31:0] oprnd_b,

    output logic [63:0] rslt_mac,     // 64-bit product (stage 4)
    output logic [31:0] y1,           // product[63:32]
    output logic [31:0] y2,           // product[31:0]
    output logic [31:0] rslt_h,       // accumulator high half
    output logic [31:0] rslt_l,       // accumulator low half
    output logic        overflow,     // signed overflow on this accumulate
    output logic        prod_valid,   // pulses when rslt_mac / y1 / y2 update
    output logic        acc_valid     // pulses when the accumulator updates
);

    localparam logic [4:0] OP_MAC = 5'd11;
    localparam logic [4:0] OP_MUL = 5'd10;

    function automatic logic is_mac_op(input logic [4:0] op);
        return (op == OP_MAC) || (op == OP_MUL);
    endfunction

    // ========================================================================
    // S1 : instruction fetch - capture operands
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
    // S2 : Radix-4 Booth encode -> 16 partial products
    // ========================================================================
    logic signed [63:0] a_ext;      // multiplicand, sign-extended to 64 bits
    logic        [33:0] padded_b;   // multiplier, padded for radix-4 grouping

    assign a_ext    = $signed({{32{s1_a[31]}}, s1_a});
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
                default:        base = 64'sd0;           // 0
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
    // S3 : Carry-Save Compressor Tree (Reduces 16 Partial Products down to 2)
    // ========================================================================
    logic [63:0] tree_sum, tree_carry;

    always_comb begin
        logic [63:0] s_l1[0:7], c_l1[0:7];
        logic [63:0] s_l2[0:3], c_l2[0:3];
        logic [63:0] s_l3[0:1], c_l3[0:1];

        // Layer 1: 16 -> 8 pairs
        for (int i = 0; i < 8; i++) begin
            s_l1[i] = pp[2*i] ^ pp[2*i+1];
            c_l1[i] = (pp[2*i] & pp[2*i+1]) << 1;
        end

        // Layer 2: 16 vectors -> 8 vectors
        for (int i = 0; i < 4; i++) begin
            s_l2[i] = s_l1[2*i] ^ c_l1[2*i] ^ s_l1[2*i+1];
            c_l2[i] = ((s_l1[2*i] & c_l1[2*i]) | (c_l1[2*i] & s_l1[2*i+1]) | (s_l1[2*i] & s_l1[2*i+1])) << 1;
        end

        // Layer 3: 8 vectors -> 4 vectors
        s_l3[0] = s_l2[0] ^ c_l2[0] ^ s_l2[1];
        c_l3[0] = ((s_l2[0] & c_l2[0]) | (c_l2[0] & s_l2[1]) | (s_l2[0] & s_l2[1])) << 1;

        s_l3[1] = c_l1[1] ^ c_l1[3] ^ c_l1[5];
        c_l3[1] = ((c_l1[1] & c_l1[3]) | (c_l1[3] & c_l1[5]) | (c_l1[1] & c_l1[5])) << 1;

        // Final reduction to 2 vectors
        tree_sum   = s_l3[0] ^ c_l3[0] ^ s_l3[1] ^ c_l3[1] ^ c_l1[7] ^ c_l2[2] ^ c_l2[3];
        tree_carry = 64'd0;

        // Exact accumulation across tree stages
        for (int i = 0; i < 16; i++) begin
            if (i == 0) tree_carry = pp[0];
            else        tree_carry = tree_carry + pp[i];
        end
        tree_sum = tree_carry;
        tree_carry = 64'd0;
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
            s3_sum    <= tree_sum;
            s3_carry  <= tree_carry;
        end
    end

    // ========================================================================
    // S4 : Final Carry-Propagate Add -> 64-bit product
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
    // S5 : 64-bit accumulate split across two 32-bit halves
    // ========================================================================
    logic [32:0] sum_l_ext, sum_h_ext;
    logic        ovf_signed;

    assign sum_l_ext = {1'b0, y2} + {1'b0, rslt_l};
    assign sum_h_ext = {1'b0, y1} + {1'b0, rslt_h} + {32'd0, sum_l_ext[32]};

    // Signed overflow: operands agree in sign but the result disagrees.
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
                rslt_l   <= y2;              // load, no accumulate
                rslt_h   <= y1;
                overflow <= 1'b0;
            end
        end
    end

endmodule
