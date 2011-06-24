; -------------------------------------------------------------------------
; divide word/byte
; in: WORD_ACC_H:WORD_ACC_L - dividend; BYTE_ACC - divisor
; out: WORD_ACC_H:WORD_ACC_L - word result; MATH_WORD_H:MATH_WORD_L - remainder
; used: WORD_ACC_H, WORD_ACC_L, MATH_WORD_L, MATH_WORD_H, MATH_COUNT, 
 

div16_8u: 
		clr 	MATH_WORD_L 				; clear remainder Low byte 
		sub 	MATH_WORD_H,	MATH_WORD_H ; clear remainder High byte and carry 
		
		ldi 	MATH_COUNT,		17 			; init loop counter 
d16_8u_1: 
		rol		WORD_ACC_L 					; shift left dividend 
		rol		WORD_ACC_H 

		dec		MATH_COUNT					; decrement counter: 
		brne	d16_8u_2 					; if done 
		ret 								; return 

d16_8u_2:
		rol		MATH_WORD_L  				;shift dividend into remainder 
		rol		MATH_WORD_H 
		sub		MATH_WORD_L,	BYTE_ACC	; remainder = remainder - divisor 
		sbci	MATH_WORD_H,	0	 		; 

		brcc 	d16_8u_3 					;if result negative - restore remainder 

		add		MATH_WORD_L,	BYTE_ACC
		brcc	d16_8_u_21 
		inc		MATH_WORD_H

d16_8_u_21: 
		clc 						; clear carry to be shifted into result 
		rjmp	d16_8u_1 			; else 

d16_8u_3: 
		sec 						; set carry to be shifted into result 
		rjmp	d16_8u_1 

; -------------------------------------------------------------------------


; -------------------------------------------------------------------------
; multiply 8 * 8
; in: BYTE_ACC - multiplicand , MATH_WORD_L - multiplier
; out: WORD_ACC_H:WORD_ACC_L - word result
; used: WORD_ACC_H, MATH_WORD_L, MATH_WORD_H

mul16_8u:
		clr		MATH_WORD_H					; clear interim storage
		clr		WORD_ACC_L					; clear result registers
		clr		WORD_ACC_H					;

m16_8u_1:
		clc
		ror		BYTE_ACC
		brcc	m16_8u_2

		add 	WORD_ACC_L,		MATH_WORD_L ; add LSB of rm1 to the result
		adc 	WORD_ACC_H,		MATH_WORD_H

m16_8u_2:
		clc 								; clear carry bit
		rol 	MATH_WORD_L 				; rotate LSB left (multiply by 2)
		rol 	MATH_WORD_H 				; rotate carry 

		tst 	BYTE_ACC 					; all bits zero?
		brne 	m16_8u_1

		ret

