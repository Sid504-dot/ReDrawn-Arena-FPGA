`timescale 1ns / 1ps

module lin_eval #(
    parameter W = 26                    // width of val, signed fixed point
    )(
    input clk,
    input [9:0] x,
    input [9:0] y,
    input signed [W-1:0] A,             // value at pixel (0, 0)
    input signed [15:0] a,              // + this per pixel to the right
    input signed [15:0] b,              // + this per line down
    output signed [W-1:0] val
    );

    reg [9:0] xq = 0;                   // x, y last clock
    reg [9:0] yq = 0;
    reg signed [W-1:0] lb = 0;          // value at the start of this line
    reg signed [W-1:0] cur = 0;         // value at the current pixel

    // the beam stays on one pixel for 4 clocks (25MHz pixels), so only
    // step when x or y actually changed
    wire adv = (x != xq) || (y != yq);

    // x = 0 -> new line (y = 0 -> new frame, start again from A)
    wire signed [W-1:0] lb_n  = (x == 10'd0) ? ((y == 10'd0) ? A : lb + b) : lb;
    wire signed [W-1:0] cur_n = (x == 10'd0) ? lb_n : cur + a;

    always @ (posedge clk) begin
        xq <= x;
        yq <= y;
        if (adv == 1) begin
            lb <= lb_n;
            cur <= cur_n;
        end
    end

    // on the clock it changes give the new value straight away
    assign val = (adv == 1) ? cur_n : cur;

endmodule
