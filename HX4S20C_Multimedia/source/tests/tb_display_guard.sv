`timescale 1ns/1ps
module tb_display_guard;
    reg clk=0,rst=1,key_next=1,key_auto=1,write_toggle=0,read_toggle=0;
    reg [1:0] active_index=0;
    wire [1:0] write_index,display_index;
    wire display_valid,write_req,write_en;
    wire [31:0] data;
    reg write_ack=0;
    reg inject_finish=0,auto_finish=0;
    integer writes=0, pixels=0;
    always #5 clk=~clk;
    sd_card_bmp #(.CLK_FREQ_HZ(10000),.SCAN_START_SECTOR(0),.SCAN_MAX_SECTOR(0),.SCAN_TARGET_COUNT(1)) dut(
        .clk(clk),.rst(rst),.key_next(key_next),.key_auto(key_auto),.bmp_width(16'd4),.bmp_height(16'd1),
        .display_valid(display_valid),.state_code(),.write_finish_toggle(write_toggle),
        .read_commit_toggle(read_toggle),.read_active_index(active_index),
        .write_buf_idx(write_index),.disp_buf_idx(display_index),.write_req(write_req),
        .write_req_ack(write_ack),.write_en(write_en),.write_data(data),
        .SD_nCS(),.SD_DCLK(),.SD_MOSI(),.SD_MISO(1'b1));
    always @(posedge clk) begin
        write_ack<=write_req;
        if(rst) begin writes<=0;pixels<=0;write_toggle<=0;end
        else begin
            if(inject_finish) write_toggle<=~write_toggle;
            if(write_req && !write_ack) begin writes<=writes+1;pixels<=0;end
            if(write_en) begin
                pixels<=pixels+1;
                if(pixels==3 && auto_finish) write_toggle<=~write_toggle;
            end
        end
    end
    initial begin
        repeat(4) @(negedge clk);rst=0;
        wait(dut.sd_card_top_m0.active);wait(!dut.sd_card_top_m0.active);
        wait(dut.sd_card_top_m0.active); // header of first load, before its write handshake
        @(negedge clk);inject_finish=1;@(negedge clk);inject_finish=0;
        wait(pixels==4);repeat(10) @(negedge clk);
        if(display_valid) $fatal(1,"frame committed before source sector completed");
        repeat(600) @(negedge clk);
        if(display_valid) $fatal(1,"stale previous write completion committed the new frame");
        inject_finish=1;@(negedge clk);inject_finish=0;auto_finish=1;
        wait(display_valid); if(writes!=1 || display_index!=0) $fatal(1,"first image fixture failed");
        // Queue next image while the display has NOT accepted the committed frame.
        key_next=0;repeat(520) @(negedge clk);key_next=1;
        repeat(1500) @(negedge clk);
        if(writes!=1) $fatal(1,"old display buffer reused before frame-boundary acceptance");
        active_index=0;read_toggle=~read_toggle;
        wait(writes==2);
        if(write_index!=1) $fatal(1,"next write did not select retired buffer");
        wait(display_index==1);
        $display("PASS tb_display_guard: first frame, queued key, ownership ACK and next buffer");$finish;
    end
    initial begin #200000;$fatal(1,"display guard watchdog writes=%d",writes);end
endmodule
