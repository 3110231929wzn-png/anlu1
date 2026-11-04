`timescale 1ns/1ps
module tb_scheduler_timeout;
    reg clk=0,rst=1,finish_toggle=0,ack=0;
    wire req,en,valid;
    integer pixels=0,writes=0;
    always #5 clk=~clk;
    sd_card_bmp #(.CLK_FREQ_HZ(10000),.SCAN_START_SECTOR(0),.SCAN_MAX_SECTOR(0),.SCAN_TARGET_COUNT(1)) dut(
        .clk(clk),.rst(rst),.key_next(1'b1),.key_auto(1'b1),.bmp_width(16'd4),.bmp_height(16'd1),
        .display_valid(valid),.state_code(),.write_finish_toggle(finish_toggle),
        .read_commit_toggle(1'b0),.read_active_index(2'd0),.write_buf_idx(),.disp_buf_idx(),
        .write_req(req),.write_req_ack(ack),.write_en(en),.write_data(),
        .SD_nCS(),.SD_DCLK(),.SD_MOSI(),.SD_MISO(1'b1));
    always @(posedge clk) begin
        ack<=req;
        if(rst) begin writes<=0;pixels<=0;finish_toggle<=0;end
        else begin
            if(req && !ack) begin writes<=writes+1;pixels<=0;end
            if(en) begin pixels<=pixels+1;if(pixels==3) finish_toggle<=~finish_toggle;end
        end
    end
    initial begin
        repeat(4) @(negedge clk);rst=0;
        wait(dut.sd_card_top_m0.active);wait(!dut.sd_card_top_m0.active); // scan
        wait(dut.sd_card_top_m0.active);wait(!dut.sd_card_top_m0.active); // load header
        @(negedge clk);dut.sd_card_top_m0.stall=1; // no data token/pixels for first load
        wait(dut.sd_card_top_m0.abort_req);
        if(valid || writes!=1) $fatal(1,"timeout fixture failed");
        @(negedge clk);dut.sd_card_top_m0.stall=0;
        wait(valid);
        if(writes!=2 || pixels!=4) $fatal(1,"scheduler did not recover and retry the complete image");
        $display("PASS tb_scheduler_timeout: load timeout, card abort, preserved scan and successful retry");$finish;
    end
    initial begin #300000;$fatal(1,"scheduler timeout watchdog writes=%0d",writes);end
endmodule
