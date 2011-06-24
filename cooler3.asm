		.include	"cooler3.h"
		.include	"cooler_macro.h"

; ------------------------------------
		.cseg
		.org	0


; ============= VECTORS ================================================================
		
			rjmp	RESET
			rjmp	INTERRUPT0
			rjmp	PIN_CHANGE
			rjmp	T1_COMPARE
			rjmp	T1_OVERFLOW
			rjmp	T0_OVERFLOW
			rjmp	EE_READY
			rjmp	COMPARATOR
			rjmp	ADC_COMPLETE

INTERRUPT0:
PIN_CHANGE:
T1_COMPARE:
T1_OVERFLOW:
EE_READY:
COMPARATOR:
ADC_COMPLETE:
			reti


; =====================================================================================
; 

; =====================================================================================
;
; --------------------------- timer 0 interrupt ---------------------------------------
; occurs every 160 msec approx (exact period is CLK * 1024 * 256)
;
;
; provides general time synchronization,
; polls button and ^FAN_ON input,
; flashes out current ADC reading & FLAGS diagnostic bytes via LED connected to PORTB.3

T0_OVERFLOW:
			in		SREG_COPY,	SREG			; store uP status at the same var as no nested ints allowed

; check that main routine executed completely since last timer int (MAIN_SYNC_FLAG should be cleared by the main routine)
			set									;
			sbrc	FLAGS_EX,	MAIN_SYNC_FLAG	; main routine processed sync cycle ?
				bld		FLAGS,	WDR_OCCUR_FLAG	; no, set routine error flag

; skip 640ms-driven procedures unless it is every 4th int
			mov		TEMP_T0,	DIAG_COUNT		; poll button & ^FAN_ON on every 4th Int0 cycle - i.e. every 640 ms
			andi	TEMP_T0,	0x03			; same for ADC flag
			brne	diag_out_start

; ------ checking button, fan on request and setting main sync request
			;set								; T was set above !!!
			bld		FLAGS_EX,	MAIN_SYNC_FLAG	; set main sync flag (every 640 ms)

; preparing for checking button
			ldi		TEMP_T0,	(1 << PORTB1)
			out		DDRB,		TEMP_T0		; set PORTB.3 to input (PORTB1 remains to be output)

			sbi		PORTB,		PORTB3		; set to high to turn on pull-up


#if ADC_EVERY_CYCLE
; do not handle ADC flag
#else
; wait after setting PORTB.3 to input, setting ADC_FLAG meanwhile
			sbrs	DIAG_COUNT,	2					; skip setting ADC request if DIAG_COUNT % 8 != 0 							
				bld		FLAGS_EX,	ADC_FLAG		; set ADC cycle request
#endif

; now checking ^FAN_ON (PORTB.2) input
			;set								; T was set above !!!
			sbic	PINB,		PORTB2			; read ^FAN_ON status
				clt
; T now contains current 'fan on' status (as read from PINB.2)

; check previous flag status
			sbrs	FLAGS,		FAN_ON_FLAG	; last time was ON ?
				rjmp	t0_fan_last_off		; no, last time was OFF - process it

; last time was ON
			bld		FLAGS,		FAN_ON_FLAG	; save new 'fan on' status
			brtc	t0_fan_set_changed		; go to setting 'fan changed' flag if current status is cleared
			rjmp	t0_check_button			; skip setting 'fan changed' otherwise

t0_fan_last_off:
			bld		FLAGS,		FAN_ON_FLAG	; save new 'fan on' status
			brtc	t0_check_button			; skip setting 'fan changed' flag if current fan status (stored in T) is cleared

t0_fan_set_changed:
			set
			bld		FLAGS_EX,	FAN_ON_CHANGED_FLAG	

; read button status
t0_check_button:
			set
			sbic	PINB,		PORTB3		; read button status
				clt
			bld		FLAGS_EX,	BUTTON_FLAG	; set button pressed flag accordingly

; restore PORTB.3 diag out
			ldi		TEMP_T0,	(1 << PORTB3) | (1 << PORTB1)	; restore PORTB outputs
			out		DDRB,		TEMP_T0							; set PORTB.1,3 to output
		

; --------------------------------------------------------

diag_out_start:

.LISTMAC
			_DEBUG_OUT		PORTB3, 	ADCH,	FLAGS	

			out		SREG, 	SREG_COPY		; restore uP status
			reti							; return from int

; =====================================================================================



; =====================================================================================
;
; ---------------------------------- Reset vector -------------------------------------

RESET:

.LISTMAC
		_INITIALIZE			; initialize vars and SFRs


; ====== main loop ===============================================
; tracks ADC start flag set by timer0 int
; performs ADC, stores ADC result
; calculates mean adc reading from last 8 ADC cycles (sliding frame)
; controls fan according to FAN_ON signal and mean reading for temp sensor

wait_loop:
		sbrs		FLAGS_EX,	MAIN_SYNC_FLAG	; wait for main sync
			rjmp	wait_loop

#if ADC_EVERY_CYCLE
; call process_temp_sensor on every sync cycle
#else
		sbrc		FLAGS_EX,	ADC_FLAG			; ADC requested ?
#endif
			rcall	process_temp_sensor				; yes, do temp sensor ADC


		sbrs		FLAGS_EX,	TEST_MODE_FLAG		; test mode ?
			rjmp	main_working_mode				; no

; -----------------------------------
; test mode

.LISTMAC
		_TEST_MODE_FAN		; handle test mode

		rjmp	MAIN_LOOP_END					

; ----------------------------------

main_working_mode:
		rcall		process_fan_pwm					; control fan

		rcall		process_auto_config				; process autoconfig, if set

		sbrs		FLAGS_EX,	FAN_ON_CHANGED_FLAG	; fan ON signal changed ?
			rjmp	main_fan_on_no_change			; no, skip handling changed signal

; FAN ON changed, process the change
		clt
		bld		FLAGS_EX,	FAN_ON_CHANGED_FLAG		; clear 'fan changed' flag

		sbrc	FLAGS,		CONFIG_SET_FLAG			; thresholds configured ?
			rjmp	main_fan_on_no_change			; yes, just control fan

		sbrc	FLAGS,		CONFIG_ERROR_FLAG		; error occurred during thresholds configuration ?
			rjmp	main_fan_on_no_change			; yes, just control fan

		sbrs	FLAGS,		FAN_ON_FLAG				; fan ON requested with no configured thresholds and no config error?
			rjmp	main_fan_on_no_change			; no, skip starting autoconfig procedure

		tst		POWER_ON_DELAY						; startup time elapsed ?
		brne	main_fan_on_no_change				; no, skip entering autoconfig mode

; fan changed to ON with no conditions above - initiating auto config session
		sbrs	FLAGS_EX,	CUR_ADC_IN_RANGE_FLAG	; current ADC in range ?
			brcs	main_fan_on_no_change			; no, skip starting autoconfig procedure

; initiating autoconfig
		mov		MIN_ADC,	CUR_ADC					; store cur ADC as min ADC

		ldi		AUTO_CONFIG_STEP,	STEP_SAVING_CORRECTION	; start autoconfig procedure
		ldi		AUTO_CONFIG_TIMING,	AUTO_CONFIG_CORR_TIME	; set ADC correction time counter

; check temperature, set PWM duty accordingly
; account config_set, shutdown, adc disconnect, adc range and external FAN ON request
main_fan_on_no_change:
		rcall		calc_set_pwm_duty				; calculate PWM

; ----- end of main cycle, clear main sync flag
MAIN_LOOP_END:
		clr			BYTE_ACC						; prepare 0 for comparisons

		cpse		POWER_ON_DELAY,		BYTE_ACC	; power-on time elapsed ?
			dec			POWER_ON_DELAY				; no, dec POWER_ON_DELAY

		cpse		FAN_CONTROL_TIMING,	BYTE_ACC	; fan state time elapsed ?
			dec			FAN_CONTROL_TIMING			; no, dec FAN_CONTROL_TIMING

		sbrs		FLAGS,		ENGINE_SHUTTING_DOWN	; engine is shutting down ?
			rjmp	main_loop_skip_sd_dec				; no, skip

		cpse		ENGINE_SHUTDOWN_COUNTER,	BYTE_ACC	; shutdown time elapsed ?
			dec			ENGINE_SHUTDOWN_COUNTER				; no, decrement

main_loop_skip_sd_dec:

; ----- watchdog reset -------------

		wdr

; ----------------------------------

		clt										;
		bld			FLAGS_EX,	MAIN_SYNC_FLAG	; clear main sync flag

		rjmp		wait_loop						; back to main loop
; ----------------------------------


;-------------------------------------------------------------------------------

		.include	"cooler_lib.asm"

;-------------------------------------------------------------------------------


