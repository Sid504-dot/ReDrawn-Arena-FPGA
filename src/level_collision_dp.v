`timescale 1ns / 1ps


module level_collision_dp #(
    parameter Y_OFS = 64
    )(
    input clk,
    input [3:0] level,
    // port a, aim / gun
    input signed [11:0] ax,
    input signed [11:0] ay,
    output a_solid,
    output a_boundary,
    output a_mirror,
    output a_mvert,
    // port b, character
    input signed [11:0] bx,
    input signed [11:0] by,
    output b_solid,
    output b_water,
    // editor writes
    input [15:0] wr_addr,
    input wr_en,
    input [3:0] wr_type                 // {mirror, boundary, vert/water, solid}
    );

    localparam COLS = 80;
    localparam ROWS = 45;
    localparam NLEV = 8;

    (* ram_style = "block" *) reg [3:0] ram [0:NLEV*COLS*ROWS-1];
    initial $readmemh("levels_col.mem", ram, 0, NLEV*COLS*ROWS-1);

    // pixel -> tile address, same as level_collision
    function [15:0] taddr;
        input [3:0] lv;
        input signed [11:0] px;
        input signed [11:0] py;
        reg signed [11:0] cy;
        reg [5:0] row;
        reg [6:0] col;
        begin
            cy = py - Y_OFS;
            row = (cy < 0) ? 6'd0 : (cy >= ROWS * 8) ? ROWS - 1 : cy[8:3];
            col = (px < 0) ? 7'd0 : (px >= COLS * 8) ? COLS - 1 : px[9:3];
            taddr = lv * 16'd3600 + {row, 6'b0} + {row, 4'b0} + col;
        end
    endfunction

    wire [15:0] addr_a = (wr_en == 1) ? wr_addr : taddr(level, ax, ay);
    wire [15:0] addr_b = taddr(level, bx, by);

    reg [3:0] qa = 4'd0;
    reg [3:0] qb = 4'd0;
    // port a, write or read
    always @ (posedge clk) begin
        if (wr_en == 1) begin
            ram[addr_a] <= wr_type;
        end
        qa <= ram[addr_a];
    end
    // port b, read only
    always @ (posedge clk) begin
        qb <= ram[addr_b];
    end

    assign a_solid = qa[0];
    assign a_boundary = qa[2];
    assign a_mirror = qa[3];
    assign a_mvert = qa[1] & qa[3];
    assign b_solid = qb[0];
    assign b_water = qb[1] & ~qb[3];

endmodule
