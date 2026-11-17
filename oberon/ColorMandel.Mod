MODULE ColorMandel; (*OBERON_RISC5_LCD_gowin L4: the Mandelbrot set in colour on the board's colour plane
  (PLAN.md L-D7..L-D12). The colour memory at 404000H holds 240 x 136 colour pixels of 4 bits over the whole
  480 x 272 screen (each one 2 x 2 screen pixels); colour pixel (cx, cy), y = 0 at the bottom, is the low nibble
  (even cx) or the high nibble (odd cx) of byte 404000H + cy * 120 + cx DIV 2. Value 0 shows Oberon's own pixel,
  1..15 the palette entry at 408000H + 4 * value (RGB565, write only).
  ColorMandel.Draw: a new viewer in the user track; its frame is made black and every colour pixel inside it
  gets 1 + n MOD 15, n = the escape count of z := z*z + c (MaxIt steps), or 0 (black) inside the set.
  ColorMandel.Clear: all colour pixels 0 (the colour stays on the screen when the viewer is closed).*)
  IMPORT SYSTEM, Display, Viewers, Oberon, MenuViewers, TextFrames;

  CONST Menu = "System.Close  System.Copy  System.Grow  ColorMandel.Clear";
    MaxIt = 60; CBase = 404000H; PBase = 408000H; CW = 240; CH = 136; Span = 120;

  PROCEDURE Clear*;
    VAR a: INTEGER;
  BEGIN a := CBase;
    WHILE a < CBase + CH * Span DO SYSTEM.PUT(a, 0); INC(a, 4) END
  END Clear;

  PROCEDURE Dot(cx, cy, c: INTEGER);   (*colour pixel (cx, cy) := c*)
    VAR a, v: INTEGER; b: BYTE;
  BEGIN
    IF (cx >= 0) & (cx < CW) & (cy >= 0) & (cy < CH) THEN
      a := CBase + cy * Span + cx DIV 2; SYSTEM.GET(a, b); v := b;
      IF ODD(cx) THEN v := v MOD 16 + c * 16 ELSE v := v DIV 16 * 16 + c END ;
      b := v; SYSTEM.PUT(a, b)
    END
  END Dot;

  PROCEDURE SetPalette;   (*entries 1..15: deep blue, blue, cyan, green, yellow, orange, red, magenta, white*)
    VAR i: INTEGER; p: ARRAY 16 OF INTEGER;
  BEGIN
    p[1] := 0010H; p[2] := 001FH; p[3] := 041FH; p[4] := 07FFH; p[5] := 07F0H; p[6] := 07E0H; p[7] := 87E0H;
    p[8] := 0FFE0H; p[9] := 0FE00H; p[10] := 0FC00H; p[11] := 0FA00H; p[12] := 0F800H; p[13] := 0F810H;
    p[14] := 0F81FH; p[15] := 0FFFFH;
    FOR i := 1 TO 15 DO SYSTEM.PUT(PBase + 4 * i, p[i]) END
  END SetPalette;

  PROCEDURE DrawSet(F: Display.Frame);
    VAR i, j, n, cx0, cx1, cy0, cy1: INTEGER; s, cx, cy, x, y, xx, yy, x0, y0: REAL;
  BEGIN
    Display.ReplConst(Display.black, F.X, F.Y, F.W, F.H, Display.replace);
    cx0 := (F.X + 1) DIV 2; cx1 := (F.X + F.W) DIV 2;   (*colour pixels fully inside the frame*)
    cy0 := (F.Y + 1) DIV 2; cy1 := (F.Y + F.H) DIV 2;
    IF (cx1 > cx0) & (cy1 > cy0) THEN
      IF (cx1 - cx0) * 4 > (cy1 - cy0) * 5 THEN s := 2.4 / FLT(cy1 - cy0) ELSE s := 3.0 / FLT(cx1 - cx0) END ;
      x0 := -0.7 - FLT(cx1 - cx0) * s / 2.0; y0 := -FLT(cy1 - cy0) * s / 2.0;
      FOR j := cy0 TO cy1 - 1 DO
        cy := y0 + FLT(j - cy0) * s;
        FOR i := cx0 TO cx1 - 1 DO
          cx := x0 + FLT(i - cx0) * s; x := 0.0; y := 0.0; xx := 0.0; yy := 0.0; n := 0;
          WHILE (n < MaxIt) & (xx + yy < 4.0) DO
            y := 2.0 * x * y + cy; x := xx - yy + cx; xx := x * x; yy := y * y; INC(n)
          END ;
          IF n = MaxIt THEN Dot(i, j, 0) ELSE Dot(i, j, 1 + n MOD 15) END
        END
      END
    END
  END DrawSet;

  PROCEDURE Handler(F: Display.Frame; VAR M: Display.FrameMsg);
    VAR F0: Display.Frame;
  BEGIN
    IF M IS Oberon.InputMsg THEN
      IF M(Oberon.InputMsg).id = Oberon.track THEN
        Oberon.DrawMouseArrow(M(Oberon.InputMsg).X, M(Oberon.InputMsg).Y)
      END
    ELSIF M IS MenuViewers.ModifyMsg THEN
      F.Y := M(MenuViewers.ModifyMsg).Y; F.H := M(MenuViewers.ModifyMsg).H; Clear; DrawSet(F)
    ELSIF M IS Oberon.ControlMsg THEN
      IF M(Oberon.ControlMsg).id = Oberon.neutralize THEN Oberon.RemoveMarks(F.X, F.Y, F.W, F.H) END
    ELSIF M IS Oberon.CopyMsg THEN
      NEW(F0); F0^ := F^; M(Oberon.CopyMsg).F := F0
    END
  END Handler;

  PROCEDURE New(): Display.Frame;
    VAR F: Display.Frame;
  BEGIN NEW(F); F.handle := Handler; RETURN F
  END New;

  PROCEDURE Draw*;
    VAR V: Viewers.Viewer; X, Y: INTEGER;
  BEGIN SetPalette; Oberon.AllocateUserViewer(Oberon.Par.vwr.X, X, Y);
    V := MenuViewers.New(TextFrames.NewMenu("ColorMandel", Menu), New(), TextFrames.menuH, X, Y)
  END Draw;

END ColorMandel.
