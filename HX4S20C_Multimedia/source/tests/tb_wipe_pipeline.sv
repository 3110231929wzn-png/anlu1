`timescale 1ns/1ps
// Actual frame wrapper/FIFO, encrypted SDR controller, diagnostic SDR device.
// Device model is not a timing-qualified physical chip; no hardware claim.
module tb_wipe_pipeline #(parameter HEIGHT=4,parameter DIRECTIONS=2,parameter MODE=0,parameter SAMPLES_ONLY=0);
    localparam WIDTH=640,N=WIDTH*HEIGHT;
    reg mc=0,vc=0,wc=0,rst=1;
    always #10 mc=~mc;
    always #20 vc=~vc;
    always #5 wc=~wc;
    wire shifted;
    assign #9 shifted=mc; // 162/360 * 20ns, matching the existing V3 PLL
    wire init,refresh,busy,rv,re,we,ack,commit;
    wire [20:0] ra,wa;
    wire [31:0] data,pixel,wd;
    wire [3:0] dm;
    wire [1:0] active;
    reg req=0,pop=0;
    reg [1:0] mode_pin=MODE;
    reg forced_busy=0,forced_refresh=0,previous_read=0;
    reg wreq=0,wen=0;
    reg [1:0] wi=0;
    reg [31:0] wdata=0;
    wire wack,wfinish;
    reg [1:0] target=0;
    integer i,f,direction,p,expected_index,errors=0,checked=0,refresh_seen=0;
    integer old_source,new_source,progress_before;
    reg [23:0] expected;

    sdram sd(.Clk(mc),.Clk_sft(shifted),.Rst(rst),.Sdr_init_done(init),
        .Sdr_init_ref_vld(refresh),.Sdr_busy(busy),.App_wr_en(we),.App_wr_addr(wa),
        .App_wr_dm(dm),.App_wr_din(wd),.App_rd_en(re),.App_rd_addr(ra),
        .Sdr_rd_en(rv),.Sdr_rd_dout(data));
    defparam sd.sdram.READ_DELAY_NS=5.4;
    frame_read_write #(.ENABLE_WIPE(1),.FRAME_WIDTH(WIDTH),.FRAME_HEIGHT(HEIGHT)) frames(
        .rst(rst),.mem_clk(mc),.Sdr_init_done(init),.Sdr_init_ref_vld(refresh|forced_refresh),.Sdr_busy(busy|forced_busy),
        .App_rd_en(re),.App_rd_addr(ra),.Sdr_rd_en(rv),.Sdr_rd_dout(data),
        .read_clk(vc),.read_req(req),.read_req_ack(ack),.read_finish(),
        .read_commit_toggle(commit),.read_active_index(active),
        .read_addr_0(21'd0),.read_addr_1(21'(N)),.read_addr_2(21'd0),.read_addr_3(21'd0),
        .transition_mode(mode_pin),.read_addr_index(target),.read_len(21'(N)),.read_en(pop),.read_data(pixel),
        .App_wr_en(we),.App_wr_addr(wa),.App_wr_din(wd),.App_wr_dm(dm),
        .write_clk(wc),.write_req(wreq),.write_req_ack(wack),.write_finish(wfinish),
        .write_addr_0(21'd0),.write_addr_1(21'(N)),.write_addr_2(21'd0),.write_addr_3(21'd0),
        .write_addr_index(wi),.write_len(21'(N)),.write_en(wen),.write_data(wdata));

    function [23:0] pattern(input integer source,input integer offset);
        pattern=(source?24'h800000:24'h100000)|offset;
    endfunction
    task produce(input integer source,input integer gap);
        integer j,flipped;
        begin
            wi=source;
            @(negedge wc);wreq=1;wait(wack);repeat(2)@(negedge wc);wreq=0;
            wait(!wack);repeat(8)@(negedge wc);
            for(j=0;j<N;j++) begin
                flipped=(HEIGHT-1-j/WIDTH)*WIDTH+j%WIDTH;
                @(negedge wc);wen=1;wdata={pattern(source,flipped),8'd0};
                @(negedge wc);wen=0;repeat(gap-2)@(negedge wc);
            end
            wait(wfinish);repeat(100)@(negedge mc);
        end
    endtask
    always @(posedge mc) if(!rst) begin
        previous_read<=re;
        if(re && !previous_read && (busy || refresh || forced_busy || forced_refresh))
            $fatal(1,"new burst starts while busy or refresh");
        if(refresh) refresh_seen++;
        if(re && (ra>=2*N)) $fatal(1,"read address out of the two frames: %0d",ra);
        if(frames.read_fifo_aclr && rv) $fatal(1,"FIFO reset before outstanding read drained");
        if(frames.read_fifo_we && frames.read_buf.full_flag) $fatal(1,"read FIFO overflow");
    end

    task frame(input integer old_s,new_s,pr);
        reg before_commit;
        integer j,col,row,sx,ch;
        reg [23:0] old_p,new_p;
        reg [7:0] chan[0:2];
        begin
            before_commit=commit;
            if(pr==0)mode_pin=MODE;
            else mode_pin=(MODE+1)%4; // moving switches must not alter this transition
            // Full-frame sample acceleration only: prior frame fully consumed;
            // small tests exercise every real 0..64 handshake without deposits.
            if(SAMPLES_ONLY && pr>0)frames.g_wipe.reader.progress=pr-1;
            if(pr==0)begin forced_busy=1;forced_refresh=1;end
            @(negedge vc);req=1;wait(ack);
            // Deliberately hold the request after ACK: progress must advance once.
            repeat(7)@(negedge vc);
            req=0;wait(commit!=before_commit);#1;
            if(frames.g_wipe.reader.progress!=pr)
                $fatal(1,"progress expected=%0d actual=%0d",pr,frames.g_wipe.reader.progress);
            if(active!==(pr==64?2'(new_s):2'(old_s)))
                $fatal(1,"premature or missing buffer release p=%0d active=%0d",pr,active);
            if(pr==0)begin
                repeat(40)begin @(negedge mc);if(re)$fatal(1,"refresh/busy not respected");end
                forced_refresh=0;
                repeat(10)begin @(negedge mc);if(re)$fatal(1,"busy release not respected");end
                forced_busy=0;
            end
            if(old_s!=new_s && frames.g_wipe.reader.mode_reg!==2'(MODE))
                $fatal(1,"mode latch expected=%0d actual=%0d",MODE,frames.g_wipe.reader.mode_reg);
            repeat(160)@(negedge vc); // vertical prefetch/blanking
            for(j=0;j<N;j++) begin
                col=j%WIDTH;row=j/WIDTH;
                if(col==0) repeat(160)@(negedge vc); // horizontal blanking
                pop=1;
                if(frames.read_buf.empty_flag) $fatal(1,"read FIFO underflow p=%0d pixel=%0d",pr,j);
                @(posedge vc);#1;
                old_p=pattern(old_s,j);new_p=pattern(new_s,j);
                case(MODE)
                    0:expected=(col<pr*10)?new_p:old_p;
                    1:expected=(row<(pr*480/64))?new_p:old_p;
                    2:begin
                        if(col<640-pr*10)expected=pattern(old_s,row*640+col+pr*10);
                        else expected=pattern(new_s,row*640+col-(640-pr*10));
                    end
                    3:begin
                        for(ch=0;ch<3;ch++)chan[ch]=(integer'(old_p[ch*8+:8])*(64-pr)+integer'(new_p[ch*8+:8])*pr)/64;
                        expected={chan[2],chan[1],chan[0]};
                    end
                endcase
                checked++;
                if(pixel[31:8]!==expected) begin
                    errors++;if(errors<10)$display("MISMATCH p=%0d xy=%0d,%0d expected=%h actual=%h",pr,col,row,expected,pixel[31:8]);
                end
                @(negedge vc);pop=0;
            end
            $display("FRAME_RESULT target=%0d p=%0d checked=%0d cumulative_errors=%0d",target,pr,N,errors);
        end
    endtask
    initial begin
        repeat(20)@(negedge mc);rst=0;wait(init);
        // Populate through the real writer: controller physical address packing
        // is not the diagnostic model's raw memory-array index.
        produce(0,4);produce(1,4);
        frame(0,0,0);
        for(direction=0;direction<DIRECTIONS;direction++) begin
            target=1-direction;
            if(SAMPLES_ONLY)begin
                frame(direction,1-direction,0);frame(direction,1-direction,1);
                frame(direction,1-direction,32);frame(direction,1-direction,63);frame(direction,1-direction,64);
            end else for(p=0;p<=64;p++)frame(direction,1-direction,p);
        end
        // Production SPI ceiling is one pixel per >=144 SD clocks. Exercise
        // the actual encrypted controller's concurrent writer/read arbitration.
        if(HEIGHT==4 && MODE==0 && !SAMPLES_ONLY) begin : concurrent_traffic
            reg finished;
            integer display_source;
            display_source=active;target=active;finished=0;
            fork
                begin produce(1-display_source,144);finished=1;end
                begin while(!finished)frame(display_source,display_source,0);end
            join
            $display("CONCURRENT_REAL_CONTROLLER writer_pixel_gap=144 errors=%0d",errors);
        end
        // Reset during an outstanding physical read, then reacquire image 0.
        target=1-active;@(negedge vc);req=1;wait(ack);@(negedge vc);req=0;
        wait(re);repeat(4)@(negedge mc);rst=1;req=0;pop=0;
        repeat(20)@(negedge mc);rst=0;target=0;wait(init);
        frame(0,0,0);
        if(errors || !refresh_seen)$fatal(1,"wipe result errors=%0d refresh_cycles=%0d",errors,refresh_seen);
        $display("PASS tb_wipe_pipeline: checked=%0d errors=0 refresh_cycles=%0d directions=%0d mode=%0d; actual encrypted controller/FIFO, held requests, reset",checked,refresh_seen,DIRECTIONS,MODE);
        $finish;
    end
    initial begin #4000000000.0;$fatal(1,"wipe watchdog");end
endmodule
