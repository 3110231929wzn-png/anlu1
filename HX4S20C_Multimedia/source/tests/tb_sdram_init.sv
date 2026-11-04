`timescale 1ns/1ps
// No SDRAM command acceptance or physical timing is inferred by this test.
// It checks that the provided controller initializes and emits idle refreshes.
module tb_sdram_init;
 wire shifted_clk;

    reg clk=0,rst=1;
 assign #9 shifted_clk=clk;
    always #10 clk=~clk;
    wire initialized,refresh_active,busy,read_valid;
    wire [31:0] read_data;
    integer refresh_edges=0;
    reg refresh_d=0;
    time last_refresh=0;
    sdram dut(.Clk(clk),.Clk_sft(shifted_clk),.Rst(rst),.Sdr_init_done(initialized),
        .Sdr_init_ref_vld(refresh_active),.Sdr_busy(busy),
        .App_wr_en(1'b0),.App_wr_addr(21'd0),.App_wr_dm(4'd0),.App_wr_din(32'd0),
        .App_rd_en(1'b0),.App_rd_addr(21'd0),.Sdr_rd_en(read_valid),.Sdr_rd_dout(read_data));
    always @(posedge clk) begin
        refresh_d<=refresh_active;
        if(initialized && refresh_active && !refresh_d) begin
            if(refresh_edges>0) begin
                // EM638325 Rev.3.2 requires 4096 refreshes per 64 ms.
                // Integer clock rounding must never make the interval longer.
                if(($time-last_refresh)<15500 || ($time-last_refresh)>15625)
                    $fatal(1,"idle refresh interval out of range: %0t",$time-last_refresh);
                $display("TRACE idle refresh interval: %0t",$time-last_refresh);
            end
            last_refresh=$time;
            refresh_edges<=refresh_edges+1;
        end
    end
    initial begin
        repeat(20) @(negedge clk);rst=0;
        wait(initialized===1'b1);
        repeat(12500) @(negedge clk);
        if(refresh_edges<2) $fatal(1,"SDRAM controller did not produce recurring idle refreshes");
        $display("PASS tb_sdram_init: provided encrypted controller initialization and recurring idle refresh");$finish;
    end
    initial begin #10000000;$fatal(1,"SDRAM initialization watchdog init=%b busy=%b refreshes=%0d",initialized,busy,refresh_edges);end
endmodule
