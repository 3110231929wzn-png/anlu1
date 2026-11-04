`timescale 1ns/1ps
module tb_e3_rescan_ownership;
reg clk=0,rst=1,ready=1,done=0,found=0,wreq=0,keypulse=0;
reg [31:0] sector=0;
reg [1:0] active_buf=0;
reg commit=0,finish=0;
wire [2:0] page;wire [3:0] total;
always #5 clk=~clk;
sd_card_bmp #(.CLK_FREQ_HZ(100000000)) dut(
 .clk(clk),.rst(rst),.key_next(1'b1),.key_auto(1'b1),.enable_e3(1'b0),
 .write_finish_toggle(finish),.read_commit_toggle(commit),.read_active_index(active_buf),
 .write_req_ack(1'b0),.SD_MISO(1'b1),.osd_display_page(page),.osd_image_total(total));
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task complete_load(input integer expected);
begin
 if(!dut.load_busy || dut.load_idx!==3'(expected) || dut.load_sector!==32'(100+expected))
   $fatal(1,"load index/sector expected=%0d got=%0d sector=%0d",expected,dut.load_idx,dut.load_sector);
 ready=0;wreq=1;tick();tick();wreq=0;tick();tick();
 ready=1;tick();tick();finish=~finish;repeat(6)tick();
 if(!dut.display_commit_pending || dut.img_idx!==3'(expected))$fatal(1,"write commit");
 active_buf=dut.disp_buf_idx;commit=~commit;repeat(6)tick();
 if(dut.display_commit_pending || page!==3'(expected))$fatal(1,"display commit/page");
end endtask
integer i,c,k;
initial begin
 force dut.sd_init_done=1'b1;
 force dut.bmp_ready=ready;
 force dut.scan_done=done;
 force dut.scan_found_valid=found;
 force dut.scan_found_sector=sector;
 force dut.write_req=wreq;
 force dut.key_next_press=keypulse;
 repeat(4)tick();rst=0;repeat(4)tick();
 // Exercise the real RTL next-index function for every legal count/current.
 for(c=0;c<=8;c=c+1)for(i=0;i<8;i=i+1)begin
   k=(c<=1 || i+1>=c)?0:i+1;
   if(dut.next_index_limited(3'(i),4'(c))!==3'(k))$fatal(1,"index c=%0d i=%0d",c,i);
 end
 for(i=0;i<8;i=i+1)begin found=1;sector=100+i;tick();end
 found=0;done=1;tick();complete_load(0);
 for(i=1;i<=8;i=i+1)begin
   keypulse=1;tick();keypulse=0;tick();complete_load(i%8);
 end
 if(total!==8)$fatal(1,"eight total");
 // Queued adaptive request cannot change the active path during a load.
 keypulse=1;tick();keypulse=0;tick();
 ready=0;wreq=1;
 force dut.e3_stable=1'b1;repeat(4)tick();
 if(dut.e3_active!==0 || !dut.e3_mode_pending)$fatal(1,"mode changed while loading");
 wreq=0;repeat(2)tick();ready=1;repeat(2)tick();finish=~finish;repeat(6)tick();
 if(dut.e3_active!==0 || !dut.display_commit_pending)$fatal(1,"mode changed before display commit");
 active_buf=dut.disp_buf_idx;commit=~commit;repeat(10)tick();
 if(dut.e3_active!==1 || dut.img_found_count!==0 || !dut.scan_kicked)
   $fatal(1,"pending mode not applied/rescanned");
 done=0;
 if(!dut.display_valid || dut.disp_buf_idx!==active_buf)$fatal(1,"RESCAN LOST DISPLAY");
 found=1;sector=100;tick();sector=101;tick();found=0;done=1;tick();
 if(dut.write_buf_idx===active_buf)$fatal(1,"ON WRITE LIVE BUFFER");
 complete_load(0);
 keypulse=1;tick();keypulse=0;tick();ready=0;wreq=1;
 force dut.e3_stable=1'b0;repeat(4)tick();
 if(dut.e3_active!==1)$fatal(1,"OFF MID LOAD");
 wreq=0;repeat(2)tick();ready=1;repeat(2)tick();finish=~finish;repeat(6)tick();
 if(dut.e3_active!==1)$fatal(1,"OFF BEFORE COMMIT");
 active_buf=dut.disp_buf_idx;commit=~commit;repeat(10)tick();done=0;
 if(dut.e3_active!==0 || !dut.display_valid || dut.disp_buf_idx!==active_buf)$fatal(1,"OFF LOST DISPLAY");
 found=1;sector=100;tick();sector=101;tick();found=0;done=1;tick();
 if(dut.write_buf_idx===active_buf)$fatal(1,"OFF WRITE LIVE BUFFER");
 complete_load(0);
 rst=1;repeat(4)tick();if(dut.display_valid!==0)$fatal(1,"RESET VALID");
 done=0;rst=0;repeat(4)tick();found=1;sector=100;tick();found=0;done=1;tick();complete_load(0);
 $display("PASS control-only OFF ON OFF, pending load+commit, rescan hold, alternate buffer, reset recovery. PIXELS/REAL READER NOT VERIFIED");
 $finish;
end
initial begin #100000;$fatal(1,"controller watchdog");end
endmodule
