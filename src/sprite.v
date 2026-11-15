`timescale 1ns / 1ps


module sprite #(
    parameter W     = 16,               // art size in art pixels
    parameter H     = 16,
    parameter SHIFT = 2,                // 2 = 4x
    parameter [W*H*4-1:0] DATA = 0      // the art, pixel 0 in the low bits
    )(
    input clk,
    input [9:0] x,                      // beam position
    input [9:0] y,
    input [9:0] x0,                     // sprite top left on screen
    input [9:0] y0,
    input flip,                         // 1 = mirror left / right
    output reg [3:0] idx,               // palette index
    output reg box                      // beam inside the sprite box
    );

    localparam WS = W << SHIFT;         // size on screen
    localparam HS = H << SHIFT;

    // clk 1: inside the box? and which art pixel
    wire [10:0] dx = {1'b0, x} - {1'b0, x0};
    wire [10:0] dy = {1'b0, y} - {1'b0, y0};
    wire hit = (x >= x0) && (dx < WS) && (y >= y0) && (dy < HS);

    wire [9:0] col_raw = dx[9:0] >> SHIFT;
    wire [9:0] row_raw = dy[9:0] >> SHIFT;

    reg hit_q;
    reg [9:0] col_q;
    reg [9:0] row_q;
    always @ (posedge clk) begin
        hit_q <= hit;
        if (flip == 1) begin
            col_q <= W - 1 - col_raw;
        end
        else begin
            col_q <= col_raw;
        end
        row_q <= row_raw;
    end

    // clk 2: read the art, 4 bits per pixel, row by row
    wire [3:0] pix = DATA[(row_q * W + col_q) * 4 +: 4];
    always @ (posedge clk) begin
        if (hit_q == 1) begin
            idx <= pix;
        end
        else begin
            idx <= 4'd0;
        end
        box <= hit_q;
    end

endmodule
