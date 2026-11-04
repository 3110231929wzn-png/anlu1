`timescale 1ns/1ps
module tb_bmp_headers;
    reg clk=0,rst=1,scan_start=0,valid=0,done=0;
    reg [7:0] byte_data=0;
    wire req,scan_done;
    wire [2:0] total;
    integer test_case,i;
    always #5 clk=~clk;
    bmp_read dut(.clk(clk),.rst(rst),.ready(),.scan_start(scan_start),
        .scan_start_sector(32'd0),.scan_max_sector(32'd0),.scan_target_count(3'd1),
        .scan_done(scan_done),.scan_found_valid(),.scan_found_sector(),.scan_found_total(total),
        .load_start(1'b0),.load_abort(1'b0),.load_sector(32'd0),.sd_init_done(1'b1),
        .state_code(),.bmp_width(16'd640),.bmp_height(16'd480),.write_req(),.write_req_ack(1'b0),
        .sd_sec_read(req),.sd_sec_read_addr(),.sd_sec_read_data(byte_data),
        .sd_sec_read_data_valid(valid),.sd_sec_read_end(done),.bmp_data_wr_en(),.bmp_data());
    function [7:0] fixture(input integer b);
        begin
            case(b)
                0:fixture=8'h42;1:fixture=8'h4d;
                2:fixture=8'h36;3:fixture=8'h10;4:fixture=8'h0e;
                10:fixture=54;18:fixture=8'h80;19:fixture=2;
                22:fixture=8'he0;23:fixture=1;26:fixture=1;28:fixture=24;
                default:fixture=0;
            endcase
            if(test_case==1 && b==20) fixture=1; // upper width bits must be checked
            if(test_case==2 && b==2) fixture=8'h33; // truncated pixel payload
            if(test_case==3 && b==13) fixture=8'h7f; // offset beyond EOF
            if(test_case==4 && b==26) fixture=0; // invalid color planes
        end
    endfunction
    initial begin
        for(test_case=0;test_case<5;test_case=test_case+1) begin
            rst=1;repeat(3) @(negedge clk);rst=0;
            scan_start=1;@(negedge clk);scan_start=0;wait(req);@(negedge clk);
            for(i=0;i<512;i=i+1) begin valid=1;byte_data=fixture(i);@(negedge clk);end
            valid=0;done=1;@(negedge clk);done=0;wait(scan_done);#1;
            if(total !== (test_case==0 ? 3'd1 : 3'd0))
                $fatal(1,"BMP header case %0d: found=%0d",test_case,total);
        end
        $display("PASS tb_bmp_headers: valid image and four malformed headers");$finish;
    end
    initial begin #100000;$fatal(1,"BMP header watchdog");end
endmodule
