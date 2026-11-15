`timescale 1ns / 1ps


module match_fsm #(
    parameter TICKS_PER_SEC = 60,
    parameter COUNT_TICKS   = 60,       // each of 3 2 1
    parameter GO_TICKS      = 30,
    parameter RESPAWN_TICKS = 120       // 2s
    )(
    input clk,
    input rst,
    input tick,                         // 60 Hz
    input [6:0] keys1,
    input [6:0] keys2,
    input ev_dead1,
    input ev_dead2,
    input [8:0] match_sec,
    input start,                        // from main menu

    output reg       gs_run,            // 1 only in PLAY
    output reg       gs_reset,          // new match
    output reg       spawn1,
    output reg       spawn2,
    output reg       alive1,
    output reg       alive2,
    output reg [2:0] ui_screen,         // 0 menu, 1 count, 2 play, 3 pause, 4 over, 5 map select
    output reg [1:0] ui_count,          // 3 2 1 0(GO)
    output reg       ui_sel,            // pause: 0 resume 1 quit
    output reg [1:0] pause_owner,       // 1 or 2
    output reg [8:0] time_left,
    output reg [4:0] kills1,
    output reg [4:0] kills2,
    output reg [1:0] winner,            // 0 draw, 1 p1, 2 p2
    output reg       by_quit,
    output reg       ui_map = 0         // 0 Bridges 1 Towers
    );

    localparam MENU = 0, COUNT = 1, PLAY = 2, PAUSE = 3, OVER = 4, MAPSEL = 5;
    localparam K_A = 0, K_D = 1, K_ESC = 5, K_ENT = 6;

    // key pressed this clock only (not held)
    reg [6:0] prev1 = 0, prev2 = 0;
    always @ (posedge clk) begin
        prev1 <= keys1;
        prev2 <= keys2;
    end
    // keys come in as held (1 while down), so compare with last clock
    // 1 now and 0 before = just pressed, so a held key only counts once
    wire [6:0] p1 = keys1 & ~prev1;
    wire [6:0] p2 = keys2 & ~prev2;
    wire [6:0] pa = p1 | p2;                          // any player
    // po = presses of whoever paused, so the other player cant unpause
    wire [6:0] po = (pause_owner == 1) ? p1 : p2;     // the one who paused

    // t_cnt counts ticks (frames) inside a screen, 60 ticks = 1 s
    // used for the countdown steps and for the 1 s match timer
    reg [7:0] t_cnt;                    // ticks counter
    reg [7:0] r_cnt1, r_cnt2;           // respawn counters

    // everything back to start
    // task = just a shortcut so the same lines are not written twice
    // (used from MAPSEL and from OVER rematch). gs_reset tells everyone
    // else (bullets, pickups, crates) to clear, spawn1/2 ask spawn_picker
    // for new spots
    task new_match;
        begin
            ui_screen <= COUNT;
            ui_count <= 3;
            t_cnt <= 0;
            gs_reset <= 1;
            spawn1 <= 1;
            spawn2 <= 1;
            alive1 <= 1;
            alive2 <= 1;
            r_cnt1 <= 0;
            r_cnt2 <= 0;
            kills1 <= 0;
            kills2 <= 0;
            time_left <= match_sec;
            winner <= 0;
            by_quit <= 0;
        end
    endtask

    always @ (posedge clk) begin
        // pulses, 1 for one clock only, so default them to 0 every clock
        gs_reset <= 0;
        spawn1 <= 0;
        spawn2 <= 0;

        if (rst == 1) begin
            ui_screen <= MENU;
            ui_count <= 3;
            ui_sel <= 0;
            pause_owner <= 1;
            t_cnt <= 0;
            r_cnt1 <= 0;
            r_cnt2 <= 0;
            alive1 <= 1;
            alive2 <= 1;
            kills1 <= 0;
            kills2 <= 0;
            time_left <= match_sec;
            winner <= 0;
            by_quit <= 0;
        end

        // MENU = waiting, game_top sends start when 2 PLAYERS is picked
        else if (ui_screen == MENU) begin
            if (start == 1) begin
                ui_screen <= MAPSEL;
            end
        end

        // A / D change map, enter start, esc back
        else if (ui_screen == MAPSEL) begin
            if (pa[K_A] == 1 || pa[K_D] == 1) begin
                ui_map <= ~ui_map;
            end
            if (pa[K_ENT] == 1) begin
                new_match;
            end else if (pa[K_ESC] == 1) begin
                ui_screen <= MENU;
            end
        end

        // 3 2 1 GO
        else if (ui_screen == COUNT) begin
            if (tick == 1) begin
                // ui_count 3 -> 2 -> 1 each COUNT_TICKS, then 0 shows GO for GO_TICKS
                if (ui_count != 0 && t_cnt == COUNT_TICKS - 1) begin
                    t_cnt <= 0;
                    ui_count <= ui_count - 1;
                end else if (ui_count == 0 && t_cnt == GO_TICKS - 1) begin
                    t_cnt <= 0;
                    ui_screen <= PLAY;
                end else begin
                    t_cnt <= t_cnt + 1;
                end
            end
        end

        else if (ui_screen == PLAY) begin
            // someone died, other one gets the kill
            // ev_dead comes from player_stats when hp hits 0
            // alive check so one death is not counted twice
            if (ev_dead1 == 1 && alive1 == 1) begin
                alive1 <= 0;
                r_cnt1 <= 0;
                kills2 <= kills2 + 1;
            end
            if (ev_dead2 == 1 && alive2 == 1) begin
                alive2 <= 0;
                r_cnt2 <= 0;
                kills1 <= kills1 + 1;
            end

            if (tick == 1) begin
                // respawn after 2s
                if (alive1 == 0) begin
                    if (r_cnt1 == RESPAWN_TICKS - 1) begin
                        alive1 <= 1;
                        spawn1 <= 1;
                    end else begin
                        r_cnt1 <= r_cnt1 + 1;
                    end
                end
                if (alive2 == 0) begin
                    if (r_cnt2 == RESPAWN_TICKS - 1) begin
                        alive2 <= 1;
                        spawn2 <= 1;
                    end else begin
                        r_cnt2 <= r_cnt2 + 1;
                    end
                end

                // match timer
                // 1 s passed -> time_left - 1, when it was 1 the match is over
                if (t_cnt == TICKS_PER_SEC - 1) begin
                    t_cnt <= 0;
                    time_left <= time_left - 1;
                    if (time_left == 1) begin
                        ui_screen <= OVER;
                        if (kills1 > kills2) begin
                            winner <= 1;
                        end else if (kills2 > kills1) begin
                            winner <= 2;
                        end else begin
                            winner <= 0;
                        end
                    end
                end else begin
                    t_cnt <= t_cnt + 1;
                end
            end

            // pause, p1 first if both
            // this is after the timer code so pause wins if both happen same clock
            if (p1[K_ESC] == 1) begin
                ui_screen <= PAUSE;
                pause_owner <= 1;
                ui_sel <= 0;
            end else if (p2[K_ESC] == 1) begin
                ui_screen <= PAUSE;
                pause_owner <= 2;
                ui_sel <= 0;
            end
        end

        // only the one who paused can use this
        else if (ui_screen == PAUSE) begin
            if (po[K_A] == 1) begin
                ui_sel <= 0;
            end
            if (po[K_D] == 1) begin
                ui_sel <= 1;
            end
            if (po[K_ESC] == 1) begin
                ui_screen <= PLAY;
            end else if (po[K_ENT] == 1) begin
                if (ui_sel == 0) begin
                    ui_screen <= PLAY;
                end else begin
                    ui_screen <= OVER;     // quitter loses
                    by_quit <= 1;
                    if (pause_owner == 1) begin
                        winner <= 2;
                    end else begin
                        winner <= 1;
                    end
                end
            end
        end

        // enter rematch, esc map select
        else if (ui_screen == OVER) begin
            if (pa[K_ENT] == 1) begin
                new_match;
            end else if (pa[K_ESC] == 1) begin
                ui_screen <= MAPSEL;
            end
        end

        // unused state numbers (6, 7) go back to menu, safety
        else begin
            ui_screen <= MENU;
        end
    end

    always @ (*) begin
        // not a register, just follows the screen
        gs_run = (ui_screen == PLAY);
    end

endmodule
