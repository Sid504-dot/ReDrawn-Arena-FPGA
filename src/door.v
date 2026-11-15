`timescale 1ns / 1ps


module door #(
    parameter SHIFT = 1                 // 1 = drawn 2x
    )(
    input clk,
    input [9:0] x,
    input [9:0] y,
    input [9:0] x0,
    input [9:0] y0,
    input [6:0] height,                 // full height in art px (>= 16)
    input [6:0] open,                   // how far the panel went up, art px
    output reg [3:0] idx
    );

    // palette colours
    localparam [3:0] C_FRAME = 4'hC;
    localparam [3:0] C_PANEL = 4'h1;
    localparam [3:0] C_SHINE = 4'hC;
    localparam [3:0] C_RED   = 4'h9;
    localparam [3:0] C_GREEN = 4'h4;
    localparam W = 12;

    // clk 1: inside? which art column c / row r
    wire [10:0] dxs = {1'b0, x} - {1'b0, x0};
    wire [10:0] dys = {1'b0, y} - {1'b0, y0};
    wire hit = (x >= x0) && (y >= y0) && (dxs < (W << SHIFT)) && (dys < ({4'd0, height} << SHIFT));
    wire [6:0] c = dxs[6+SHIFT:SHIFT];
    wire [6:0] r = dys[6+SHIFT:SHIFT];

    reg hit_q;
    reg closed_q;
    reg [6:0] c_q;
    reg [6:0] r_q;
    reg [6:0] h_q;
    reg [6:0] pend_q;
    always @ (posedge clk) begin
        hit_q <= hit;
        c_q <= c;
        r_q <= r;
        h_q <= height;
        pend_q <= height - 7'd2 - open;     // last row of the panel
        closed_q <= (open == 7'd0);
    end

    // clk 2: which part of the door is this pixel
    wire in_house = (r_q < 7'd8);
    wire in_socket = (r_q >= h_q - 7'd6);
    wire house_edge = in_house && (c_q == 0 || c_q == W-1 || r_q == 0 ||
                      (r_q == 7'd7 && (c_q < 3 || c_q > 8)));
    wire sock_edge = in_socket && (c_q == 0 || c_q == W-1 || r_q == h_q - 7'd1 ||
                     (r_q == h_q - 7'd6 && (c_q < 3 || c_q > 8)));
    wire lamp = in_house && r_q >= 2 && r_q <= 5 && c_q >= 4 && c_q <= 7;
    // bottom corners of the panel left out so it looks rounded
    wire in_panel = (c_q >= 3) && (c_q <= 8) && (r_q >= 7'd8) && (r_q <= pend_q)
                    && !(r_q == pend_q && (c_q == 3 || c_q == 8));

    always @ (posedge clk) begin
        if (hit_q == 0) begin
            idx <= 4'h0;
        end
        else if (lamp == 1) begin
            idx <= closed_q ? C_RED : C_GREEN;
        end
        else if (house_edge == 1 || sock_edge == 1) begin
            idx <= C_FRAME;
        end
        else if (in_panel == 1) begin
            idx <= (c_q == 7'd4) ? C_SHINE : C_PANEL;   // 1 column shine
        end
        else begin
            idx <= 4'h0;
        end
    end

endmodule
