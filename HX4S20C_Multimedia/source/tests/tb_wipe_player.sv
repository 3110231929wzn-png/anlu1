`timescale 1ns/1ps
// Real scheduler/BMP parser/writer/read engine/generated FIFOs. Card sectors
// and an ordered 23-cycle SDRAM user endpoint are explicit boundary models.
module tb_wipe_player;
    localparam W=640,H=4,N=W*H;
    reg sc=0,mc=0,vc=0,rst=1,key_next=1,key_auto=1;
    always #5 sc=~sc;
    always #10 mc=~mc;
    always #20 vc=~vc;
    wire wreq,wack,wen,wfin,valid,commit,ren,wen_mem,rack;
    wire [31:0] wdata,wd,pixel;
    wire [20:0] ra,wa;
    wire [3:0] dm;
    wire [1:0] wi,di,ai;
    wire [1:0] osd_page,osd_mode;
    wire [2:0] osd_total;
    wire osd_auto;
    integer osd_page_checks=0;
    reg finish_toggle=0,req=0,pop=0;
    reg [1:0] mode_pin=0;
    reg [31:0] memory[0:2*N-1],pipe_data[0:22];
    reg [22:0] pipe_valid=0;
    integer cycle=0,i,j,frames=0,checked=0,errors=0,protected_cycles=0;
    integer loads=0,queued_tested=0,auto_tested=0,reset_tested=0;
    wire busy=(cycle%997)<17;
    wire refresh=(cycle%1301)<23;
    sd_card_bmp #(.CLK_FREQ_HZ(500000),.SCAN_START_SECTOR(0),.SCAN_MAX_SECTOR(47),.SCAN_TARGET_COUNT(3)) source(
        .clk(sc),.rst(rst),.key_next(key_next),.key_auto(key_auto),.state_code(),
        .bmp_width(16'd640),.bmp_height(16'd4),.display_valid(valid),
        .osd_display_page(osd_page),.osd_image_total(osd_total),.osd_auto_play(osd_auto),
        .write_finish_toggle(finish_toggle),.read_commit_toggle(commit),.read_active_index(ai),
        .write_buf_idx(wi),.disp_buf_idx(di),.write_req(wreq),.write_req_ack(wack),
        .write_en(wen),.write_data(wdata),.SD_nCS(),.SD_DCLK(),.SD_MOSI(),.SD_MISO(1'b1));
    frame_read_write #(.ENABLE_WIPE(1),.FRAME_WIDTH(W),.FRAME_HEIGHT(H)) frames_dut(
        .rst(rst),.mem_clk(mc),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(refresh),.Sdr_busy(busy),
        .App_rd_en(ren),.App_rd_addr(ra),.Sdr_rd_en(pipe_valid[22]),.Sdr_rd_dout(pipe_data[22]),
        .read_clk(vc),.read_req(req),.read_req_ack(rack),.read_finish(),
        .read_commit_toggle(commit),.read_active_index(ai),.osd_transition_mode(osd_mode),
        .read_addr_0(21'd0),.read_addr_1(21'(N)),.read_addr_2(21'd0),.read_addr_3(21'd0),
        .transition_mode(mode_pin),.read_addr_index(di),.read_len(21'(N)),.read_en(pop),.read_data(pixel),
        .App_wr_en(wen_mem),.App_wr_addr(wa),.App_wr_din(wd),.App_wr_dm(dm),
        .write_clk(sc),.write_req(wreq),.write_req_ack(wack),.write_finish(wfin),
        .write_addr_0(21'd0),.write_addr_1(21'(N)),.write_addr_2(21'd0),.write_addr_3(21'd0),
        .write_addr_index(wi),.write_len(21'(N)),.write_en(wen),.write_data(wdata));
    always @(posedge mc) begin
        if(rst) begin pipe_valid<=0;cycle<=0;finish_toggle<=0;end
        else begin
            cycle<=cycle+1;pipe_valid<={pipe_valid[21:0],ren};
            if(ren) begin
                if(ra>=2*N)$fatal(1,"player read range");pipe_data[0]<=memory[ra];
            end
            for(i=1;i<23;i++) pipe_data[i]<=pipe_data[i-1];
            if(wen_mem) begin
                if(wa>=2*N)$fatal(1,"player write range");
                if(valid && (wa/N)==ai)$fatal(1,"write over active old buffer");
                if(source.display_commit_pending)$fatal(1,"write while old/new protected");
                memory[wa]<=wd;
            end
            if(wfin)begin finish_toggle<=~finish_toggle;loads<=loads+1;end
            if(source.display_commit_pending)protected_cycles<=protected_cycles+1;
            if(frames_dut.read_fifo_aclr && pipe_valid[22])$fatal(1,"clear before delayed response");
            if(frames_dut.read_fifo_we && frames_dut.read_buf.full_flag)$fatal(1,"overflow");
        end
    end
    task press_next;
        begin @(negedge sc);key_next=0;repeat(26000)@(negedge sc);key_next=1;repeat(26000)@(negedge sc);end
    endtask
    task toggle_auto;
        begin @(negedge sc);key_auto=0;repeat(26000)@(negedge sc);key_auto=1;repeat(26000)@(negedge sc);end
    endtask
    function [23:0] expected_pixel(input integer image,offset);
        expected_pixel=(24'h100000+image*24'h300000)|offset;
    endfunction
    task consume;
        integer pr,old_image,new_image,k,pix,source_image,mode_expected,ch;
        reg [23:0] old_rgb,new_rgb;
        reg [7:0] chan[0:2];
        reg before_commit;
        reg [23:0] expected_rgb;
        begin
            before_commit=commit;
            @(negedge vc);req=1;wait(rack);repeat(5)@(negedge vc);req=0;
            wait(commit!=before_commit);#1;
            pr=frames_dut.g_wipe.reader.progress;
            // Known sequential image fixtures; final commit already uses new index.
            new_image=source.img_idx;
            old_image=(pr==64 || !frames_dut.g_wipe.reader.wipe_active)?new_image:((new_image+2)%3);
            mode_expected=(loads-2)%4;
            if(frames_dut.g_wipe.reader.wipe_active || pr==64)begin
                if(frames_dut.g_wipe.reader.mode_reg!==2'(mode_expected))
                    $fatal(1,"player mode expected=%0d actual=%0d",mode_expected,frames_dut.g_wipe.reader.mode_reg);
            end else mode_expected=0; // normal image: both sources are identical
            if(pr<64 && frames_dut.g_wipe.reader.wipe_active && osd_page!==2'(old_image))
                $fatal(1,"OSD early page p=%0d expected=%0d actual=%0d",pr,old_image,osd_page);
            if(osd_total!==3 || osd_auto!==source.auto_play_en || osd_mode!==frames_dut.g_wipe.reader.mode_reg)
                $fatal(1,"OSD source status mismatch");
            repeat(320)@(negedge vc);
            if(pr==64 && osd_page!==2'(new_image))$fatal(1,"OSD final page expected=%0d actual=%0d",new_image,osd_page);
            osd_page_checks++;
            for(k=0;k<N;k++)begin
                if(k%W==0)repeat(160)@(negedge vc);
                pop=1;if(frames_dut.read_buf.empty_flag)$fatal(1,"player FIFO underflow pr=%0d i=%0d",pr,k);
                @(posedge vc);#1;
                old_rgb=expected_pixel(old_image,k);new_rgb=expected_pixel(new_image,k);
                case(mode_expected)
                    0:expected_rgb=(k%W<pr*10)?new_rgb:old_rgb;
                    1:expected_rgb=(k/W<pr*480/64)?new_rgb:old_rgb;
                    2:begin
                        if(k%W<640-pr*10)expected_rgb=expected_pixel(old_image,(k/W)*W+k%W+pr*10);
                        else expected_rgb=expected_pixel(new_image,(k/W)*W+k%W-(640-pr*10));
                    end
                    3:begin
                        for(ch=0;ch<3;ch++)chan[ch]=(integer'(old_rgb[ch*8+:8])*(64-pr)+integer'(new_rgb[ch*8+:8])*pr)/64;
                        expected_rgb={chan[2],chan[1],chan[0]};
                    end
                endcase
                checked++;
                if(pixel[31:8]!==expected_rgb)begin errors++;if(errors<8)$display("PLAYER_MISMATCH p=%0d i=%0d expected=%h actual=%h",pr,k,expected_rgb,pixel[31:8]);end
                @(negedge vc);pop=0;
            end
            frames++;
        end
    endtask
    initial begin
        repeat(20)@(negedge sc);rst=0;wait(valid);consume();
        fork
            begin
                press_next();wait(source.display_commit_pending && di==1);
                // Queue another key while the two images are frozen.
                wait(frames_dut.g_wipe.reader.wipe_active);mode_pin=1;
                press_next();queued_tested=1;
            end
            begin
                wait(source.display_commit_pending && di==1);
                while(ai!=1)consume();
            end
        join
        // Pending key must cause one subsequent image load, not overwrite.
        while(source.img_idx!=2 || ai!=di || source.display_commit_pending)consume();
        mode_pin=2;toggle_auto();
        wait(source.img_idx==0 && source.display_commit_pending);auto_tested=1;
        while(ai!=di || source.display_commit_pending)consume();
        mode_pin=3;
        // Keep displaying while autoplay reads the fourth image transaction.
        while(source.img_idx!=1 || ai!=di || source.display_commit_pending)consume();
        toggle_auto(); // stop autoplay before the reset check
        @(negedge vc);req=1;wait(rack);@(negedge vc);req=0;
        wait(ren);repeat(4)@(negedge mc);rst=1;req=0;pop=0;reset_tested=1;
        repeat(20)@(negedge mc);rst=0;wait(valid);consume();
        if(errors || !protected_cycles || !queued_tested || !auto_tested || !reset_tested)
            $fatal(1,"player result errors=%0d",errors);
        $display("OSD_DISPLAY_CONFIRM_CHECKS=%0d",osd_page_checks);
        $display("PASS tb_wipe_player: pixels=%0d frames=%0d loads=%0d protected_cycles=%0d modes=0,1,2,3 queued_key=1 auto=1 reset=1 errors=0",checked,frames,loads,protected_cycles);
        $finish;
    end
    initial begin #100000000.0;$fatal(1,"player watchdog image=%0d active=%0d target=%0d pending=%b",source.img_idx,ai,di,source.display_commit_pending);end
endmodule

module sd_card_top(input clk,rst,abort_req,output SD_nCS,SD_DCLK,SD_MOSI,input SD_MISO,
    output reg sd_init_done,input sd_sec_read,input [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data,output reg sd_sec_read_data_valid,sd_sec_read_end,
    input sd_sec_write,input [31:0] sd_sec_write_addr,input [7:0] sd_sec_write_data,
    output sd_sec_write_data_req,sd_sec_write_end);
    // Production high-speed DIV=1: at least 8*((1+2)*2)=48 SD clocks/byte.
    // Source throughput is therefore not one byte/clock as in the deliberate
    // overdrive run retained in stage2/player_initial evidence.
    reg active;integer offset,pace;reg [31:0] sector;
    assign SD_nCS=1;assign SD_DCLK=0;assign SD_MOSI=1;
    assign sd_sec_write_data_req=0;assign sd_sec_write_end=0;
    function [7:0] fixture(input integer absolute_byte);
        integer image,b,pixel_index,visible_offset;reg [23:0] rgb;
        begin
            image=absolute_byte/8192;b=absolute_byte%8192;
            pixel_index=(b-54)/3;
            visible_offset=(3-pixel_index/640)*640+pixel_index%640;
            rgb=(24'h100000+image*24'h300000)|visible_offset;
            case(b)
                0:fixture=8'h42;1:fixture=8'h4d;2:fixture=8'h36;3:fixture=8'h1e;
                10:fixture=54;18:fixture=8'h80;19:fixture=2;22:fixture=4;
                26:fixture=1;28:fixture=24;
                default:begin
                    if(b>=54 && b<7734)case((b-54)%3)
                        0:fixture=rgb[7:0];1:fixture=rgb[15:8];2:fixture=rgb[23:16];endcase
                    else fixture=0;
                end
            endcase
        end
    endfunction
    always @(posedge clk)begin
        sd_sec_read_data_valid<=0;sd_sec_read_end<=0;
        if(rst)begin sd_init_done<=0;active<=0;offset<=0;pace<=0;sector<=0;sd_sec_read_data<=0;end
        else begin
            sd_init_done<=1;
            if(abort_req)active<=0;
            else if(active && pace!=0)pace<=pace-1;
            else if(active)begin
                if(offset==512)begin active<=0;sd_sec_read_end<=1;end
                else begin sd_sec_read_data_valid<=1;sd_sec_read_data<=fixture(sector*512+offset);offset<=offset+1;pace<=47;end
            end else if(sd_sec_read && !sd_sec_read_end)begin active<=1;offset<=0;pace<=0;sector<=sd_sec_read_addr;end
        end
    end
endmodule
