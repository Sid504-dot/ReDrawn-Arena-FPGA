`timescale 1ns / 1ps


module aim_gun2 (
    input clk,
    input [9:0] x,
    input [9:0] y,
    input upd,                          // 1 clk at start of vblank
    input [9:0] m1x,                    // mice
    input [9:0] m1y,
    input [9:0] m2x,
    input [9:0] m2y,
    input vis1,                         // player on screen
    input vis2,
    input [9:0] p1x,                    // player sprite top left (16 x 16)
    input [9:0] p1y,
    input [9:0] p2x,
    input [9:0] p2y,
    output [3:0] gun1_idx,
    output [3:0] gun2_idx,
    output reg face1,                   // 1 = facing left
    output reg face2,
    output reg signed [15:0] c1,        // aim cos / sin * 16384, for bullets
    output reg signed [15:0] s1,
    output reg signed [15:0] c2,
    output reg signed [15:0] s2,
    output reg [9:0] mz1x,              // gun tip, shots start here
    output reg [9:0] mz1y,
    output reg [9:0] mz2x,
    output reg [9:0] mz2y,
    // shared angle unit (port b)
    output reg ang_req,
    output reg signed [15:0] ang_vx,
    output reg signed [15:0] ang_vy,
    input ang_ack,
    input [15:0] ang_cz,
    input signed [15:0] ang_s,
    input signed [15:0] ang_c
    );
    `include "sprite_data_a.vh"

    initial begin
        face1 = 0;
        face2 = 0;
        c1 = 16'sd16384;
        s1 = 16'sd0;
        c2 = 16'sd16384;
        s2 = 16'sd0;
        mz1x = 0;
        mz1y = 0;
        mz2x = 0;
        mz2y = 0;
        ang_req = 0;
        ang_vx = 0;
        ang_vy = 0;
    end

    localparam signed [27:0] HALF = 28'sd8192;     // 0.5 with 14 bit fraction, for rounding
    localparam HAND_OUT = 5;                       // hand 5 px from body middle
    localparam GUN_PX = 2;                         // gun art pixel held in the hand
    localparam GUN_PY = 3;
    localparam TIP = 13;                           // hand -> gun tip in px

    // which player now
    reg who = 0;                        // 0 p1, 1 p2
    wire [9:0] mx = who ? m2x : m1x;
    wire [9:0] my = who ? m2y : m1y;
    wire vis = who ? vis2 : vis1;
    wire [9:0] bc_x = (who ? p2x : p1x) + 10'd8;   // body middle
    wire [9:0] bc_y = (who ? p2y : p1y) + 10'd10;

    // 1 multiplier used 4 times one after another
    reg signed [15:0] ma = 0;
    reg signed [15:0] mb = 0;
    reg signed [27:0] prod = 0;
    always @ (posedge clk) begin
        prod <= ma * mb;
    end

    localparam F_IDLE   = 0;
    localparam F_CORDIC = 1;            // waiting for angle_unit
    localparam F_TABLE  = 2;            // not used
    localparam F_ANCHOR = 3;            // move hand out
    localparam F_MUL    = 4;            // gun_px numbers
    localparam F_LOAD   = 5;            // ask angle_unit
    reg [2:0] fst = F_IDLE;
    reg [9:0] pvx = 0;                  // the hand (gun turns around it)
    reg [9:0] pvy = 0;
    reg [2:0] mstep = 0;
    reg signed [27:0] p1 = 0;
    reg signed [27:0] p2 = 0;
    reg signed [27:0] p3 = 0;
    reg tab2 = 0;
    reg on_q = 0;
    reg lefty_q = 0;
    reg signed [15:0] c = 16'sd16384;   // direction for the player being done
    reg signed [15:0] s = 16'sd0;
    // results per player for gun_px
    reg signed [25:0] Au1 = 0;
    reg signed [25:0] Av1 = 0;
    reg signed [25:0] Au2 = 0;
    reg signed [25:0] Av2 = 0;
    reg gon1 = 0;
    reg gon2 = 0;
    reg flv1 = 0;
    reg flv2 = 0;
    reg signed [15:0] pc1 = 16'sd16384;
    reg signed [15:0] ps1 = 0;
    reg signed [15:0] pc2 = 16'sd16384;
    reg signed [15:0] ps2 = 0;
    // tip = hand + 13 * (cos, sin), <<< 14 puts the hand in the same fixed point
    wire signed [27:0] mzx_f = ($signed({18'b0, pvx}) <<< 14) + $signed(TIP) * c + HALF;
    wire signed [27:0] mzy_f = ($signed({18'b0, pvy}) <<< 14) + $signed(TIP) * s + HALF;

    always @ (posedge clk) begin
        case (fst)
            F_IDLE: begin
                if (upd == 1) begin
                    who <= 0;
                    fst <= F_LOAD;
                end
            end

            F_LOAD: begin
                pvx <= bc_x;
                pvy <= bc_y;
                on_q <= vis;
                ang_req <= 1;
                ang_vx <= $signed({6'b0, mx}) - $signed({6'b0, bc_x});
                ang_vy <= $signed({6'b0, my}) - $signed({6'b0, bc_y});
                fst <= F_CORDIC;
            end

            F_CORDIC: begin
                if (ang_ack == 1) begin
                    ang_req <= 0;
                    s <= ang_s;
                    c <= ang_c;
                    // angle between 90 and 270 deg (64-192 of 256) = aiming left
                    lefty_q <= (ang_cz[15:8] + {7'd0, ang_cz[7]} > 8'd64) && (ang_cz[15:8] + {7'd0, ang_cz[7]} < 8'd192);
                    fst <= F_ANCHOR;
                end
            end

            F_ANCHOR: begin
                pvx <= (($signed({18'b0, pvx}) <<< 14) + $signed(HAND_OUT) * c + HALF) >>> 14;
                pvy <= (($signed({18'b0, pvy}) <<< 14) + $signed(HAND_OUT) * s + HALF) >>> 14;
                mstep <= 0;
                fst <= F_MUL;
            end

            // Au = -(px*c + py*s), Av = px*s - py*c (gun position rotated back)
            // product comes 1 clk after ma / mb are set
            F_MUL: begin
                mstep <= mstep + 1;
                case (mstep)
                    3'd0: begin
                        ma <= $signed({6'b0, pvx});
                        mb <= c;
                    end
                    3'd1: begin
                        ma <= $signed({6'b0, pvy});
                        mb <= s;
                    end
                    3'd2: begin
                        p1 <= prod;
                        ma <= $signed({6'b0, pvx});
                        mb <= s;
                    end
                    3'd3: begin
                        p2 <= prod;
                        ma <= $signed({6'b0, pvy});
                        mb <= c;
                    end
                    3'd4: begin
                        p3 <= prod;
                    end
                    default: begin
                        // all outputs of a player change together
                        if (who == 0) begin
                            Au1 <= -(p1 + p2);
                            Av1 <= p3 - prod;
                            gon1 <= on_q;
                            flv1 <= lefty_q;
                            pc1 <= c;
                            ps1 <= s;
                            c1 <= c;
                            s1 <= s;
                            face1 <= lefty_q;
                            mz1x <= mzx_f >>> 14;
                            mz1y <= mzy_f >>> 14;
                            who <= 1;               // now p2
                            fst <= F_LOAD;
                        end
                        else begin
                            Au2 <= -(p1 + p2);
                            Av2 <= p3 - prod;
                            gon2 <= on_q;
                            flv2 <= lefty_q;
                            pc2 <= c;
                            ps2 <= s;
                            c2 <= c;
                            s2 <= s;
                            face2 <= lefty_q;
                            mz2x <= mzx_f >>> 14;
                            mz2y <= mzy_f >>> 14;
                            fst <= F_IDLE;
                        end
                    end
                endcase
            end

            default: begin
                fst <= F_IDLE;
            end
        endcase
    end

    // drawing, 1 per player
    gun_px u_px1 (.clk(clk), .x(x), .y(y), .Au(Au1), .Av(Av1), .c(pc1), .s(ps1), .on(gon1), .flipv(flv1), .idx(gun1_idx));
    gun_px u_px2 (.clk(clk), .x(x), .y(y), .Au(Au2), .Av(Av2), .c(pc2), .s(ps2), .on(gon2), .flipv(flv2), .idx(gun2_idx));

endmodule


// rotated 16 x 8 gun, 2 clk delay
module gun_px (
    input clk,
    input [9:0] x,
    input [9:0] y,
    input signed [25:0] Au,             // from aim_gun2
    input signed [25:0] Av,
    input signed [15:0] c,
    input signed [15:0] s,
    input on,
    input flipv,                        // flip up / down (aiming left)
    output reg [3:0] idx
    );
    `include "sprite_data_a.vh"

    initial begin
        idx = 0;
    end

    localparam signed [27:0] HALF = 28'sd8192;
    localparam GUN_PX = 2;
    localparam GUN_PY = 3;

    // u, v = position along / across the gun for this pixel
    // u = Au + x*c + y*s, v = Av - x*s + y*c, lin_eval does it without multiplying
    wire signed [25:0] u;
    wire signed [25:0] v;
    lin_eval ev_u (.clk(clk), .x(x), .y(y), .A(Au), .a(c), .b(s), .val(u));
    lin_eval ev_v (.clk(clk), .x(x), .y(y), .A(Av), .a(-s), .b(c), .val(v));
    // back to whole art pixels (rounded)
    wire signed [13:0] upx = (u + HALF) >>> 14;
    wire signed [13:0] vpx = (v + HALF) >>> 14;
    wire signed [13:0] gcol = upx + GUN_PX;
    wire signed [13:0] grow = (flipv ? -vpx : vpx) + GUN_PY;
    wire in_gun = on && gcol >= 0 && gcol < 16 && grow >= 0 && grow < 8;

    reg in_gun_q = 0;
    reg [3:0] gc_q = 0;
    reg [2:0] gr_q = 0;
    always @ (posedge clk) begin
        in_gun_q <= in_gun;
        gc_q <= gcol[3:0];
        gr_q <= grow[2:0];
        if (in_gun_q == 1) begin
            idx <= SPR_GUN[({gr_q, 4'b0} + gc_q) * 4 +: 4];
        end
        else begin
            idx <= 4'h0;
        end
    end

endmodule
