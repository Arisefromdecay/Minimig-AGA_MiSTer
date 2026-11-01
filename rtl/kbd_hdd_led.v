// kbd_hdd_led.v
//
// Turns the (very short) IDE activity strobe into a visible flicker on the
// USB keyboard's Scroll Lock LED.
//
// Main_MiSTer reads the core's keyboard-LED request (UIO_GET_KBD_LED, 0x1F)
// only every 100 ms, so raw DRQ pulses would be missed. This module:
//   * stretches every activity pulse to HOLD_MS,
//   * while busy, blinks ON_MS on / OFF_MS off (both > 100 ms so every phase
//     is guaranteed to be seen by the HPS poll),
//   * always starts a new burst with the LED on, so even a single sector
//     read gives one blink.

module kbd_hdd_led
#(
	parameter CLK_HZ = 28_375_160, // Minimig clk_sys (PAL); NTSC is close enough
	parameter HOLD_MS = 200,
	parameter ON_MS   = 160,
	parameter OFF_MS  = 160
)
(
	input  clk,
	input  reset,
	input  activity,  // IDE activity strobe (any width)
	output led        // 1 = Scroll Lock LED on
);

// synchronise (cheap, and harmless if already in this domain)
reg [1:0] act_s = 0;
always @(posedge clk) act_s <= {act_s[0], activity};
wire act = act_s[1];

// 1 ms tick
localparam DIV = CLK_HZ / 1000;
reg [15:0] div_cnt = 0;
reg        tick = 0;
always @(posedge clk) begin
	tick <= 0;
	if (div_cnt == DIV - 1) begin
		div_cnt <= 0;
		tick    <= 1;
	end
	else div_cnt <= div_cnt + 1'd1;
end

// activity hold-off
reg [9:0] hold = 0;
always @(posedge clk) begin
	if (reset)              hold <= 0;
	else if (act)           hold <= HOLD_MS[9:0];
	else if (tick && |hold) hold <= hold - 1'd1;
end

wire busy = act | (|hold);

// blink phase, restarts with LED on at each new burst
localparam PERIOD = ON_MS + OFF_MS;
reg [9:0] phase = 0;
always @(posedge clk) begin
	if (reset | ~busy) phase <= 0;
	else if (tick)     phase <= (phase == PERIOD - 1) ? 10'd0 : phase + 1'd1;
end

assign led = busy && (phase < ON_MS);

endmodule
