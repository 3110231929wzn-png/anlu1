`timescale 1ns/1ps
// Sector-level card model: the real BMP reader and scheduler are under test.
module sd_card_top(input clk,rst,abort_req,output SD_nCS,SD_DCLK,SD_MOSI,input SD_MISO,
    output reg sd_init_done, input sd_sec_read,input [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data,output reg sd_sec_read_data_valid,sd_sec_read_end,
    input sd_sec_write,input [31:0] sd_sec_write_addr,input [7:0] sd_sec_write_data,
    output sd_sec_write_data_req,sd_sec_write_end);
    reg active; reg stall=0; integer offset;
    assign SD_nCS=1;assign SD_DCLK=0;assign SD_MOSI=1;
    assign sd_sec_write_data_req=0;assign sd_sec_write_end=0;
    function [7:0] fixture(input integer b);
        case(b)
            0:fixture=8'h42;1:fixture=8'h4d;2:fixture=66;10:fixture=54;
            18:fixture=4;22:fixture=1;26:fixture=1;28:fixture=24;
            54:fixture=8'h11;55:fixture=8'h22;56:fixture=8'h33;
            57:fixture=8'h44;58:fixture=8'h55;59:fixture=8'h66;
            default:fixture=0;
        endcase
    endfunction
    always @(posedge clk) begin
        sd_sec_read_data_valid<=0;sd_sec_read_end<=0;
        if(rst) begin
            sd_init_done<=0;active<=0;offset<=0;sd_sec_read_data<=0;
        end else begin
            sd_init_done<=1;
            if(abort_req) active<=0;
            else if(active && !stall) begin
                if(offset==512) begin active<=0;sd_sec_read_end<=1;end
                else begin sd_sec_read_data_valid<=1;sd_sec_read_data<=fixture(offset);offset<=offset+1;end
            end else if(!active && sd_sec_read && !sd_sec_read_end) begin active<=1;offset<=0;end
        end
    end
endmodule

