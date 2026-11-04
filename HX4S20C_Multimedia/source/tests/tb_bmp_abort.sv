`timescale 1ns/1ps
module tb_bmp_abort;
    reg clk=0,rst=1,scan_start=0,load_start=0,load_abort=0,init_done=0;
    reg ack=0,byte_valid=0,sector_end=0;
    reg [7:0] byte_data=0;
    wire ready,scan_done,found_valid,write_req,read_req,pixel_valid;
    wire [31:0] found_sector,read_addr;
    wire [2:0] found_total;
    wire [3:0] state_code;
    wire [23:0] pixel;
    integer i;
    always #5 clk=~clk;
    bmp_read dut(.clk(clk),.rst(rst),.ready(ready),
        .scan_start(scan_start),.scan_start_sector(32'd10),.scan_max_sector(32'd10),
        .scan_target_count(3'd1),.scan_done(scan_done),.scan_found_valid(found_valid),
        .scan_found_sector(found_sector),.scan_found_total(found_total),
        .load_start(load_start),.load_abort(load_abort),.load_sector(32'd10),
        .sd_init_done(init_done),.state_code(state_code),.bmp_width(16'd640),.bmp_height(16'd480),
        .write_req(write_req),.write_req_ack(ack),.sd_sec_read(read_req),.sd_sec_read_addr(read_addr),
        .sd_sec_read_data(byte_data),.sd_sec_read_data_valid(byte_valid),.sd_sec_read_end(sector_end),
        .bmp_data_wr_en(pixel_valid),.bmp_data(pixel));

    function [7:0] fixture_byte(input integer offset);
        case(offset)
            0:fixture_byte=8'h42; 1:fixture_byte=8'h4d;
            2:fixture_byte=8'h36; 3:fixture_byte=8'h10; 4:fixture_byte=8'h0e;
            10:fixture_byte=54;
            18:fixture_byte=8'h80;19:fixture_byte=8'h02;
            22:fixture_byte=8'he0;23:fixture_byte=8'h01;
            26:fixture_byte=1;28:fixture_byte=24;
            default:fixture_byte=0;
        endcase
    endfunction
    task header_sector;
        begin
            wait(read_req); @(negedge clk);
            for(i=0;i<512;i=i+1) begin
                byte_valid=1; byte_data=fixture_byte(i); @(negedge clk);
            end
            byte_valid=0; sector_end=1; @(negedge clk); sector_end=0;
            repeat(3) @(negedge clk);
        end
    endtask
    task start_load;
        begin
            @(negedge clk);load_start=1;@(negedge clk);load_start=0;
            header_sector();
            if(!write_req) $fatal(1,"load failed to request frame write");
            ack=1;wait(!write_req);@(negedge clk);ack=0;
            wait(read_req);repeat(2) @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;init_done=1;
        @(negedge clk);scan_start=1;@(negedge clk);scan_start=0;
        header_sector();
        if(!scan_done || found_total!=1 || found_sector!=10) $fatal(1,"scan fixture failed");
        start_load();
        @(negedge clk);load_abort=1;@(negedge clk);load_abort=0;
        repeat(2) @(negedge clk);
        if(!ready || !scan_done || found_total!=1)
            $fatal(1,"load abort lost reusable media index: ready=%b scan_done=%b total=%d",ready,scan_done,found_total);
        start_load();
        if(!read_req) $fatal(1,"retry did not resume sector reads");
        // Media loss must still invalidate the directory, unlike a load timeout.
        init_done=0;repeat(3) @(negedge clk);
        if(scan_done || found_total!=0 || write_req || read_req)
            $fatal(1,"media loss did not clear scan/index and requests");
        $display("PASS tb_bmp_abort: scan, abort, retry and media loss");$finish;
    end
    initial begin #100000; $fatal(1,"BMP watchdog"); end
endmodule
