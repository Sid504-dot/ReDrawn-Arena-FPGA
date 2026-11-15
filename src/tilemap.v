`timescale 1ns / 1ps


module tilemap #(
    parameter Y_OFS = 64
    )(
    input clk,
    input [9:0] x,
    input [9:0] y,
    input [3:0] level,
    input [7:0] frame,                  // for the water wave
    output reg [3:0] idx,               // palette index, 0 = nothing
    output reg shadow,
    output reg water_surf,
    output reg water_body,
    // editor, only works while y >= 480
    input [15:0] ed_addr,
    input ed_we,
    input [15:0] ed_wdata,
    output [15:0] ed_rdata              // word at ed_addr, 1 clk later
    );
    `include "sprite_data.vh"

    localparam COLS = 80;
    localparam ROWS = 45;
    localparam LEVEL_WORDS = COLS * ROWS;
    localparam NLEV = 10;

    reg [15:0] ram [0:NLEV*LEVEL_WORDS-1];
    initial begin
        $readmemh("levels.mem", ram, 0, 8*LEVEL_WORDS-1);
        $readmemh("arena.mem", ram, 8*LEVEL_WORDS, 10*LEVEL_WORDS-1);
    end

    // pixel -> {address, x in tile, y in tile (art px), outside}
    function [20:0] lookup;
        input [10:0] px;
        input [10:0] py;
        input [3:0] lvl;
        reg signed [11:0] cy;
        reg [5:0] row;
        reg [6:0] col;
        reg ext;
        begin
            cy = $signed({1'b0, py}) - Y_OFS;
            ext = (cy < 0) || (cy >= ROWS * 8);     // above / below the level
            row = (cy < 0) ? 6'd0 : (cy >= ROWS * 8) ? ROWS - 1 : cy[8:3];
            col = px[10] ? 7'd0 : px[9:3];          // px[10] = went negative
            lookup = {lvl * 16'd3600 + {row, 6'b0} + {row, 4'b0} + col, px[2:1], cy[2:1], ext};
        end
    endfunction

    wire [20:0] la = lookup({1'b0, x}, {1'b0, y}, level);
    wire [20:0] lb = lookup({1'b0, x} - 11'd4, {1'b0, y} - 11'd4, level);
    wire ed_own = (y >= 10'd480);       // editor owns port b now
    wire [15:0] addr_b = (ed_own == 1) ? ed_addr : lb[20:5];

    // clk 1: read port a, port b read / editor write
    reg [15:0] wa;
    reg [15:0] wb;
    reg [1:0] lxa;
    reg [1:0] lya;
    reg [1:0] lxb;
    reg [1:0] lyb;
    reg exa;
    reg exb;
    reg own_q;
    reg [2:0] gx_q;                     // grass art column
    reg [2:0] px_q;                     // pixel in the tile
    reg [2:0] py_q;
    reg [2:0] tcol_q;                   // tile column, for the wave
    reg xd_q;                           // dash pattern
    reg yd_q;
    always @ (posedge clk) begin
        wa <= ram[la[20:5]];
        {lxa, lya, exa} <= la[4:0];
        {lxb, lyb, exb} <= lb[4:0];
        gx_q <= x[3:1];
        px_q <= x[2:0];
        py_q <= y[2:0] - Y_OFS[2:0];
        tcol_q <= x[5:3];
        xd_q <= x[3];
        yd_q <= y[3];
        own_q <= ed_own;
    end
    always @ (posedge clk) begin
        if (ed_own == 1 && ed_we == 1) begin
            ram[addr_b] <= ed_wdata;
        end
        wb <= ram[addr_b];
    end
    assign ed_rdata = wb;

    // wall outline: bits 1-8 say which sides / corners touch air
    // (bit 3 left, 4 right, 1 top, 2 bottom, 5-8 corners)
    // above / below the level only the left and right sides are drawn
    function outline;
        input [15:0] w;
        input [1:0] lx;
        input [1:0] ly;
        input ext;
        begin
            outline = w[0] && (
                (w[3] && lx == 0) || (w[4] && lx == 3) ||
                (!ext && ((w[1] && ly == 0) || (w[2] && ly == 3) ||
                          (w[5] && lx == 0 && ly == 0) || (w[6] && lx == 3 && ly == 0) ||
                          (w[7] && lx == 0 && ly == 3) || (w[8] && lx == 3 && ly == 3))));
        end
    endfunction

    // clk 2
    localparam [7:0] WAVE = 8'b0011_1000;   // which tile columns are wave tops
    wire [3:0] gpix = SPR_GRASS[((lya + 1) * SPR_GRASS_W + gx_q) * 4 +: 4];
    wire [2:0] wi = tcol_q + frame[6:4];    // wave moves with the frame counter
    wire wave_up = WAVE[wi];
    wire [1:0] surf_row = wave_up ? 2'd0 : 2'd1;
    wire bnd_bad = wa[14];                  // invalid boundary
    // dashes: vertical boundary uses the x middle, horizontal the y middle
    wire bnd_on = wa[13] ? ((lxa == 2'd1 || (bnd_bad && lxa == 2'd2)) && !yd_q)
                         : ((lya == 2'd1 || (bnd_bad && lya == 2'd2)) && !xd_q);
    wire terr = !wa[15];                    // normal tile

    // crate tiles (only old arena maps had them), position in the 16 / 32 px box
    wire [4:0] cbx = {wa[3:2], px_q};
    wire [4:0] cby = {wa[5:4], py_q};
    wire [3:0] ccol = wa[13] ? cbx[4:1] : cbx[3:0];
    wire [3:0] crow = wa[13] ? cby[4:1] : cby[3:0];
    wire [3:0] cpix = SPR_CRATE[({crow, 4'b0} + ccol) * 4 +: 4];

    // mirror tiles, m_c = across the panel (0 = open side), m_a = along it
    wire [1:0] m_raw = wa[13] ? lxa : lya;
    wire [1:0] m_c = wa[12] ? 2'd3 - m_raw : m_raw;
    wire [1:0] m_a = wa[13] ? lya : lxa;
    wire m_cap = (wa[11] && m_a == 2'd0) || (wa[10] && m_a == 2'd3);
    wire m_lip = (wa[11] && m_a == 2'd1) || (wa[10] && m_a == 2'd2);
    reg [3:0] mpix;
    always @ (*) begin
        if (m_cap || m_c == 2'd3) begin
            mpix = 4'h5;                    // wood, caps and back
        end
        else if (m_c == 2'd0) begin
            mpix = m_lip ? 4'h5 : 4'h0;     // open side, only bracket corners
        end
        else if (m_c == 2'd1) begin
            mpix = 4'hB;                    // glass shine
        end
        else begin
            mpix = 4'hC;                    // glass
        end
    end

    always @ (posedge clk) begin
        if (wa[15] && !exa) begin
            idx <= wa[14] ? mpix : cpix;    // mirror or crate tile
        end
        else if (outline(wa, lxa, lya, exa)) begin
            idx <= 4'h3;                    // wall green
        end
        else if (terr && wa[12] && !exa && bnd_on) begin
            idx <= bnd_bad ? 4'h9 : 4'h1;   // boundary, red if invalid
        end
        else if (terr && wa[9] && !exa) begin
            idx <= gpix;                    // grass
        end
        else begin
            idx <= 4'h0;
        end
        // shadow = outline of the tile 4 px up-left, not while editor uses port b
        shadow <= outline(wb, lxb, lyb, exb) && !own_q;
        // bit 10 water, bit 11 = top tile of the water
        water_surf <= terr && wa[10] && !exa && wa[11] && (lya == surf_row);
        water_body <= terr && wa[10] && !exa && (!wa[11] || lya > surf_row);
    end

endmodule
