`timescale 1ns / 1ps


module spring_gfx (
    input clk,
    input [9:0] x,
    input [9:0] y,
    input [19:0] x0,                    // {spring 1, spring 0} box top left, 1023 = hidden
    input [19:0] y0,
    input [5:0] frame,                  // {spring 1, spring 0} 0 extended .. 4 compressed
    output reg [7:0] idx,               // {spring 1, spring 0} palette index, 0 = nothing
    output reg [1:0] box                // beam inside the box
    );

    // 5 frames * 32 * 48 = 7680 entries
    (* rom_style = "block" *) reg [3:0] rom [0:7679];
    initial $readmemh("spring_frames.mem", rom);

    initial begin
        idx = 0;
        box = 0;
    end

    // address for each spring
    reg [12:0] a [0:1];
    reg [1:0] hit;
    integer k;
    reg [10:0] dx;
    reg [10:0] dy;
    reg [2:0] f;
    always @ (*) begin
        for (k = 0; k < 2; k = k + 1) begin
            dx = {1'b0, x} - {1'b0, x0[k*10 +: 10]};
            dy = {1'b0, y} - {1'b0, y0[k*10 +: 10]};
            f = frame[k*3 +: 3];
            hit[k] = (x >= x0[k*10 +: 10]) && (dx < 11'd64) && (y >= y0[k*10 +: 10]) && (dy < 11'd96);
            // frame * 1536 + row * 32 + col, /2 because drawn 2x
            // (1536 = 1024 + 512 so shifts instead of a multiply)
            a[k] = {f, 10'd0} + {f, 9'd0} + {dy[6:1], dx[5:1]};
        end
    end

    reg [3:0] d0 = 0;
    reg [3:0] d1 = 0;
    reg [1:0] hit_q = 0;
    always @ (posedge clk) begin
        // clk 1: read both
        d0 <= rom[a[0]];
        d1 <= rom[a[1]];
        hit_q <= hit;
        // clk 2: 0 when outside the box
        idx <= {hit_q[1] ? d1 : 4'h0, hit_q[0] ? d0 : 4'h0};
        box <= hit_q;
    end

endmodule
