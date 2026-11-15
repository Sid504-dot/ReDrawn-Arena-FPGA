`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: bullets
// Description: fire / freeze shots in the air, 4 slots: 0-1 are p1's, 2-3 are p2's
//              (if both slots of a player are full the new shot is lost)
//              each frame every shot moves 6 px = 3 small steps of 2 px, after every
//              step it asks the map what is there (1 lookup at a time, takes a few clk):
//                other player  -> hit_fire / hit_freeze to player_stats, shot gone
//                own player, only after it bounced off a mirror (6 Nov)
//                              -> self_fire (grow) / self_freeze (shrink), no damage
//                mirror tile   -> step back and bounce (flip x or y), max 3 bounces
//                wall / off    -> shot gone
//              small steps so a fast shot cant jump over a thin wall or a player
//              position is fixed point 12.8 (top 12 bits = pixel, low 8 = fraction)
//              so slow angles still move smoothly
//////////////////////////////////////////////////////////////////////////////////


module bullets (
    input clk,
    input reset,                            // gs_reset
    input tick,
    input run,                              // gs_run
    input shoot_fire1, shoot_freeze1,       // from player_stats
    input shoot_fire2, shoot_freeze2,
    input [9:0] mz1x, mz1y, mz2x, mz2y,     // gun tip
    input signed [15:0] c1, s1, c2, s2,     // aim cos / sin
    input signed [11:0] p1x, p1y, p2x, p2y,
    input alive1, alive2,
    input [5:0] w1, h1, w2, h2,             // hitbox sizes (players can be resized)
    // map lookup, answer 1 clock later
    output reg signed [11:0] col_px = 0, col_py = 0,
    input col_solid, col_bnd,
    input col_mir, col_mvert,               // mirror, vertical one flips x else y
    output reg hit_fire1 = 0, hit_freeze1 = 0,
    output reg hit_fire2 = 0, hit_freeze2 = 0,
    output reg self_fire1 = 0, self_freeze1 = 0,   // own shot came back: resize yourself
    output reg self_fire2 = 0, self_freeze2 = 0,
    // for drawing
    output [3:0] b_on,
    output [3:0] b_frz,
    output [39:0] b_x,                      // slot k = b_x[k*10 +: 10]
    output [39:0] b_y,
    // for the crate check in arena_core
    output chk,
    output chk_frz,
    output chk_hitp,
    // spark where a shot hit a player (8 frames, grows 3 -> 10 px)
    output reg sk_on = 0,
    output reg sk_frz = 0,                  // 1 = freeze shot (blue rim), 0 = fire (red rim)
    output reg [2:0] sk_t = 0,              // frame of the spark 0-7
    output reg [9:0] sk_x = 0,              // where the shot was when it hit
    output reg [9:0] sk_y = 0
    );
    localparam NS = 4, SUBS = 3;

    // one entry per slot (arrays, index = slot number)
    reg               on  [0:NS-1];
    reg               frz [0:NS-1];
    reg signed [19:0] px  [0:NS-1];         // x 12.8 fixed point
    reg signed [19:0] py  [0:NS-1];
    reg signed [15:0] vx  [0:NS-1];         // speed per step
    reg signed [15:0] vy  [0:NS-1];
    reg        [1:0]  nb  [0:NS-1];         // bounces

    integer i;
    initial begin
        for (i = 0; i < NS; i = i + 1) begin
            on[i] = 0;
            frz[i] = 0;
            px[i] = 0;
            py[i] = 0;
            vx[i] = 0;
            vy[i] = 0;
            nb[i] = 0;
        end
    end

    // flatten the arrays into buses for arena_render (10 bits per slot)
    genvar g;
    generate for (g = 0; g < NS; g = g + 1) begin : g_out
        assign b_on[g]  = on[g];
        assign b_frz[g] = frz[g];
        assign b_x[g*10 +: 10] = px[g][17:8];
        assign b_y[g*10 +: 10] = py[g][17:8];
    end endgenerate

    // player_stats gives a 1 clock pulse, remember it until the fsm
    // gets to S_LAUNCH (it might be busy moving shots)
    reg pf1 = 0, pz1 = 0, pf2 = 0, pz2 = 0;  // shots waiting to launch
    reg tp = 0;                              // tick waiting

    // fsm, one shot step at a time:
    // IDLE -> LAUNCH (new shot waiting) or MOVE (new frame)
    // MOVE: add speed -> ASK: send position to map -> WAIT: map memory
    // needs a clock -> CHECK: look at answer, next step / next slot
    localparam S_IDLE = 0, S_LAUNCH = 1, S_MOVE = 2, S_ASK = 3, S_WAIT = 4, S_CHECK = 5;
    reg [2:0] st = S_IDLE;
    reg [1:0] k = 0;                         // slot
    reg [1:0] sub = 0;                       // step
    wire signed [11:0] ix = px[k][19:8];
    wire signed [11:0] iy = py[k][19:8];
    wire mine1 = (k < 2);                    // p1's slot
    // hit the other player
    // p1's shots can only hit p2 and the other way round
    wire in_p1 = alive1 && ix >= p1x && ix < p1x + $signed({6'd0, w1}) && iy >= p1y && iy < p1y + $signed({6'd0, h1});
    wire in_p2 = alive2 && ix >= p2x && ix < p2x + $signed({6'd0, w2}) && iy >= p2y && iy < p2y + $signed({6'd0, h2});
    wire bounced = (nb[k] != 2'd0);          // own shot only counts after a bounce (else it hits you at the gun)
    wire hit_p2 = (mine1 && in_p2) || (!mine1 && bounced && in_p2);     // p2 hit (by p1, or by own bounced shot)
    wire hit_p1 = (!mine1 && in_p1) || (mine1 && bounced && in_p1);
    // outside the play area (y 64-423, under the hud)
    wire off    = (ix < 0) || (ix >= 640) || (iy < 64) || (iy >= 424);
    // arena_core uses these to see if the shot hit a crate
    // (crates are not in the map memory, arena_core checks them itself)
    assign chk      = (st == S_CHECK) && on[k];
    assign chk_frz  = frz[k];
    assign chk_hitp = hit_p1 || hit_p2 || off;

    // start a shot, speed = aim * 2 px
    // start a shot at the gun tip, +0.5 px (8'h80) so it rounds properly
    // cos / sin are scaled by 2^14, >>> 5 gives about 2 px per step
    task launch(input [1:0] slot, input is_frz, input [9:0] mx, input [9:0] my,
                input signed [15:0] cc, input signed [15:0] ss);
        begin
            on[slot] <= 1;
            frz[slot] <= is_frz;
            px[slot] <= {2'b00, mx, 8'h80};
            py[slot] <= {2'b00, my, 8'h80};
            vx[slot] <= cc >>> 5;
            vy[slot] <= ss >>> 5;
            nb[slot] <= 0;
        end
    endtask

    always @ (posedge clk) begin
        hit_fire1 <= 0;
        hit_freeze1 <= 0;
        hit_fire2 <= 0;
        hit_freeze2 <= 0;
        self_fire1 <= 0;
        self_freeze1 <= 0;
        self_fire2 <= 0;
        self_freeze2 <= 0;
        if (shoot_fire1 == 1) begin
            pf1 <= 1;
        end
        if (shoot_freeze1 == 1) begin
            pz1 <= 1;
        end
        if (shoot_fire2 == 1) begin
            pf2 <= 1;
        end
        if (shoot_freeze2 == 1) begin
            pz2 <= 1;
        end
        if (tick == 1 && run == 1) begin
            tp <= 1;
        end
        // spark: next frame, gone after frame 7
        if (tick == 1 && run == 1 && sk_on == 1) begin
            if (sk_t == 3'd7) begin
                sk_on <= 0;
            end
            else begin
                sk_t <= sk_t + 1;
            end
        end

        if (reset == 1) begin
            for (i = 0; i < NS; i = i + 1) begin
                on[i] <= 0;
            end
            pf1 <= 0;
            pz1 <= 0;
            pf2 <= 0;
            pz2 <= 0;
            tp <= 0;
            sk_on <= 0;
            st <= S_IDLE;
        end else begin
            case (st)
            // new shots first, then moving
            S_IDLE: begin
                if (pf1 || pz1 || pf2 || pz2) begin
                    st <= S_LAUNCH;
                end else if (tp == 1) begin
                    tp <= 0;
                    k <= 0;
                    sub <= 0;
                    st <= S_MOVE;
                end
            end

            // 1 shot per clock into a free slot
            S_LAUNCH: begin
                if (pf1 || pz1) begin
                    if (on[0] == 0) begin
                        // !pf1 = it is a freeze shot (fire is done first if both waiting)
                        launch(2'd0, !pf1, mz1x, mz1y, c1, s1);
                    end else if (on[1] == 0) begin
                        launch(2'd1, !pf1, mz1x, mz1y, c1, s1);
                    end
                    if (pf1 == 1) begin
                        pf1 <= 0;
                    end else begin
                        pz1 <= 0;
                    end
                end else if (pf2 || pz2) begin
                    if (on[2] == 0) begin
                        launch(2'd2, !pf2, mz2x, mz2y, c2, s2);
                    end else if (on[3] == 0) begin
                        launch(2'd3, !pf2, mz2x, mz2y, c2, s2);
                    end
                    if (pf2 == 1) begin
                        pf2 <= 0;
                    end else begin
                        pz2 <= 0;
                    end
                end
                st <= S_IDLE;
            end

            // empty slot -> skip to next slot
            S_MOVE: begin
                if (on[k] == 1) begin
                    px[k] <= px[k] + vx[k];
                    py[k] <= py[k] + vy[k];
                    st <= S_ASK;
                end else if (k == NS - 1) begin
                    st <= S_IDLE;
                end else begin
                    k <= k + 1;
                    sub <= 0;
                end
            end

            S_ASK: begin
                col_px <= ix;
                col_py <= iy;
                st <= S_WAIT;
            end

            S_WAIT: begin
                st <= S_CHECK;               // map answer next clock
            end

            S_CHECK: begin
                if (hit_p1 || hit_p2) begin
                    on[k] <= 0;
                    // start a new spark here (a newer hit replaces an old spark)
                    sk_on <= 1;
                    sk_frz <= frz[k];
                    sk_t <= 0;
                    sk_x <= ix[9:0];
                    sk_y <= iy[9:0];
                    // p1's own shot is checked first (hit_p1 with mine1 = self)
                    if (hit_p1 == 1) begin
                        if (mine1 == 1) begin
                            self_freeze1 <= frz[k];
                            self_fire1 <= !frz[k];
                        end else if (frz[k] == 1) begin
                            hit_freeze1 <= 1;
                        end else begin
                            hit_fire1 <= 1;
                        end
                    end else begin
                        if (mine1 == 0) begin
                            self_freeze2 <= frz[k];
                            self_fire2 <= !frz[k];
                        end else if (frz[k] == 1) begin
                            hit_freeze2 <= 1;
                        end else begin
                            hit_fire2 <= 1;
                        end
                    end
                // step back first so the shot is not stuck inside the mirror
                end else if (!off && col_mir && nb[k] != 3) begin
                    // mirror: step back and bounce
                    px[k] <= px[k] - vx[k];
                    py[k] <= py[k] - vy[k];
                    if (col_mvert == 1) begin
                        vx[k] <= -vx[k];
                    end else begin
                        vy[k] <= -vy[k];
                    end
                    nb[k] <= nb[k] + 1;
                end else if (off || col_solid || col_bnd) begin
                    on[k] <= 0;
                end

                // next step or next slot
                // more steps only if the shot is still flying
                if (sub != SUBS - 1 && !(hit_p1 || hit_p2 || off || col_solid || col_bnd)) begin
                    sub <= sub + 1;
                    st <= S_MOVE;
                end else if (k == NS - 1) begin
                    st <= S_IDLE;
                end else begin
                    k <= k + 1;
                    sub <= 0;
                    st <= S_MOVE;
                end
            end

            default: begin
                st <= S_IDLE;
            end
            endcase
        end
    end

endmodule
