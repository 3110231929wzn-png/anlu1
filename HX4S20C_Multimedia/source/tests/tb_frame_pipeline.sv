`timescale 1ns/1ps
// Real frame controller and generated asynchronous FIFOs. Only the SDRAM
// user-interface endpoint is modeled; this is not a physical SDRAM timing test.
module tb_frame_pipeline #(
    parameter WIDTH=8, HEIGHT=4, BURST_SIZE=8, PIXEL_GAP=1,
    parameter TIMEOUT_NS=200000,
    parameter CASE_NAME="frame_pipeline"
);
    localparam integer N=WIDTH*HEIGHT;
    localparam [20:0] FRAME_LENGTH=N;
    reg mem_clk=0,write_clk=0,read_clk=0,rst=1;
    always #4 mem_clk=~mem_clk;
    always #5 write_clk=~write_clk;
    always #20 read_clk=~read_clk;
    reg write_req=0,write_en=0,read_req=0,read_en=0;
    reg [1:0] write_index=0,read_index=0;
    reg [31:0] write_data=0;
    wire write_ack,write_finish,read_ack,read_finish,commit_toggle;
    wire [1:0] active_index;
    wire [31:0] read_data,app_wr_data;
    wire [20:0] app_wr_addr,app_rd_addr;
    wire app_wr_en,app_rd_en;
    wire [3:0] dm;
    reg [31:0] memory[0:2*N-1];
    reg [7:0] rd_valid=0;
    reg [31:0] rd_pipe[0:7];
    integer writes=0,finishes=0,i,row,col,offset;
    reg old_commit;
    frame_read_write #(.BURST_SIZE(BURST_SIZE),.FRAME_WIDTH(WIDTH),.FRAME_HEIGHT(HEIGHT),.WRITE_V_FLIP(1)) dut(
        .rst(rst),.mem_clk(mem_clk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),
        .App_rd_en(app_rd_en),.App_rd_addr(app_rd_addr),.Sdr_rd_en(rd_valid[7]),.Sdr_rd_dout(rd_pipe[7]),
        .read_clk(read_clk),.read_req(read_req),.read_req_ack(read_ack),.read_finish(read_finish),
        .read_commit_toggle(commit_toggle),.read_active_index(active_index),
        .read_addr_0(21'd0),.read_addr_1(FRAME_LENGTH),.read_addr_2(21'd0),.read_addr_3(21'd0),
        .read_addr_index(read_index),.read_len(FRAME_LENGTH),.read_en(read_en),.read_data(read_data),
        .App_wr_en(app_wr_en),.App_wr_addr(app_wr_addr),.App_wr_din(app_wr_data),.App_wr_dm(dm),
        .write_clk(write_clk),.write_req(write_req),.write_req_ack(write_ack),.write_finish(write_finish),
        .write_addr_0(21'd0),.write_addr_1(FRAME_LENGTH),.write_addr_2(21'd0),.write_addr_3(21'd0),
        .write_addr_index(write_index),.write_len(FRAME_LENGTH),.write_en(write_en),.write_data(write_data));
    always @(posedge mem_clk) begin
        if(rst) begin rd_valid<=0;writes<=0;finishes<=0;end
        else begin
            rd_valid<={rd_valid[6:0],app_rd_en};
            if(app_rd_en) begin
                if(app_rd_addr>=2*N) $fatal(1,"read address out of bounds");
                rd_pipe[0]<=memory[app_rd_addr];
            end
            for(i=1;i<8;i=i+1) rd_pipe[i]<=rd_pipe[i-1];
            if(app_wr_en) begin
                if(app_wr_addr>=2*N || dm!==0) $fatal(1,"write address/mask invalid");
                memory[app_wr_addr]<=app_wr_data;writes<=writes+1;
            end
            if(app_wr_en && (app_rd_en || rd_valid[7])) $fatal(1,"read/write overlap at memory boundary");
            if(write_finish) finishes<=finishes+1;
        end
    end
    task begin_write(input [1:0] idx);
        begin
            @(negedge write_clk);write_index=idx;write_req=1;
            wait(write_ack);repeat(2) @(negedge write_clk);write_req=0;
            wait(!write_ack);repeat(8) @(negedge write_clk);
            $display("TRACE write handshake idx=%d state=%d fifo_reset=%b used=%d",idx,dut.frame_fifo_write_m0.state,dut.write_fifo_aclr,dut.rdusedw);
        end
    endtask
    task pixels(input [31:0] tag,input integer count);
        integer p;
        begin
            for(p=0;p<count;p=p+1) begin
                @(negedge write_clk);write_en=1;write_data=tag+p;
                if(PIXEL_GAP>1) begin
                    @(negedge write_clk);write_en=0;
                    repeat(PIXEL_GAP-2) @(negedge write_clk);
                end
            end
            @(negedge write_clk);write_en=0;
            $display("TRACE source complete count=%d state=%d used=%d busy=%b",count,dut.frame_fifo_write_m0.state,dut.rdusedw,dut.App_rd_busy);
        end
    endtask
    task check_memory(input integer base,input [31:0] tag);
        integer y,x;
        begin
            for(y=0;y<HEIGHT;y=y+1) for(x=0;x<WIDTH;x=x+1)
                if(memory[base+y*WIDTH+x] !== tag+(HEIGHT-1-y)*WIDTH+x)
                    $fatal(1,"FIFO write/vertical flip mismatch address=%0d got=%h want=%h",base+y*WIDTH+x,memory[base+y*WIDTH+x],tag+(HEIGHT-1-y)*WIDTH+x);
        end
    endtask
    task read_frame(input [1:0] idx,input [31:0] tag);
        integer y,x;
        begin
            old_commit=commit_toggle;
            @(negedge read_clk);read_index=idx;read_req=1;
            wait(read_ack);@(negedge read_clk);read_req=0;
            wait(commit_toggle!=old_commit);
            if(active_index!==idx) $fatal(1,"wrong active frame index");
            repeat(40) @(negedge read_clk);
            for(y=0;y<HEIGHT;y=y+1) begin
                for(x=0;x<WIDTH;x=x+1) begin
                    @(negedge read_clk);read_en=1;
                    @(posedge read_clk);#1;
                    if(read_data !== tag+(HEIGHT-1-y)*WIDTH+x)
                        $fatal(1,"FIFO read mismatch buffer=%0d y=%0d x=%0d got=%h want=%h",idx,y,x,read_data,tag+(HEIGHT-1-y)*WIDTH+x);
                end
                @(negedge read_clk);read_en=0;
                repeat(3) @(negedge read_clk);
            end
            @(negedge read_clk);read_en=0;
        end
    endtask
    initial begin
        for(offset=0;offset<2*N;offset=offset+1) memory[offset]=32'hdeadbeef;
        repeat(8) @(negedge write_clk);rst=0;
        begin_write(0);pixels(32'h1000,N);wait(write_finish);#1;check_memory(0,32'h1000);
        read_frame(0,32'h1000);
        // A partial frame left in the real FIFO must not leak into the next request.
        begin_write(1);pixels(32'hbad00000,4);repeat(30) @(negedge mem_clk);
        if(finishes!=1) $fatal(1,"partial frame falsely completed");
        begin_write(1);pixels(32'h2000,N);wait(write_finish);#1;check_memory(N,32'h2000);
        check_memory(0,32'h1000);read_frame(1,32'h2000);
        // Independent read/write clocks and simultaneous requests to separate buffers.
        fork
            begin begin_write(0);pixels(32'h3000,N);wait(write_finish);end
            begin read_frame(1,32'h2000);end
        join
        #1;check_memory(0,32'h3000);read_frame(0,32'h3000);
        if(finishes!=3 || writes!=3*N) $fatal(1,"transaction accounting mismatch finishes=%0d writes=%0d",finishes,writes);
        $display("PASS tb_%s: real async FIFOs, %0dx%0d, burst=%0d, vertical flip, partial restart, dual-buffer traffic",CASE_NAME,WIDTH,HEIGHT,BURST_SIZE);$finish;
    end
    initial begin #(TIMEOUT_NS);$display("TRACE controller-used=%b length=%d count=%d into=%b",dut.frame_fifo_write_m0.rdusedw,dut.frame_fifo_write_m0.write_len_latch,dut.frame_fifo_write_m0.write_cnt,dut.frame_fifo_write_m0.into_burst);$fatal(1,"frame pipeline watchdog writes=%0d finishes=%0d state=%d used=%d req=%b ack=%b",writes,finishes,dut.frame_fifo_write_m0.state,dut.rdusedw,write_req,write_ack);end
endmodule

module tb_frame_pipeline_full;
    tb_frame_pipeline #(.WIDTH(640),.HEIGHT(480),.BURST_SIZE(256),.PIXEL_GAP(2),
                       .TIMEOUT_NS(200000000),.CASE_NAME("frame_pipeline_full")) full();
endmodule
