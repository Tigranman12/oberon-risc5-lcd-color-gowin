`timescale 1ns / 1ps
// tb_lcd.v - OBERON_RISC5_LCD_gowin L1: rtl/r5_lcd.v alone (run_lcd.sh, a few seconds).
//   1. The CPU port writes all 4080 words (a pseudo-random picture), then byte-lane writes into some words;
//      a shadow copy follows every write.
//   2. Every word is read back through the CPU port (rdata one clock after the address) = the shadow.
//   3. One whole panel frame is recorded at the falling edges of lcd_clk (data is stable there):
//      272 lines of exactly 480 pixels with lcd_de, colours only white (FFFFH) or black, and every pixel =
//      bit x MOD 32 of shadow word y * 15 + x DIV 32 (Display.Mod's layout), with ROT = 1 (default): y = line,
//      x = 479 - position; ROT = 0: y = 271 - line, x = position (run_lcd.sh runs both);
//      lcd_clk periods per frame = 560 x 297, one hsync and one vsync pulse per line / frame.
//   The frame is also written to lcd_frame.ppm (P3, 480 x 272) for a look.
// L4: the colour memory (a[13:12] = 01) gets a pattern with many zero nibbles (transparent)
//   and byte-lane writes and is read back; palette entry 5 is written (entry 0 must stay unused), palette loads give
//   0; every panel pixel must be the colour value's palette entry (the default table, entry 5 changed)
//   where it is not 0, else Oberon's bit as white FFFFH / black 0000H.
// Last lines: "RESULT: n/m" and "TB PASS" or "TB FAIL".
module tb_lcd;
    reg clk = 1'b0, lclk = 1'b0;
    always #29.63 clk  = ~clk;           // 16.875 MHz, the CPU clock
    always #18.52 lclk = ~lclk;          // 27 MHz
    reg         we = 1'b0;
    reg  [3:0]  be = 4'h0;
    reg  [13:0] a = 14'd0;
    reg  [31:0] wdata = 32'd0;
    wire [31:0] rdata;
    wire        lcd_clk, lcd_de, lcd_hsync, lcd_vsync;
    wire [4:0]  lcd_r, lcd_b;
    wire [5:0]  lcd_g;
    parameter ROT = 1;                               // = r5_lcd's ROT180
    r5_lcd #(.ROT180(ROT)) dut (.clk(clk), .we(we), .be(be), .a(a), .wdata(wdata), .rdata(rdata), .lclk(lclk),
        .lcd_clk(lcd_clk), .lcd_de(lcd_de), .lcd_hsync(lcd_hsync), .lcd_vsync(lcd_vsync),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b));

    reg [31:0] sh [0:4095];
    reg [31:0] csh [0:4095];                         // L4: the colour memory's shadow
    reg [15:0] pm [0:15];                            // L4: the palette's model
    integer pass = 0, total = 0;
    task check(input ok, input [8*60-1:0] what);
        begin
            total = total + 1;
            if (ok) begin pass = pass + 1; $display("PASS: %0s", what); end
            else $display("FAIL: %0s", what);
        end
    endtask
    task wr(input [11:0] wa, input [3:0] wbe, input [31:0] d);
        begin
            @(negedge clk); a = {2'b00, wa}; be = wbe; wdata = d; we = 1'b1;
            @(negedge clk); we = 1'b0;
            if (wbe[0]) sh[wa][7:0]   = d[7:0];
            if (wbe[1]) sh[wa][15:8]  = d[15:8];
            if (wbe[2]) sh[wa][23:16] = d[23:16];
            if (wbe[3]) sh[wa][31:24] = d[31:24];
        end
    endtask
    task wrc(input [11:0] wa, input [3:0] wbe, input [31:0] d);   // L4: colour memory
        begin
            @(negedge clk); a = {2'b01, wa}; be = wbe; wdata = d; we = 1'b1;
            @(negedge clk); we = 1'b0;
            if (wbe[0]) csh[wa][7:0]   = d[7:0];
            if (wbe[1]) csh[wa][15:8]  = d[15:8];
            if (wbe[2]) csh[wa][23:16] = d[23:16];
            if (wbe[3]) csh[wa][31:24] = d[31:24];
        end
    endtask
    task wrp(input [3:0] k, input [15:0] d);        // L4: palette entry k (0 is never written)
        begin
            @(negedge clk); a = {2'b10, 8'd0, k}; be = 4'hF; wdata = {16'hDEAD, d}; we = 1'b1;
            @(negedge clk); we = 1'b0;
            if (k != 4'd0) pm[k] = d;
        end
    endtask

    // frame recorder
    integer x = 0, line = 0, nlines = 0, badlen = 0, badpix = 0, badcol = 0, nclk = 0, nhs = 0, nvs = 0;
    integer recording = 0, done = 0, fd, y, w, i, rbad, xo;
    reg     de_d = 1'b0, hs_d = 1'b0, vs_d = 1'b0, pix, expv;
    reg [15:0] rgb, expc;
    reg [3:0]  cv;
    integer    ncol = 0, nbw = 0;
    always @(negedge lcd_clk) begin
        if (recording) begin
            nclk = nclk + 1;
            if (lcd_hsync & ~hs_d) nhs = nhs + 1;
            if (lcd_de) begin
                rgb = {lcd_r, lcd_g, lcd_b};
                y  = ROT ? line : 271 - line;        // ROT180 (default): line l = y l, position p = x 479 - p
                xo = ROT ? 479 - x : x;
                w = sh[y * 15 + xo / 32];
                expv = w[xo % 32];
                w = csh[(y / 2) * 30 + xo / 16];     // L4: colour pixel (x DIV 2, y DIV 2)
                cv = w[((xo / 2) % 8) * 4 +: 4];
                expc = (cv != 4'd0) ? pm[cv] : (expv ? 16'hFFFF : 16'h0000);
                if (cv != 4'd0) ncol = ncol + 1; else nbw = nbw + 1;
                if (cv == 4'd0 && rgb != 16'hFFFF && rgb != 16'h0000) badcol = badcol + 1;
                if (rgb !== expc) begin
                    if (badpix < 5) $display("  pixel x %0d line %0d: %h, expected %h (colour value %0d, bit %b)",
                                             x, line, rgb, expc, cv, expv);
                    badpix = badpix + 1;
                end
                if (line < 272) $fwrite(fd, "%0d %0d %0d%s", {rgb[15:11], 3'b0}, {rgb[10:5], 2'b0}, {rgb[4:0], 3'b0},
                                        (x % 8 == 7) ? "\n" : "  ");
                x = x + 1;
            end
            if (~lcd_de & de_d) begin                // end of an active line
                if (x != 480) badlen = badlen + 1;
                x = 0; line = line + 1; nlines = nlines + 1;
            end
        end
        if (lcd_vsync & ~vs_d) begin                 // a vsync pulse: start / stop recording
            nvs = nvs + 1;
            if (recording) begin recording = 0; done = 1; end
            else if (!done && nvs == 1) begin recording = 1; nclk = 0; nhs = 0; line = 0; x = 0; end
        end
        de_d = lcd_de; hs_d = lcd_hsync; vs_d = lcd_vsync;
    end

    initial begin
        for (i = 0; i < 4096; i = i + 1) begin sh[i] = 32'hx; csh[i] = 32'hx; end
        // L4: the default palette (entry 0 unused)
        pm[0]  = 16'h0000; pm[1]  = 16'h0010; pm[2]  = 16'h001F; pm[3]  = 16'h041F; pm[4]  = 16'h07FF;
        pm[5]  = 16'h07F0; pm[6]  = 16'h07E0; pm[7]  = 16'h87E0; pm[8]  = 16'hFFE0; pm[9]  = 16'hFE00;
        pm[10] = 16'hFC00; pm[11] = 16'hFA00; pm[12] = 16'hF800; pm[13] = 16'hF810; pm[14] = 16'hF81F;
        pm[15] = 16'hFFFF;
        // 1. the picture: all 4080 words, then byte lanes
        for (i = 0; i < 4080; i = i + 1) wr(i, 4'hF, (i * 32'h9E3779B1) ^ (i << 7) ^ 32'h5A5A0F0F);
        wr(0, 4'hF, 32'hFFFFFFFF);                   // bottom line, x 0..31: white
        wr(4065, 4'hF, 32'h00000001);                // top line (y = 271): only x = 0
        wr(100, 4'b0001, 32'h000000AB);
        wr(101, 4'b0010, 32'h0000CD00);
        wr(102, 4'b0100, 32'h00EF0000);
        wr(103, 4'b1000, 32'h12000000);
        // L4: the colour memory: odd nibbles 0, every 3rd word all 0 (transparent spans), then byte lanes
        for (i = 0; i < 4080; i = i + 1)
            wrc(i, 4'hF, (i % 3 == 0) ? 32'd0 : (((i * 32'h2545F491) ^ (i >> 3)) & 32'h0F0F0F0F));
        wrc(200, 4'b0001, 32'h000000F1);
        wrc(201, 4'b0010, 32'h00002E00);
        wrc(202, 4'b0100, 32'h003D0000);
        wrc(203, 4'b1000, 32'h4C000000);
        wrp(5, 16'h1234);                            // L4: a palette entry changed
        wrp(0, 16'hFFFF);                            // entry 0 is never used: no effect
        // 2. read back
        rbad = 0;
        for (i = 0; i < 4080; i = i + 1) begin
            @(negedge clk); a = i;
            @(negedge clk);                          // rdata was taken at the edge in between
            if (rdata !== sh[i]) begin
                if (rbad < 5) $display("  word %0d: %h, expected %h", i, rdata, sh[i]);
                rbad = rbad + 1;
            end
        end
        check(rbad == 0, "CPU port: 4080 words read back (word writes)");
        rbad = 0;                                    // L4: the colour memory read back, the palette reads 0
        for (i = 0; i < 4080; i = i + 1) begin
            @(negedge clk); a = {2'b01, i[11:0]};
            @(negedge clk);
            if (rdata !== csh[i]) begin
                if (rbad < 5) $display("  colour word %0d: %h, expected %h", i, rdata, csh[i]);
                rbad = rbad + 1;
            end
        end
        @(negedge clk); a = {2'b10, 12'd5};
        @(negedge clk); if (rdata !== 32'd0) rbad = rbad + 1;
        @(negedge clk); a = {2'b11, 12'd5};
        @(negedge clk); if (rdata !== 32'd0) rbad = rbad + 1;
        check(rbad == 0 && csh[200][7:0] == 8'hF1 && csh[203][31:24] == 8'h4C,
              "L4: colour memory read back (words, byte lanes); palette and 11 read 0");
        check(sh[100][7:0] == 8'hAB && sh[101][15:8] == 8'hCD && sh[102][23:16] == 8'hEF && sh[103][31:24] == 8'h12
              && rbad == 0, "CPU port: byte lanes 0-3 written alone");
        // 3. one frame
        fd = $fopen("lcd_frame.ppm", "w");
        $fwrite(fd, "P3\n480 272\n255\n");
        wait (done == 1);
        $fclose(fd);
        check(nlines == 272 && badlen == 0, "LCD: 272 lines of 480 pixels (lcd_de)");
        check(badcol == 0, "LCD: colour value 0: only white / black");
        check(badpix == 0, "LCD: every pixel = palette[c] or Display.Mod's bit (ROT180 or not)");
        check(ncol > 30000 && nbw > 30000, "L4: both colour and Oberon's pixels in the frame");
        check(nclk == 560 * 297, "LCD: 560 x 297 pixel clocks per frame");
        check(nhs == 297, "LCD: 297 hsync pulses per frame");
        $display("frame: %0d lines, %0d pixel clocks, %0d hsync, bad: len %0d pix %0d col %0d; colour %0d, 1-bit %0d",
                 nlines, nclk, nhs, badlen, badpix, badcol, ncol, nbw);
        $display("RESULT: %0d/%0d", pass, total);
        if (pass == total) $display("TB PASS"); else $display("TB FAIL");
        $finish;
    end
    initial begin #60_000_000; $display("TIMEOUT"); $display("TB FAIL"); $finish; end
endmodule
