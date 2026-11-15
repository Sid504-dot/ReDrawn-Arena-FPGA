`timescale 1ns / 1ps


module sprite_sz #(
    parameter W = 16,                   // normal art
    parameter H = 16,
    parameter [W*H*4-1:0] DATA = 0,
    parameter AW = 8,                   // small art
    parameter AH = 8,
    parameter [AW*AH*4-1:0] ADATA = 0,
    parameter HAS_ALT = 0               // 1 = small art exists
    )(
    input clk,
    input [9:0] x,
    input [9:0] y,
    input [9:0] x0,
    input [9:0] y0,
    input [1:0] sz,
    input flip,
    output reg [3:0] idx,
    output reg box
    );

    wire alt = (HAS_ALT != 0) && (sz == 2'd1);     // use small art
    wire big = (sz == 2'd2);                       // draw 2x
    wire [10:0] dx = {1'b0, x} - {1'b0, x0};
    wire [10:0] dy = {1'b0, y} - {1'b0, y0};
    // size on screen
    wire [6:0] ws = alt ? AW : big ? (W << 1) : W;
    wire [6:0] hs = alt ? AH : big ? (H << 1) : H;
    wire hit = (x >= x0) && (dx < ws) && (y >= y0) && (dy < hs);
    // art pixel, /2 when big
    wire [5:0] cr = big ? dx[6:1] : dx[5:0];
    wire [5:0] rr = big ? dy[6:1] : dy[5:0];
    wire [5:0] cw = alt ? AW - 1 : W - 1;          // last column, for flip

    // clk 1
    reg hit_q = 0;
    reg alt_q = 0;
    reg [5:0] col_q = 0;
    reg [5:0] row_q = 0;
    always @ (posedge clk) begin
        hit_q <= hit;
        alt_q <= alt;
        if (flip == 1) begin
            col_q <= cw - cr;
        end
        else begin
            col_q <= cr;
        end
        row_q <= rr;
    end

    // clk 2, read from the right art
    wire [3:0] pix_b = DATA[(row_q * W + col_q) * 4 +: 4];
    wire [3:0] pix_a = ADATA[(row_q * AW + col_q) * 4 +: 4];
    always @ (posedge clk) begin
        if (hit_q == 0) begin
            idx <= 4'h0;
        end
        else if (HAS_ALT != 0 && alt_q == 1) begin
            idx <= pix_a;
        end
        else begin
            idx <= pix_b;
        end
        box <= hit_q;
    end

endmodule
