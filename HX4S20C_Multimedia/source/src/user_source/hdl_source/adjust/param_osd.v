// E4 parameter panel for V3: x456..623, y32..47 (14 cells, 12x16 each).
// Opaque dark backing keeps labels readable without overlapping E1 title,
// scrolling subtitle or bottom PIC/MODE/TIME/FX. Zero pixel latency.
module param_osd (
    input  wire              I_clk,
    input  wire              I_rst,

    // 像素流（来自 osd_overlay 输出）
    input  wire              I_de,
    input  wire              I_hs,
    input  wire              I_vs,
    input  wire [23:0]       I_rgb,

    // 参数（param_ctrl 帧锁存后的值）
    input  wire signed [7:0] I_bri,          // -64 ~ +64
    input  wire signed [5:0] I_con,          // 增益 = 1 + q/32
    input  wire              I_sel,          // 0 = 正在调亮度，1 = 正在调对比度

    output wire              O_de,
    output wire              O_hs,
    output wire              O_vs,
    output wire [23:0]       O_rgb
);

//-----------------------------------------------------------------------------
//  版式常量
//-----------------------------------------------------------------------------
localparam [9:0] X0      = 10'd456;   // 38 * 12, aligned to character cell
localparam [9:0] Y0      = 10'd32;   // Below title; above the image body
localparam [5:0] CELLS   = 6'd14;     // 字符数
localparam [9:0] X1      = X0 + CELLS * 12;   // 624
localparam [5:0] IDX0    = 6'd38;             // 456 / 12

localparam [23:0] COL_ON  = {8'hFF, 8'hC8, 8'h30};   // 选中：琥珀黄
localparam [23:0] COL_OFF = {8'hD8, 8'hE0, 8'hF0};   // 未选中：浅灰白

//-----------------------------------------------------------------------------
//  像素坐标计数：与 osd_overlay 完全一致的写法（de 期间 x 累加、12 像素进一格，
//  de 下降沿行号加一，vs 上升沿清零），保证两层的行列基准严格对齐
//-----------------------------------------------------------------------------
reg [9:0] x_cnt;
reg [3:0] cx;        // 字符格内列 0~11
reg [5:0] cidx;      // 字符序号
reg [9:0] y_cnt;
reg       de_d, vs_d;

wire vs_rise = I_vs & ~vs_d;
wire de_fall = ~I_de & de_d;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        x_cnt <= 10'd0;
        cx    <= 4'd0;
        cidx  <= 6'd0;
        y_cnt <= 10'd0;
        de_d  <= 1'b0;
        vs_d  <= 1'b0;
    end else begin
        de_d <= I_de;
        vs_d <= I_vs;

        if (!I_de) begin
            x_cnt <= 10'd0;
            cx    <= 4'd0;
            cidx  <= 6'd0;
        end else begin
            x_cnt <= x_cnt + 10'd1;
            if (cx == 4'd11) begin
                cx   <= 4'd0;
                cidx <= cidx + 6'd1;
            end else begin
                cx <= cx + 4'd1;
            end
        end

        if (vs_rise)
            y_cnt <= 10'd0;
        else if (de_fall)
            y_cnt <= y_cnt + 10'd1;
    end
end

wire       in_line  = (y_cnt >= Y0) && (y_cnt < (Y0 + 10'd16));
wire       in_zone  = in_line && (x_cnt >= X0) && (x_cnt < X1);
wire       in_cell  = (cidx >= IDX0) && (cidx < (IDX0 + CELLS));
wire [3:0] idx      = cidx - IDX0;              // 0 ~ 13
wire [9:0] s_row    = y_cnt - Y0;               // only valid when in_line
wire [3:0] row      = s_row[3:0];               // 0 ~ 15

//-----------------------------------------------------------------------------
//  数值 → 字符
//-----------------------------------------------------------------------------
// 十位（0~9 -> 0~9，用于 0~99 的十进制拆分）
function [3:0] div10;
    input [7:0] v;
    begin
        if      (v >= 8'd90) div10 = 4'd9;
        else if (v >= 8'd80) div10 = 4'd8;
        else if (v >= 8'd70) div10 = 4'd7;
        else if (v >= 8'd60) div10 = 4'd6;
        else if (v >= 8'd50) div10 = 4'd5;
        else if (v >= 8'd40) div10 = 4'd4;
        else if (v >= 8'd30) div10 = 4'd3;
        else if (v >= 8'd20) div10 = 4'd2;
        else if (v >= 8'd10) div10 = 4'd1;
        else                 div10 = 4'd0;
    end
endfunction

//-----------------------------------------------------------------------------
//  亮度：符号 + 两位十进制（十位为 0 时显示空格，避免出现 "+05"）
//-----------------------------------------------------------------------------
wire [7:0]  bri_mag  = I_bri[7] ? (8'd0 - I_bri) : {1'b0, I_bri[6:0]};   // 0 ~ 64
wire [3:0]  bri_tens = div10(bri_mag);
wire [7:0]  bri_ones = bri_mag - {2'd0, bri_tens, 3'd0} - {4'd0, bri_tens, 1'b0}; // mag - tens*10

wire [7:0]  bri_sign = (I_bri > 8'sd0) ? 8'h2B :          // '+'
                       (I_bri < 8'sd0) ? 8'h2D : 8'h20;   // '-' / ' '
wire [7:0]  bri_t_ch = (bri_tens == 4'd0) ? 8'h20 : (8'h30 + {4'd0, bri_tens});
wire [7:0]  bri_o_ch = 8'h30 + bri_ones[4:0];

//-----------------------------------------------------------------------------
//  对比度：编码 q -> 增益百分数 = (3216 + 100q) >>> 5，范围 50 ~ 150
//  再拆成 1.25 / 0.75 这样的三位数字
//-----------------------------------------------------------------------------
wire signed [12:0] q13   = {{7{I_con[5]}}, I_con};
wire signed [12:0] hh13  = (13'sd3216 + q13 * 13'sd100) >>> 5;
wire        [7:0]  con_h = hh13[7:0];                     // 50 ~ 150
wire        [7:0]  con_i = (con_h >= 8'd100) ? 8'd1 : 8'd0;
wire        [7:0]  con_r = con_h - (con_i ? 8'd100 : 8'd0);   // 0 ~ 99
wire        [3:0]  con_t = div10(con_r);
wire        [7:0]  con_o = con_r - {2'd0, con_t, 3'd0} - {4'd0, con_t, 1'b0};

wire [7:0]  con_i_ch = 8'h30 + con_i[3:0];
wire [7:0]  con_t_ch = 8'h30 + {4'd0, con_t};
wire [7:0]  con_o_ch = 8'h30 + con_o[4:0];

//-----------------------------------------------------------------------------
//  字符拼装
//-----------------------------------------------------------------------------
function [7:0] param_char;
    input [3:0] i;
    input [7:0] sgn;
    input [7:0] t0;
    input [7:0] u0;
    input [7:0] c0;
    input [7:0] c1;
    input [7:0] c2;
    begin
        case (i)
            4'd0 : param_char = 8'h42;   // 'B'
            4'd1 : param_char = 8'h52;   // 'R'
            4'd2 : param_char = 8'h49;   // 'I'
            4'd3 : param_char = sgn;     // 符号 / 空格
            4'd4 : param_char = t0;      // 十位 / 空格
            4'd5 : param_char = u0;      // 个位
            4'd6 : param_char = 8'h20;   // 空格
            4'd7 : param_char = 8'h43;   // 'C'
            4'd8 : param_char = 8'h4F;   // 'O'
            4'd9 : param_char = 8'h4E;   // 'N'
            4'd10: param_char = c0;      // 整数位 0/1
            4'd11: param_char = 8'h2E;   // '.'
            4'd12: param_char = c1;      // 十分位
            4'd13: param_char = c2;      // 百分位
            default: param_char = 8'h20;
        endcase
    end
endfunction

wire [7:0] code = param_char(idx, bri_sign, bri_t_ch, bri_o_ch,
                             con_i_ch, con_t_ch, con_o_ch);

// 字符 -> 字模索引（param_font.v 里只有这 20 个字符）
function [4:0] font_idx;
    input [7:0] c;
    begin
        if (c >= 8'h30 && c <= 8'h39)        // '0' ~ '9'
            font_idx = 5'd4 + (c - 8'h30);
        else begin
            case (c)
                8'h2B: font_idx = 5'd1;      // '+'
                8'h2D: font_idx = 5'd2;      // '-'
                8'h2E: font_idx = 5'd3;      // '.'
                8'h42: font_idx = 5'd14;     // 'B'
                8'h43: font_idx = 5'd15;     // 'C'
                8'h49: font_idx = 5'd16;     // 'I'
                8'h4E: font_idx = 5'd17;     // 'N'
                8'h4F: font_idx = 5'd18;     // 'O'
                8'h52: font_idx = 5'd19;     // 'R'
                default: font_idx = 5'd0;    // 空格
            endcase
        end
    end
endfunction

wire [4:0] gidx = font_idx(code);
wire [9:0] grow;

param_font u_param_font (
    .addr ({gidx, row}),
    .data (grow)
);

// 字符格内：前 10 列是点阵，后 2 列是字间距
wire [3:0] sub = cx;
wire       px  = in_zone && in_cell && (sub < 4'd10) && grow[9 - sub];

// 高亮：亮度数值在 3~5 格，对比度数值在 10~13 格
wire field_b = (idx >= 4'd10);
wire on_sel  = field_b ? I_sel : ~I_sel;

// V3: fixed panel below title, leaving bottom PIC/MODE/TIME/FX untouched.
assign O_rgb = px ? (on_sel ? COL_ON : COL_OFF) :
               (I_de && in_zone ? 24'h18202c : I_rgb);
assign O_de  = I_de;
assign O_hs  = I_hs;
assign O_vs  = I_vs;

endmodule
