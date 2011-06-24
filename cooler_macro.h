//
// ------- initialize vars and SFRs ---------------------------------
.MACRO	_INITIALIZE
		cli		

		ldi		BYTE_ACC,	OSCCAL_CAL	// calibr constant for 1.6 MHz
		out		OSCCAL, BYTE_ACC		// correct clock freq

		ldi		BYTE_ACC,	(1 << PORTB3) | (1 << PORTB1)	// set PB.1,3 to high
		out		PORTB,	BYTE_ACC		// setup portB pins

		ldi		BYTE_ACC,	(1 << PORTB1)
		out		DDRB,	BYTE_ACC		// set PORTB.1 to output


		ldi		BYTE_ACC, 	(1 << ACD)
		out		ACSR,	BYTE_ACC		// disable comparator

		ldi		BYTE_ACC,	(1 << ADEN) | (1 << ADPS2)	// ADEN | ADPS2 enable ADC, ADC freq = clock/16
		out		ADCSR,	BYTE_ACC		// configure ADC
		
		ldi		BYTE_ACC,	(1 << REFS0) | (1 << ADLAR) | (1 << MUX1) | (1 << MUX0)
		out		ADMUX,	BYTE_ACC		// External Vref to PORTB.0, ADLAR | ADC3 input

		ldi		BYTE_ACC,	(1 << CS02) | (1 << CS00)
		out		TCCR0,	BYTE_ACC		// timer 0 clock/1024

		ldi		BYTE_ACC,	(1 << TOIE0)// TOIE0 
		out		TIMSK,	BYTE_ACC		// enable int's from Timer0 overflow (6 Hz)
		
		ser		CUR_ADC					// current ADC = 255 (further in the code also sets ADC Buffer to 0xFF)
		out		OCR1B,	CUR_ADC			// OCR1B is also set to 0xFF
		
		clr		BYTE_ACC				// BYTE_ACC contains 0x00 - used further in the code
		out		OCR1A,	BYTE_ACC		// set OCR1A to 0 to drive PWM out low

#if INVERTED_PWM 
		// PWM mode, inverted PWM on PORTB.1, prescaler = clock / 32 (62.5 kHz, 16 uSec)
		ldi		MATH_COUNT,	(1 << PWM1) | (1 << COM1A1) | (1 << COM1A0) | (1 << CS13) | (1 << CS11)
#else
		// PWM mode, non-inverted PWM on PORTB.1, prescaler = clock / 32 (62.5 kHz, 16 uSec)
		ldi		MATH_COUNT,	(1 << PWM1) | (1 << COM1A1) | (1 << CS13) | (1 << CS11)
#endif
		out		TCCR1,	MATH_COUNT		// setup Timer1

		clr		FLAGS					// clear flags
		clr		FLAGS_EX				// clear extended flags

		// set ADC mean buffer to 255 - to avoid starting fan when empty buffer positions have 0
		ldi		ZL,	ADC_BUFFER + ADC_BUFFER_LEN

init_clr_buf:
		dec		ZL
		st		Z,		CUR_ADC		// CUR_ADC is already set to 0xFF by SER instruction above !
		brne	init_clr_buf

// buffer cleared, ZL set to 0
		out		ADCH,	CUR_ADC		// pre-fill ADCH with 255 as previous ADC reading

		set									// T flag is set to be used far below !!!

		in		MATH_COUNT,	MCUSR			//
		sbrc	MATH_COUNT,	WDRF			// WDRF	- check if Watchdog reset occurred
			bld		FLAGS,	WDR_OCCUR_FLAG	// set WDR_OCCUR_FLAG if yes

		clr		DIAG_COUNT				// clear diag timing
		in		DIAG_OUT_BYTE,	ADCH	// set to 255 diag ADC latch
		clr		ADC_LOAD_CORRECTION		// clear ADC correction
	
// check if button pressed upon power on
// if so, clear config info and enter test mode
		sbic	PINB,	PORTB3				// read button status
			rjmp	init_skip_clr_config	// not pressed upon power-on, skip unconfiguring

		//set										// make sure T flag is already set by SET instruction above !!!
		bld		FLAGS_EX,	TEST_MODE_FLAG			// set test mode flag

// clear config info
		ldi		WORD_ACC_L,	EEPROM_CONFIG_CRC		// write 0 to CRC to make EEPROM_CONFIG invalid
		rcall	eeprom_write						 

#if TRACK_RUN_COUNT
		ldi		WORD_ACC_L,	EEPROM_RUN_COUNT		// clear EEPROM run count & WDR count
		rcall	eeprom_write						// 
		rcall	eeprom_write_preinc
	#if EEPROM_WDR_COUNT
		rcall	eeprom_write_preinc						 
	#endif
#else
	#if EEPROM_WDR_COUNT
		ldi		WORD_ACC_L,	EEPROM_RUN_COUNT		// clear EEPROM run count & WDR count
		rcall	eeprom_write
	#endif
#endif
		
init_skip_clr_config:
		ldi		BYTE_ACC,	(1 << PORTB3) | (1 << PORTB1)
		out		DDRB,		BYTE_ACC				// set PORTB.1, 3 to output

// read min/max thresholds from EEPROM
		clr		WORD_ACC_H							// clear checksum accumulator
		ldi		WORD_ACC_L,		EEPROM_ADC_CORRECTION	// read config marker
		rcall	eeprom_read_checksum
		mov		ADC_LOAD_CORRECTION,	BYTE_ACC

		rcall	eeprom_read_preinc_checksum				// read EEPROM_U_MIN (++WORD_ACC_L)
		mov		MIN_ADC,		BYTE_ACC
		
		rcall	eeprom_read_preinc_checksum				// read EEPROM_U_MAX (++WORD_ACC_L)
		mov		MAX_ADC,		BYTE_ACC

		rcall	eeprom_read_preinc_checksum				// read EEPROM_CONFIG_CRC (++WORD_ACC_L)
		brne	init_config_incorrect					// checksum should be 0 - if not, config incorrect	
	
// config is ok, set flag

		set											// make sure T flag is already set by SET instruction above !!!
		bld		FLAGS,			CONFIG_SET_FLAG		// setting 'Config valid' flag

init_config_incorrect:

#if TRACK_RUN_COUNT
// increment EEPROM run count
		ldi		WORD_ACC_L,		EEPROM_RUN_COUNT
		rcall	eeprom_read
		inc		BYTE_ACC
		rcall	eeprom_write
		tst		BYTE_ACC
		brne	init_skip_run_count_high

		rcall	eeprom_read_preinc	// EEPROM_RUN_COUNT+1 (++WORD_ACC_L)
		inc		BYTE_ACC
		rcall	eeprom_write

init_skip_run_count_high:
#endif

#if TRACK_WDR_COUNT

		sbrs	FLAGS,			WDR_OCCUR_FLAG	// WDR occurred ?
			rjmp	init_skip_wdr_inc			// no, go to sei/main loop

// increment EEPROM WDR count
		ldi		WORD_ACC_L,		EEPROM_WDR_COUNT
		rcall	eeprom_read
		inc		BYTE_ACC		
		breq	init_skip_wdr_inc				// if WDR count was 255 - do not update in EEPROM to 0.	
		rcall	eeprom_write

#endif

// ----- enable interrupts - entering main loop
init_skip_wdr_inc:

		ldi		BYTE_ACC,		POWER_ON_CONTROL_DELAY
		mov		POWER_ON_DELAY,	BYTE_ACC

		clr		AUTO_CONFIG_STEP
		clr		FAN_CONTROL_TIMING				// TEST_MODE_COUNT in test mode
		clr		FAN_CONTROL_REQ_OCR
		clr		ENGINE_SHUTDOWN_COUNTER

		ldi		BYTE_ACC,		(1 << WDE) | (1 << WDP2) | (1 << WDP1) | (1 << WDP0)
		out		WDTCR,			BYTE_ACC		// enable WDT

		sei

.ENDMACRO
// -----------------------------------------------------------------------------------------------------------------


//
// ------- save configuration procedure  ---------------------------------------------------------------------------
.MACRO	_SAVE_CONFIG

		ldi		WORD_ACC_L,		EEPROM_ADC_CORRECTION
		mov		BYTE_ACC,		ADC_LOAD_CORRECTION
		mov		WORD_ACC_H,		BYTE_ACC			// checksum - 1st byte
		rcall	eeprom_write						// 
		
		mov		BYTE_ACC,		MIN_ADC				// write MIN_ADC to eeprom
		rcall	eeprom_write_preinc_checksum		// EEPROM_U_MIN (++WORD_ACC_L), checksum (WORD_ACC_H) += BYTE_ACC

		mov		BYTE_ACC,		MAX_ADC				// write MAX_ADC to eeprom
		rcall	eeprom_write_preinc_checksum		// EEPROM_U_MAX (++WORD_ACC_L), checksum (WORD_ACC_H) += BYTE_ACC

		neg		WORD_ACC_H							// make two's complement 
		
		mov		BYTE_ACC,		WORD_ACC_H
		rcall	eeprom_write_preinc					// EEPROM_CONFIG_CRC (++WORD_ACC_L)


.ENDMACRO
// -----------------------------------------------------------------------------------------------------------------


//
// ------- debug LED out procedure  --------------------------------------------------------------------------------
// PARAMS:
// @0 - bit number of PORTB the diag LED connected to
// @1 - first byte to flash out
// @2 - second byte to flash out
.MACRO	_DEBUG_OUT

			cpi		DIAG_COUNT,	64 + 16		// next byte to diag ?
			brne	diag_skip_flags_reload	// no, skip loading flags

			mov		DIAG_OUT_BYTE,	@2		// latch flags into DIAG_OUT_BYTE

diag_skip_flags_reload:
			cpi		DIAG_COUNT,	128 + 16	// two diag bytes flashed ?
			brcc	diag_inc_exit			// yes, form up pause by skipping diag flashes
			
			cpi		DIAG_COUNT,	64			// within first diag byte ?
			brcs	diag_out_bits			// yes, go to diag out bits

			cpi		DIAG_COUNT,	64 + 16		// less than beginning of second diag byte ?
			brcs	diag_inc_exit			// yes, form up pause by skipping diag flashes

diag_out_bits:
			mov		TEMP_T0, 	DIAG_COUNT
			andi	TEMP_T0, 	0x07		// phases 0..7 of current bit
			breq	diag_out_drive_1		// if phase 0 - LED always ON (either beginning of @@@@____ for "1", or @_______ for "0")

			sbrc	TEMP_T0,	2			// phases 4..7 ? (bit 2 set?)
				rjmp	diag_out_drive_0	// yes, LED OFF

			sbrs	DIAG_OUT_BYTE,	7		// current bit == "0" ?
				rjmp	diag_out_drive_0	// yes, go to LED OFF for phases 1..3

diag_out_drive_1:
			cbi		PORTB,	@0				// drive diag out low (LED ON)
			rjmp	diag_out_next

diag_out_drive_0:
			sbi		PORTB,	@0				// drive diag out high (LED OFF)

diag_out_next:
			inc		TEMP_T0					// check if next bit to be processed (TEMP_T0 becomes 0x08 then)
			sbrc	TEMP_T0,	3			// bit 3 set (means that 0x07 just become 0x08) ?
				lsl		DIAG_OUT_BYTE		// yes, shift left DIAG_OUT_BYTE to process next bit

diag_inc_exit:
			inc		DIAG_COUNT				// next phase
			cpi		DIAG_COUNT,	128 + 16 + 48	// 64 (1st diag byte) + 16 (pause) + 64 (2nd diag byte) + 48 (pause) = 192
			brne	diag_exit

			clr		DIAG_COUNT				// next diag cycle will start with 0x00
			in		DIAG_OUT_BYTE, @1		// latch current ADC reading into diag byte
					
diag_exit:


.ENDMACRO
// -----------------------------------------------------------------------------------------------------------------


//
// ------- test mode procedure - 0 to 75% fan speed stepped by 25% for 2 sec each ---------------------------------
.MACRO		_TEST_MODE_FAN

		mov		BYTE_ACC,	DIAG_COUNT			// get cycle counter (ranged 00000000..10111111)
		lsl		BYTE_ACC						// shift bits 5,4 to make them 7,6
		lsl		BYTE_ACC						//
		andi	BYTE_ACC,	0b11000000			// mask out lower bits
												// PWM changes 0%, 25%, 50%, 75%, 0% ... every 16 * 0.16 seconds

		sbrc	FLAGS,		FAN_ON_FLAG			// FAN ON request active ?
			in	BYTE_ACC,		OCR1B			// yes, ignore calculated PWM, set OCR1A = OCR1B to reach max duty cycle
		
		out		OCR1A,		BYTE_ACC			// write PWM value to PWM timer

.ENDMACRO
