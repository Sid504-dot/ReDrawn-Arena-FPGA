`timescale 1ns / 1ps


module level_collision_a2 #(
    parameter Y_OFS = 64,
    parameter NMAP  = 2
    )(
    input clk,
    input [1:0] map,                    // 0 bridges, 1 towers
    input signed [11:0] ax,
    input signed [11:0] ay,
    output a_solid,
    output a_boundary,
    input signed [11:0] bx,
    input signed [11:0] by,
    output b_solid,
    output b_boundary,
    output a_water,
    output b_water,
    output a_mir,                       // mirror at point a (shots bounce)
    output a_mvert                      // that mirror is vertical
    );

    localparam COLS = 80;
    localparam ROWS = 45;

    reg [3:0] ram [0:NMAP*COLS*ROWS-1];
    initial $readmemh("arena_col.mem", ram);

    // pixel -> tile address
    function [13:0] addr;
        input [1:0] m;
        input signed [11:0] px;
        input signed [11:0] py;
        reg signed [11:0] cy;
        reg [5:0] row;
        reg [6:0] col;
        begin
            cy = py - Y_OFS;
            row = (cy < 0) ? 6'd0 : (cy >= ROWS * 8) ? ROWS - 1 : cy[8:3];
            col = (px < 0) ? 7'd0 : (px >= COLS * 8) ? COLS - 1 : px[9:3];
            addr = m * 14'd3600 + {row, 6'b0} + {row, 4'b0} + col;
        end
    endfunction

    reg [3:0] qa = 4'd0;
    reg [3:0] qb = 4'd0;
    always @ (posedge clk) begin
        qa <= ram[addr(map, ax, ay)];
    end
    always @ (posedge clk) begin
        qb <= ram[addr(map, bx, by)];
    end

    assign a_solid = qa[0];
    assign a_boundary = qa[2];
    assign b_solid = qb[0];
    assign b_boundary = qb[2];
    assign a_water = qa[1] & ~qa[3];
    assign b_water = qb[1] & ~qb[3];
    assign a_mir = qa[3];
    assign a_mvert = qa[1];

endmodule
