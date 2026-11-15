
localparam SLOT_PLAYER = 0,  SLOT_FLAG  = 1,  SLOT_GUN    = 2,
           SLOT_BOX0   = 3,  N_BOX      = 2,                     // 3..4  crates
           SLOT_SCALE  = 7,
           SLOT_DOOR0  = 8,  N_DOOR     = 2,                     // 8..9
           SLOT_MIR0   = 10, N_MIR      = 2,                     // 10..11
           SLOT_SPRING0 = 12, N_SPRING  = 2,                     // 12..13
           SLOT_TREE0  = 14, N_TREE     = 1,                     // 14
           SLOT_XGHOST = 15,                                     // crate ghost when the crate slots are full
           NSLOT       = 16;                                     // (slots 5-6 are old crate slots, unused)
localparam N_LEVELS = 8;          // 0-6 built-in levels, 7 = user level U1
localparam [3:0] N_BUILT = 4'd7;  // built-in levels (user levels start at this number)
localparam [3:0] N_USER  = 4'd1;  // user (editor) save slots: only U1
localparam [3:0] N_PLAY  = 4'd7;  // built-in levels on the play bar

`define REDRAWN_EDITOR
`ifdef REDRAWN_EDITOR
localparam EDITOR_ON = 1;
`else
localparam EDITOR_ON = 0;
`endif
localparam TILE_Y0  = 64;         // screen y of tile row 0 (tiles are 8x8 px, 80 x 45 of them)

localparam [1:0] SZ_NORMAL = 2'd0, SZ_SMALL = 2'd1, SZ_BIG = 2'd2;
