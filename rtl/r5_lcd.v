`timescale 1ns / 1ps
// r5_lcd.v - OBERON_RISC5_LCD_gowin L1: Oberon's 1-bit frame buffer of 480 x 272 pixels in
// block RAM, and the controller of the Sipeed 4.3" RGB LCD that shows it.
//
// CPU port (clk = the CPU clock), at 400000H-403FFFH in r5_tang (word a = adr[13:2], 0..4095; 4080 are shown):
//   we writes the byte lanes be of wdata into word a; rdata = word a one clock after a (the load's wait clock).
//   Four byte-wide memories (m0 = bits 7..0 ... m3 = bits 31..24), so byte stores (STB) need no read-modify-write.
// LCD port (lclk = the 27 MHz crystal): the timing of Sipeed's lcd_4.3 example:
//   one pixel every 3 clocks (9 MHz); H 30 + 480 + 50 = 560 pixels, V 5 + 272 + 20 = 297 lines (about 54 Hz);
//   lcd_clk is high in ph0, ph1 and low in ph2, data change with its rising edge.
// Pixel layout as Wirth's Display.Mod, Span = 60 bytes = 15 words:
//   pixel (x, y) = bit x MOD 32 of word y * 15 + x DIV 32; y = 0 is the BOTTOM line (ROT180 below decides how
//   the panel's scan maps to x and y). Bit 1 = white (Display.white), 0 = black.
// L4: a colour plane over it. The CPU port's a[13:12] selects:
//   00 the frame memory (400000H), 01 the colour memory (404000H: 240 x 136 colour pixels of 4 bits, pixel (cx, cy)
//   = nibble cx MOD 8 of word cy * 30 + cx DIV 8, y = 0 at the bottom; read back as the frame memory),
//   10 the palette (408000H: entry a[3:0] := wdata[15:0] RGB565; write only, loads give 0), 11 nothing.
//   Panel pixel (x, y) shows colour value c of colour pixel (x DIV 2, y DIV 2): c = 0 transparent (Oberon's bit:
//   FFFFH / 0000H), c = 1..15 the palette entry c. Both memories are 0 after configuration.
module r5_lcd #(parameter ROT180 = 1) (
    input  wire        clk,
    input  wire        we,
    input  wire [3:0]  be,
    input  wire [13:0] a,              // L4: a[13:12] = 00 frame, 01 colour, 10 palette
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    input  wire        lclk,
    output reg         lcd_clk, lcd_de, lcd_hsync, lcd_vsync,
    output reg  [4:0]  lcd_r,
    output reg  [5:0]  lcd_g,
    output reg  [4:0]  lcd_b
);
    reg [7:0] m0 [0:4095];
    reg [7:0] m1 [0:4095];
    reg [7:0] m2 [0:4095];
    reg [7:0] m3 [0:4095];
    reg [7:0] c0 [0:4095];              // L4: the colour memory, byte lanes as m0..m3
    reg [7:0] c1 [0:4095];
    reg [7:0] c2 [0:4095];
    reg [7:0] c3 [0:4095];
    // L4: the palette, RGB565; entry 0 unused (0 = transparent)
    reg [15:0] pal [0:15] /* synthesis syn_ramstyle = "registers" */;
    integer k;
    initial begin
        pal[0]  = 16'h0000; pal[1]  = 16'h0010; pal[2]  = 16'h001F; pal[3]  = 16'h041F;
        pal[4]  = 16'h07FF; pal[5]  = 16'h07F0; pal[6]  = 16'h07E0; pal[7]  = 16'h87E0;
        pal[8]  = 16'hFFE0; pal[9]  = 16'hFE00; pal[10] = 16'hFC00; pal[11] = 16'hFA00;
        pal[12] = 16'hF800; pal[13] = 16'hF810; pal[14] = 16'hF81F; pal[15] = 16'hFFFF;
        // simulation only: block RAM is 0 after configuration; a loop here could make Gowin build flip-flops
        // synthesis translate_off
        for (k = 0; k < 4096; k = k + 1) begin c0[k] = 8'd0; c1[k] = 8'd0; c2[k] = 8'd0; c3[k] = 8'd0; end
        // synthesis translate_on
    end

    // ---- CPU port ----
    reg [7:0] r0, r1, r2, r3;                        // the lanes' read registers
    reg [7:0] s0, s1, s2, s3;                        // L4: the colour lanes' read registers
    reg [1:0] rsel = 2'b00;                          // L4: a[13:12] of the last read
    assign rdata = (rsel == 2'b00) ? {r3, r2, r1, r0} : (rsel == 2'b01) ? {s3, s2, s1, s0} : 32'd0;
    wire fwe = we & (a[13:12] == 2'b00);
    wire cwe = we & (a[13:12] == 2'b01);
    always @(posedge clk) begin
        rsel <= a[13:12];
        if (we & (a[13:12] == 2'b10) & (a[3:0] != 4'd0)) pal[a[3:0]] <= wdata[15:0];
    end
    // Gowin's DPB has no read-before-write (WRITE_MODE 2'b10, PA2122 in the first build),
    // so each lane reads only when it is not written ("normal" mode 2'b00: the
    // output keeps its value during a write). The CPU never loads in the clock of a store, so loads are the same.
    always @(posedge clk) if (fwe & be[0]) m0[a[11:0]] <= wdata[7:0];   else r0 <= m0[a[11:0]];
    always @(posedge clk) if (fwe & be[1]) m1[a[11:0]] <= wdata[15:8];  else r1 <= m1[a[11:0]];
    always @(posedge clk) if (fwe & be[2]) m2[a[11:0]] <= wdata[23:16]; else r2 <= m2[a[11:0]];
    always @(posedge clk) if (fwe & be[3]) m3[a[11:0]] <= wdata[31:24]; else r3 <= m3[a[11:0]];
    always @(posedge clk) if (cwe & be[0]) c0[a[11:0]] <= wdata[7:0];   else s0 <= c0[a[11:0]];
    always @(posedge clk) if (cwe & be[1]) c1[a[11:0]] <= wdata[15:8];  else s1 <= c1[a[11:0]];
    always @(posedge clk) if (cwe & be[2]) c2[a[11:0]] <= wdata[23:16]; else s2 <= c2[a[11:0]];
    always @(posedge clk) if (cwe & be[3]) c3[a[11:0]] <= wdata[31:24]; else s3 <= c3[a[11:0]];

    // ---- LCD timing ----
    localparam H_BP = 30, H_ACT = 480, H_TOT = 560;
    localparam V_BP = 5,  V_ACT = 272, V_TOT = 297;
    reg [1:0] ph = 2'd0;                // clock slot inside one pixel
    reg [9:0] h  = 10'd0;
    reg [8:0] v  = 9'd0;
    always @(posedge lclk) begin
        ph <= (ph == 2'd2) ? 2'd0 : ph + 2'd1;
        if (ph == 2'd2) begin
            if (h == H_TOT - 1) begin
                h <= 10'd0;
                v <= (v == V_TOT - 1) ? 9'd0 : v + 9'd1;
            end else
                h <= h + 10'd1;
        end
    end
    wire       act = (h >= H_BP) && (h < H_BP + H_ACT) && (v >= V_BP) && (v < V_BP + V_ACT);
    wire [9:0] ax  = h - H_BP;                           // x 0..479 (garbage outside)
    // ROT180 (user, 2026-11-09, A): the panel lies with its cable on top, where its scan starts at the bottom-right
    // corner (board photo docs/l1_board_lcdtest.jpg): panel line l shows y = l and scan position p shows x = 479 - p.
    // ROT180 = 0: line l shows y = 271 - l, p shows x = p (the panel turned, cable at the bottom).
    wire [8:0] oy  = ROT180 ? (v - V_BP) : 9'd271 - (v - V_BP);     // Oberon's y of this panel line
    wire [9:0] ox  = ROT180 ? 10'd479 - ax : ax;                    // Oberon's x of this scan position
    wire [12:0] la = {oy, 4'b0} - {4'b0, oy} + {8'b0, ox[9:5]};    // oy * 15 + x DIV 32 (0..4079)

    // ph0: address la applied; the word is read at every edge, so it is valid in ph1 and ph2 of the pixel
    reg [31:0] q = 32'd0;
    always @(posedge lclk) q <= {m3[la[11:0]], m2[la[11:0]], m1[la[11:0]], m0[la[11:0]]};
    // L4: colour pixel (ox DIV 2, oy DIV 2) = nibble ox[3:1] of word cy * 30 + ox DIV 16, read the same way
    wire [7:0]  cy = oy[8:1];                                        // 0..135
    wire [12:0] ca = {cy, 5'b0} - {4'b0, cy, 1'b0} + {7'b0, ox[9:4]}; // cy * 30 + ox DIV 16 (0..4079)
    reg  [31:0] cq = 32'd0;
    always @(posedge lclk) cq <= {c3[ca[11:0]], c2[ca[11:0]], c1[ca[11:0]], c0[ca[11:0]]};
    wire [3:0]  cv = cq[{ox[3:1], 2'b00} +: 4];                      // the colour value of this pixel

    initial begin
        lcd_clk = 1'b0; lcd_de = 1'b0; lcd_hsync = 1'b0; lcd_vsync = 1'b0;
        lcd_r = 5'd0; lcd_g = 6'd0; lcd_b = 5'd0;
    end
    always @(posedge lclk) begin
        lcd_clk <= (ph == 2'd2) || (ph == 2'd0);         // high in ph0, ph1; low in ph2
        if (ph == 2'd2) begin
            lcd_de    <= act;
            lcd_hsync <= (h >= H_BP + H_ACT + 1);        // like Sipeed: high in the front porch
            lcd_vsync <= (v >= V_BP + V_ACT + 1);
            {lcd_r, lcd_g, lcd_b} <= ~act ? 16'h0000 : (cv != 4'd0) ? pal[cv] :   // L4: colour over Oberon's bit
                                     q[ox[4:0]] ? 16'hFFFF : 16'h0000;
        end
    end
endmodule
