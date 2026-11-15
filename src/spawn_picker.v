`timescale 1ns / 1ps


module spawn_picker #(
    parameter MIN_DIST = 200,               // |dx| + |dy| in px
    parameter MAX_TRY  = 15                 // after this just take the point
    )(
    input clk,
    input rst,
    input req1, req2,                       // spawn1 / spawn2 from match_fsm
    input [1:0] map,
    input signed [11:0] p1x, p1y,
    input signed [11:0] p2x, p2y,
    output reg load1 = 0, load2 = 0,
    output reg signed [11:0] sx = 0, sy = 0
    );
    `include "arena_data.vh"

    wire [15:0] rnd;
    lfsr16 #(.SEED(16'h1D2B)) u_rnd (.clk(clk), .q(rnd));

    // req is a 1 clock pulse, pend remembers it while busy with the other one
    reg pend1 = 0, pend2 = 0;               // waiting to be placed
    reg busy = 0;
    reg who = 0;                            // 0 = p1, 1 = p2
    reg [3:0] tries = 0;

    // random point and how far it is from the other player
    // distance = |dx| + |dy| (no multiply needed, good enough)
    wire [2:0] idx = rnd[2:0];
    wire signed [11:0] cx = {2'b00, spawn_x({map, idx})};
    wire signed [11:0] cy = {2'b00, spawn_y({map, idx})};
    wire signed [11:0] ox = who ? p1x : p2x;
    wire signed [11:0] oy = who ? p1y : p2y;
    wire other_waiting = who ? pend1 : pend2;        // other one not placed yet
    wire signed [12:0] ddx = cx - ox, ddy = cy - oy;
    wire [12:0] adx = ddx[12] ? -ddx : ddx;
    wire [12:0] ady = ddy[12] ? -ddy : ddy;
    wire far = other_waiting || (adx + ady >= MIN_DIST);

    always @ (posedge clk) begin
        load1 <= 0;
        load2 <= 0;

        if (rst == 1) begin
            pend1 <= 0;
            pend2 <= 0;
            busy <= 0;
        end else begin
            if (req1 == 1) begin
                pend1 <= 1;
            end
            if (req2 == 1) begin
                pend2 <= 1;
            end

            if (busy == 0) begin
                // p1 first
                if (pend1 == 1 || req1 == 1) begin
                    busy <= 1;
                    who <= 0;
                    tries <= 0;
                end else if (pend2 == 1 || req2 == 1) begin
                    busy <= 1;
                    who <= 1;
                    tries <= 0;
                end
            end else begin
                // try 1 point every clock
                // pend <= req: if a new request came in this same clock dont lose it
                if (far == 1 || tries == MAX_TRY) begin
                    sx <= cx;
                    sy <= cy;
                    if (who == 1) begin
                        load2 <= 1;
                        pend2 <= req2;
                    end else begin
                        load1 <= 1;
                        pend1 <= req1;
                    end
                    busy <= 0;
                end else begin
                    tries <= tries + 1;
                end
            end
        end
    end

endmodule
