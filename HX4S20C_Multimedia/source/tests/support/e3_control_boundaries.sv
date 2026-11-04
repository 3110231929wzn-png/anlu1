// Interface-only boundary models; actual controller RTL is under test.
module bmp_read(
    input                       clk,
    input                       rst,
    // E3 kill switch (SW4=C5). 1 = adaptive: accept any 24bpp BMP inside the
    // supported size window and let bmp_scaler fit it. 0 = legacy: accept
    // 640x480 only, exactly the pre-E3 behaviour (scaler bypassed upstream).
    input                       enable_e3,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [3:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [3:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input                       load_abort,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,

    // E3: accept any 24bpp uncompressed BMP within the supported size window
    output reg                  info_valid,               // 1-clk pulse: header accepted, size latched
    output reg [10:0]           src_width,                // BMP header width  (pixels)
    output reg [10:0]           src_height,               // BMP header height (pixels, positive only)
    output reg [10:0]           px_x,                     // source pixel column of the strobed pixel
    output reg [10:0]           px_y,                     // source pixel row    of the strobed pixel

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data
);
endmodule
module bmp_scaler #(
    parameter integer OUT_W   = 640,
    parameter integer OUT_H   = 480,
    parameter integer SRC_MAX = 1024   // keep equal to bmp_read.v SRC_W_MAX
)(
    input                       clk,
    input                       rst,
    input                       load_start,   // new image starts: full reset
    input                       info_valid,   // 1-clk pulse: W/H valid
    input  [10:0]               src_w,
    input  [10:0]               src_h,
    input                       px_valid,
    input  [23:0]               px_data,
    input  [10:0]               px_x,
    input  [10:0]               px_y,
    output reg                  out_valid,
    output reg [23:0]           out_data
);
endmodule
module sd_card_top
#(
	parameter  SPI_LOW_SPEED_DIV = 248,         // SD card low speed mode frequency division parameter,spi clk speed = clk speed /((SPI_LOW_SPEED_DIV + 2) * 2 )
	parameter  SPI_HIGH_SPEED_DIV = 1           // SD card high speed mode frequency division parameter,spi clk speed = clk speed /((SPI_HIGH_SPEED_DIV + 2) * 2 )
)
(
	input            clk,
	input            rst,
    input            abort_req,
	output           SD_nCS,                    //SD card chip select (SPI mode)
	output           SD_DCLK,                   //SD card clock
	output           SD_MOSI,                   //SD card controller data output
	input            SD_MISO,                   //SD card controller data input
	output           sd_init_done,              //SD card initialization is complete
	input            sd_sec_read,               //SD card sector read
	input[31:0]      sd_sec_read_addr,          //SD card sector read address
	output[7:0]      sd_sec_read_data,          //SD card sector read data
	output           sd_sec_read_data_valid,    //SD card sector read data valid
	output           sd_sec_read_end,           //SD card sector read end
	input            sd_sec_write,              //SD card sector write
	input[31:0]      sd_sec_write_addr,         //SD card sector write address
	input[7:0]       sd_sec_write_data,         //SD card sector write data
	output           sd_sec_write_data_req,     //SD card sector write data next clock is valid
	output           sd_sec_write_end           //SD card sector write end
);
endmodule
