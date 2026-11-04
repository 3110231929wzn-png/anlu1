`timescale 1ns/1ps
module tb_frame_reader;
    reg clk=0,rst=1,req=0;
    reg [1:0] index=0;
    wire ack,toggle;
    wire [1:0] active_index;
    wire [20:0] address;
    reg old_toggle;
    always #4 clk=~clk;
    frame_fifo_read #(.BURST_SIZE(256)) dut(.rst(rst),.mem_clk(clk),.Sdr_init_done(1'b1),
        .Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),.Sdr_rd_en(1'b0),.App_wr_busy(1'b0),
        .O_rd_busy(),.App_rd_en(),.App_rd_addr(address),.read_req(req),.read_req_ack(ack),
        .read_finish(),.read_commit_toggle(toggle),.read_active_index(active_index),
        .read_addr_0(21'd0),.read_addr_1(21'd307200),.read_addr_2(21'd0),.read_addr_3(21'd0),
        .read_addr_index(index),.read_len(21'd307200),.fifo_aclr(),.wrusedw(10'd511));
    task request(input [1:0] selected,input [20:0] base_address);
        begin
            old_toggle=toggle;#3;index=selected;req=1;wait(ack);#11;req=0;
            wait(toggle!=old_toggle);#1;
            if(active_index!==selected || address!==base_address) $fatal(1,"frame descriptor mismatch");
            repeat(8) @(negedge clk);
            if(toggle===old_toggle || ack) $fatal(1,"frame handoff did not finish");
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        request(1,21'd307200);
        index=0;repeat(10) @(negedge clk);
        if(active_index!=1 || address!=307200) $fatal(1,"midframe selector changed active buffer");
        request(0,21'd0);
        $display("PASS tb_frame_reader: descriptor latch and stable active buffer");$finish;
    end
    initial begin #20000;$fatal(1,"frame reader watchdog");end
endmodule
