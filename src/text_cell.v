`timescale 1ns / 1ps

module text_cell #(
    parameter LEN   = 8,
    parameter SHIFT = 1
    )(
    input clk,
    input [9:0] x,
    input [9:0] y,
    input [9:0] x0,
    input [9:0] y0,
    input [8*LEN-1:0] str,
    input en,                           // 0 = line not shown
    output reg [13:0] cq                // {in, ch[7:0], row[2:0], col[1:0]}
    );

    initial begin
        cq = 0;
    end

    // same maths as text_line
    wire [10:0] dx = {1'b0, x} - {1'b0, x0};
    wire [10:0] dy = {1'b0, y} - {1'b0, y0};
    wire [9:0] fx = dx[9:0] >> SHIFT;
    wire [9:0] fy = dy[9:0] >> SHIFT;
    wire [7:0] ci = fx[9:2];
    wire inside = en && (x >= x0) && (y >= y0) && (ci < LEN) && (fy < 5) && (fx[1:0] != 2'd3);

    always @ (posedge clk) begin
        if (inside == 1) begin
            cq <= {1'b1, str[8*(LEN-1-ci) +: 8], fy[2:0], fx[1:0]};
        end
        else begin
            cq <= 14'd0;                // all 0 so ORing works
        end
    end

endmodule


module text_glyph (
    input clk,
    input [13:0] cq,                    // from text_cell (ORed)
    output reg on
    );
    `include "font35.vh"

    initial begin
        on = 0;
    end

    // cq[12:5] char, cq[4:2] row, cq[1:0] column (bit 2 = left)
    wire [2:0] bits = font35(cq[12:5], cq[4:2]);
    always @ (posedge clk) begin
        on <= cq[13] && bits[2 - cq[1:0]];
    end

endmodule
