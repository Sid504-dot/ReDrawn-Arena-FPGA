`timescale 1ns / 1ps

module game_top #(
    parameter SIM_TICK_DIV = 0          // only for sim, 0 on board
    )(
    input clk,                  // 100MHz
    input btnC,                 // reset
    inout PS2Clk,               // usb mouse / keyboard
    inout PS2Data,
    inout ja1,                  // main = keyboard 1 in, sender = tx out
    input rx_keyboard2,         // JA2
    input rx_mouse2,            // JA3
    output Hsync,
    output Vsync,
    output [3:0] vgaRed,
    output [3:0] vgaGreen,
    output [3:0] vgaBlue,
    output [15:0] led,
    input [15:0] sw,
    input btnU,
    output [6:0] seg,
    output dp,
    output [3:0] an,
    output oled_cs,
    output oled_sdin,
    output oled_sclk,
    output oled_dc,
    output oled_resn,
    output oled_vccen,
    output oled_pmoden
    );

    // reset
    // btnC through 2 flip flops so reset is clean and in step with clk
    // starts at 11 so everything is in reset right at power up
    reg [1:0] rst_sync = 2'b11;
    always @ (posedge clk) begin
        rst_sync <= {rst_sync[0], btnC};
    end
    wire rst = rst_sync[1];

    // switches and btnU, 2 flip flops each
    // switch can change at any time, 2 flip flops stop half changed values
    reg [15:0] sw_q1 = 0;
    reg [15:0] sw_q = 0;
    reg [1:0] bu_q = 0;
    always @ (posedge clk) begin
        sw_q1 <= sw;
        sw_q <= sw_q1;
        bu_q <= {bu_q[0], btnU};
    end

    // vga
    wire video_on;
    wire [9:0] x;
    wire [9:0] y;
    // 640 x 480 at 60 Hz, x / y = pixel being drawn now
    vga_sync u_vga (.clk(clk), .reset(rst), .hsync(Hsync), .vsync(Vsync),
        .video_on(video_on), .p_tick(), .x(x), .y(y));

    // frame counter for blinking
    // +1 every frame (start of vblank), frame[5] blinks PRESS ENTER
    reg [7:0] frame = 0;
    reg vb_q = 0;
    always @ (posedge clk) begin
        vb_q <= (y >= 10'd480);
        if ((y >= 10'd480) && !vb_q) begin
            frame <= frame + 1;
        end
    end

    // mouse 1 (MouseCtl), after reset set max 639 x 479 and start in middle
    // MouseCtl needs the limits and start position written in after reset
    // one value per clock: m_value + the matching set pulse
    reg [11:0] m_value = 0;
    reg m_setx = 0;
    reg m_sety = 0;
    reg m_setmax_x = 0;
    reg m_setmax_y = 0;
    wire m_rst = rst || (sw_q[15:14] == 2'b01);    // off on keyboard sender
    reg [2:0] m_setup = 0;
    always @ (posedge clk) begin
        m_setx <= 0;
        m_sety <= 0;
        m_setmax_x <= 0;
        m_setmax_y <= 0;
        if (m_rst == 1) begin
            m_setup <= 0;
        end
        else begin
            case (m_setup)
                3'd0: begin
                    m_value <= 12'd639;
                    m_setmax_x <= 1;
                    m_setup <= 3'd1;
                end
                3'd1: begin
                    m_value <= 12'd479;
                    m_setmax_y <= 1;
                    m_setup <= 3'd2;
                end
                3'd2: begin
                    m_value <= 12'd320;
                    m_setx <= 1;
                    m_setup <= 3'd3;
                end
                3'd3: begin
                    m_value <= 12'd240;
                    m_sety <= 1;
                    m_setup <= 3'd4;
                end
                default: begin
                end
            endcase
        end
    end

    wire [11:0] m1xpos;
    wire [11:0] m1ypos;
    wire m1l;
    wire m1r;
    MouseCtl u_mouse1 (
        .clk(clk), .rst(m_rst),
        .xpos(m1xpos), .ypos(m1ypos), .zpos(), .left(m1l), .middle(), .right(m1r), .new_event(),
        .value(m_value), .setx(m_setx), .sety(m_sety), .setmax_x(m_setmax_x), .setmax_y(m_setmax_y),
        .ps2_clk(PS2Clk), .ps2_data(PS2Data));
    wire [9:0] m1x = m1xpos[9:0];
    wire [9:0] m1y = m1ypos[9:0];

    // link receivers
    wire [6:0] keys1;
    wire [6:0] keys2;
    wire ok_k1;
    wire ok_k2;
    wire ok_m2;
    wire gd_k1;                 // good / bad packet, for oled counters
    wire bd_k1;
    wire gd_k2;
    wire bd_k2;
    wire gd_m2;
    wire bd_m2;
    // link_rx: uart packets -> keys held, link_ok = packets arriving
    // pkt_good / pkt_bad = 1 clock per packet, counted on the oled
    wire rx_keyboard1 = ja1;    // main board reads keyboard 1 on JA1 (declared before use)
    link_rx u_link_k1 (.clk(clk), .rst(rst), .rx(rx_keyboard1), .keys_rx(keys1), .link_ok(ok_k1),
        .pkt_good(gd_k1), .pkt_bad(bd_k1));
    link_rx u_link_k2 (.clk(clk), .rst(rst), .rx(rx_keyboard2), .keys_rx(keys2), .link_ok(ok_k2),
        .pkt_good(gd_k2), .pkt_bad(bd_k2));
    wire [20:0] mouse2;         // {x, y, left, right}
    link_rx_mouse u_link_m2 (.clk(clk), .rst(rst), .rx(rx_mouse2), .mouse_rx(mouse2), .link_ok(ok_m2),
        .pkt_good(gd_m2), .pkt_bad(bd_m2));

    // switch settings
    // sw0 oled page, sw3-2 match length, sw4 inf ammo, sw6 7seg time / score
    wire oled_page = sw_q[0];
    reg [8:0] match_sec;
    always @ (*) begin
        case (sw_q[3:2])
            2'b00: match_sec = 9'd120;
            2'b01: match_sec = 9'd60;
            2'b10: match_sec = 9'd180;
            default: match_sec = 9'd300;
        endcase
    end
    wire inf_ammo = sw_q[4];
    wire seg_score = sw_q[6];

    // board role
    // sender_roles makes the tx for a sender board and its 7seg / leds
    wire [1:0] role = sw_q[15:14];
    wire is_main = (role == 2'b00) || (role == 2'b11);     // 11 also main
    wire tx_s;
    wire [31:0] s_text;
    wire [3:0] s_dots;
    wire [15:0] s_led;
    // keyboard sender reads the usb pins through these (only reads them)
    wire kb_c = PS2Clk;
    wire kb_d = PS2Data;
    sender_roles u_send (.clk(clk), .rst(rst), .role(role), .sw(sw_q),
        .kb_ps2_clk(kb_c), .kb_ps2_data(kb_d),
        .xpos(m1xpos), .ypos(m1ypos), .m_left(m1l), .m_right(m1r),
        .tx(tx_s), .seg_text(s_text), .seg_dots(s_dots), .led(s_led));

    // sender drives JA1, main board only reads
    // inout so one bitstream works for all: z = not driving, just listening
    assign ja1 = (is_main == 1) ? 1'bz : tx_s;

    // mouse 2 packet = {x 10 bits, y 9 bits, left, right}
    wire [9:0] m2x = mouse2[20:11];
    wire [9:0] m2y = {1'b0, mouse2[10:2]};
    wire m2l = mouse2[1];
    wire m2r = mouse2[0];

    // which game is on screen
    // mode = which game is on screen
    localparam [1:0] M_MAIN  = 2'd0;
    localparam [1:0] M_SOLO  = 2'd1;
    localparam [1:0] M_ARENA = 2'd2;
    reg [1:0] mode = M_MAIN;
    reg sel = 0;                // 0 = 1 PLAYER, 1 = 2 PLAYERS
    reg [6:0] kp1 = 0;          // keys last clk
    reg [6:0] kp2 = 0;
    always @ (posedge clk) begin
        kp1 <= keys1;
        kp2 <= keys2;
    end
    // pressed this clock only, so holding Enter doesnt keep starting
    wire [6:0] pr = (keys1 & ~kp1) | (keys2 & ~kp2);   // pressed on either keyboard
    wire [6:0] pr1 = keys1 & ~kp1;                     // pressed on keyboard 1
    wire [2:0] ui_screen;
    // arena_start = 1 clock pulse, tells match_fsm to go to the map screen
    reg arena_start = 0;
    always @ (posedge clk) begin
        arena_start <= 0;
        if (rst == 1) begin
            mode <= M_MAIN;
            sel <= 0;
        end
        else begin
            case (mode)
                M_MAIN: begin
                    if (pr[0] == 1) begin       // A
                        sel <= 0;
                    end
                    if (pr[1] == 1) begin       // D
                        sel <= 1;
                    end
                    if (pr[6] == 1) begin       // Enter
                        if (sel == 1) begin
                            mode <= M_ARENA;
                            arena_start <= 1;
                        end
                        else begin
                            mode <= M_SOLO;
                        end
                    end
                end
                M_SOLO: begin
                    if (pr1[5] == 1) begin      // Esc
                        mode <= M_MAIN;
                    end
                end
                M_ARENA: begin
                    // arena back at its menu
                    // arena_start check: the clock we start, ui_screen is still 0
                    if (arena_start == 0 && ui_screen == 3'd0) begin
                        mode <= M_MAIN;
                    end
                end
                default: begin
                    mode <= M_MAIN;
                end
            endcase
        end
    end

    // keys only go to the arena when its on
    // so playing one game doesnt move things in the other
    wire [6:0] a_keys1 = (mode == M_ARENA) ? keys1 : 7'd0;
    wire [6:0] a_keys2 = (mode == M_ARENA) ? keys2 : 7'd0;

    // main menu
    wire menu_on;
    wire [11:0] menu_rgb;
    menu_screen u_menu (.clk(clk), .x(x), .y(y), .show(mode == M_MAIN), .mode_sel(sel),
        .ok1(ok_k1), .ok2(ok_k2 && ok_m2), .frame(frame), .on(menu_on), .rgb(menu_rgb));

    // shared gun angle unit, port a redrawn, port b arena
    wire an_a_req;
    wire an_a_zero;
    wire an_a_ovr_en;
    wire an_a_ack;
    wire an_b_req;
    wire an_b_ack;
    wire signed [15:0] an_a_vx;
    wire signed [15:0] an_a_vy;
    wire signed [15:0] an_b_vx;
    wire signed [15:0] an_b_vy;
    wire signed [15:0] an_s;
    wire signed [15:0] an_c;
    wire [7:0] an_a_ovr;
    wire [15:0] an_cz;
    // cordic angle + sin / cos, one copy shared by both games (saves luts)
    // port a = redrawn aim, port b = arena guns, they take turns
    angle_unit u_angle (.clk(clk),
        .a_req(an_a_req), .a_vx(an_a_vx), .a_vy(an_a_vy), .a_zero(an_a_zero), .a_ovr_en(an_a_ovr_en),
        .a_ovr_ang(an_a_ovr), .a_ack(an_a_ack),
        .b_req(an_b_req), .b_vx(an_b_vx), .b_vy(an_b_vy), .b_ack(an_b_ack),
        .cz(an_cz), .s(an_s), .c(an_c));

    // game 1, redrawn single player
    // also draws arena terrain + pads and runs the arena crates
    // redrawn_core also draws the arena terrain (arena map = its level
    // slot 8) and pads, and runs the 2 arena crates on its crate engine
    wire [11:0] solo_rgb;
    wire [6:0] terrain_px;
    wire [19:0] ar_spx0;
    wire [19:0] ar_spy0;
    wire [5:0] ar_spf;
    wire [1:0] ar_map;
    wire [1:0] ar_sza;
    wire [1:0] ar_szb;
    wire ar_ctick;
    wire ar_lda;
    wire ar_ldb;
    wire ar_push;
    wire ar_push_r;
    wire ar_push_id;
    wire signed [11:0] ar_ax;
    wire signed [11:0] ar_ay;
    wire signed [11:0] ar_bx;
    wire signed [11:0] ar_by;
    wire [4:0] ar_p1w;          // arena players' hitbox sizes (crate engine)
    wire [4:0] ar_p1h;
    wire [4:0] ar_p2w;
    wire [4:0] ar_p2h;
    wire signed [11:0] ar_p1x;
    wire signed [11:0] ar_p1y;
    wire signed [11:0] ar_p2x;
    wire signed [11:0] ar_p2y;
    wire signed [11:0] ar_cax;
    wire signed [11:0] ar_cay;
    wire signed [11:0] ar_cbx;
    wire signed [11:0] ar_cby;
    wire pe_tick;
    wire pe_run1;
    wire pe_run2;
    wire [2:0] pe_k1;
    wire [2:0] pe_k2;
    wire pe_ld1;
    wire pe_ld2;
    wire signed [11:0] pe_sx;
    wire signed [11:0] pe_sy;
    wire pe_ln1;
    wire pe_ln2;
    wire pe_rq1;
    wire pe_rq2;
    wire [1:0] pe_rqs1;
    wire [1:0] pe_rqs2;
    wire pe_qs;
    wire pe_qw;
    wire signed [11:0] pe_qx;
    wire signed [11:0] pe_qy;
    wire signed [11:0] pe_1x;
    wire signed [11:0] pe_1y;
    wire signed [11:0] pe_2x;
    wire signed [11:0] pe_2y;
    wire [1:0] pe_1s;
    wire [1:0] pe_2s;
    wire pe_g1;
    wire pe_g2;
    // redraw effect shared with the arena (crate resize animation)
    wire ar_rd_start;
    wire [9:0] ar_rd_cx;
    wire [9:0] ar_rd_cy;
    wire [6:0] ar_rd_rad;
    wire rd_busy;
    wire rd_swap;
    wire [3:0] rd_idx;
    redrawn_core u_solo (.clk(clk), .btnC(rst), .x(x), .y(y), .video_on(video_on),
        .active(mode == M_SOLO), .mx(m1x), .my(m1y), .mleft(m1l), .mright(m1r),
        .key_l(keys1[0]), .key_r(keys1[1]), .key_jump(keys1[2]), .key_ent(keys1[6]), .key_rst(keys1[4]),
        .arena_view(mode == M_ARENA), .terrain_out(terrain_px), .ar_spx0(ar_spx0), .ar_spy0(ar_spy0), .ar_spf(ar_spf),
        .ar_map(ar_map), .ar_tick(ar_ctick), .ar_load_a(ar_lda), .ar_load_b(ar_ldb),
        .ar_ax(ar_ax), .ar_ay(ar_ay), .ar_bx(ar_bx), .ar_by(ar_by), .ar_sza(ar_sza), .ar_szb(ar_szb),
        .ar_push(ar_push), .ar_push_r(ar_push_r), .ar_push_id(ar_push_id),
        .ar_p1w(ar_p1w), .ar_p1h(ar_p1h), .ar_p2w(ar_p2w), .ar_p2h(ar_p2h),
        .ar_p1x(ar_p1x), .ar_p1y(ar_p1y), .ar_p2x(ar_p2x), .ar_p2y(ar_p2y),
        .ar_cax(ar_cax), .ar_cay(ar_cay), .ar_cbx(ar_cbx), .ar_cby(ar_cby),
        .ar_etick(pe_tick), .ar_run1(pe_run1), .ar_run2(pe_run2), .ar_k1(pe_k1), .ar_k2(pe_k2),
        .ar_ld1(pe_ld1), .ar_ld2(pe_ld2), .ar_sx(pe_sx), .ar_sy(pe_sy), .ar_ln1(pe_ln1), .ar_ln2(pe_ln2),
        .ar_rq1(pe_rq1), .ar_rq2(pe_rq2), .ar_rqs1(pe_rqs1), .ar_rqs2(pe_rqs2), .ar_qs(pe_qs), .ar_qw(pe_qw),
        .ar_qx(pe_qx), .ar_qy(pe_qy), .ar_e1x(pe_1x), .ar_e1y(pe_1y), .ar_e2x(pe_2x), .ar_e2y(pe_2y),
        .ar_e1s(pe_1s), .ar_e2s(pe_2s), .ar_eg1(pe_g1), .ar_eg2(pe_g2),
        .sw(12'd0), .rgb(solo_rgb),
        .ang_req(an_a_req), .ang_vx(an_a_vx), .ang_vy(an_a_vy), .ang_zero(an_a_zero), .ang_ovr_en(an_a_ovr_en), .ang_ovr(an_a_ovr),
        .ang_ack(an_a_ack), .ang_cz(an_cz), .ang_s(an_s), .ang_c(an_c),
        .ar_rd_start(ar_rd_start), .ar_rd_cx(ar_rd_cx), .ar_rd_cy(ar_rd_cy), .ar_rd_rad(ar_rd_rad),
        .rd_busy(rd_busy), .rd_swap(rd_swap), .rd_idx(rd_idx));

    // game 2, arena
    wire [11:0] arena_rgb;
    wire [8:0] time_left;
    wire [4:0] kills1;
    wire [4:0] kills2;
    wire [1:0] winner;
    wire [6:0] hp1;
    wire [6:0] hp2;
    wire [3:0] af1;
    wire [3:0] az1;
    wire [3:0] af2;
    wire [3:0] az2;
    wire alive1;
    wire alive2;
    wire signed [11:0] p1x;
    wire signed [11:0] p1y;
    wire signed [11:0] p2x;
    wire signed [11:0] p2y;
    arena_core #(.SIM_TICK_DIV(SIM_TICK_DIV)) u_arena (
        .clk(clk), .rst(rst), .x(x), .y(y), .video_on(video_on), .terrain_in(terrain_px), .start(arena_start),
        .keys1(a_keys1), .keys2(a_keys2),
        .m1x(m1x), .m1y(m1y), .m2x(m2x), .m2y(m2y),
        .m1l(m1l && mode == M_ARENA), .m1r(m1r && mode == M_ARENA),
        .m2l(m2l && mode == M_ARENA), .m2r(m2r && mode == M_ARENA),
        .match_sec(match_sec), .inf_ammo(inf_ammo), .map(ar_map),
        .cr_tick(ar_ctick), .cr_load_a(ar_lda), .cr_load_b(ar_ldb),
        .cr_ax(ar_ax), .cr_ay(ar_ay), .cr_bx(ar_bx), .cr_by(ar_by), .sz_a(ar_sza), .sz_b(ar_szb),
        .cr_push(ar_push), .cr_push_r(ar_push_r), .cr_push_id(ar_push_id),
        .cr_p1w(ar_p1w), .cr_p1h(ar_p1h), .cr_p2w(ar_p2w), .cr_p2h(ar_p2h),
        .cr_p1x(ar_p1x), .cr_p1y(ar_p1y), .cr_p2x(ar_p2x), .cr_p2y(ar_p2y),
        .ca_x(ar_cax), .ca_y(ar_cay), .cb_x(ar_cbx), .cb_y(ar_cby),
        .e_tick(pe_tick), .e_run1(pe_run1), .e_run2(pe_run2), .e_k1(pe_k1), .e_k2(pe_k2),
        .e_ld1(pe_ld1), .e_ld2(pe_ld2), .e_sx(pe_sx), .e_sy(pe_sy), .e_ln1(pe_ln1), .e_ln2(pe_ln2),
        .e_rq1(pe_rq1), .e_rq2(pe_rq2), .e_rqs1(pe_rqs1), .e_rqs2(pe_rqs2), .e_qs(pe_qs), .e_qw(pe_qw),
        .e_qx(pe_qx), .e_qy(pe_qy), .e1x(pe_1x), .e1y(pe_1y), .e2x(pe_2x), .e2y(pe_2y),
        .e1s(pe_1s), .e2s(pe_2s), .eg1(pe_g1), .eg2(pe_g2),
        .rgb(arena_rgb), .sp_x0(ar_spx0), .sp_y0(ar_spy0), .sp_frame(ar_spf),
        .ui_screen(ui_screen), .time_left(time_left), .kills1(kills1), .kills2(kills2), .winner(winner),
        .hp1(hp1), .hp2(hp2), .af1(af1), .az1(az1), .af2(af2), .az2(az2),
        .alive1(alive1), .alive2(alive2), .p1x(p1x), .p1y(p1y), .p2x(p2x), .p2y(p2y),
        .ang_req(an_b_req), .ang_vx(an_b_vx), .ang_vy(an_b_vy), .ang_ack(an_b_ack), .ang_cz(an_cz),
        .ang_s(an_s), .ang_c(an_c),
        .rd_start(ar_rd_start), .rd_cx(ar_rd_cx), .rd_cy(ar_rd_cy), .rd_rad(ar_rd_rad),
        .rd_busy(rd_busy), .rd_swap(rd_swap), .rd_idx(rd_idx));

    // vga out, all 3 have same delay
    // all 3 pictures have the same delay so they line up with hsync / vsync
    reg [11:0] rgb;
    always @ (*) begin
        case (mode)
            M_MAIN: rgb = menu_rgb;
            M_SOLO: rgb = solo_rgb;
            default: rgb = arena_rgb;
        endcase
    end
    assign vgaRed = rgb[11:8];
    assign vgaGreen = rgb[7:4];
    assign vgaBlue = rgb[3:0];

    // leds: 15-13 links ok, 12-10 screen, 9-5 p1 hp, 4-0 p2 hp
    // sender boards show their own leds (s_led)
    function [4:0] hpbar;
        input [6:0] h;
        begin
            if (h > 80)
                hpbar = 5'b11111;
            else if (h > 60)
                hpbar = 5'b01111;
            else if (h > 40)
                hpbar = 5'b00111;
            else if (h > 20)
                hpbar = 5'b00011;
            else if (h > 0)
                hpbar = 5'b00001;
            else
                hpbar = 5'b00000;
        end
    endfunction
    assign led = (is_main == 1) ? {ok_k1, ok_k2, ok_m2, ui_screen, hpbar(hp1), hpbar(hp2)} : s_led;

    // 7seg, sw6 = 0 time M.SS, sw6 = 1 score k1.k2
    // menu PLAY, 1 PLAYER 1P, map screen SEL, end P1 / P2 / tIE
    wire [2:0] t_min = (time_left >= 300) ? 3'd5 : (time_left >= 240) ? 3'd4 : (time_left >= 180) ? 3'd3 :
                       (time_left >= 120) ? 3'd2 : (time_left >= 60)  ? 3'd1 : 3'd0;
    wire [8:0] t_sec = time_left - t_min * 9'd60;

    // tens and units, n < 60
    function [7:0] tens_units;
        input [5:0] n;
        begin
            if (n >= 50)
                tens_units = {4'd5, n - 6'd50};
            else if (n >= 40)
                tens_units = {4'd4, n - 6'd40};
            else if (n >= 30)
                tens_units = {4'd3, n - 6'd30};
            else if (n >= 20)
                tens_units = {4'd2, n - 6'd20};
            else if (n >= 10)
                tens_units = {4'd1, n - 6'd10};
            else
                tens_units = {4'd0, n[3:0]};
        end
    endfunction

    wire [7:0] ts = tens_units(t_sec[5:0]);
    wire [7:0] k1d = tens_units({1'b0, kills1});
    wire [7:0] k2d = tens_units({1'b0, kills2});
    wire [3:0] t_s10 = ts[7:4];
    wire [3:0] t_s1 = ts[3:0];
    wire [3:0] k1_10 = k1d[7:4];
    wire [3:0] k1_1 = k1d[3:0];
    wire [3:0] k2_10 = k2d[7:4];
    wire [3:0] k2_1 = k2d[3:0];

    reg [31:0] seg_text;
    reg [3:0] seg_dots;
    always @ (*) begin
        seg_dots = 4'b0000;
        if (mode == M_MAIN) begin
            seg_text = "PLAY";
        end
        else if (mode == M_SOLO) begin
            seg_text = " 1P ";
        end
        else if (ui_screen == 3'd0) begin
            seg_text = "PLAY";
        end
        else if (ui_screen == 3'd5) begin
            seg_text = "SEL ";
        end
        else if (ui_screen == 3'd4) begin
            if (winner == 2'd1)
                seg_text = " P1 ";
            else if (winner == 2'd2)
                seg_text = " P2 ";
            else
                seg_text = "tIE ";
        end
        else if (seg_score == 1) begin
            seg_text = {8'h30 + k1_10, 8'h30 + k1_1, 8'h30 + k2_10, 8'h30 + k2_1};
            seg_dots = 4'b0100;
        end
        else begin
            seg_text = {" ", 8'h30 + t_min, 8'h30 + t_s10, 8'h30 + t_s1};
            seg_dots = 4'b0100;
        end
    end
    seg7 u_seg (.clk(clk), .text(is_main ? seg_text : s_text), .dots(is_main ? seg_dots : s_dots),
        .seg(seg), .dp(dp), .an(an));

    // oled, 6.25MHz clk = 100MHz / 16
    // Oled_Display needs 6.25 MHz: flip every 8 clocks = 100 MHz / 16
    reg [2:0] c625 = 0;
    reg clk6p25m = 0;
    always @ (posedge clk) begin
        c625 <= c625 + 1;
        if (c625 == 3'd7) begin
            clk6p25m <= ~clk6p25m;
        end
    end
    wire [12:0] oled_idx;
    wire [15:0] oled_px;
    Oled_Display u_oled (.clk(clk6p25m), .reset(rst), .frame_begin(), .sending_pixels(), .sample_pixel(),
        .pixel_index(oled_idx), .pixel_data(oled_px),
        .cs(oled_cs), .sdin(oled_sdin), .sclk(oled_sclk), .d_cn(oled_dc), .resn(oled_resn),
        .vccen(oled_vccen), .pmoden(oled_pmoden));
    // oled_debug draws the text for each pixel the oled asks for
    oled_debug u_odbg (.clk(clk), .clr(bu_q[1]), .page(oled_page),
        .ok_k1(ok_k1), .ok_k2(ok_k2), .ok_m2(ok_m2),
        .good_k1(gd_k1), .bad_k1(bd_k1), .good_k2(gd_k2), .bad_k2(bd_k2), .good_m2(gd_m2), .bad_m2(bd_m2),
        .keys1(keys1), .keys2(keys2), .m1x(m1x), .m1y(m1y), .m2x(m2x), .m2y(m2y),
        .m1l(m1l), .m1r(m1r), .m2l(m2l), .m2r(m2r),
        .role(role),
        .pixel_index(oled_idx), .pixel_data(oled_px));

endmodule
