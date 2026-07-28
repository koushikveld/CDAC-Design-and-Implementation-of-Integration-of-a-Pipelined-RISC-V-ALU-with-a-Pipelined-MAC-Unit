`timescale 1ns / 1ps
//=============================================================================
// pipelined_booth_mac_5stage
//
//   16 x 16 signed multiply-accumulate, radix-4 modified Booth encoding with
//   a Wallace (carry-save) compression tree, split across five pipeline
//   stages so that no single stage carries the whole multiplier delay.
//
//   S1  IF   : capture opcode and operands
//   S2  ID   : Booth encode -> generate the eight partial products
//   S3  PLE  : Wallace tree compresses 8 partial products down to 2 vectors
//   S4  AEG  : final carry-propagate add -> rslt_mac, y1, y2
//   S5  WB   : 32-bit accumulate into {rslt_h, rslt_l}, overflow detect
//
//   Throughput: one MAC per clock. Latency: 4 clocks to rslt_mac,
//   5 clocks to the accumulator.
//
//   Opcodes
//     OP_MAC (11) : acc <- acc + (a * b)
//     OP_MUL (10) : acc <- (a * b)          (load, does not accumulate)
//     anything else: pipeline idles, accumulator holds
//   acc_clear zeroes the accumulator synchronously.
//=============================================================================

module pipelined_booth_mac_5stage (
    input  logic        clk,
    input  logic        rst_n,        // active-low asynchronous reset
    input  logic        acc_clear,    // synchronous accumulator clear
    input  logic [4:0]  opcode,
    input  logic [15:0] oprnd_a,
    input  logic [15:0] oprnd_b,

    output logic [31:0] rslt_mac,     // 32-bit product (stage 4)
    output logic [15:0] y1,           // product[31:16]
    output logic [15:0] y2,           // product[15:0]
    output logic [15:0] rslt_h,       // accumulator high half
    output logic [15:0] rslt_l,       // accumulator low half
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
    logic [15:0] s1_a, s1_b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_opcode <= 5'd0;
            s1_a      <= 16'd0;
            s1_b      <= 16'd0;
        end else begin
            s1_opcode <= opcode;
            s1_a      <= oprnd_a;
            s1_b      <= oprnd_b;
        end
    end

    // ========================================================================
    // S2 : Booth encode -> eight partial products
    //
    //   Radix-4 groups are (b[2i+1], b[2i], b[2i-1]) with b[-1] = 0, so the
    //   multiplier is padded with one zero at the bottom and one sign bit at
    //   the top. Sixteen bits need exactly eight groups - a ninth group can
    //   only ever see three copies of the sign bit, which encodes to zero.
    // ========================================================================
    logic signed [31:0] a_ext;      // multiplicand, sign-extended to 32 bits
    logic        [17:0] padded_b;   // multiplier, padded for radix-4 grouping

    assign a_ext    = {{16{s1_a[15]}}, s1_a};
    assign padded_b = {s1_b[15], s1_b, 1'b0};    // sign bit + b + implicit b[-1]

    logic signed [31:0] pp_next [0:7];

    always_comb begin
        for (int i = 0; i < 8; i++) begin
            logic [2:0]         bgroup;
            logic signed [31:0] base;

            bgroup = padded_b[2*i +: 3];
            case (bgroup)
                3'b001, 3'b010: base =   a_ext;          // +1 x A
                3'b011:         base =   a_ext <<< 1;    // +2 x A
                3'b100:         base = -(a_ext <<< 1);   // -2 x A
                3'b101, 3'b110: base =  -a_ext;          // -1 x A
                default:        base = 32'sd0;           // 000 or 111 -> 0
            endcase

            pp_next[i] = base <<< (2 * i);
        end
    end

    logic [4:0]         s2_opcode;
    logic signed [31:0] pp [0:7];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_opcode <= 5'd0;
            for (int i = 0; i < 8; i++) pp[i] <= 32'sd0;
        end else begin
            s2_opcode <= s1_opcode;
            for (int i = 0; i < 8; i++) pp[i] <= pp_next[i];
        end
    end

    // ========================================================================
    // S3 : Wallace tree - carry-save compression of 8 vectors down to 2
    //
    //   A 3:2 counter replaces three addends with a sum vector and a carry
    //   vector without any carry propagation, so the delay is a couple of
    //   gate levels per layer instead of a 32-bit ripple.
    // ========================================================================
    function automatic logic [31:0] csa_sum(input logic [31:0] x, y, z);
        return x ^ y ^ z;
    endfunction

    function automatic logic [31:0] csa_carry(input logic [31:0] x, y, z);
        return ((x & y) | (y & z) | (x & z)) << 1;
    endfunction

    logic [31:0] l1s0, l1c0, l1s1, l1c1;
    logic [31:0] l2s0, l2c0, l2s1, l2c1;
    logic [31:0] l3s,  l3c;
    logic [31:0] l4s,  l4c;

    always_comb begin
        // layer 1 : 8 -> 6
        l1s0 = csa_sum  (pp[0], pp[1], pp[2]);
        l1c0 = csa_carry(pp[0], pp[1], pp[2]);
        l1s1 = csa_sum  (pp[3], pp[4], pp[5]);
        l1c1 = csa_carry(pp[3], pp[4], pp[5]);
        // layer 2 : 6 -> 4
        l2s0 = csa_sum  (l1s0, l1c0, l1s1);
        l2c0 = csa_carry(l1s0, l1c0, l1s1);
        l2s1 = csa_sum  (l1c1, pp[6], pp[7]);
        l2c1 = csa_carry(l1c1, pp[6], pp[7]);
        // layer 3 : 4 -> 3
        l3s  = csa_sum  (l2s0, l2c0, l2s1);
        l3c  = csa_carry(l2s0, l2c0, l2s1);
        // layer 4 : 3 -> 2
        l4s  = csa_sum  (l3s, l3c, l2c1);
        l4c  = csa_carry(l3s, l3c, l2c1);
    end

    logic [4:0]  s3_opcode;
    logic [31:0] s3_sum, s3_carry;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_opcode <= 5'd0;
            s3_sum    <= 32'd0;
            s3_carry  <= 32'd0;
        end else begin
            s3_opcode <= s2_opcode;
            s3_sum    <= l4s;
            s3_carry  <= l4c;
        end
    end

    // ========================================================================
    // S4 : final carry-propagate add -> the 32-bit product
    // ========================================================================
    logic [31:0] product_next;
    logic [4:0]  s4_opcode;

    assign product_next = s3_sum + s3_carry;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rslt_mac   <= 32'd0;
            y1         <= 16'd0;
            y2         <= 16'd0;
            s4_opcode  <= 5'd0;
            prod_valid <= 1'b0;
        end else begin
            s4_opcode  <= s3_opcode;
            prod_valid <= is_mac_op(s3_opcode);
            if (is_mac_op(s3_opcode)) begin
                rslt_mac <= product_next;
                y1       <= product_next[31:16];
                y2       <= product_next[15:0];
            end
        end
    end

    // ========================================================================
    // S5 : accumulate.  {rslt_h, rslt_l} + {y1, y2} performed as two 16-bit
    //      halves with an explicit carry between them.
    // ========================================================================
    logic [16:0] sum_l_ext, sum_h_ext;
    logic        ovf_signed;

    assign sum_l_ext = {1'b0, y2} + {1'b0, rslt_l};
    assign sum_h_ext = {1'b0, y1} + {1'b0, rslt_h} + {16'd0, sum_l_ext[16]};

    // Signed overflow: operands agree in sign but the result disagrees.
    // A carry-out is NOT overflow for signed values - adding two negatives
    // always produces a carry and is usually perfectly in range.
    assign ovf_signed = (y1[15] == rslt_h[15]) && (sum_h_ext[15] != rslt_h[15]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rslt_h    <= 16'd0;
            rslt_l    <= 16'd0;
            overflow  <= 1'b0;
            acc_valid <= 1'b0;
        end else if (acc_clear) begin
            rslt_h    <= 16'd0;
            rslt_l    <= 16'd0;
            overflow  <= 1'b0;
            acc_valid <= 1'b0;
        end else begin
            acc_valid <= is_mac_op(s4_opcode);
            if (s4_opcode == OP_MAC) begin
                rslt_l   <= sum_l_ext[15:0];
                rslt_h   <= sum_h_ext[15:0];
                overflow <= ovf_signed;
            end else if (s4_opcode == OP_MUL) begin
                rslt_l   <= y2;              // load, no accumulate
                rslt_h   <= y1;
                overflow <= 1'b0;
            end
        end
    end

endmodule
