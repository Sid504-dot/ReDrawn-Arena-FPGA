`timescale 1ns / 1ps


module player_stats #(
    parameter MAX_HP       = 100,
    parameter FIRE_DMG     = 20,
    parameter FREEZE_DMG   = 5,
    parameter FREEZE_TICKS = 120,       // 2s
    parameter START_AMMO   = 4,
    parameter MAX_AMMO     = 9,
    parameter PICK_AMMO    = 2,         // per ammo box
    parameter COOLDOWN     = 15         // 0.25s between shots
    )(
    input clk,
    input tick,
    input run,                  // gs_run
    input spawn,
    input alive,

    input btn_fire,             // mouse left
    input btn_freeze,           // mouse right

    input hit_fire,
    input hit_freeze,
    input pickup,
    input inf_ammo,             // sw4

    output reg [6:0] hp,
    output reg [3:0] ammo_fire,
    output reg [3:0] ammo_freeze,
    output           frozen,
    output reg       ev_dead,
    output reg       shoot_fire,
    output reg       shoot_freeze
    );

    reg [7:0] frz_cnt = 0;          // freeze time left
    reg [5:0] cool = 0;             // cooldown left
    // dead = own copy of "no hp", stops hits/shots until next spawn
    reg       dead = 1;             // dead until first spawn
    reg [1:0] prev = 0;             // buttons last clock

    // start values for the output regs (fpga loads these at power up)
    initial begin
        hp = 0;
        ammo_fire = 0;
        ammo_freeze = 0;
        ev_dead = 0;
        shoot_fire = 0;
        shoot_freeze = 0;
    end

    assign frozen = (frz_cnt != 0);

    // button pressed this clock only
    // same edge trick as match_fsm, holding the button = 1 shot only
    wire [1:0] btn   = {btn_freeze, btn_fire};
    wire [1:0] press = btn & ~prev;
    // can shoot only while playing, alive, not frozen and cooldown done
    wire can_act = run && alive && !dead && !frozen && (cool == 0);

    // damage this clock
    wire       live = run && alive && !dead;
    // both shots can hit the same clock so add the damage
    wire [8:0] dmg  = (hit_fire ? FIRE_DMG : 0) + (hit_freeze ? FREEZE_DMG : 0);
    wire       hit  = live && (hit_fire || hit_freeze);

    // ammo after pickup, max MAX_AMMO
    // worked out before the always block so the box and a shot in the
    // same clock both count (+2 from box and -1 from shot)
    wire       got_pickup = pickup && live;
    wire [4:0] fire_up    = ammo_fire + PICK_AMMO;
    wire [4:0] freeze_up  = ammo_freeze + PICK_AMMO;
    wire [3:0] fire_n     = !got_pickup ? ammo_fire   : (fire_up > MAX_AMMO)   ? MAX_AMMO : fire_up[3:0];
    wire [3:0] freeze_n   = !got_pickup ? ammo_freeze : (freeze_up > MAX_AMMO) ? MAX_AMMO : freeze_up[3:0];

    // fire first if both pressed
    // getting hit this clock cancels shooting this clock
    wire go        = can_act && !hit;
    wire do_fire   = go && press[0] && (ammo_fire != 0);
    wire do_freeze = go && press[1] && !press[0] && (ammo_freeze != 0);

    always @ (posedge clk) begin
        prev <= btn;
        ev_dead <= 0;
        shoot_fire <= 0;
        shoot_freeze <= 0;

        // spawn overrides everything else
        if (spawn == 1) begin
            hp <= MAX_HP;
            ammo_fire <= START_AMMO;
            ammo_freeze <= START_AMMO;
            frz_cnt <= 0;
            cool <= 0;
            dead <= 0;
        end else begin
            // timers stop when paused
            if (run == 1 && tick == 1) begin
                if (frz_cnt != 0) begin
                    frz_cnt <= frz_cnt - 1;
                end
                if (cool != 0) begin
                    cool <= cool - 1;
                end
            end

            if (hit == 1) begin
                // >= so hp never goes below 0 (it is unsigned, would wrap round)
                if (dmg >= hp) begin
                    hp <= 0;
                    dead <= 1;
                    ev_dead <= 1;
                    frz_cnt <= 0;
                end else begin
                    hp <= hp - dmg;
                    if (hit_freeze == 1) begin
                        frz_cnt <= FREEZE_TICKS;
                    end
                end
            end

            // pickup and shot together so neither is lost
            ammo_fire   <= fire_n   - ((do_fire   && !inf_ammo) ? 4'd1 : 4'd0);
            ammo_freeze <= freeze_n - ((do_freeze && !inf_ammo) ? 4'd1 : 4'd0);
            shoot_fire   <= do_fire;
            shoot_freeze <= do_freeze;
            if (do_fire == 1 || do_freeze == 1) begin
                cool <= COOLDOWN;
            end
        end
    end

endmodule
