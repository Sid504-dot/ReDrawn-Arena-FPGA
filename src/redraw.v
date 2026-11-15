`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: redraw
// Description: "redraw" effect played on an object when it changes size
//              simple version (4 Nov, saves luts): a square of grey / white
//              checks grows over the object, flickers, then shrinks
//              32 frames (~0.5 s), swap pulses at frame 16 while the object
//              is fully covered, that is when the caller changes its size
//              only 1 effect at a time (start ignored while busy)
//              2 clk delay like the other drawing modules
//////////////////////////////////////////////////////////////////////////////////


module redraw (
    input clk,
    input [9:0] x,
    input [9:0] y,
    input new_frame,                    // 1 pulse per frame
    input start,                        // begin the effect
    input [9:0] cx,                     // middle of the object
    input [9:0] cy,
    input [6:0] rad,                    // half size of the square (bigger of old / new)
    output reg busy,
    output reg swap,                    // 1 clk pulse in the middle
    output [3:0] idx                    // palette index, 0 = nothing
    );
    `include "sprite_data.vh"

    initial begin
        busy = 0;
        swap = 0;
    end

    reg [4:0] t = 0;                    // frame of the effect 0-31
    reg [9:0] ccx = 0;                  // latched at start
    reg [9:0] ccy = 0;
    reg [6:0] crad = 0;
    // size goes 1 2 3 4 (quarters of rad) ... 4 ... 4 3 2 1
    wire [4:0] kk = 5'd31 - t + 5'd1;   // frames left
    wire [2:0] k = (t < 5'd3) ? t[2:0] + 3'd1 : (t > 5'd28) ? kk[2:0] : 3'd4;
    reg [8:0] rt = 0;                   // size now = crad * k / 4

    always @ (posedge clk) begin
        swap <= 0;
        if (start == 1 && busy == 0) begin
            busy <= 1;
            t <= 5'd0;
            ccx <= cx;
            ccy <= cy;
            crad <= rad;
        end
        else if (busy == 1 && new_frame == 1) begin
            if (t == 5'd15) begin
                swap <= 1;
            end
            if (t == 5'd31) begin
                busy <= 0;
            end
            t <= t + 5'd1;
        end
        // crad * k / 4 with shifts, no multiplier
        case (k)
            3'd4: rt <= {2'b0, crad};
            3'd3: rt <= {3'b0, crad[6:1]} + {4'b0, crad[6:2]};     // 1/2 + 1/4
            3'd2: rt <= {3'b0, crad[6:1]};
            default: rt <= {4'b0, crad[6:2]};
        endcase
    end

    // clk 1: inside the square?  clk 2: colour
    reg in1 = 0;
    reg chk1 = 0;
    wire [10:0] ax = (x >= ccx) ? {1'b0, x - ccx} : {1'b0, ccx - x};   // |x - cx|
    wire [10:0] ay = (y >= ccy) ? {1'b0, y - ccy} : {1'b0, ccy - y};
    reg [3:0] cloud = 0;
    always @ (posedge clk) begin
        in1 <= busy && (ax < {2'b0, rt}) && (ay < {2'b0, rt});
        chk1 <= x[3] ^ y[3] ^ t[2];     // 8 px checks, swap every 4 frames
        if (in1 == 0) begin
            cloud <= 4'h0;
        end
        else if (chk1 == 1) begin
            cloud <= 4'hC;              // grey
        end
        else begin
            cloud <= 4'h2;              // white
        end
    end
    assign idx = cloud;

endmodule
