`timescale 1ns/1ps
// Sector-interface card model for the E3 chain test.
//
// REUSE of the previously-passing model tests/support/sd_card_top_model.sv:
// the module name, port list, handshake and streaming timing (512 bytes per
// sector at one byte per clk, sd_sec_read_end pulse, abort_req/stall
// behaviour) are copied verbatim. Only the data source differs: the original
// hard-coded 4x1 fixture is rejected by the E3 size window (SRC_W_MIN=120),
// so this variant streams a synthetic BMP disk image computed on the fly:
//   image A: 1280x720 24bpp, file starts at sector 1  (5401 sectors)
//   image B:  800x600 24bpp, file starts at sector 5410 (2813 sectors)
// sd_init_done is raised after INIT_DELAY_CYCLES to mimic real card init
// latency and let the E3 mode switch settle before the first scan.
// BYTE_GAP: clocks between streamed bytes on sd_sec_read_data (byte period
// = BYTE_GAP wc clks, valid for 1 clk). Set to the REAL RTL byte interval,
// derived from the product SPI engine (sd_card_top.v + spi_master.v +
// sd_card_cmd.v), wc = 100 MHz, SPI_HIGH_SPEED_DIV = 1:
//   SPI bit clock = 100 MHz / ((1+2)*2) = 16.667 MHz (see sd_card_top.v header)
//   bit time      = 6 wc clks  -> 8 bits                    = 48 clks
//   spi_master per byte: LAST_HALF_CYCLE (~2-3) + ACK (1) + ACK_WAIT (1) ~ 5
//   sd_card_cmd S_READ per-byte wr_req re-arm                       ~ 2-3
//   total                                                           ~ 56
// => 1 byte / 56 clks = 1.79 MB/s. (The old default 32 = 3.125 MB/s was
// derived from a 25 MHz theoretical ceiling that the RTL does not use and
// was 1.75x faster than the real interface; the old 3 = 33 MB/s was proven
// to overflow the write FIFO and is stimulus-only.)
module sd_card_top #(parameter integer INIT_DELAY_CYCLES = 1_300_000,
                     parameter integer BYTE_GAP = 56)(
    input clk,rst,abort_req,output SD_nCS,SD_DCLK,SD_MOSI,input SD_MISO,
    output reg sd_init_done, input sd_sec_read,input [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data,output reg sd_sec_read_data_valid,sd_sec_read_end,
    input sd_sec_write,input [31:0] sd_sec_write_addr,input [7:0] sd_sec_write_data,
    output sd_sec_write_data_req,sd_sec_write_end);
    reg active; reg stall=0; integer offset; integer init_cnt=0; integer gap_cnt=0;
    assign SD_nCS=1;assign SD_DCLK=0;assign SD_MOSI=1;
    assign sd_sec_write_data_req=0;assign sd_sec_write_end=0;
    localparam A_SEC0 = 1,      A_W = 640, A_H = 480;
    localparam B_SEC0 = 1810,   B_W = 640,  B_H = 480;
    localparam A_SECTORS = (54 + A_H*((3*A_W+3)/4*4) + 511)/512; // 5401
    localparam B_SECTORS = (54 + B_H*((3*B_W+3)/4*4) + 511)/512; // 2813

    // RGB content of the two synthetic images (deterministic, cheap to model)
    function [7:0] img_r(input integer is_b, x, y);
        img_r = is_b ? (y & 255) : (x & 255);
    endfunction
    function [7:0] img_g(input integer is_b, x, y);
        img_g = is_b ? (x & 255) : (y & 255);
    endfunction
    function [7:0] img_b(input integer is_b, x, y);
        img_b = is_b ? ((x+y) & 255) : ((x^y) & 255);
    endfunction

    // byte at file offset o of image (w,h)
    function [7:0] file_byte(input integer is_b, o, w, h);
        integer rowsz,r,c,k,x,y;
        begin
            rowsz = (3*w+3)/4*4;
            if (o < 54) begin
                file_byte = 8'h00;
                case (o)
                    0: file_byte = 8'h42; 1: file_byte = 8'h4d;
                    2,3,4,5: file_byte = (54 + h*rowsz) >> ((o-2)*8);
                    10,11,12,13: file_byte = 54 >> ((o-10)*8);
                    14,15,16,17: file_byte = 40 >> ((o-14)*8);
                    18,19,20,21: file_byte = w >> ((o-18)*8);
                    22,23,24,25: file_byte = h >> ((o-22)*8);
                    26: file_byte = 1;         // biPlanes  = 1 (LSB, MSB=0)
                    28: file_byte = 24;        // biBitCount = 24 (LSB, MSB=0)
                endcase
            end else begin
                o = o - 54;
                r = o / rowsz;                 // row index from bottom
                c = (o % rowsz) / 3;
                k = (o % rowsz) % 3;
                if (c < w) begin
                    x = c; y = h - 1 - r;
                    case (k)
                        0: file_byte = img_b(is_b, x, y); // B first (BMP order)
                        1: file_byte = img_g(is_b, x, y);
                        default: file_byte = img_r(is_b, x, y);
                    endcase
                end else file_byte = 8'h00;    // row padding
            end
        end
    endfunction

    function [7:0] disk_byte(input integer sec, b);
        begin
            if (sec >= A_SEC0 && sec < A_SEC0+A_SECTORS)
                disk_byte = file_byte(0,(sec-A_SEC0)*512+b, A_W, A_H);
            else if (sec >= B_SEC0 && sec < B_SEC0+B_SECTORS)
                disk_byte = file_byte(1,(sec-B_SEC0)*512+b, B_W, B_H);
            else disk_byte = 8'h00;
        end
    endfunction

    always @(posedge clk) begin
        sd_sec_read_data_valid<=0;sd_sec_read_end<=0;
        if(rst) begin
            sd_init_done<=0;active<=0;offset<=0;sd_sec_read_data<=0;init_cnt<=0;gap_cnt<=0;
        end else begin
            if (!sd_init_done) begin
                init_cnt <= init_cnt + 1;
                if (init_cnt >= INIT_DELAY_CYCLES) sd_init_done <= 1;
            end
            if(abort_req) active<=0;
            else if(active && !stall) begin
                if(offset==512) begin active<=0;sd_sec_read_end<=1;end
                else if(gap_cnt != 0) begin gap_cnt <= gap_cnt - 1; end
                else begin
                    sd_sec_read_data_valid<=1;sd_sec_read_data<=disk_byte(sd_sec_read_addr,offset);offset<=offset+1;
                    gap_cnt <= BYTE_GAP - 1;
                end
            end else if(!active && sd_sec_read && !sd_sec_read_end) begin active<=1;offset<=0;gap_cnt<=0;end
        end
    end
endmodule
