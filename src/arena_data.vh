
function [9:0] spawn_x;
    input [4:0] i;      // {map, index}
    case (i)
        5'd0: spawn_x = 10'd98;
        5'd1: spawn_x = 10'd530;
        5'd2: spawn_x = 10'd178;
        5'd3: spawn_x = 10'd450;
        5'd4: spawn_x = 10'd162;
        5'd5: spawn_x = 10'd466;
        5'd6: spawn_x = 10'd234;
        5'd7: spawn_x = 10'd394;
        5'd8: spawn_x = 10'd90;
        5'd9: spawn_x = 10'd538;
        5'd10: spawn_x = 10'd146;
        5'd11: spawn_x = 10'd482;
        5'd12: spawn_x = 10'd194;
        5'd13: spawn_x = 10'd434;
        5'd14: spawn_x = 10'd114;
        5'd15: spawn_x = 10'd514;
        default: spawn_x = 10'd1023;
    endcase
endfunction

function [9:0] spawn_y;
    input [4:0] i;      // {map, index}
    case (i)
        5'd0: spawn_y = 10'd354;
        5'd1: spawn_y = 10'd354;
        5'd2: spawn_y = 10'd322;
        5'd3: spawn_y = 10'd322;
        5'd4: spawn_y = 10'd258;
        5'd5: spawn_y = 10'd258;
        5'd6: spawn_y = 10'd226;
        5'd7: spawn_y = 10'd226;
        5'd8: spawn_y = 10'd266;
        5'd9: spawn_y = 10'd266;
        5'd10: spawn_y = 10'd346;
        5'd11: spawn_y = 10'd346;
        5'd12: spawn_y = 10'd330;
        5'd13: spawn_y = 10'd330;
        5'd14: spawn_y = 10'd202;
        5'd15: spawn_y = 10'd202;
        default: spawn_y = 10'd1023;
    endcase
endfunction

// ammo / bomb box points: box sprite top-left (16 x 12)
function [9:0] pick_x;
    input [4:0] i;      // {map, index}
    case (i)
        5'd0: pick_x = 10'd312;
        5'd1: pick_x = 10'd224;
        5'd2: pick_x = 10'd400;
        5'd3: pick_x = 10'd312;
        5'd4: pick_x = 10'd104;
        5'd5: pick_x = 10'd520;
        5'd6: pick_x = 10'd208;
        5'd7: pick_x = 10'd416;
        5'd8: pick_x = 10'd312;
        5'd9: pick_x = 10'd240;
        5'd10: pick_x = 10'd384;
        5'd11: pick_x = 10'd176;
        5'd12: pick_x = 10'd448;
        5'd13: pick_x = 10'd88;
        5'd14: pick_x = 10'd536;
        5'd15: pick_x = 10'd312;
        default: pick_x = 10'd1023;
    endcase
endfunction

function [9:0] pick_y;
    input [4:0] i;      // {map, index}
    case (i)
        5'd0: pick_y = 10'd132;
        5'd1: pick_y = 10'd164;
        5'd2: pick_y = 10'd164;
        5'd3: pick_y = 10'd340;
        5'd4: pick_y = 10'd292;
        5'd5: pick_y = 10'd292;
        5'd6: pick_y = 10'd396;
        5'd7: pick_y = 10'd396;
        5'd8: pick_y = 10'd380;
        5'd9: pick_y = 10'd300;
        5'd10: pick_y = 10'd300;
        5'd11: pick_y = 10'd172;
        5'd12: pick_y = 10'd172;
        5'd13: pick_y = 10'd300;
        5'd14: pick_y = 10'd300;
        5'd15: pick_y = 10'd108;
        default: pick_y = 10'd1023;
    endcase
endfunction

// physical crates at the start of a match: sprite top-left (16 x 16)
function [9:0] crate_x;
    input [2:0] i;      // {map, index}
    case (i)
        3'd0: crate_x = 10'd208;
        3'd1: crate_x = 10'd416;
        3'd2: crate_x = 10'd256;
        3'd3: crate_x = 10'd368;
        default: crate_x = 10'd1023;
    endcase
endfunction

function [9:0] crate_y;
    input [2:0] i;      // {map, index}
    case (i)
        3'd0: crate_y = 10'd320;
        3'd1: crate_y = 10'd320;
        3'd2: crate_y = 10'd296;
        3'd3: crate_y = 10'd296;
        default: crate_y = 10'd1023;
    endcase
endfunction

// springs (bounce pads): spring_gfx box top-left (64 x 96), 1023 = none
function [9:0] aspr_x;
    input [2:0] i;      // {map, index}
    case (i)
        3'd0: aspr_x = 10'd24;
        3'd1: aspr_x = 10'd552;
        3'd2: aspr_x = 10'd24;
        3'd3: aspr_x = 10'd552;
        default: aspr_x = 10'd1023;
    endcase
endfunction

function [9:0] aspr_y;
    input [2:0] i;      // {map, index}
    case (i)
        3'd0: aspr_y = 10'd272;
        3'd1: aspr_y = 10'd272;
        3'd2: aspr_y = 10'd312;
        3'd3: aspr_y = 10'd312;
        default: aspr_y = 10'd1023;
    endcase
endfunction

// trees (1023 = none)
function [9:0] tree_x;
    input [2:0] i;      // {map, index}
    case (i)
        3'd0: tree_x = 10'd104;
        3'd1: tree_x = 10'd504;
        3'd2: tree_x = 10'd1023;
        3'd3: tree_x = 10'd1023;
        default: tree_x = 10'd1023;
    endcase
endfunction

function [9:0] tree_y;
    input [2:0] i;      // {map, index}
    case (i)
        3'd0: tree_y = 10'd326;
        3'd1: tree_y = 10'd326;
        3'd2: tree_y = 10'd1023;
        3'd3: tree_y = 10'd1023;
        default: tree_y = 10'd1023;
    endcase
endfunction

