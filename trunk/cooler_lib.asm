;
; 
; -------- perform ADC conversion and recalc mean ADC result ------------------------------------------------------
process_temp_sensor:

; wait for timer1 overflow to make sure OCR1A is actually loaded into internal OCR register
		ldi		WORD_ACC_L,		(1 << TOV1)		;
		out		TIFR,			WORD_ACC_L		; clear TOV1 in TIFR
		nop										; need any instruction to have TOV1 cleared by hardware. NOP will do here

adc_wait_ocr_overflow:	
		in		BYTE_ACC,		TIFR			; wait for TOV1 becoming 1
		sbrs	BYTE_ACC,		TOV1			; which means Timer1 overflow
			rjmp	adc_wait_ocr_overflow		; and guarantees OCR1A to be loaded into internal OCR

; wait until output pulse becomes low to eliminate affecting ADC voltage offset due to current thru common ground
		in		MATH_COUNT,		OCR1A			; read OCR1A to check if fan is on, off, or pulse-driven
		tst		MATH_COUNT						; fan is off ?
		breq	adc_guaranteed_mosfet_off		; yes, do not wait, go to adc start

		ldi		WORD_ACC_H,		1				; wait MOSFET off only once if no OCR reload is necessary

		cpi		MATH_COUNT,		OCR_ADC_VALUE	; current OCR1A < threshold for ADC measuring ?
		brcs	adc_wait_mosfet_next_cycle		; yes, no need to set lower PWM during ADC conversion - skipping setting lower PWM

; need to set lower PWM duty to have enough time for ADC while MOSFET is OFF
		ldi		BYTE_ACC,		OCR_ADC_VALUE	;
		out		OCR1A,			BYTE_ACC		; set lower PWM value during the ADC
		
		inc		WORD_ACC_H						; now we need an extra OCR reload, so waiting MOSFET off twice
												; once with current OCR and next time with new OCR value loaded
adc_wait_mosfet_next_cycle:
		ldi		WORD_ACC_L,		(1 << OCF1A)	;
		out		TIFR,			WORD_ACC_L		; clear OCF1A in TIFR
		nop										; need any instruction to have OCF1A cleared by hardware. NOP will do here

; wait until fan MOSFET turns off
adc_wait_mosfet_off:	
		in		BYTE_ACC,		TIFR			;
		sbrs	BYTE_ACC,		OCF1A			;
			rjmp	adc_wait_mosfet_off			; wait until MOSFET is driven low

; we have not less than approx 16 * (256 - OCR_ADC_VALUE) uSeconds while MOSFET is off
; +0

		dec		WORD_ACC_H						; if need to wait only once - this decrement will end the loop
		brne	adc_wait_mosfet_next_cycle		; otherwise, we'll perform another waiting cycle

adc_guaranteed_mosfet_off:
; now we need to wait while current oscillations upon MOSFET turning-off disappear 
; meanwhile taking the result of previous ADC cycle and calc mean value

; ------- get previous ADC cycle result
		in 		BYTE_ACC,	ADCH					; get result of previous ADC

		set											; set ADC disconnected flag
		cpi		BYTE_ACC,	DISCONNECTED_MAX_ADC	; temp sensor connected ?
		brcs	adc_disconnected_flag_set			; no, go to setting ADC_DISCONNECTED_FLAG

; sensor connected
		ldi		MATH_WORD_L,	ENGINE_SHUTDOWN_TIME		; set shutdown time
		mov		ENGINE_SHUTDOWN_COUNTER,	MATH_WORD_L		; to be used when entering shutdown mode

		clt											; clear T as ADC is connected
		bld		FLAGS,		ENGINE_SHUTTING_DOWN	; clear "engine off" flag and clear ADC_DISCONNECTED_FLAG then

adc_disconnected_flag_set:
		bld		FLAGS,		ADC_DISCONNECTED_FLAG	; set temp sensor disconnected flag accordingly

; ------- correct read ADC result using ADC_LOAD_CORRECTION
		sbrs	FLAGS,		CONFIG_SET_FLAG			; config set ?
			rjmp		adc_skip_correction			; no, skip correction

; ADC_LOAD_CORRECTION is for full RPM (256)
; so, to get correction for current RPM we need to calculate correction = ADC_LOAD_CORRECTION * OCR1A / 256
; i.e. take high byte of ADC_LOAD_CORRECTION * OCR1A
		mov		MATH_WORD_L,	ADC_LOAD_CORRECTION
		mov		BYTE_ACC,		MATH_COUNT			; MATH_COUNT = OCR1A (current PWM)
		rcall	mul16_8u							; WORD_ACC_H:WORD_ACC_L = ADC_LOAD_CORRECTION * OCR1A

		in 		BYTE_ACC,	ADCH					; get result of previous ADC again
		add		BYTE_ACC,	WORD_ACC_H				; and correct the result, taking high byte as low (thus dividing by 256)

		set											;
		tst		WORD_ACC_H							; set ADC_CORRECTED_FLAG if correcting value > 0
		brne	adc_corr_flag_set					;
		clt											;

adc_corr_flag_set:
		bld		FLAGS,		ADC_CORRECTED_FLAG		;

; ------ handle ADC_DISCONNECT_FLAG, ENGINE_SHUTTING_DOWN flags
adc_skip_correction:
		sbrs	FLAGS,		ADC_DISCONNECTED_FLAG	; temp sensor disconnected ?
			rjmp	adc_sensor_connected			; no, skip shutdown logic

; process disconnected ADC
		sbrs	FLAGS_EX,	FAN_PULSE_OCCUR_FLAG	; fan pulses ever occurred ?
			rjmp	adc_skip_store_and_recalc		; no, skip shutdown and recalculating mean ADC logic

		sbrs	FLAGS_EX,	ADC_EVER_CONNECTED_FLAG	; temp sensor ever connected ?
			rjmp	adc_skip_store_and_recalc		; no, sensor never been connected, skip shutdown and recalculating mean ADC logic

		set
		bld		FLAGS,		ENGINE_SHUTTING_DOWN	; set "engine off" flag

		rjmp	adc_skip_store_and_recalc			; skip mean recalculation

; ADC reading in range (sensor connected), store ADC result
adc_sensor_connected:

; correct sudden negative surges by limiting ADC reading dynamics
		tst		POWER_ON_DELAY							; power-on time elapsed ?
		brne	adc_store_reading						; no, skip correcting dynamics

		sbrs	FLAGS,			CONFIG_SET_FLAG			; thresholds configured ?
			rjmp	adc_store_reading					; no, skip dynamic correction	

		mov		MATH_WORD_L,	CUR_ADC					;
		sub		MATH_WORD_L,	BYTE_ACC				; new ADC > mean ADC ?
		brcs	adc_store_reading						; yes, do not limit positive dynamics
		
; dynamics negative - limit it
		cpi		MATH_WORD_L,	ADC_MAX_NEG_DYNAMICS	; exceeds max negative dynamics ?
		brcs	adc_store_reading						; no, store uncorrected

		mov		BYTE_ACC,		CUR_ADC					;
		subi	BYTE_ACC,		ADC_MAX_NEG_DYNAMICS	; yes, limit ADC drop to ADC_MAX_NEG_DYNAMICS readings in every ADC cycle

adc_store_reading:
		inc		ZL								; pre-inc ptr
		andi	ZL,		(ADC_BUFFER_LEN - 1)	; make it roll (0..7)		
		st		Z,		BYTE_ACC				; store in ADC buffer @ current ptr

; ------ recalculate mean ADC from 8 previous ADC results
		clr		WORD_ACC_L				;
		clr		WORD_ACC_H				; clear accumulated sum

		mov		ZH,			ZL			; store Z in r31

		ldi		ZL,			ADC_BUFFER + ADC_BUFFER_LEN - 1
; +14

adc_recalc_mean:
		ld		BYTE_ACC,	Z
		add		WORD_ACC_L,	BYTE_ACC	; low result += [z]
		clr		BYTE_ACC
		adc		WORD_ACC_H, BYTE_ACC
		dec		ZL						; ptr--
		brpl	adc_recalc_mean			; while <> 0 - next reading
; +48 + 16 = +64

		mov		ZL,			ZH			; restore Z

; WORD_ACC_H:WORD_ACC_L contains average ADC reading * ADC_BUFFER_LEN
; shift right 3 times (div by 8) to find mean reading
		ror		WORD_ACC_H
		ror		WORD_ACC_L

		ror		WORD_ACC_H
		ror		WORD_ACC_L

		ror		WORD_ACC_H
		ror		WORD_ACC_L

; WORD_ACC_L now contains average ADC reading
		mov		CUR_ADC,	WORD_ACC_L	; save calculated mean in CUR_ADC

; set CUR_ADC IN RANGE flag according to new CUR_ADC value
		clt		
		cpi		CUR_ADC,	AUTO_CONFIG_MIN_ADC		; CUR_ADC < lower threshold ?
		brcs	adc_set_in_range					; yes, go to clearing flag

		ldi		BYTE_ACC,	AUTO_CONFIG_MAX_ADC
		cp		BYTE_ACC,	CUR_ADC					; CUR_ADC > AUTO_CONFIG_MAX_ADC ?
		brcs	adc_set_in_range					; yes, go to clearing flag

		set											; CUR_ADC in range, set T to copy to the flag
		bld		FLAGS_EX,	ADC_EVER_CONNECTED_FLAG	; and set temp sensor ever connected

adc_set_in_range:
		bld		FLAGS_EX,	CUR_ADC_IN_RANGE_FLAG	; set CUR_ADC_IN_RANGE_FLAG

adc_skip_store_and_recalc:
; ----------------------------
; start ADC conversion
; conversion time = 20usec * 15 cycles = 300usec
; no need to disable ints - t0 overflow never happens as main routine is synchronized with t0 overflow 

; ADC conversion start		
		ldi		BYTE_ACC,	(1 << ADEN) | (1 << ADSC) | (1 << ADPS2)	; ADEN | ADSC | ADPS2 enable ADC, clock/16
		out		ADCSR,		BYTE_ACC		; start ADC
; +66 (40 us)

adc_wait_completion:
		sbic	ADCSR, 		ADSC			; go to save ADC result when ADC finished
			rjmp	adc_wait_completion		; wait until ADC completes
	
; -----------------------------

		out		OCR1A,		MATH_COUNT	; restore OCR1A if was changed for ADC purpose

#if ADC_EVERY_CYCLE
; do not use ADC flag
#else
		clt								; clear ADC_FLAG
		bld		FLAGS_EX,	ADC_FLAG	; ready for next ADC cycle
#endif
		ret

; -----------------------------------------------------------------------------------------------------------------


;
; 
; ------ calculate OCR1A value (duty cycle) for current temp (ADC reading) ----------------------------------------
calc_set_pwm_duty:
; in: CUR_ADC - ADC reading
; out: BYTE_ACC - OCR1A value

		in		BYTE_ACC,		OCR1B
		sbrc	FLAGS,		FAN_ON_FLAG			; fan ON requested ?
			rjmp	calc_pwm_set				; yes, exit with fan @ full RPM
		
		clr		BYTE_ACC							; prepare value for fan OFF

		sbrs	FLAGS,			ENGINE_SHUTTING_DOWN	; engine shutdown ?
			rjmp	calc_pwm_no_shut					; no, skip s/d logic

; processing engine shutdown
		tst		ENGINE_SHUTDOWN_COUNTER					; s/d counter zero ?
		breq	calc_pwm_set							; yes, exit with fan stopped

		ldi		BYTE_ACC,	OCR_ENGINE_OFF_VALUE		; no, set shutdown PWM
		rjmp	calc_pwm_set							; and exit

calc_pwm_no_shut:
		sbrc	FLAGS,			ADC_DISCONNECTED_FLAG	; temp sensor connected ?
			rjmp	calc_pwm_set					; no, turn OFF fan

		tst		AUTO_CONFIG_STEP					; in autoconfig (and no FAN ON request - checked above)?
		brne	calc_pwm_skip_set					; yes, exit without changing PWM at all

		sbrs	FLAGS,			CONFIG_SET_FLAG		; thresholds configured ?
			rjmp	calc_pwm_set					; no, turn OFF fan

		tst			POWER_ON_DELAY					; power-on time elapsed ?
		brne 		calc_pwm_set					; no, turn OFF fan

		cp		MAX_ADC,		CUR_ADC				; greater than MAX_ADC ?
		brcs	calc_pwm_set						; yes, turn fan off

		ldi		BYTE_ACC,		OCR_MAX_VALUE		; prepare value for fan ON
		cp		CUR_ADC,		MIN_ADC				; less than MIN_ADC ?
		brcs	calc_pwm_set						; yes, set max PWM duty

; calculate PWM duty cycle as
; OCR_MIN_VALUE + (Umax - U) * (OCR_MAX_VALUE - OCR_MIN_VALUE) / (Umax - Umin) 
		mov		BYTE_ACC,		MAX_ADC							;
		sub		BYTE_ACC,		CUR_ADC							; BYTE_ACC = (Umax - U)

		ldi		MATH_WORD_L,	OCR_MAX_VALUE - OCR_MIN_VALUE	; MATH_WORD_L = (OCR_MAX_VALUE - OCR_MIN_VALUE)

											; BYTE_ACC = (Umax - U), 
		rcall	mul16_8u					; MATH_WORD_L = (OCR_MAX_VALUE - OCR_MIN_VALUE)
											; result: WORD_ACC_H:WORD_ACC_L = (Umax - U) * (OCR_MAX_VALUE - OCR_MIN_VALUE)

		mov		BYTE_ACC,		MAX_ADC
		sub		BYTE_ACC,		MIN_ADC		; BYTE_ACC = (Umax - Umin)	

											; BYTE_ACC = (Umax - Umin)	
		rcall	div16_8u					; WORD_ACC_H:WORD_ACC_L = (Umax - U) * (OCR_MAX_VALUE - OCR_MIN_VALUE)
											; result: WORD_ACC_H:WORD_ACC_L = (Umax - U) * (OCR_MAX_VALUE - OCR_MIN_VALUE) / (Umax - Umin)
	
		ldi		BYTE_ACC,		OCR_MIN_VALUE	; adding OCR_MIN_VALUE to the result
		add		BYTE_ACC,		WORD_ACC_L		; BYTE_ACC = OCR_MIN_VALUE + (Umax - U) * (OCR_MAX_VALUE - OCR_MIN_VALUE) / (Umax - Umin)

calc_pwm_set:
		mov		FAN_CONTROL_REQ_OCR,	BYTE_ACC	; store needed PWM in pending location (to be used by fan_process)

calc_pwm_skip_set:
		ret										; return with BYTE_ACC = PWM duty value

; -----------------------------------------------------------------------------------------------------------------


; ------ soft-start for cooler fan procedure --------------------------------------------------------
; performs a soft-start for cooler fan
; does not allow changing ON/OFF state within less than MIN_FAN_STATE_TIME 640msec counts
; except when in unconfigurated state or due to explicit FAN ON request
process_fan_pwm:
		mov		BYTE_ACC,		FAN_CONTROL_REQ_OCR		;
		in		WORD_ACC_L,		OCR1A					;
		cp		WORD_ACC_L,		BYTE_ACC				; actual PWM == desired ?
		breq	fan_proc_exit							; yes, exit

		sbrs	FLAGS,		CONFIG_SET_FLAG			; config set ?
			rjmp		fan_proc_set_pwm			; no, skip state time & smoothing logic	- set PWM immediately

		sbrc	FLAGS,		ENGINE_SHUTTING_DOWN	; shutdown ?
			rjmp		fan_proc_set_pwm			; yes, skip state time & smoothing logic - set PWM immediately

		tst		BYTE_ACC							; fan ON requested ?
		brne	fan_proc_request_on					; yes, process FAN ON

; requested PWM == 0
		tst		WORD_ACC_L							; requested OFF, check if current state is OFF
		breq	fan_proc_no_change					; current is OFF - no change in fan state, go to fan control

		tst		FAN_CONTROL_TIMING					; current is ON - check if time elapsed to change fan state
		breq	fan_proc_change_reload				; elapsed, proceed with stopping fan

; current is ON while OFF requested within less than MIN_FAN_STATE_TIME
		ldi		BYTE_ACC, 	OCR_MIN_VALUE			; keep fan at min power until MIN_FAN_STATE_TIME elapsed
		rjmp	fan_proc_no_change

; requested PWM > 0
fan_proc_request_on:
		sbrc	FLAGS,		FAN_ON_FLAG				; FAN ON request active and requested > 0 ?
			rjmp	fan_proc_set_pwm				; yes, skip state time & smoothing logic - set PWM immediately

		tst		WORD_ACC_L							; requested ON, check current
		brne	fan_proc_no_change					; current ON, no change in fan state, go to fan control

		tst		FAN_CONTROL_TIMING					; fan state changed - check if time elapsed to change fan state
		brne	fan_proc_exit						; not yet elapsed, do not change PWM, exiting

fan_proc_change_reload:
		ldi		FAN_CONTROL_TIMING,		MIN_FAN_STATE_TIME	; yes, reload state time counter and proceed with state change

fan_proc_no_change:
		cp		BYTE_ACC,		WORD_ACC_L			; check if new duty cycle > current
		brcs	fan_proc_set_pwm					; no, new duty < current, so skip smoothing PWM duty cycle
		
; PWM smoothing logic
; new duty > current
		tst		WORD_ACC_L							; fan was off ?
		brne	fan_proc_limit_positive				; no, go to smoothing value

		ldi		BYTE_ACC, 		OCR_START_VALUE		; fan was OFF, so to rev up fan, load constant fan start value
		rjmp 	fan_proc_set_pwm					; start with OCR_START_VALUE

; limit fan dynamics MAX_FAN_DYN_DUTY
fan_proc_limit_positive:
		mov		WORD_ACC_H,		BYTE_ACC
		sub		WORD_ACC_H,		WORD_ACC_L			; WORD_ACC_H = requested PWM - last PWM
		cpi		WORD_ACC_H,		MAX_FAN_DYN_DUTY	; difference exceeds max positive dynamics ?
		brcs	fan_proc_set_pwm					; no, set as requested

		mov		BYTE_ACC,		WORD_ACC_L			; yes, limit positive dynamics
		subi	BYTE_ACC,	-MAX_FAN_DYN_DUTY		; to MAX_FAN_DYN_DUTY

fan_proc_set_pwm:
		out		OCR1A,			BYTE_ACC			; set new PWM in OCR

		tst		BYTE_ACC							; we just loaded turn off fan OCR value?
		breq	fan_proc_exit						; yes, skip setting pulse occur flag

		set												; fan was ON at least once,
		bld		FLAGS_EX,		FAN_PULSE_OCCUR_FLAG	; set FAN_PULSE_OCCUR_FLAG accordingly

fan_proc_exit:		
		ret

; -------------------------------------------------------------------------


;
; -----	autoconfig steps dispatcher --------------------------
;
process_auto_config:
		tst			AUTO_CONFIG_STEP
		breq		ac_continue

		mov			MATH_COUNT,	AUTO_CONFIG_STEP
		dec			MATH_COUNT
		breq		ac_step_SAVING_CONFIG
		dec			MATH_COUNT
		breq		ac_step_WAITING_GAP
		dec			MATH_COUNT
		breq		ac_step_SLOWING_FAN
		dec			MATH_COUNT
		breq		ac_step_WAITING_FAN_OFF
		dec			MATH_COUNT
		breq		ac_step_SAVING_CORRECTION

ac_error:
		set
		bld			FLAGS,		CONFIG_ERROR_FLAG		; set error flag
		clr			AUTO_CONFIG_STEP					; clear step code
		rjmp		ac_exit								; exit
				
; ----------------------------
; save ADC correction value due to common ground and voltage drop
ac_step_SAVING_CORRECTION:
		sbrs	FLAGS,		FAN_ON_FLAG	; fan on ?
			rjmp	ac_error			; no, error as it should be on during at least 4 * 0.64 seconds

		dec		AUTO_CONFIG_TIMING
		brne	ac_continue

		clr		ADC_LOAD_CORRECTION			; set correction = 0
		mov		BYTE_ACC,	MIN_ADC
		ld		WORD_ACC_L,	Z				; get last stored ADC value directly from buffer
		sub		BYTE_ACC,	WORD_ACC_L		; MIN ADC < last stored ADC?
		brcs	ac_step_corr_skip			; yes, leave correction = 0

		inc		BYTE_ACC					; add 1 to have rounding rather than truncation when calculating proportional correction

		mov		ADC_LOAD_CORRECTION,	BYTE_ACC	; save correction

ac_step_corr_skip:
		rjmp	ac_next_step		


; ----------------------------
; wait until fan request is OFF, then go to next step
ac_step_WAITING_FAN_OFF:
		sbrc	FLAGS,		FAN_ON_FLAG	
			rjmp	ac_continue

		ldi		BYTE_ACC,	AUTO_CONFIG_OCR_VALUE_1	; set high fan rpm
		mov		FAN_CONTROL_REQ_OCR,	BYTE_ACC

ac_next_step:
		dec		AUTO_CONFIG_STEP					; next step & exit
ac_continue:
		rjmp	ac_exit							; exit

; ----------------------------
; slowing down fan, go to next step when OFF
; check if button is pressed during slowdown, then store current ADC as max and go to save autoconfig
ac_step_SLOWING_FAN:
		sbrc	FLAGS,		FAN_ON_FLAG			; fan on ?
			rjmp	ac_error					; yes, go to error as it should be off during slowing FAN

		sbrc	FLAGS_EX,	BUTTON_FLAG			; button pressed ?
			rjmp	ac_step_BUTTON_DETECTED		; yes, skip further steps, go to processing button

		dec		FAN_CONTROL_REQ_OCR
		mov		BYTE_ACC,			FAN_CONTROL_REQ_OCR
		cpi		BYTE_ACC,			AUTO_CONFIG_OCR_VALUE_2
		brcc	ac_continue

		clr		FAN_CONTROL_REQ_OCR

		ldi		AUTO_CONFIG_TIMING,		AUTO_CONFIG_GAP_TIME	; set gap time counter, go to next step

		rjmp	ac_next_step

; ----------------------------
; wait AUTO_CONFIG_TIMING * 640 msec with fan OFF, then store current ADC as max and go to next step
; check if button is pressed during waiting, then store current ADC as max and go to save autoconfig
ac_step_WAITING_GAP:
		sbrc	FLAGS,		FAN_ON_FLAG			; fan on ?
			rjmp	ac_error					; yes, go to error as it should be off during slowing FAN

		sbrc	FLAGS_EX,		BUTTON_FLAG			; button pressed ?
			rjmp	ac_step_BUTTON_DETECTED			; yes, skip further steps, go to processing button
		
		dec		AUTO_CONFIG_TIMING
		brne	ac_continue

		sbrs	FLAGS_EX,	CUR_ADC_IN_RANGE_FLAG	; current ADC in range ?
			rjmp	ac_error						; no, set autoconfig error

		mov		MAX_ADC,	CUR_ADC				; store cur ADC as max ADC

; sub 1/8 of MAX-MIN from MAX to shift up fan turn on threshold
; when set automatically
		mov		BYTE_ACC,	CUR_ADC				; BYTE_ACC = max - min
		sub		BYTE_ACC,	MIN_ADC				;
		brcs	ac_error						; no, set autoconfig error

		lsr		BYTE_ACC
		lsr		BYTE_ACC
		lsr		BYTE_ACC						; BYTE_ACC = (max - min) / 8

		sub		MAX_ADC,	BYTE_ACC			; MAX_ADC = MAX_ADC - (max - min) / 8
		rjmp	ac_next_step

ac_step_BUTTON_DETECTED:
		sbrs	FLAGS_EX,	CUR_ADC_IN_RANGE_FLAG	; current ADC in range ?
			rjmp	ac_error						; no, set autoconfig error

		mov		MAX_ADC,		CUR_ADC					; store cur ADC as max ADC
		ldi		AUTO_CONFIG_STEP,	STEP_SAVING_CONFIG	; set next step as STEP_SAVING_CONFIG
		rjmp	ac_continue								; go to exiting

; ----------------------------
; save min/max thresholds with checksum, set up 'Configured' flag and exit autoconfig mode
ac_step_SAVING_CONFIG:
; check that MAX_ADC > MIN_ADC
		mov		BYTE_ACC,	MAX_ADC				; BYTE_ACC = max - min
		sub		BYTE_ACC,	MIN_ADC				; MAX > MIN ?
		brcs	ac_error						; no, set autoconfig error

		cpi		BYTE_ACC,	CONFIG_MIN_MAX_GAP	; MAX - MIN >= CONFIG_MIN_MAX_GAP ?
		brcs	ac_error						; no, set autoconfig error	

.LISTMAC
		_SAVE_CONFIG							; save configuration to EEPROM
		
		set										;
		bld		FLAGS,		CONFIG_SET_FLAG		; set CONFIG_SET_FLAG in current variable

		rjmp	ac_next_step

ac_exit:
		set
		tst			AUTO_CONFIG_STEP
		brne		ac_exit_set_flag
		clt

ac_exit_set_flag:
		bld			FLAGS,		AUTO_CONFIG_FLAG
		ret

; -------------------------------------------------------------------------


		.include	"math.asm"
		.include	"eeprom.asm"

; -------------------------------------------------------------------------



