`timescale 1ns/1ps
// Vendor EG_LOGIC_BRAM read-latency probe (item B).
// Uses the vendor model from the local TD installation, NOT a self-written
// substitute. Measures port-B read latency for REGMODE_B = OUTREG vs NOREG
// with the exact port mapping bmp_scaler.v uses.
module tb;
    reg clk = 0;
    always #5 clk = ~clk;

    reg         wea = 0;
    reg  [10:0] addra = 0, addrb = 0;
    reg  [23:0] dia = 0;
    wire [23:0] doa_out, dob_outreg, dob_noreg;
    integer i;

    // write ports driven identically for both instances
    always @(posedge clk) begin
        wea <= 1'b0;
        if (!$past(wea)) ;
    end

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(24), .DATA_WIDTH_B(24),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11),
        .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .BYTE_ENABLE(0), .MODE("DP"),
        .REGMODE_A("NOREG"), .REGMODE_B("OUTREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K")
    ) u_outreg (
        .dia(dia), .dib(24'd0), .addra(addra), .addrb(addrb),
        .cea(1'b1), .ocea(1'b1), .clka(clk), .wea(wea), .rsta(1'b0), .bea(1'b1),
        .ceb(1'b1), .oceb(1'b1), .clkb(clk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
        .doa(doa_out), .dob(dob_outreg)
    );

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(24), .DATA_WIDTH_B(24),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11),
        .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .BYTE_ENABLE(0), .MODE("DP"),
        .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K")
    ) u_noreg (
        .dia(dia), .dib(24'd0), .addra(addra), .addrb(addrb),
        .cea(1'b1), .ocea(1'b1), .clka(clk), .wea(wea), .rsta(1'b0), .bea(1'b1),
        .ceb(1'b1), .oceb(1'b1), .clkb(clk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
        .doa(doa_out), .dob(dob_noreg)
    );

    // ---- stimulus ------------------------------------------------------
    // cycle 0..7   : write mem[0..7] = {8'hA0, addr} on port A
    // cycle 20     : addrb = 3  (first read)
    // cycle 30     : addrb = 5  (second read)
    // cycle 40     : addrb = 7  (third read)
    // cycle 50..62 : addrb held; watch dob settle
    task poke(input integer idx, input [23:0] val);
        begin
            @(negedge clk); dia = val; addra = idx[10:0]; wea = 1;
            @(negedge clk); wea = 0; dia = 0;
        end
    endtask

    integer k;
    initial begin
        // 8 write pulses
        for (i = 0; i < 8; i = i + 1) begin
            @(negedge clk); dia = {16'hA000 + i[15:0], 8'h11}; addra = i[10:0]; wea = 1;
        end
        @(negedge clk); wea = 0; dia = 0;

        // first read: address 3
        @(negedge clk); addrb = 11'd3;
        for (k = 0; k < 5; k = k + 1) begin
            @(posedge clk); #1;
            $display("RD3 OUTREG cycle%0d dob=%h  NOREG cycle%0d dob=%h", k, dob_outreg, k, dob_noreg);
        end

        // second read: address 5
        @(negedge clk); addrb = 11'd5;
        for (k = 0; k < 5; k = k + 1) begin
            @(posedge clk); #1;
            $display("RD5 OUTREG cycle%0d dob=%h  NOREG cycle%0d dob=%h", k, dob_outreg, k, dob_noreg);
        end

        // back-to-back address change while reads continue
        @(negedge clk); addrb = 11'd7;
        for (k = 0; k < 5; k = k + 1) begin
            @(posedge clk); #1;
            $display("RD7 OUTREG cycle%0d dob=%h  NOREG cycle%0d dob=%h", k, dob_outreg, k, dob_noreg);
        end

        // write-port A readback via doa (NOREG assumed)
        @(negedge clk); addra = 11'd0;
        @(posedge clk); #1; $display("DOA addr0=%h", doa_out);

        $display("BRAM PROBE DONE");
        $finish;
    end

    initial begin
        #100000;
        $display("WATCHDOG");
        $finish;
    end
endmodule
