`timescale 1ns/1ps
module tb_sd_abort;
    reg clk=0,rst=1,abort_req=0,read_req=0,cmd_ack=0,cmd_error=0,block_ack=0;
    wire init_done,read_end,cmd_req,block_req;
    wire [47:0] cmd;
    wire [7:0] r1;
    always #5 clk=~clk;
    sd_card_sec_read_write dut(.clk(clk),.rst(rst),.abort_req(abort_req),
        .sd_init_done(init_done),.sd_sec_read(read_req),.sd_sec_read_addr(32'd123),
        .sd_sec_read_data(),.sd_sec_read_data_valid(),.sd_sec_read_end(read_end),
        .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),
        .sd_sec_write_data_req(),.sd_sec_write_end(),.spi_clk_div(),
        .cmd_req(cmd_req),.cmd_req_ack(cmd_ack),.cmd_req_error(cmd_error),
        .cmd(cmd),.cmd_r1(r1),.cmd_data_len(),.block_read_req(block_req),
        .block_read_valid(1'b0),.block_read_data(8'd0),.block_read_req_ack(block_ack),
        .block_write_req(),.block_write_data(),.block_write_data_rd(1'b0),.block_write_req_ack(1'b0));
    task reply(input [7:0] command_number);
        begin
            wait(cmd_req); if(cmd[47:40]!==command_number) $fatal(1,"unexpected command %0d",cmd[47:40]);
            @(negedge clk);cmd_ack=1;@(negedge clk);cmd_ack=0;repeat(2) @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        reply(0);reply(8);reply(55);reply(41);reply(16);
        if(!init_done) $fatal(1,"initialization fixture failed");
        read_req=1;reply(17);wait(block_req);
        // Card never returns a data token. An abort must return to command-ready.
        read_req=0;abort_req=1;@(negedge clk);abort_req=0;repeat(2) @(negedge clk);
        if(!init_done || block_req || cmd_req) $fatal(1,"abort did not preserve initialized idle state");
        read_req=1;reply(17);read_req=0;wait(block_req);
        block_ack=1;@(negedge clk);block_ack=0;
        if(!read_end) $fatal(1,"retry never completed");
        $display("PASS tb_sd_abort: stalled block abort and new CMD17 completion");$finish;
    end
    initial begin #20000;$fatal(1,"SD abort watchdog");end
endmodule
