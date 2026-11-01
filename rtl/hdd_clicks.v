// hdd_clicks.v
//
// Synthesised seek noise of an early-90s 2.5" IDE drive, played while the
// IDE interface is busy. No samples needed: each tick is an LFSR noise burst
// plus two damped resonators (a ~3.2-4.3 kHz metallic ping and a
// ~1.1-1.4 kHz body), followed by a gentle low-pass.
//
// While busy, a scheduler fires either a single hard tick or a fast
// "chatter" train of 4-11 softer ticks 3-7 ms apart, then waits 20-105 ms.
// Timing, pitch and strength are randomised from the LFSR.
//
// Loudness follows the core's drive sound volume setting (0 = off).
// Output is a signed 16-bit mono sample at 48 kHz (held between samples).

module hdd_clicks
#(
	parameter CLK_HZ    = 28_375_160
)
(
	input                    clk,
	input                    reset,
	input                    activity,
	input              [1:0] volume,  // OSD drive sound volume: 0 = off, 1..3 = -6 dB steps
	output reg signed [15:0] sample = 0
);

// ---------------------------------------------------------------- 48 kHz tick
reg [31:0] ph = 0;
reg        ce = 0;
always @(posedge clk) begin
	ce <= 0;
	if (ph >= CLK_HZ - 48000) begin
		ph <= ph + 48000 - CLK_HZ;
		ce <= 1;
	end
	else ph <= ph + 48000;
end

// ------------------------------------------------------------------ noise
reg [15:0] lfsr = 16'hACE1;
always @(posedge clk) if (ce) lfsr <= {lfsr[0]^lfsr[2]^lfsr[3]^lfsr[5], lfsr[15:1]};
wire signed [8:0] noise = {1'b0, lfsr[7:0]} - 9'sd128;

// a second, free-running LFSR for decisions (decorrelated from the noise)
reg [23:0] rnd = 24'h5A3C96;
always @(posedge clk) rnd <= {rnd[22:0], rnd[23]^rnd[22]^rnd[21]^rnd[16]};

// -------------------------------------------------------------- busy detect
reg [1:0] act_s = 0;
always @(posedge clk) act_s <= {act_s[0], activity};

reg [11:0] hold = 0;                     // ~50 ms bridge over gaps between sectors
always @(posedge clk) begin
	if (reset)            hold <= 0;
	else if (act_s[1])    hold <= 12'd2400;
	else if (ce && |hold) hold <= hold - 1'd1;
end
wire busy = (act_s[1] | (|hold)) & (|volume);

// ---------------------------------------------------------------- scheduler
reg [12:0] wait_cnt = 0;
reg  [3:0] train    = 0;
reg        fire     = 0;
reg  [7:0] strength = 0;
reg  [1:0] pitch    = 0;

always @(posedge clk) begin
	fire <= 0;
	if (reset | ~busy) begin
		wait_cnt <= 0;
		train    <= 0;
	end
	else if (ce) begin
		if (|wait_cnt) wait_cnt <= wait_cnt - 1'd1;
		else begin
			fire  <= 1;
			pitch <= rnd[1:0];
			if (|train) begin                                  // inside a chatter train
				strength <= 8'd90 + {1'b0, rnd[9:3]};          // 90..217
				train    <= train - 1'd1;
				wait_cnt <= (train == 1) ? 13'd960 + rnd[23:12] // then 20..105 ms pause
				                         : 13'd144 + rnd[15:8] - rnd[15:10]; // 3..7 ms
			end
			else if (rnd[7:0] < 8'd115) begin                  // ~45%: start a train
				strength <= 8'd90 + {1'b0, rnd[14:8]};
				train    <= 4'd3 + rnd[18:16];                  // 4..11 ticks total
				wait_cnt <= 13'd144 + rnd[15:8] - rnd[15:10];
			end
			else begin                                         // single hard tick
				strength <= 8'd180 + {2'b00, rnd[13:8]};       // 180..243
				wait_cnt <= 13'd960 + rnd[23:12];
			end
		end
	end
end

// ------------------------------------------------------------- tick voice
// resonator coefficients, Q14 (2*r*cos(w), r^2), fs = 48 kHz
wire signed [17:0] p_c1 = (pitch == 0) ? 18'sd29420 :   // 3200 Hz
                          (pitch == 1) ? 18'sd28789 :   // 3550 Hz
                          (pitch == 2) ? 18'sd28098 :   // 3900 Hz
                                         18'sd27348;    // 4250 Hz
wire signed [17:0] b_c1 = (pitch == 0) ? 18'sd32093 :   // 1100 Hz
                          (pitch == 1) ? 18'sd32029 :   // 1200 Hz
                          (pitch == 2) ? 18'sd31960 :   // 1300 Hz
                                         18'sd31885;    // 1400 Hz
localparam signed [17:0] P_C2 = 18'sd15825;   // tau 1.2 ms
localparam signed [17:0] B_C2 = 18'sd16046;   // tau 2.0 ms

reg        pend = 0;      // trigger waiting for the next sample tick
reg  [7:0] amp  = 0;
always @(posedge clk) begin
	if (fire) begin pend <= 1; amp <= strength; end
	else if (ce) pend <= 0;
end

reg        [15:0] nenv = 0;
reg signed [17:0] p1 = 0, p2 = 0, b1 = 0, b2 = 0;
reg signed [19:0] mix = 0;
reg signed [19:0] lp  = 0;

wire signed [35:0] p_fb = p_c1 * p1 - P_C2 * p2;
wire signed [35:0] b_fb = b_c1 * b1 - B_C2 * b2;
wire signed [17:0] p_x  = pend ? $signed({2'b00, amp, 4'b0}) - $signed({6'b0, amp, 4'b0} >> 4) : 18'sd0; // ~15*A
wire signed [17:0] b_x  = pend ? $signed({8'b0, amp, 2'b0}) + $signed({10'b0, amp} >> 1)  : 18'sd0; // ~4.5*A
wire signed [17:0] p_n  = (p_fb >>> 14) + p_x;
wire signed [17:0] b_n  = (b_fb >>> 14) + b_x;
wire signed [19:0] lp_v = lp >>> (2'd3 - volume);
wire signed [25:0] n_mul = noise * $signed({1'b0, nenv});

always @(posedge clk) begin
	if (reset) begin
		nenv <= 0; p1 <= 0; p2 <= 0; b1 <= 0; b2 <= 0; lp <= 0; sample <= 0;
	end
	else if (ce) begin
		nenv <= pend ? {2'b00, amp, 6'b0} : nenv - (nenv >> 5);
		p2 <= p1; p1 <= p_n;
		b2 <= b1; b1 <= b_n;

		mix <= (n_mul >>> 7) + p1 + b1;
		lp  <= lp + (((mix - lp) * 9) >>> 4);

		// volume 3: lp, 2: lp/2 (about -10 dBFS peak), 1: lp/4, 0: silent
		sample <= ~|volume         ? 16'sd0 :
		          (lp_v >  20'sd32767) ? 16'sh7FFF :
		          (lp_v < -20'sd32768) ? 16'sh8000 : lp_v[15:0];
	end
end

endmodule
