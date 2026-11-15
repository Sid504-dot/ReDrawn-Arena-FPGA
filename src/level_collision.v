`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: level_collision
// Description: map lookup for physics ("what tile is at this pixel")
//              own copy of the level tiles, 4 bits per tile, loaded from
//              levels_col.mem, the editor writes into it too so user levels work
//              give (px, py) + level slot, 1 clk later:
//                solid, water, boundary, mirror (+ mvert = mirror is vertical)
//              mirrors are solid as well
//              crates / doors are not tiles, check their boxes separately
//              outside the screen it repeats the edge tiles (same as drawn)
//              4 bits = {mirror, boundary, mirror ? vertical : water, solid}
//              ARENA = 1 -> also holds the 2 arena maps in slots 8-9
//              (this copy is used by the crate engine, crates exist in both games)
//////////////////////////////////////////////////////////////////////////////////


module level_collision #(
    parameter Y_OFS = 64,               // level starts 64 px down (hud above)
    parameter ARENA = 0
    )(
    input clk,
    input [3:0] level,                  // slot 0-7 (8-9 arena)
    input signed [11:0] px,
    input signed [11:0] py,
    output solid,
    output water,
    output boundary,
    output mirror,
    output mvert,
    // editor writes (any time)
    input [15:0] wr_addr,
    input wr_en,
    input [3:0] wr_type                 // {mirror, boundary, vert/water, solid}
    );

    localparam COLS = 80;               // 80 x 45 tiles of 8 x 8 px
    localparam ROWS = 45;
    localparam NLEV = (ARENA != 0) ? 10 : 8;

    reg [3:0] ram [0:NLEV*COLS*ROWS-1];
    initial begin
        $readmemh("levels_col.mem", ram, 0, 8*COLS*ROWS-1);
        if (ARENA != 0) begin
            $readmemh("arena_col.mem", ram, 8*COLS*ROWS, 10*COLS*ROWS-1);
        end
    end

    // pixel -> tile row / column (/8 = drop 3 bits), stuck to the edges
    wire signed [11:0] cy = py - Y_OFS;
    wire [5:0] row = (cy < 0) ? 6'd0 : (cy >= ROWS * 8) ? ROWS - 1 : cy[8:3];
    wire [6:0] col = (px < 0) ? 7'd0 : (px >= COLS * 8) ? COLS - 1 : px[9:3];
    // level * 3600 + row * 80 + col, row * 80 = row * 64 + row * 16
    wire [15:0] addr = level * 16'd3600 + {row, 6'b0} + {row, 4'b0} + col;

    // only 1 read per clock so vivado puts it in block ram
    reg [3:0] q = 4'd0;
    always @ (posedge clk) begin
        if (wr_en == 1) begin
            ram[wr_addr] <= wr_type;
        end
        q <= ram[addr];
    end

    // split the 4 bits
    assign solid = q[0];
    assign water = q[1] & ~q[3];        // bit 1 means water only if not a mirror
    assign mvert = q[1] & q[3];
    assign boundary = q[2];
    assign mirror = q[3];

endmodule
