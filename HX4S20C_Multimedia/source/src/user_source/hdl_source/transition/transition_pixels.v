// Pure combinational 640x480 RGB transition algorithm; zero clock latency.
// Mode: 0 left-to-right wipe, 1 top-to-bottom wipe, 2 old slides left/new
// enters from right, 3 per-channel unsigned crossfade with floor rounding.
// Progress is 0..64 inclusive; larger values saturate at the new image.
//
// Pixel contract: I_old_rgb / I_new_rgb must contain pixels sampled at the
// advertised O_old_x / O_new_x and O_source_y when the corresponding
// O_*_needed flag is set. For sliding, these differ from the output I_x.
// Coordinate outputs depend ONLY on mode/progress/output coordinates, never
// on RGB. A caller can therefore calculate source addresses before sampling.
// Inactive source coordinates are zero. Invalid output coordinates produce
// black, O_valid=0 and no source requests. No frame address, RAM, FIFO, read
// request, clock, reset, DE or playback control is implemented here.
module transition_pixels(
    input [1:0] I_mode,
    input [6:0] I_progress,
    input [9:0] I_x,
    input [8:0] I_y,
    input [23:0] I_old_rgb, I_new_rgb,
    output reg [23:0] O_rgb,
    output reg [9:0] O_old_x, O_new_x,
    output reg [8:0] O_source_y,
    output reg O_old_needed, O_new_needed,
    output wire O_valid
);
    wire [6:0] progress = (I_progress > 7'd64) ? 7'd64 : I_progress;
    wire [10:0] progress_wide = {4'd0, progress};
    // 640*p/64 = 10*p. Keep sufficient width for the p=64 endpoint.
    wire [10:0] horizontal_cut = (progress_wide << 3) + (progress_wide << 1);
    wire [15:0] progress_vertical = {9'd0, progress};
    wire [15:0] vertical_product = (progress_vertical << 9) - (progress_vertical << 5);
    wire [9:0] vertical_cut = vertical_product[15:6];
    wire [10:0] slide_split = 11'd640 - horizontal_cut;
    reg select_new;

    function [7:0] fade_channel;
        input [7:0] old_channel, new_channel;
        input [6:0] p;
        reg [14:0] old_term, new_term, sum;
        begin
            old_term = old_channel * (7'd64 - p);
            new_term = new_channel * p;
            sum = old_term + new_term;
            fade_channel = sum[13:6];
        end
    endfunction

    assign O_valid = (I_x < 10'd640) && (I_y < 9'd480);

    always @* begin
        O_rgb = 24'd0;
        O_old_x = 10'd0;
        O_new_x = 10'd0;
        O_source_y = 9'd0;
        O_old_needed = 1'b0;
        O_new_needed = 1'b0;
        select_new = 1'b0;
        if (O_valid) begin
            O_source_y = I_y;
            case (I_mode)
                2'd0: select_new = ({1'b0, I_x} < horizontal_cut);
                2'd1: select_new = ({1'b0, I_y} < vertical_cut);
                2'd2: select_new = ({1'b0, I_x} >= slide_split);
                2'd3: select_new = 1'b0;
            endcase
            if (I_mode == 2'd3) begin
                O_old_needed = (progress < 7'd64);
                O_new_needed = (progress > 7'd0);
                // Endpoint bypass also makes the unused source irrelevant
                // if its pixel port contains X while it is not requested.
                if (progress == 7'd0) begin
                    O_rgb = I_old_rgb;
                end else if (progress == 7'd64) begin
                    O_rgb = I_new_rgb;
                end else begin
                    O_rgb = {
                        fade_channel(I_old_rgb[23:16], I_new_rgb[23:16], progress),
                        fade_channel(I_old_rgb[15:8], I_new_rgb[15:8], progress),
                        fade_channel(I_old_rgb[7:0], I_new_rgb[7:0], progress)
                    };
                end
            end else begin
                O_old_needed = ~select_new;
                O_new_needed = select_new;
                O_rgb = select_new ? I_new_rgb : I_old_rgb;
            end
            if (O_old_needed) begin
                if (I_mode == 2'd2) begin
                    O_old_x = {1'b0, I_x} + horizontal_cut;
                end else begin
                    O_old_x = I_x;
                end
            end
            if (O_new_needed) begin
                if (I_mode == 2'd2) begin
                    O_new_x = {1'b0, I_x} - slide_split;
                end else begin
                    O_new_x = I_x;
                end
            end
        end
    end
endmodule
