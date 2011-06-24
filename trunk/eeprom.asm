; -------------------------------------------------------------------------
; in: ++WORD_ACC_L - EEPROM address, WORD_ACC_H - accumulating checksum 
; out: BYTE_ACC - EEPROM data read, WORD_ACC_H - accumulating checksum
; Z flag is set when checksum read == 0
eeprom_read_preinc_checksum:
		inc		WORD_ACC_L	
; -------------------------------------------------------------------------
; in: WORD_ACC_L - EEPROM address, WORD_ACC_H - accumulating checksum
; out: BYTE_ACC - EEPROM data read, WORD_ACC_H - accumulating checksum
eeprom_read_checksum:
		sbic	EECR,		EEWE		; wait until EEWE becomes 0
			rjmp	eeprom_read_checksum
		out		EEAR,		WORD_ACC_L
		sbi		EECR,		EERE		; set EERE
		in		BYTE_ACC,	EEDR
		add		WORD_ACC_H,	BYTE_ACC
		ret


; -------------------------------------------------------------------------
; in: ++WORD_ACC_L - EEPROM address, BYTE_ACC - data to write, WORD_ACC_H - accumulating checksum
; out: none
eeprom_write_preinc_checksum:
		add		WORD_ACC_H,	BYTE_ACC
; -------------------------------------------------------------------------
; in: ++WORD_ACC_L - EEPROM address, BYTE_ACC - data to write
; out: none
eeprom_write_preinc:
		inc		WORD_ACC_L	
; -------------------------------------------------------------------------
; in: WORD_ACC_L - EEPROM address, BYTE_ACC - data to write
; out: none
eeprom_write:
		sbic	EECR,		EEWE		; wait until EEWE becomes 0
			rjmp	eeprom_write
		out		EEAR,		WORD_ACC_L
		out		EEDR,		BYTE_ACC	
		
		cli
			sbi		EECR,		EEMWE		; EEMWE
			sbi		EECR,		EEWE		; EEWE
		sei

		ret


; ------ EEPROM vars ------------------------------------------------------
		.eseg
		.org		0

EEPROM_RUN_COUNT:		.dw		0
EEPROM_WDR_COUNT:		.db		0
EEPROM_ADC_CORRECTION:	.db		0
EEPROM_U_MIN:			.db		0
EEPROM_U_MAX:			.db		0
EEPROM_CONFIG_CRC:		.db		0


