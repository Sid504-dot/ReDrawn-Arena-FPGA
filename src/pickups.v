`timescale 1ns / 1ps


module pickups #(
    parameter FIRST_TICKS = 180,            // 3s after match start
    parameter AGAIN_TICKS = 600             // 10s after taken
    )(
    input clk,
    input reset,                            // gs_reset
    input tick,
    input run,                              // gs_run
    input [1:0] map,
    input signed [11:0] p1x, p1y,           // hitbox 12 x 14
    input signed [11:0] p2x, p2y,
    input alive1, alive2,
    input [5:0] w1, h1, w2, h2,     // player hitbox sizes (players can be resized)
    output reg pick1 = 0, pick2 = 0,
    output reg       on0 = 0, on1 = 0,      // box showing
    output reg [9:0] x0 = 0, y0 = 0,        // box 16 x 12
    output reg [9:0] x1 = 0, y1 = 0
    );
    `include "arena_data.vh"

    wire [15:0] rnd;
    lfsr16 #(.SEED(16'h7A31)) u_rnd (.clk(clk), .q(rnd));

    // t0 / t1 count down in ticks (frames) while the box is hidden
    reg [10:0] t0 = FIRST_TICKS, t1 = FIRST_TICKS;   // wait counters
    reg [2:0] i0 = 0, i1 = 0;                        // which point each box is on

    // player touching box
    // rectangle overlap: player hitbox w x h vs box 16 x 12
    // $signed({2'b0, bx}) makes the 10 bit box spot signed like the player
    function touch;
        input signed [11:0] px, py;
        input [9:0] bx, by;
        input [5:0] w, h;
        begin
            touch = (px + $signed({6'd0, w}) > $signed({2'b0, bx})) && (px < $signed({2'b0, bx}) + 16) &&
                    (py + $signed({6'd0, h}) > $signed({2'b0, by})) && (py < $signed({2'b0, by}) + 12);
        end
    endfunction

    wire a0 = alive1 && on0 && touch(p1x, p1y, x0, y0, w1, h1);   // p1 on box 0
    wire a1 = alive1 && on1 && touch(p1x, p1y, x1, y1, w1, h1);
    wire b0 = alive2 && on0 && touch(p2x, p2y, x0, y0, w2, h2);   // p2 on box 0
    wire b1 = alive2 && on1 && touch(p2x, p2y, x1, y1, w2, h2);

    // random point, not where the other box is
    // cand = random point 0-7, changes every clock, so when a box is ready
    // it just waits until cand lands on a point the other box isnt on
    wire [2:0] cand = rnd[2:0];
    wire [9:0] cx = pick_x({map, cand}), cy = pick_y({map, cand});
    wire ok0 = !(on1 && cand == i1);
    wire ok1 = !(on0 && cand == i0);

    always @ (posedge clk) begin
        pick1 <= 0;
        pick2 <= 0;

        if (reset == 1) begin
            on0 <= 0;
            on1 <= 0;
            t0 <= FIRST_TICKS;
            t1 <= FIRST_TICKS;
        end else if (run == 1) begin
            // taken (p1 wins if both)
            if (a0 == 1 || b0 == 1) begin
                on0 <= 0;
                t0 <= AGAIN_TICKS;
            end
            if (a1 == 1 || b1 == 1) begin
                on1 <= 0;
                t1 <= AGAIN_TICKS;
            end
            // if both touch the same box the same clock p1 gets it
            pick1 <= a0 || a1;
            pick2 <= (b0 && !a0) || (b1 && !a1);

            // wait
            if (on0 == 0 && tick == 1 && t0 != 0) begin
                t0 <= t0 - 1;
            end
            if (on1 == 0 && tick == 1 && t1 != 0) begin
                t1 <= t1 - 1;
            end

            // show up, 1 box per clock
            // else if = only 1 box placed per clock, so both cant take the same cand
            if (on0 == 0 && t0 == 0 && !(a0 || b0) && ok0) begin
                on0 <= 1;
                i0 <= cand;
                x0 <= cx;
                y0 <= cy;
            end else if (on1 == 0 && t1 == 0 && !(a1 || b1) && ok1) begin
                on1 <= 1;
                i1 <= cand;
                x1 <= cx;
                y1 <= cy;
            end
        end
    end

endmodule
