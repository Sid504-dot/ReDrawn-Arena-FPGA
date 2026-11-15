`timescale 1ns / 1ps


module oled_debug (
    input clk,                          // 100 MHz
    input clr,                          // btnU
    input page,                         // sw0
    input ok_k1, ok_k2, ok_m2,          // link ok
    input good_k1, bad_k1, good_k2, bad_k2, good_m2, bad_m2,
    input [6:0] keys1, keys2,
    input [9:0] m1x, m1y, m2x, m2y,
    input m1l, m1r, m2l, m2r,
    input [1:0] role,                   // sw15-14
    input [12:0] pixel_index,           // from Oled_Display
    output reg [15:0] pixel_data
    );
    `include "font57.vh"

    // packet counters, good wraps at FFFF, bad stops at FFF
    // g = good packets (16 bit, wraps), e = bad ones (12 bit, stops at FFF)
    // 1 = keyboard 1, 2 = keyboard 2, 3 = mouse 2
    reg [15:0] g1 = 0, g2 = 0, g3 = 0;
    reg [11:0] e1 = 0, e2 = 0, e3 = 0;
    always @ (posedge clk) begin
        if (clr == 1) begin
            g1 <= 0;
            g2 <= 0;
            g3 <= 0;
            e1 <= 0;
            e2 <= 0;
            e3 <= 0;
        end else begin
            if (good_k1 == 1) begin
                g1 <= g1 + 1;
            end
            if (good_k2 == 1) begin
                g2 <= g2 + 1;
            end
            if (good_m2 == 1) begin
                g3 <= g3 + 1;
            end
            if (bad_k1 == 1 && e1 != 12'hFFF) begin
                e1 <= e1 + 1;
            end
            if (bad_k2 == 1 && e2 != 12'hFFF) begin
                e2 <= e2 + 1;
            end
            if (bad_m2 == 1 && e3 != 12'hFFF) begin
                e3 <= e3 + 1;
            end
        end
    end

    // number to hex char
    // 0-9 -> '0'-'9', 10-15 -> 'A'-'F' (8'h37 + 10 = 'A')
    function [7:0] hexc; input [3:0] n; hexc = (n < 4'd10) ? {4'h3, n} : 8'h37 + {4'd0, n}; endfunction
    // mouse x y as 3 hex digits
    wire [23:0] n3 [0:3];
    assign n3[0] = {hexc({2'b0, m1x[9:8]}), hexc(m1x[7:4]), hexc(m1x[3:0])};
    assign n3[1] = {hexc({2'b0, m1y[9:8]}), hexc(m1y[7:4]), hexc(m1y[3:0])};
    assign n3[2] = {hexc({2'b0, m2x[9:8]}), hexc(m2x[7:4]), hexc(m2x[3:0])};
    assign n3[3] = {hexc({2'b0, m2y[9:8]}), hexc(m2y[7:4]), hexc(m2y[3:0])};
    function [15:0] onoff_ok; input b; onoff_ok = b ? "OK" : "--"; endfunction

    // which char cell (6 x 8 px) the pixel is in
    // multiply + shift instead of divide
    // divide by 96 and 6 are slow in hardware so use
    // multiply by (2^n / divisor) then shift right by n
    wire [25:0] pyw = pixel_index * 13'd2731;       // pixel_index / 96 = (pixel_index * 2731) >> 18
    wire [5:0]  py  = pyw[23:18];
    wire [6:0]  px  = pixel_index - py * 7'd96;
    wire [12:0] colw = px * 6'd43;                  // px / 6 = (px * 43) >> 8
    wire [3:0]  col = colw[11:8];                   // 0..15
    wire [2:0]  fx  = px - col * 3'd6;              // x in the cell
    wire [2:0]  row = py[5:3];                      // 0..7
    wire [2:0]  fy  = py[2:0];                      // y in the cell

    // 1 text row = 16 chars, hi = which chars are green
    // line = the 16 chars of the text row this pixel is in
    // c_base = normal colour, c_hi = colour of chars marked in hi
    reg [8*16-1:0] line;
    reg [15:0]     hi;
    reg [15:0]     c_base, c_hi;

    localparam [15:0] WHITE = 16'hFFFF, GREEN = 16'h07E0, RED = 16'hF800, YELLOW = 16'hFFE0,
                      CYAN = 16'h07FF, GREY = 16'h7BEF, BLACK = 16'h0000;

    // keys A D J(space) R P(esc) E(enter)
    localparam [8*16-1:0] KEYTXT = "A D J   R P E   ";
    // key j is drawn at char 2*j, chars counted from the left (bit 15)
    // j 3 is Shift, not used
    function [15:0] keymask;  input [6:0] k;  integer j;
        begin
            keymask = 16'd0;
            for (j = 0; j < 7; j = j + 1) if (k[j] && j != 3) keymask[15 - 2*j] = 1'b1;
        end
    endfunction
    // mouse row, L at col 11, R at col 13
    wire [8*16-1:0] mrow1 = {"M ", n3[0], ",", n3[1], "  L R  "};
    wire [8*16-1:0] mrow2 = {"M ", n3[2], ",", n3[3], "  L R  "};
    function [15:0] mmask; input l, r;
        mmask = (l ? 16'h0010 : 16'd0) | (r ? 16'h0004 : 16'd0);
    endfunction
    wire [8*4-1:0] k4a = {hexc(g1[15:12]), hexc(g1[11:8]), hexc(g1[7:4]), hexc(g1[3:0])};
    wire [8*4-1:0] k4b = {hexc(g2[15:12]), hexc(g2[11:8]), hexc(g2[7:4]), hexc(g2[3:0])};
    wire [8*4-1:0] k4c = {hexc(g3[15:12]), hexc(g3[11:8]), hexc(g3[7:4]), hexc(g3[3:0])};
    wire [8*3-1:0] e3a = {hexc(e1[11:8]), hexc(e1[7:4]), hexc(e1[3:0])};
    wire [8*3-1:0] e3b = {hexc(e2[11:8]), hexc(e2[7:4]), hexc(e2[3:0])};
    wire [8*3-1:0] e3c = {hexc(e3[11:8]), hexc(e3[7:4]), hexc(e3[3:0])};

    // build the text for the current row
    always @ (*) begin
        line = {16{" "}}; hi = 16'd0; c_base = WHITE; c_hi = GREEN;
        if (role == 2'b01 || role == 2'b10) begin
            case (row)
                3'd0: begin line = "SENDER BOARD    "; c_base = YELLOW; end
                3'd2: line = (role == 2'b01) ? "KEYBOARD -> JA1 " : "MOUSE -> JA1    ";
                3'd4: begin line = "SW15-14 = 00 FOR"; c_base = GREY; end
                3'd5: begin line = "THE MAIN BOARD  "; c_base = GREY; end
                default: ;
            endcase
        end else if (row == 0) begin
            c_base = YELLOW;
            line = page ? "2/2 INPUTS SW0=1" : "1/2 LINKS  SW0=0";
        end else case (page)
        // LINKS
        1'b0: case (row)
            3'd1: begin line = {"KB1 JA1 ", onoff_ok(ok_k1), {6{" "}}}; c_base = ok_k1 ? GREEN : RED; end
            3'd2: line = {" G ", k4a, "  B ", e3a, "  "};
            3'd3: begin line = {"KB2 JA2 ", onoff_ok(ok_k2), {6{" "}}}; c_base = ok_k2 ? GREEN : RED; end
            3'd4: line = {" G ", k4b, "  B ", e3b, "  "};
            3'd5: begin line = {"MS2 JA3 ", onoff_ok(ok_m2), {6{" "}}}; c_base = ok_m2 ? GREEN : RED; end
            3'd6: line = {" G ", k4c, "  B ", e3c, "  "};
            3'd7: begin line = {"MS1 X", n3[0], " Y", n3[1], "   "}; c_base = CYAN; end
            default: ;
        endcase
        // INPUTS
        1'b1: case (row)
            3'd1: begin line = "P1 KEYS (JA1)   "; c_base = CYAN; end
            3'd2: begin line = KEYTXT; hi = keymask(keys1); c_base = GREY; end
            3'd3: begin line = mrow1;  hi = mmask(m1l, m1r); c_base = GREY; end
            3'd4: begin line = "P2 KEYS (JA2)   "; c_base = CYAN; end
            3'd5: begin line = KEYTXT; hi = keymask(keys2); c_base = GREY; end
            3'd6: begin line = mrow2;  hi = mmask(m2l, m2r); c_base = GREY; end
            3'd7: begin line = "GREEN = HELD    "; c_base = GREY; end
            default: ;
        endcase
        endcase
    end

    // font lookup
    // pick this cell's char, its row of 5 bits from the font,
    // then the bit for this x (font is 5 x 7, cell is 6 x 8 so there is a gap)
    wire [7:0] ch   = line[8*(15 - col) +: 8];
    wire [4:0] bits = font57(ch, fy);
    wire       lit  = (fx < 3'd5) && (fy < 3'd7) && bits[3'd4 - fx];
    always @ (posedge clk) begin
        if (lit == 0) begin
            pixel_data <= BLACK;
        end else if (hi[15 - col] == 1) begin
            pixel_data <= c_hi;
        end else begin
            pixel_data <= c_base;
        end
    end

endmodule
