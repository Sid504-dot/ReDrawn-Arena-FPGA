`timescale 1ns / 1ps

module gun (
    input clk,
    input [9:0] y,
    input mode_edit,
    input table_load,                   // restart / level change / undo
    input [16*30-1:0] objs,             // object table
    input [13:0] door_open,             // {door 1, door 0} how far the panel went up
    input [19:0] spr_top,               // {spring 1, spring 0} top rows (spring_ctrl)
    input face_left,                    // from aim
    input aim_busy,                     // aim is using the map lookup
    // map lookup, shared with aim, ours while busy = 1
    output reg busy,
    output reg signed [11:0] col_px,
    output reg signed [11:0] col_py,
    input col_solid,                    // includes mirrors
    input col_bnd,
    // gun state
    output reg gun_held,
    output reg [9:0] gd_x,              // dropped gun 8 x 8 box top left
    output reg [9:0] gd_y,
    output reg gd_left,                 // dropped gun points left
    output reg [9:0] clip_l,            // held gun only drawn where clip_l <= x < clip_r
    output reg [9:0] clip_r,
    output reg gun_dropped,             // 1 clk pulses
    output reg gun_picked,
    output reg gun_err
    );
    `include "obj_slots.vh"

    initial begin
        busy = 0;
        col_px = 0;
        col_py = 0;
        gun_held = 1;
        gd_x = 0;
        gd_y = 0;
        gd_left = 0;
        clip_l = 0;
        clip_r = 10'd1023;
        gun_dropped = 0;
        gun_picked = 0;
        gun_err = 0;
    end

    // player from the object table
    wire pl_vis = objs[SLOT_PLAYER*30 + 29];
    wire [9:0] pl_x = objs[SLOT_PLAYER*30 + 19 +: 10];
    wire [9:0] pl_y = objs[SLOT_PLAYER*30 + 9 +: 10];
    wire [1:0] pl_sz = objs[SLOT_PLAYER*30 +: 2];      // 0 normal 16, 1 small 8, 2 big 32
    wire [9:0] pl_w = (pl_sz == 2'd1) ? 10'd8 : (pl_sz == 2'd2) ? 10'd32 : 10'd16;
    wire [9:0] pl_h = pl_w;                            // square
    wire [9:0] ccx = pl_x + (pl_w >> 1);               // body middle
    wire [9:0] ccy = pl_y + (pl_h >> 1);
    wire [6:0] ccol = ccx[9:3];                        // its tile column / row
    wire [5:0] crow = (ccy < 10'd64) ? 6'd0 : (ccy >= 10'd424) ? 6'd44 : (ccy - 10'd64) >> 3;

    // does the 8 x 8 box at (bx, by) hit a closed door, a spring or the scale
    reg [9:0] bx = 0;
    reg [9:0] by = 0;
    reg obj_hit;
    integer j;
    always @ (*) begin
        obj_hit = 0;
        // doors 24 px wide, height minus how far it opened
        for (j = SLOT_DOOR0; j < SLOT_DOOR0 + N_DOOR; j = j + 1) begin
            if (objs[j*30 + 29] && bx < objs[j*30 + 19 +: 10] + 10'd24 && objs[j*30 + 19 +: 10] < bx + 10'd8 &&
                by < objs[j*30 + 9 +: 10] + {2'b0, objs[j*30 + 2 +: 7], 1'b0} - {2'b0, door_open[(j - SLOT_DOOR0)*7 +: 7], 1'b0} &&
                objs[j*30 + 9 +: 10] < by + 10'd8) begin
                obj_hit = 1;
            end
        end
        // springs 64 wide, from the top now down to the base
        for (j = SLOT_SPRING0; j < SLOT_SPRING0 + 2; j = j + 1) begin
            if (objs[j*30 + 29] && bx < objs[j*30 + 19 +: 10] + 10'd64 && objs[j*30 + 19 +: 10] < bx + 10'd8 &&
                by < objs[j*30 + 9 +: 10] + 10'd96 && spr_top[(j - SLOT_SPRING0)*10 +: 10] < by + 10'd8) begin
                obj_hit = 1;
            end
        end
        // scale 40 x 28
        if (objs[SLOT_SCALE*30 + 29] && bx < objs[SLOT_SCALE*30 + 19 +: 10] + 10'd40 && objs[SLOT_SCALE*30 + 19 +: 10] < bx + 10'd8 &&
            by < objs[SLOT_SCALE*30 + 9 +: 10] + 10'd28 && objs[SLOT_SCALE*30 + 9 +: 10] < by + 10'd8) begin
            obj_hit = 1;
        end
    end

    // body touching the dropped gun
    wire touch = (pl_x < gd_x + 10'd8) && (gd_x < pl_x + pl_w) && (pl_y < gd_y + 10'd8) && (gd_y < pl_y + pl_h);

    // start at row 500, aim is done by then
    reg go_q = 0;
    wire go = (y == 10'd500) && !go_q;
    reg load_seen = 0;

    // fsm states
    localparam G_IDLE  = 0;
    localparam G_WAIT  = 1;             // wait for aim to free the lookup
    localparam G_INIT  = 2;
    localparam G_CROSS = 3;             // walk the columns crossed
    localparam G_XCHK  = 4;
    localparam G_DROP  = 5;             // try a drop spot
    localparam G_START = 6;
    localparam G_UP    = 7;
    localparam G_BELOW = 8;
    localparam G_FALL  = 9;
    localparam G_OBJ   = 10;
    localparam G_SUP   = 11;            // dropped gun still held up?
    localparam G_PICK  = 12;
    localparam G_CLIP  = 13;
    localparam G_CLL   = 14;
    localparam G_CLR   = 15;
    localparam G_DONE  = 16;
    localparam G_LK    = 17;            // 2 tile lookup, returns to ret

    reg [4:0] st = G_IDLE;
    reg [4:0] ret = G_IDLE;
    reg pv = 0;                         // pcx is valid
    reg armed = 0;                      // player left the gun since the drop
    reg [9:0] pcx = 0;                  // body middle last frame
    reg [6:0] sc = 0;                   // column being scanned
    reg [6:0] cend = 0;
    reg dir = 0;                        // 0 moving right, 1 left
    reg [6:0] db = 0;                   // boundary column it was dropped at
    reg dside = 0;                      // gun is 0 left / 1 right of it
    reg [4:0] k = 0;                    // which drop spot we are trying
    reg [9:0] x0 = 0;
    reg [5:0] r = 0;
    reg [2:0] up = 0;
    reg falling = 0;
    reg dropped_now = 0;
    reg picked_now = 0;
    // 2 tile lookup: columns la and lb on row lr, outside the level = solid
    reg signed [8:0] la = 0;
    reg signed [8:0] lb = 0;
    reg [5:0] lr = 0;
    reg [2:0] lk = 0;
    reg sol_a = 0;
    reg bnd_a = 0;
    reg sol_any = 0;
    reg bnd_any = 0;
    wire signed [8:0] xa = $signed({2'b0, x0[9:3]});
    wire signed [8:0] xb = xa + ((x0[2:0] != 3'd0) ? 9'sd1 : 9'sd0);   // box covers 1 or 2 columns

    // crates (objects, not tiles) for the 8 x 8 box at (x0, yb):
    // crate_in = a crate overlaps it, crate_below = a crate top is in the 8 px
    // under it, ct_min = the highest such top
    wire [9:0] yb = 10'd64 + {4'd0, r, 3'b0};
    reg crate_in;
    reg crate_below;
    reg [9:0] ct_min;
    reg [9:0] cxj;
    reg [9:0] cyj;
    reg [9:0] csj;
    always @ (*) begin
        crate_in = 0;
        crate_below = 0;
        ct_min = 10'h3FF;
        for (j = SLOT_BOX0; j < SLOT_BOX0 + N_BOX; j = j + 1) begin
            cxj = objs[j*30 + 19 +: 10];
            cyj = objs[j*30 + 9 +: 10];
            csj = (objs[j*30 +: 2] == 2'd1) ? 10'd8 : (objs[j*30 +: 2] == 2'd2) ? 10'd32 : 10'd16;
            if (objs[j*30 + 29] && x0 < cxj + csj && cxj < x0 + 10'd8) begin
                if (yb < cyj + csj && cyj < yb + 10'd8) begin
                    crate_in = 1;
                end
                else if (cyj < yb + 10'd16 && cyj + csj > yb + 10'd8) begin
                    crate_below = 1;
                    if (cyj < ct_min) begin
                        ct_min = cyj;
                    end
                end
            end
        end
    end

    // start a 2 tile lookup, comes back to state "back" with sol_any / bnd_any
    task look;
        input signed [8:0] a;
        input signed [8:0] b;
        input [5:0] row;
        input [4:0] back;
        begin
            la <= a;
            lb <= b;
            lr <= row;
            lk <= 0;
            ret <= back;
            st <= G_LK;
        end
    endtask

    always @ (posedge clk) begin
        go_q <= (y == 10'd500);
        gun_dropped <= 0;
        gun_picked <= 0;
        if (table_load == 1) begin
            load_seen <= 1;
        end

        case (st)
            G_IDLE: begin
                if (go == 1) begin
                    st <= G_WAIT;
                end
            end

            G_WAIT: begin
                if (aim_busy == 0) begin
                    busy <= 1;
                    dropped_now <= 0;
                    picked_now <= 0;
                    st <= G_INIT;
                end
            end

            G_INIT: begin
                if (mode_edit || !pl_vis || load_seen) begin
                    // back in the hand
                    gun_held <= 1;
                    pv <= 0;
                    armed <= 0;
                    gun_err <= 0;
                    load_seen <= 0;
                    st <= G_CLIP;
                end
                else if (gun_held && pv && pcx[9:3] != ccol) begin
                    // middle moved to another column, check every column on the way
                    dir <= (ccol < pcx[9:3]);
                    sc <= pcx[9:3];
                    cend <= ccol;
                    st <= G_CROSS;
                end
                else begin
                    st <= gun_held ? G_CLIP : G_SUP;
                end
            end

            // crossing check
            G_CROSS: begin
                sc <= dir ? sc - 7'd1 : sc + 7'd1;
                look($signed({2'b0, dir ? sc - 7'd1 : sc + 7'd1}), $signed({2'b0, dir ? sc - 7'd1 : sc + 7'd1}), crow, G_XCHK);
            end

            G_XCHK: begin
                if (bnd_any == 1) begin
                    // gun stays on the side it came from
                    db <= sc;
                    dside <= dir;
                    k <= 0;
                    st <= G_DROP;
                end
                else begin
                    st <= (sc == cend) ? G_CLIP : G_CROSS;
                end
            end

            // drop spot k: 0 = 1 px gap, 1 = touching, 2+ = k px away
            G_DROP: begin
                if (k == 5'd24) begin
                    gun_err <= 1;               // nothing works, keep it
                    st <= G_CLIP;
                end
                else begin
                    if (dside == 0) begin
                        x0 <= {db, 3'b0} - 10'd8 - ((k == 0) ? 10'd1 : (k == 1) ? 10'd0 : {5'd0, k});
                    end
                    else begin
                        x0 <= {db, 3'b0} + 10'd8 + ((k == 0) ? 10'd1 : (k == 1) ? 10'd0 : {5'd0, k});
                    end
                    r <= crow;
                    up <= 0;
                    falling <= 0;
                    st <= G_START;
                end
            end

            // is the spot at hand height free
            G_START: begin
                look(xa, xb, r, G_UP);
            end

            G_UP: begin
                if (bnd_any && up == 0) begin
                    gun_err <= 1;               // hit another boundary, stop
                    st <= G_CLIP;
                end
                else if (sol_any || bnd_any || crate_in) begin
                    // blocked: try up to 4 rows higher, else next spot
                    if (up == 3'd4 || r == 0) begin
                        k <= k + 1;
                        st <= G_DROP;
                    end
                    else begin
                        up <= up + 1;
                        r <= r - 1;
                        st <= G_START;
                    end
                end
                else begin
                    st <= G_BELOW;
                end
            end

            // falling: what is under it
            G_BELOW: begin
                if (r == 6'd44) begin
                    // reached the bottom row
                    if (falling == 1) begin
                        gun_err <= 1;
                        st <= G_PICK;
                    end
                    else begin
                        k <= k + 1;
                        st <= G_DROP;
                    end
                end
                else begin
                    look(xa, xb, r + 6'd1, G_FALL);
                end
            end

            G_FALL: begin
                if (sol_any == 1) begin
                    // lands on ground / mirror
                    bx <= x0;
                    by <= 10'd64 + {r, 3'b0};
                    st <= G_OBJ;
                end
                else if (crate_below == 1) begin
                    // lands on a crate, pixel exact
                    bx <= x0;
                    by <= ct_min - 10'd8;
                    st <= G_OBJ;
                end
                else if (bnd_any == 1) begin
                    if (falling == 1) begin
                        gun_err <= 1;
                        st <= G_PICK;
                    end
                    else begin
                        k <= k + 1;
                        st <= G_DROP;
                    end
                end
                else begin
                    r <= r + 1;                 // air or water, keep falling
                    st <= G_BELOW;
                end
            end

            G_OBJ: begin
                if (falling == 1) begin
                    gd_y <= by;                 // dropped gun settled again
                    st <= G_PICK;
                end
                else if (obj_hit == 1) begin
                    k <= k + 1;
                    st <= G_DROP;
                end
                else begin
                    gd_x <= bx;
                    gd_y <= by;
                    gd_left <= face_left;
                    gun_held <= 0;
                    armed <= 0;
                    dropped_now <= 1;
                    st <= G_DONE;
                end
            end

            // dropped gun: run the fall again from where it is
            G_SUP: begin
                x0 <= gd_x;
                r <= (gd_y - 10'd64) >> 3;
                falling <= 1;
                st <= G_BELOW;
            end

            // pick up
            G_PICK: begin
                if (touch == 0) begin
                    armed <= 1;
                end
                else if (armed && (dside ? (ccx >= {db, 3'b0} + 10'd8) : (ccx < {db, 3'b0}))) begin
                    gun_held <= 1;
                    armed <= 0;
                    picked_now <= 1;
                end
                st <= G_CLIP;
            end

            // held gun clip: nearest boundary up to 3 columns each side
            G_CLIP: begin
                clip_l <= 10'd0;
                clip_r <= 10'd1023;
                if (!(gun_held || picked_now)) begin
                    st <= G_DONE;
                end
                else begin
                    sc <= ccol;
                    up <= 0;
                    st <= G_CLL;
                end
            end

            // left side, up = columns done
            G_CLL: begin
                if (up != 0 && bnd_any) begin
                    clip_l <= {sc, 3'b0} + 10'd8;
                    sc <= ccol;
                    up <= 0;
                    st <= G_CLR;
                end
                else if (up == 3'd3 || sc == 0) begin
                    sc <= ccol;
                    up <= 0;
                    st <= G_CLR;
                end
                else begin
                    up <= up + 1;
                    sc <= sc - 1;
                    look($signed({2'b0, sc - 7'd1}), $signed({2'b0, sc - 7'd1}), crow, G_CLL);
                end
            end

            // right side
            G_CLR: begin
                if (up != 0 && bnd_any) begin
                    clip_r <= {sc, 3'b0};
                    st <= G_DONE;
                end
                else if (up == 3'd3 || sc == 7'd79) begin
                    st <= G_DONE;
                end
                else begin
                    up <= up + 1;
                    sc <= sc + 1;
                    look($signed({2'b0, sc + 7'd1}), $signed({2'b0, sc + 7'd1}), crow, G_CLR);
                end
            end

            G_DONE: begin
                pv <= 1;
                pcx <= ccx;
                busy <= 0;
                gun_picked <= picked_now;
                gun_dropped <= dropped_now;
                st <= G_IDLE;
            end

            // 2 tile lookup, answer 2 clk after the address
            G_LK: begin
                lk <= lk + 1;
                case (lk)
                    3'd0: begin
                        col_px <= {la[8], la[8], la, 3'b0};
                        col_py <= 12'sd64 + $signed({3'b0, lr, 3'b0});
                    end
                    3'd2: begin
                        sol_a <= col_solid || la < 0 || la > 9'sd79;
                        bnd_a <= col_bnd;
                        col_px <= {lb[8], lb[8], lb, 3'b0};
                    end
                    3'd4: begin
                        sol_any <= sol_a || col_solid || lb < 0 || lb > 9'sd79;
                        bnd_any <= bnd_a || col_bnd;
                        st <= ret;
                    end
                    default: begin
                    end
                endcase
            end

            default: begin
                st <= G_IDLE;
            end
        endcase
    end

endmodule
