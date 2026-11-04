//=============================================================================
//  osd_overlay.v : 视频 OSD 叠加（赛题扩展要求 E1：图层叠加与字幕效果）
//  Derived from junior OSD package; V3 E1 edits are maintained here.
//  Do not run the old generator over this file: it lacks E1 fixes/status.
//
//  在 640x480@60 的 RGB 像素流上做 6 层叠加（自底向上）：
//    1) 顶部标题条  半透明底带，50% Alpha 混合
//    2) 图片标题    "安路科技演示"，24x24 中文点阵，白字固定居中
//    3) 底部信息条  半透明底带，50% Alpha 混合
//    4) 滚动字幕    淡青色，每帧左移 1 像素（像素级平滑滚动）
//    5) 信息行      页码 / 自动轮播状态 / 上电时间戳（BMP 编号、模式、mm:ss）
//    6) 页码指示条  右上角图形层，1~4 根柱状条，点亮 50% / 未点亮 25% 两级 Alpha
//
//  纯组合叠加，不用行缓存、也不延迟 de/hs/vs，像素时序与原来完全一致。
//  字模：osd_font_cn.v（中文 24x24，字符格 26x24）/ osd_font_5x7.v（ASCII 10x14，字符格 12x16）
//=============================================================================

module osd_overlay #(
    parameter integer CLK_FREQ = 25_000_000,   // video_clk = 25MHz
    parameter integer H_ACTIVE = 640,
    parameter integer V_ACTIVE = 480
)(
    input  wire        I_clk,
    input  wire        I_rst,

    // 视频像素流：de/hs/vs 与 I_rgb 由 video_delay 对齐后送入
    input  wire        I_de,
    input  wire        I_hs,
    input  wire        I_vs,
    input  wire [23:0] I_rgb,

    output wire        O_de,
    output wire        O_hs,
    output wire        O_vs,
    output wire [23:0] O_rgb,

    // 来自 sd_card_bmp，已在 video_clk 域做过同步
    input  wire [2:0]  I_page,      // 当前显示图片编号 0~7
    input  wire [3:0]  I_total,     // 扫描到的图片总数 0~8
    input  wire [1:0]  I_mode,      // actual transition scheduler latched mode
    input  wire        I_auto,      // 自动轮播开关
    input  wire        I_e3         // E3 自适应缩放开关：1=ON, 0=OFF(仅 640x480)
);

// ---------------------------- 版式常量 ----------------------------
localparam [9:0] Y_TITLE_TEXT = 10'd4  ;  // 标题文字顶行，占 4~27 行
localparam [9:0] Y_TITLE_TOP  = 10'd2  ;  // 标题底带 2~29 行
localparam [9:0] Y_TITLE_BOT  = 10'd30 ;
localparam [9:0] TITLE_X0     = 10'd243;  // 标题左端（6 字居中）
localparam [9:0] TITLE_X1     = 10'd397;  // 标题右端（不含）
localparam [9:0] Y_BOT_TOP    = 10'd420;  // 底部底带 420~479 行
localparam [9:0] Y_SCROLL     = 10'd424;  // 滚动字幕顶行
localparam [9:0] Y_INFO       = 10'd452;  // 信息行顶行
localparam [9:0] BAR_X0       = 10'd560;  // 页码柱状条左端
localparam [9:0] BAR_Y_BOT    = 10'd24 ;
localparam [5:0] BAR_W        = 6'd6;    // 单根柱条宽度（8 根，每根占 8px 槽位中的 6px）
localparam [4:0] CN_PX        = 5'd24;   // 中文字模宽度
localparam [5:0] CN_STEP      = 6'd26;   // 中文字符格宽
localparam [6:0] SCROLL_LEN   = 7'd128;   // 必须是 2 的幂

// ---------------------------- 图层颜色 ----------------------------
localparam [7:0] BAND_R = 8'h0A, BAND_G = 8'h10, BAND_B = 8'h1E;   // 底带：深蓝黑
localparam [7:0] TITLE_R = 8'hFF, TITLE_G = 8'hFF, TITLE_B = 8'hFF; // 标题：白
localparam [7:0] SCROLL_R = 8'hA0, SCROLL_G = 8'hE4, SCROLL_B = 8'hFF; // 滚动：淡青
localparam [7:0] BAR_R = 8'hFF, BAR_G = 8'hA8, BAR_B = 8'h38;      // 柱条：橙

// ---------------------------- 坐标计数器 ----------------------------
// x 用两套计数：x_cnt 给图形层绝对定位；cx/cidx 直接给出字符格内偏移与字符序号，
// 避免在像素通路上做 /12 除法。标题层另有一套 26 像素步进的计数。
reg  [9:0]  x_cnt;      // 行内像素坐标 0~639
reg  [3:0]  cx;         // 字符格内偏移 0~11
reg  [5:0]  cidx;       // 字符序号 0~53
reg  [4:0]  t_cx;       // 标题字符格内偏移 0~25
reg  [2:0]  t_ci;       // 标题字符序号 0~5
reg  [9:0]  y_cnt;      // 行号 0~479
reg         de_d;
reg         vs_d;

wire de_fall = de_d & ~I_de;
wire vs_rise = ~vs_d & I_vs;
wire title_win = (x_cnt >= TITLE_X0) && (x_cnt < TITLE_X1);

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        x_cnt <= 10'd0;
        cx    <= 4'd0;
        cidx  <= 6'd0;
        t_cx  <= 5'd0;
        t_ci  <= 3'd0;
        y_cnt <= 10'd0;
        de_d  <= 1'b0;
        vs_d  <= 1'b0;
    end else begin
        de_d <= I_de;
        vs_d <= I_vs;

        // 每个 de 周期就是一个有效像素：x_cnt 与 cx 一起走
        if (!I_de) begin
            x_cnt <= 10'd0;
            cx    <= 4'd0;
            cidx  <= 6'd0;
            t_cx  <= 5'd0;
            t_ci  <= 3'd0;
        end else begin
            x_cnt <= x_cnt + 10'd1;
            if (cx == 4'd11) begin
                cx   <= 4'd0;
                cidx <= cidx + 6'd1;
            end else begin
                cx   <= cx + 4'd1;
            end
            // 标题字符格：进窗口才开始走，26 像素进一格
            if (title_win) begin
                if (t_cx == CN_STEP[4:0] - 5'd1) begin
                    t_cx <= 5'd0;
                    t_ci <= t_ci + 3'd1;
                end else begin
                    t_cx <= t_cx + 5'd1;
                end
            end
        end

        // 行号：换帧清零，每条 de 结束时加一（de 高电平期间即为本行行号）
        if (vs_rise)
            y_cnt <= 10'd0;
        else if (de_fall)
            y_cnt <= y_cnt + 10'd1;
    end
end

// ------------------------- 滚动字幕的相位 -------------------------
// scroll_cell：整体左移了多少个字符格；scroll_px：格内还差几个像素
// 每帧前进 1 像素，12 像素进位一次，得到像素级平滑滚动
reg [3:0] scroll_px;
reg [6:0] scroll_cell;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        scroll_px   <= 4'd0;
        scroll_cell <= 7'd0;
    end else if (vs_rise) begin
        if (scroll_px == 4'd11) begin
            scroll_px   <= 4'd0;
            scroll_cell <= scroll_cell + 7'd1;   // 7 位自然在 128 处回绕
        end else begin
            scroll_px <= scroll_px + 4'd1;
        end
    end
end

// ------------------------- 上电时间戳（BCD） -------------------------
reg [24:0] tick_cnt;
reg [3:0]  sec_lo, sec_hi, min_lo, min_hi;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        tick_cnt <= 25'd0;
        sec_lo   <= 4'd0;
        sec_hi   <= 4'd0;
        min_lo   <= 4'd0;
        min_hi   <= 4'd0;
    end else if (tick_cnt == (CLK_FREQ - 1)) begin
        tick_cnt <= 25'd0;
        if (sec_lo == 4'd9) begin
            sec_lo <= 4'd0;
            if (sec_hi == 4'd5) begin
                sec_hi <= 4'd0;
                if (min_lo == 4'd9) begin
                    min_lo <= 4'd0;
                    if (min_hi == 4'd5) min_hi <= 4'd0;
                    else                 min_hi <= min_hi + 4'd1;
                end else begin
                    min_lo <= min_lo + 4'd1;
                end
            end else begin
                sec_hi <= sec_hi + 4'd1;
            end
        end else begin
            sec_lo <= sec_lo + 4'd1;
        end
    end else begin
        tick_cnt <= tick_cnt + 25'd1;
    end
end

reg [3:0] view_sec_lo,view_sec_hi,view_min_lo,view_min_hi;
always @(posedge I_clk or posedge I_rst) begin
    if(I_rst)begin view_sec_lo<=0;view_sec_hi<=0;view_min_lo<=0;view_min_hi<=0;end
    else if(vs_rise)begin
        view_sec_lo<=sec_lo;view_sec_hi<=sec_hi;view_min_lo<=min_lo;view_min_hi<=min_hi;
    end
end

// ------------------------- 文本表（自动生成） -------------------------
// 滚动字幕（128 个字符，超出 640 像素窗口的部分靠 scroll_cell 回绕显示）
function [7:0] osd_scroll_char(input [6:0] i);
    begin
        case (i)
            7'd0  : osd_scroll_char = 8'h57;   // 'W'
            7'd1  : osd_scroll_char = 8'h45;   // 'E'
            7'd2  : osd_scroll_char = 8'h4C;   // 'L'
            7'd3  : osd_scroll_char = 8'h43;   // 'C'
            7'd4  : osd_scroll_char = 8'h4F;   // 'O'
            7'd5  : osd_scroll_char = 8'h4D;   // 'M'
            7'd6  : osd_scroll_char = 8'h45;   // 'E'
            7'd7  : osd_scroll_char = 8'h20;   // ' '
            7'd8  : osd_scroll_char = 8'h54;   // 'T'
            7'd9  : osd_scroll_char = 8'h4F;   // 'O'
            7'd10 : osd_scroll_char = 8'h20;   // ' '
            7'd11 : osd_scroll_char = 8'h41;   // 'A'
            7'd12 : osd_scroll_char = 8'h4E;   // 'N'
            7'd13 : osd_scroll_char = 8'h4C;   // 'L'
            7'd14 : osd_scroll_char = 8'h4F;   // 'O'
            7'd15 : osd_scroll_char = 8'h47;   // 'G'
            7'd16 : osd_scroll_char = 8'h49;   // 'I'
            7'd17 : osd_scroll_char = 8'h43;   // 'C'
            7'd18 : osd_scroll_char = 8'h20;   // ' '
            7'd19 : osd_scroll_char = 8'h46;   // 'F'
            7'd20 : osd_scroll_char = 8'h50;   // 'P'
            7'd21 : osd_scroll_char = 8'h47;   // 'G'
            7'd22 : osd_scroll_char = 8'h41;   // 'A'
            7'd23 : osd_scroll_char = 8'h20;   // ' '
            7'd24 : osd_scroll_char = 8'h48;   // 'H'
            7'd25 : osd_scroll_char = 8'h44;   // 'D'
            7'd26 : osd_scroll_char = 8'h4D;   // 'M'
            7'd27 : osd_scroll_char = 8'h49;   // 'I'
            7'd28 : osd_scroll_char = 8'h20;   // ' '
            7'd29 : osd_scroll_char = 8'h4D;   // 'M'
            7'd30 : osd_scroll_char = 8'h55;   // 'U'
            7'd31 : osd_scroll_char = 8'h4C;   // 'L'
            7'd32 : osd_scroll_char = 8'h54;   // 'T'
            7'd33 : osd_scroll_char = 8'h49;   // 'I'
            7'd34 : osd_scroll_char = 8'h4D;   // 'M'
            7'd35 : osd_scroll_char = 8'h45;   // 'E'
            7'd36 : osd_scroll_char = 8'h44;   // 'D'
            7'd37 : osd_scroll_char = 8'h49;   // 'I'
            7'd38 : osd_scroll_char = 8'h41;   // 'A'
            7'd39 : osd_scroll_char = 8'h20;   // ' '
            7'd40 : osd_scroll_char = 8'h44;   // 'D'
            7'd41 : osd_scroll_char = 8'h49;   // 'I'
            7'd42 : osd_scroll_char = 8'h53;   // 'S'
            7'd43 : osd_scroll_char = 8'h50;   // 'P'
            7'd44 : osd_scroll_char = 8'h4C;   // 'L'
            7'd45 : osd_scroll_char = 8'h41;   // 'A'
            7'd46 : osd_scroll_char = 8'h59;   // 'Y'
            7'd47 : osd_scroll_char = 8'h20;   // ' '
            7'd48 : osd_scroll_char = 8'h20;   // ' '
            7'd49 : osd_scroll_char = 8'h20;   // ' '
            7'd50 : osd_scroll_char = 8'h54;   // 'T'
            7'd51 : osd_scroll_char = 8'h46;   // 'F'
            7'd52 : osd_scroll_char = 8'h20;   // ' '
            7'd53 : osd_scroll_char = 8'h43;   // 'C'
            7'd54 : osd_scroll_char = 8'h41;   // 'A'
            7'd55 : osd_scroll_char = 8'h52;   // 'R'
            7'd56 : osd_scroll_char = 8'h44;   // 'D'
            7'd57 : osd_scroll_char = 8'h20;   // ' '
            7'd58 : osd_scroll_char = 8'h42;   // 'B'
            7'd59 : osd_scroll_char = 8'h4D;   // 'M'
            7'd60 : osd_scroll_char = 8'h50;   // 'P'
            7'd61 : osd_scroll_char = 8'h20;   // ' '
            7'd62 : osd_scroll_char = 8'h50;   // 'P'
            7'd63 : osd_scroll_char = 8'h4C;   // 'L'
            7'd64 : osd_scroll_char = 8'h41;   // 'A'
            7'd65 : osd_scroll_char = 8'h59;   // 'Y'
            7'd66 : osd_scroll_char = 8'h45;   // 'E'
            7'd67 : osd_scroll_char = 8'h52;   // 'R'
            7'd68 : osd_scroll_char = 8'h20;   // ' '
            7'd69 : osd_scroll_char = 8'h57;   // 'W'
            7'd70 : osd_scroll_char = 8'h49;   // 'I'
            7'd71 : osd_scroll_char = 8'h54;   // 'T'
            7'd72 : osd_scroll_char = 8'h48;   // 'H'
            7'd73 : osd_scroll_char = 8'h20;   // ' '
            7'd74 : osd_scroll_char = 8'h52;   // 'R'
            7'd75 : osd_scroll_char = 8'h45;   // 'E'
            7'd76 : osd_scroll_char = 8'h41;   // 'A'
            7'd77 : osd_scroll_char = 8'h4C;   // 'L'
            7'd78 : osd_scroll_char = 8'h2D;   // '-'
            7'd79 : osd_scroll_char = 8'h54;   // 'T'
            7'd80 : osd_scroll_char = 8'h49;   // 'I'
            7'd81 : osd_scroll_char = 8'h4D;   // 'M'
            7'd82 : osd_scroll_char = 8'h45;   // 'E'
            7'd83 : osd_scroll_char = 8'h20;   // ' '
            7'd84 : osd_scroll_char = 8'h4F;   // 'O'
            7'd85 : osd_scroll_char = 8'h53;   // 'S'
            7'd86 : osd_scroll_char = 8'h44;   // 'D'
            7'd87 : osd_scroll_char = 8'h20;   // ' '
            7'd88 : osd_scroll_char = 8'h4F;   // 'O'
            7'd89 : osd_scroll_char = 8'h56;   // 'V'
            7'd90 : osd_scroll_char = 8'h45;   // 'E'
            7'd91 : osd_scroll_char = 8'h52;   // 'R'
            7'd92 : osd_scroll_char = 8'h4C;   // 'L'
            7'd93 : osd_scroll_char = 8'h41;   // 'A'
            7'd94 : osd_scroll_char = 8'h59;   // 'Y'
            7'd95 : osd_scroll_char = 8'h20;   // ' '
            7'd96 : osd_scroll_char = 8'h20;   // ' '
            7'd97 : osd_scroll_char = 8'h20;   // ' '
            7'd98 : osd_scroll_char = 8'h50;   // 'P'
            7'd99 : osd_scroll_char = 8'h41;   // 'A'
            7'd100: osd_scroll_char = 8'h47;   // 'G'
            7'd101: osd_scroll_char = 8'h45;   // 'E'
            7'd102: osd_scroll_char = 8'h20;   // ' '
            7'd103: osd_scroll_char = 8'h31;   // '1'
            7'd104: osd_scroll_char = 8'h2D;   // '-'
            7'd105: osd_scroll_char = 8'h34;   // '4'
            7'd106: osd_scroll_char = 8'h20;   // ' '
            7'd107: osd_scroll_char = 8'h41;   // 'A'
            7'd108: osd_scroll_char = 8'h55;   // 'U'
            7'd109: osd_scroll_char = 8'h54;   // 'T'
            7'd110: osd_scroll_char = 8'h4F;   // 'O'
            7'd111: osd_scroll_char = 8'h4D;   // 'M'
            7'd112: osd_scroll_char = 8'h41;   // 'A'
            7'd113: osd_scroll_char = 8'h54;   // 'T'
            7'd114: osd_scroll_char = 8'h49;   // 'I'
            7'd115: osd_scroll_char = 8'h43;   // 'C'
            7'd116: osd_scroll_char = 8'h20;   // ' '
            7'd117: osd_scroll_char = 8'h53;   // 'S'
            7'd118: osd_scroll_char = 8'h4C;   // 'L'
            7'd119: osd_scroll_char = 8'h49;   // 'I'
            7'd120: osd_scroll_char = 8'h44;   // 'D'
            7'd121: osd_scroll_char = 8'h45;   // 'E'
            7'd122: osd_scroll_char = 8'h53;   // 'S'
            7'd123: osd_scroll_char = 8'h48;   // 'H'
            7'd124: osd_scroll_char = 8'h4F;   // 'O'
            7'd125: osd_scroll_char = 8'h57;   // 'W'
            7'd126: osd_scroll_char = 8'h20;   // ' '
            7'd127: osd_scroll_char = 8'h20;   // ' '
            default: osd_scroll_char = 8'h20;
        endcase
    end
endfunction

// 信息行："E3:ON/OFF  PIC n/N  MODE:AUTO    T=mm:ss  FX:HWIPE"
function [7:0] osd_info_char(input [5:0] i, input [2:0] page, input [3:0] total,
                             input autoplay, input [1:0] effect, input e3_on,
                             input [3:0] mhi, mlo, shi, slo);
    begin
        case (i)
            // 行首显示 E3 自适应缩放开关状态（0~5），拨 SW4 即时翻转
            6'd0 :  osd_info_char = 8'h45;   // 'E'
            6'd1 :  osd_info_char = 8'h33;   // '3'
            6'd2 :  osd_info_char = 8'h3A;   // ':'
            6'd3 :  osd_info_char = 8'h4F;   // 'O'
            6'd4 :  osd_info_char = e3_on ? 8'h4E : 8'h46;   // 'N' / 'F'
            6'd5 :  osd_info_char = e3_on ? 8'h20 : 8'h46;   // ' ' / 'F'
            6'd8 :  osd_info_char = 8'h50;   // 'P'
            6'd9 :  osd_info_char = 8'h49;   // 'I'
            6'd10:  osd_info_char = 8'h43;   // 'C'
            6'd11:  osd_info_char = 8'h20;   // ' '
            6'd12:  osd_info_char = 8'h31 + {5'd0, page};          // 当前页码（page 从 0 起，显示 1~8）
            6'd13:  osd_info_char = 8'h2F;   // '/'
            6'd14:  osd_info_char = (total == 4'd0) ? 8'h2D : (8'h30 | {4'd0, total});
            6'd17:  osd_info_char = 8'h4D;   // 'M'
            6'd18:  osd_info_char = 8'h4F;   // 'O'
            6'd19:  osd_info_char = 8'h44;   // 'D'
            6'd20:  osd_info_char = 8'h45;   // 'E'
            6'd21:  osd_info_char = 8'h3A;   // ':'
            6'd22:  osd_info_char = autoplay ? 8'h41 : 8'h4D;   // 'A' / 'M'
            6'd23:  osd_info_char = autoplay ? 8'h55 : 8'h41;   // 'U' / 'A'
            6'd24:  osd_info_char = autoplay ? 8'h54 : 8'h4E;   // 'T' / 'N'
            6'd25:  osd_info_char = autoplay ? 8'h4F : 8'h55;   // 'O' / 'U'
            6'd26:  osd_info_char = autoplay ? 8'h20 : 8'h41;   // ' ' / 'A'
            6'd27:  osd_info_char = autoplay ? 8'h20 : 8'h4C;   // ' ' / 'L'
            6'd30:  osd_info_char = 8'h54;   // 'T'
            6'd31:  osd_info_char = 8'h3D;   // '='
            6'd32:  osd_info_char = 8'h30 | {4'd0, mhi};
            6'd33:  osd_info_char = 8'h30 | {4'd0, mlo};
            6'd34:  osd_info_char = 8'h3A;   // ':'
            6'd35:  osd_info_char = 8'h30 | {4'd0, shi};
            6'd36:  osd_info_char = 8'h30 | {4'd0, slo};
            6'd39: osd_info_char = "F";
            6'd40: osd_info_char = "X";
            6'd41: osd_info_char = ":";
            6'd42: case(effect)
                0:osd_info_char="H";1:osd_info_char="V";2:osd_info_char="S";3:osd_info_char="F";
            endcase
            6'd43: case(effect)
                0,1:osd_info_char="W";2:osd_info_char="L";3:osd_info_char="A";
            endcase
            6'd44: case(effect)
                0,1:osd_info_char="I";2:osd_info_char="I";3:osd_info_char="D";
            endcase
            6'd45: case(effect)
                0,1:osd_info_char="P";2:osd_info_char="D";3:osd_info_char="E";
            endcase
            6'd46: osd_info_char = effect==3 ? " " : "E";
            default: osd_info_char = 8'h20;
        endcase
    end
endfunction

// ------------------------- Alpha 混合 -------------------------
// 只用移位和加法，不占乘法器
function [7:0] bl50(input [7:0] a, input [7:0] b);   // (a+b)/2
    begin
        bl50 = (a >> 1) + (b >> 1) + (a[0] & b[0]);
    end
endfunction

function [7:0] bl25(input [7:0] a, input [7:0] b);   // a*3/4 + b/4
    reg [9:0] sum;
    begin
        sum = {2'b00,a} + ({2'b00,a} << 1) + {2'b00,b};
        bl25 = sum[9:2];
    end
endfunction

// ------------------------- 各图层命中判定 -------------------------
wire line_title  = (y_cnt >= Y_TITLE_TEXT) && (y_cnt < (Y_TITLE_TEXT + 10'd24));
wire line_scroll = (y_cnt >= Y_SCROLL)     && (y_cnt < (Y_SCROLL + 16));
wire line_info   = (y_cnt >= Y_INFO)       && (y_cnt < (Y_INFO + 16));

wire [9:0] t_row = y_cnt - Y_TITLE_TEXT;
wire [9:0] s_row = y_cnt - Y_SCROLL;
wire [9:0] i_row = y_cnt - Y_INFO;

// 标题：中文 24x24 点阵，t_ci 选字、t_cx 选列
wire [23:0] cn_row;
osd_font_cn u_osd_font_cn (
    .addr ({t_ci, t_row[4:0]}),
    .data (cn_row)
);

// 列索引：先判 t_cx < 24 再算 23-t_cx，避免出现越界下标
wire [4:0] cn_col = (t_cx < CN_PX) ? (5'd23 - t_cx) : 5'd0;
wire cn_px = I_de && title_win && line_title && (t_cx < CN_PX) && cn_row[cn_col];

// 滚动字幕：字符格基准 + 格内像素余量，进位到下一个字符
wire [4:0] s_pos   = {1'b0, cx} + {1'b0, scroll_px};   // 0~22
wire       s_carry = (s_pos >= 5'd12);
wire [4:0] s_sub5  = s_pos - 5'd12;
wire [3:0] s_sub   = s_carry ? s_sub5[3:0] : s_pos[3:0];
wire [6:0] s_idx   = scroll_cell + {1'b0, cidx} + {6'd0, s_carry};

wire [7:0] code_scroll = osd_scroll_char(s_idx[6:0]);
wire [7:0] code_info   = osd_info_char(cidx, I_page, I_total, I_auto, I_mode, I_e3,
                                      view_min_hi, view_min_lo, view_sec_hi, view_sec_lo);

wire [7:0] code_sel = line_scroll ? code_scroll : code_info;
wire [3:0] row_sel  = line_scroll ? s_row[3:0] : i_row[3:0];
wire [3:0] sub_sel  = line_scroll ? s_sub : cx;

// 字模查表：字符必须在 0x20~0x5F 内，否则当空格处理
wire [7:0] code_ok  = (code_sel >= 8'h20 && code_sel <= 8'h5F) ? code_sel : 8'h20;
wire [5:0] glyph_idx = code_ok[5:0] - 6'h20;
wire [9:0] glyph_row;

osd_font_5x7 u_osd_font_5x7 (
    .addr ({glyph_idx, row_sel}),
    .data (glyph_row)
);

wire [3:0] sub_ok = (sub_sel < 4'd10) ? sub_sel : 4'd0;
wire px_on = (sub_sel < 4'd10) && glyph_row[9 - sub_ok];
wire txt_on = I_de && px_on && (line_scroll || line_info);

// 底带：上下两条半透明黑底
wire in_title_band = (y_cnt >= Y_TITLE_TOP) && (y_cnt < Y_TITLE_BOT);
wire in_bot_band   = (y_cnt >= Y_BOT_TOP);

// 右上角页码柱状条（图形层）：8 根，点亮数 = 当前页码 + 1
// 每根占 8px 槽位（BAR_W=6px 柱体 + 2px 间隙），8 根正好铺满 64px 区域。
// 柱高 6..20（步进 2），全部落在 BAR_Y_BOT=24 的上边界内。
wire [5:0] bar_x  = x_cnt - BAR_X0;
wire [2:0] bar_i  = bar_x[5:3];
wire [4:0] bar_h  = 5'd6 + {bar_i, 1'b0};   // 6 / 8 / 10 / ... / 20
wire in_bar = (y_cnt < BAR_Y_BOT) &&
              (x_cnt >= BAR_X0) && (x_cnt < (BAR_X0 + 10'd64)) &&
              (bar_x[2:0] < BAR_W[2:0]) &&
              (y_cnt >= (BAR_Y_BOT - bar_h));
wire bar_lit = (bar_i <= I_page);

// ------------------------- 像素合成 -------------------------
reg [7:0] r_out, g_out, b_out;

always @(*) begin
    r_out = I_rgb[23:16];
    g_out = I_rgb[15:8];
    b_out = I_rgb[7:0];

    if (I_de) begin
        // 1) 半透明底带
        if (in_title_band || in_bot_band) begin
            r_out = bl50(r_out, BAND_R);
            g_out = bl50(g_out, BAND_G);
            b_out = bl50(b_out, BAND_B);
        end
        // 2) 柱状条
        if (in_bar) begin
            if (bar_lit) begin
                r_out = bl50(r_out, BAR_R);
                g_out = bl50(g_out, BAR_G);
                b_out = bl50(b_out, BAR_B);
            end else begin
                r_out = bl25(r_out, BAR_R);
                g_out = bl25(g_out, BAR_G);
                b_out = bl25(b_out, BAR_B);
            end
        end
        // 3) 文字（最上层，实心）：标题白字；滚动字幕淡青；信息行白字
        if (cn_px) begin
            r_out = TITLE_R;
            g_out = TITLE_G;
            b_out = TITLE_B;
        end else if (txt_on) begin
            r_out = line_scroll ? SCROLL_R : TITLE_R;
            g_out = line_scroll ? SCROLL_G : TITLE_G;
            b_out = line_scroll ? SCROLL_B : TITLE_B;
        end
    end
end

assign O_rgb = {r_out, g_out, b_out};
assign O_de  = I_de;
assign O_hs  = I_hs;
assign O_vs  = I_vs;

endmodule
