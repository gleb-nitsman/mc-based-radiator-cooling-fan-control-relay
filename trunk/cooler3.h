//
// DEVICE PINOUT CONFIG

// PB0 (Aref) 	- Vref for ADC
// PB1 (OC1A) 	- pulse out
// PB2 			- ^FAN_ON
// PB3 			- ^BUTTON / DIAG_OUT (LED)
// PB4 (ADC3) 	- analog IN (temp sensor)


// !!!!!!!!!!!!!!!!!!
// if power MOSFET can be driven directly by PWM output (logic level MOSFET),
// set the following define variable to 0
// otherwise, if bipolar inverting cascade is used, set to 1
//
#define INVERTED_PWM (1)
//
// !!!!!!!!!!!!!!!!!!


// set to 1 to write in EEPROM CPU ignition ON counts occurred since last test mode
#define TRACK_RUN_COUNT (0)
//


// set to 1 to write in EEPROM CPU resets occurred due to watchdog timer
#define TRACK_WDR_COUNT (0)
//

// set to 1 to perform ADC in every MAIN_SYNC cycle (every 640 msecs)
// when set to 0 - ADC is performed every 2nd MAIN_SYNC (every 1.28 secs)
#define ADC_EVERY_CYCLE (1)
//

// fan duty cycle calculation:
// OCR1B = 255
// OCR1A value: 
// U < Umin : 240
// Umin <= U <= Umax : 38 + (Umax - U) / (Umax - Umin) * (256 - 38)
// Umax < U : 0
// max OCR1A = 240 that gives 15 Timer1 counts min for ADC conversion
// Timer1 count period = 0.625 uS * 32 = 20 uS/count -> 300 uS / ADC conversion min.

.equ	OCR_MIN_VALUE	=	31		// min fan duty cycle = 31/256 (12%)
.equ	OCR_MAX_VALUE	=	255		// max fan duty cycle = 255/256 (93% when turned on by temp sensor)
.equ	OCR_ADC_VALUE	=	200		// provides gap for temp sensor voltage ADC while MOSFET is off (16 uSec * 36 = 576 uSeconds)
.equ	OCR_START_VALUE	=	76		// start fan duty cycle = 76/256 (30%) 
.equ	OCR_ENGINE_OFF_VALUE	=	128	// fan speed during engine shutoff = 128/256 (50%) 
.equ	MIN_FAN_STATE_TIME		=	23	// 15 sec / 0.64 = 23 * 640ms synchronized fan_control calls
.equ	MAX_FAN_DYN_DUTY		=	2	// 
.equ	POWER_ON_CONTROL_DELAY	=	23	// 15 sec / 0.64 = 23 * 640ms synchronized fan_control calls
.equ	ENGINE_SHUTDOWN_TIME	=	13	// 8 sec

// ======= auto config settings ===============
//
.equ	AUTO_CONFIG_CORR_TIME		= 	4	// 4 * 0.64 = 3 sec

// fan slows down from 75 to 12% duty for 164 * 0.64 seconds = 103 secs
.equ	AUTO_CONFIG_OCR_VALUE_1		=	192
.equ	AUTO_CONFIG_OCR_VALUE_2		=	31

// then fan is paused for 60 seconds
.equ	AUTO_CONFIG_GAP_TIME		= 	94	// 60 sec / 0.64  = 94 
//

// auto config algo:
;
// 1. is activated when config not set and ECU "fan on" request becomes active
// 2. remember ADC reading at "fan on" request as T1
// 3. wait until "fan on" becomes inactive again
// 4. turn on fan at AUTO_CONFIG_OCR_VALUE_1 speed for AUTO_CONFIG_FAN_ON_TIME_1 seconds
// 5. slow down fan to AUTO_CONFIG_OCR_VALUE_2 speed and keep it running for AUTO_CONFIG_FAN_ON_TIME_2 seconds
// 6. turn off fan
// 7. wait AUTO_CONFIG_GAP_TIME seconds
// 8. make sure that no "fan on" requests come from ECU during steps 4-7
// 9. if step 8 is FALSE - exit from the auto config procedure
// 10. check for button pressed during step 7 - if pressed, go to step 11
// 11. remember ADC reading as T2
// 12. set start threshold as T2 and end threshold as T1

// ============================================
.equ	STEP_SAVING_CORRECTION	=	5
.equ	STEP_WAITING_FAN_OFF 	=	4
.equ	STEP_SLOWING_FAN		=	3
.equ	STEP_WAITING_GAP		=	2
.equ	STEP_SAVING_CONFIG		= 	1



// approx Uts (U temp sensor) @ 14V (running engine)
//
//	t, C		U, V
//
//	45			9.0
//	60			7.4
//	65			6.5
//	70			6.15
//	75			5.7
//	80			5.2
//	85			4.65

// Uts @ 13V (stall engine) @ 85 C = 4.02

.equ	CONFIG_MIN_MAX_GAP		=	4			// min difference between T1 and T2 ADC readings
.equ	DISCONNECTED_MAX_ADC	=	16			// max ADC when temp sensor is disconnected
.equ	AUTO_CONFIG_MAX_ADC		=	248			// max ADC reading for T1
.equ	AUTO_CONFIG_MIN_ADC		=	24			// max ADC reading for T2
.equ	ADC_MAX_NEG_DYNAMICS	=	2			// max negative difference

		.include	"tn15def.inc"


.equ	OSCCAL_CAL		= 	133;117;138

//
// ------------- Register variables assignment -----------------
//
// R0..R7 - ADC average calc buffer
.equ	ADC_BUFFER		=	0
.equ	ADC_BUFFER_LEN	=	8


// -------------  R8 - Flags ----------------------------------
.def	FLAGS			=	r8
		.equ	ENGINE_SHUTTING_DOWN	=	0
		.equ	FAN_ON_FLAG				=	1
		.equ	WDR_OCCUR_FLAG			= 	2
		.equ	AUTO_CONFIG_FLAG		= 	3
		.equ	CONFIG_ERROR_FLAG		= 	4
		.equ	CONFIG_SET_FLAG			= 	5
		.equ	ADC_DISCONNECTED_FLAG	=	6
		.equ	ADC_CORRECTED_FLAG		=	7
// ------------------------------------------------------------

// -------------  R9 - Extended Flags -------------------------
.def	FLAGS_EX		=	r9
		.equ	MAIN_SYNC_FLAG			=	0
		.equ	ADC_FLAG		 		=	1
		.equ	ADC_EVER_CONNECTED_FLAG	=	2
		.equ	BUTTON_FLAG				= 	3
		.equ	FAN_ON_CHANGED_FLAG		= 	4
		.equ	FAN_PULSE_OCCUR_FLAG	= 	5
		.equ	TEST_MODE_FLAG			=	6
		.equ	CUR_ADC_IN_RANGE_FLAG	= 	7
// ------------------------------------------------------------

// -------------  R10 - SREG for ISRs -------------------------
.def	SREG_COPY		= 	r10
// ------------------------------------------------------------

// ------------- R11, R12 - High/Low Temp thresholds ----------
.def	MIN_ADC			=	r11
.def	MAX_ADC			=	r12	
// ------------------------------------------------------------

// ------------- Power-on delay -----------
.def	POWER_ON_DELAY		=	r13
// ------------------------------------------------------------

// ------------- Fan control -----------
.def	FAN_CONTROL_REQ_OCR	=	r14
// ------------------------------------------------------------

.def	ENGINE_SHUTDOWN_COUNTER	=	r15

// ------------- R16..R21 - Math variables --------------------
.def	BYTE_ACC		= 	r16
.def	MATH_COUNT		= 	r17
.def	WORD_ACC_L		=	r18
.def	WORD_ACC_H		=	r19
.def	MATH_WORD_L		=	r20
.def	MATH_WORD_H		=	r21
// ------------------------------------------------------------

// ------------- Mean ADC reading -----------------------------
.def	CUR_ADC			=	r22
// ------------------------------------------------------------

// -------------	T0_OVERFLOW ISR variables --------------------
.def	DIAG_OUT_BYTE	=	r23			// diagnostics byte latch
.def	DIAG_COUNT		=	r24			// diagnostics counter
.def	TEMP_T0			=	r25			// temp variable for the ISR
// ------------------------------------------------------------

// ------------- Autoconfig Timing ----------------------------
.def	AUTO_CONFIG_TIMING	=	r26
.def	AUTO_CONFIG_STEP 	=	r27
// ------------------------------------------------------------

// ------------- FAN control and test mode vars ---------------
.def	FAN_CONTROL_TIMING	=	r28
// ------------------------------------------------------------

// ------------- ADC correction at full fan RPM ---------------
.def	ADC_LOAD_CORRECTION	=	r29
// ------------------------------------------------------------

