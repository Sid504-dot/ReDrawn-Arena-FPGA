`timescale 1ns / 1ps


module seg7 (
    input clk,                          // 100MHz
    input [31:0] text,
    input [3:0] dots,
    output reg [6:0] seg,               // seg[0] = a ... seg[6] = g
    output reg dp,
    output reg [3:0] an                 // which digit is on
    );

    initial begin
        seg = 7'h7F;                    // all off
        dp = 1;
        an = 4'hF;
    end

    // char -> segments g f e d c b a, 1 = lit (inverted at the output)
    function [6:0] glyph;
        input [7:0] ch;
        begin
            case (ch)
                "0": glyph = 7'b0111111;
                "1": glyph = 7'b0000110;
                "2": glyph = 7'b1011011;
                "3": glyph = 7'b1001111;
                "4": glyph = 7'b1100110;
                "5": glyph = 7'b1101101;
                "6": glyph = 7'b1111101;
                "7": glyph = 7'b0000111;
                "8": glyph = 7'b1111111;
                "9": glyph = 7'b1101111;
                "A", "a": glyph = 7'b1110111;
                "B", "b": glyph = 7'b1111100;
                "C": glyph = 7'b0111001;
                "c": glyph = 7'b1011000;
                "D", "d": glyph = 7'b1011110;
                "E", "e": glyph = 7'b1111001;
                "F", "f": glyph = 7'b1110001;
                "G", "g": glyph = 7'b0111101;
                "H", "h": glyph = 7'b1110110;
                "I", "i": glyph = 7'b0000110;
                "J", "j": glyph = 7'b0011110;
                "L", "l": glyph = 7'b0111000;
                "N", "n": glyph = 7'b1010100;
                "O", "o": glyph = 7'b1011100;
                "P", "p": glyph = 7'b1110011;
                "R", "r": glyph = 7'b1010000;
                "S", "s": glyph = 7'b1101101;
                "T", "t": glyph = 7'b1111000;
                "U", "u": glyph = 7'b0111110;
                "Y", "y": glyph = 7'b1101110;
                "-": glyph = 7'b1000000;
                "_": glyph = 7'b0001000;
                default: glyph = 7'b0000000;
            endcase
        end
    endfunction

    reg [16:0] cnt = 0;                 // 100000 clk = 1 ms
    reg [1:0] sel = 0;                  // digit lit now, 0 = right one
    always @ (posedge clk) begin
        if (cnt == 17'd99999) begin
            cnt <= 0;
            sel <= sel + 1;
        end
        else begin
            cnt <= cnt + 1;
        end
        // ~ because active low
        seg <= ~glyph(text[sel*8 +: 8]);
        dp <= ~dots[sel];
        an <= ~(4'b0001 << sel);
    end

endmodule
