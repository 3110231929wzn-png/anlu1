`timescale 1ns/1ps
// Real scheduler + BMP reader + frame controller + generated asynchronous FIFOs.
// Card sectors and the SDRAM user endpoint are behavioral boundary models.
module tb_player_pipeline;
    reg sd_clk=0,mem_clk=0,video_clk=0,rst=1,key_next=1;
    always #5 sd_clk=~sd_clk;
    always #4 mem_clk=~mem_clk;
    always #20 video_clk=~video_clk;
    wire req,ack,en,finish,display_valid,commit;
    wire [31:0] data,wr_data;
    wire [1:0] wr_index,disp_index,active_index;
    wire wr_en,rd_en,rd_ack;
    wire [20:0] wr_addr,rd_addr;
    wire [3:0] dm;
    reg read_req=0,finish_toggle=0;
    reg [31:0] memory[0:7],rd_pipe[0:7];
    reg [7:0] rd_valid=0;
    integer i,j,writes=0,finishes=0,old_writes;
    reg old_commit;
    sd_card_bmp #(.CLK_FREQ_HZ(10000),.SCAN_START_SECTOR(0),.SCAN_MAX_SECTOR(0),.SCAN_TARGET_COUNT(1)) source(
        .clk(sd_clk),.rst(rst),.key_next(key_next),.key_auto(1'b1),.bmp_width(16'd4),.bmp_height(16'd1),
        .display_valid(display_valid),.state_code(),.write_finish_toggle(finish_toggle),
        .read_commit_toggle(commit),.read_active_index(active_index),.write_buf_idx(wr_index),.disp_buf_idx(disp_index),
        .write_req(req),.write_req_ack(ack),.write_en(en),.write_data(data),
        .SD_nCS(),.SD_DCLK(),.SD_MOSI(),.SD_MISO(1'b1));
    frame_read_write #(.BURST_SIZE(4),.FRAME_WIDTH(4),.FRAME_HEIGHT(1),.WRITE_V_FLIP(1)) frames(
        .rst(rst),.mem_clk(mem_clk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),
        .App_rd_en(rd_en),.App_rd_addr(rd_addr),.Sdr_rd_en(rd_valid[7]),.Sdr_rd_dout(rd_pipe[7]),
        .read_clk(video_clk),.read_req(read_req),.read_req_ack(rd_ack),.read_finish(),
        .read_commit_toggle(commit),.read_active_index(active_index),
        .read_addr_0(21'd0),.read_addr_1(21'd4),.read_addr_2(21'd0),.read_addr_3(21'd0),
        .read_addr_index(disp_index),.read_len(21'd4),.read_en(1'b0),.read_data(),
        .App_wr_en(wr_en),.App_wr_addr(wr_addr),.App_wr_din(wr_data),.App_wr_dm(dm),
        .write_clk(sd_clk),.write_req(req),.write_req_ack(ack),.write_finish(finish),
        .write_addr_0(21'd0),.write_addr_1(21'd4),.write_addr_2(21'd0),.write_addr_3(21'd0),
        .write_addr_index(wr_index),.write_len(21'd4),.write_en(en),.write_data(data));
    always @(posedge mem_clk) begin
        if(rst) begin rd_valid<=0;finish_toggle<=0;writes<=0;finishes<=0;end
        else begin
            rd_valid<={rd_valid[6:0],rd_en};
            if(rd_en) begin
                if(rd_addr>7) $fatal(1,"player read address overflow");
                rd_pipe[0]<=memory[rd_addr];
            end
            for(i=1;i<8;i=i+1) rd_pipe[i]<=rd_pipe[i-1];
            if(wr_en) begin
                if(wr_addr>7 || dm!==0) $fatal(1,"player write address/mask invalid");
                if(display_valid && (wr_addr/4)==active_index)
                    $fatal(1,"writer overwrote active display buffer");
                memory[wr_addr]<=wr_data;writes<=writes+1;
            end
            if(finish) begin finish_toggle<=~finish_toggle;finishes<=finishes+1;end
        end
    end
    task press_next;
        begin
            @(negedge sd_clk);key_next=0;repeat(520) @(negedge sd_clk);
            key_next=1;repeat(520) @(negedge sd_clk);
        end
    endtask
    task accept_frame(input [1:0] expected_index);
        begin
            old_commit=commit;
            @(negedge video_clk);read_req=1;wait(rd_ack);
            @(negedge video_clk);read_req=0;wait(commit!=old_commit);#1;
            if(active_index!==expected_index) $fatal(1,"frame acceptance selected wrong buffer");
            repeat(8) @(negedge sd_clk);
        end
    endtask
    task check_image(input integer base);
        begin
            if(memory[base]!==32'h33221100 || memory[base+1]!==32'h66554400 ||
               memory[base+2]!==0 || memory[base+3]!==0)
                $fatal(1,"complete BMP RGB frame was not stored in buffer %0d",base/4);
        end
    endtask
    initial begin
        for(j=0;j<8;j=j+1) memory[j]=32'hdeadbeef;
        repeat(8) @(negedge sd_clk);rst=0;
        wait(display_valid);#1;check_image(0);old_writes=writes;
        press_next();repeat(200) @(negedge sd_clk);
        if(writes!=old_writes) $fatal(1,"queued load ran without display handoff");
        accept_frame(0);wait(disp_index==1);#1;check_image(4);check_image(0);
        accept_frame(1);
        press_next();wait(en);@(negedge sd_clk);source.sd_card_top_m0.stall=1;
        wait(source.sd_card_top_m0.abort_req);#1;
        if(!display_valid || disp_index!=1) $fatal(1,"timeout discarded the last complete picture");
        @(negedge sd_clk);source.sd_card_top_m0.stall=0;
        repeat(20) @(negedge sd_clk);press_next();
        wait(disp_index==0);#1;check_image(0);check_image(4);
        if(finishes!=3 || writes!=12) $fatal(1,"player frame accounting mismatch writes=%0d finish=%0d",writes,finishes);
        $display("PASS tb_player_pipeline: real writer/FIFO completion, queued handoff, partial timeout and retry without active-buffer overwrite");$finish;
    end
    initial begin #400000;$fatal(1,"player pipeline watchdog writes=%0d finishes=%0d",writes,finishes);end
endmodule
