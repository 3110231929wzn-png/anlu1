`timescale 1ns/1ps
module tb_video_axis;
    reg clk=0, rst=1, vs=0, de=0;
    reg [23:0] rgb=0;
    wire user_flag, valid_flag, last_flag;
    wire [23:0] data;
    integer frame_no, row, pixel, run_no;
    always #5 clk=~clk;
    video_rgb_to_axis_640x480 dut(clk,rst,vs,de,rgb,
        user_flag,valid_flag,last_flag,data);

    task beat(input bit in_de, input bit in_vs, input [23:0] in_rgb,
              input bit expected_user, input bit expected_last);
        begin
            @(negedge clk); de=in_de; vs=in_vs; rgb=in_rgb;
            @(posedge clk); #1;
            if (valid_flag !== in_de || data !== in_rgb ||
                user_flag !== expected_user || last_flag !== expected_last)
                $fatal(1,"AXIS mismatch run=%0d frame=%0d row=%0d pixel=%0d valid=%b user=%b last=%b expected_last=%b",
                    run_no,frame_no,row,pixel,valid_flag,user_flag,last_flag,expected_last);
        end
    endtask

    initial begin
        for (run_no=0; run_no<2; run_no=run_no+1) begin
            rst=1; repeat(3) @(negedge clk); rst=0;
            for (frame_no=0; frame_no<2; frame_no=frame_no+1) begin
                beat(0,1,0,0,0); beat(0,1,0,0,0); beat(0,0,0,0,0);
                for (row=0; row<480; row=row+1) begin
                    for (pixel=0; pixel<640; pixel=pixel+1)
                        beat(1,0,{frame_no[3:0],row[9:0],pixel[9:0]},
                             row==0 && pixel==0,pixel==639);
                    beat(0,0,0,0,0); beat(0,0,0,0,0);
                end
            end
        end
        $display("PASS tb_video_axis: four full frames, line markers, SOF, RGB and reset");
        $finish;
    end
    initial begin #20000000; $fatal(1,"video watchdog"); end
endmodule
