;  LCD routines adapted for the DE10-Lite configured as a CV_8052 processor
cseg

; When using a 33.333333MHz crystal clock
; one cycle takes 1.0/33.333333MHz = 30 ns

;---------------------------------;
; Wait 40 microseconds            ;
;---------------------------------;
Wait40uSec:
	push AR0
	mov R0, #190
L0: 
	nop
	nop
	nop
	nop
	djnz R0, L0 ; 1+1+1+1+3 cycles->7*30ns*190=40us
	pop AR0
    ret

;---------------------------------;
; Wait 'R2' milliseconds          ;
;---------------------------------;
Wait_Milli_Seconds mac
	push AR2
	mov R2, %0
	lcall ?Wait_Milli_Seconds
	pop AR2
endmac

?Wait_Milli_Seconds:
	push AR0
	push AR1
L3: mov R1, #50
L2: mov R0, #223
L1: djnz R0, L1 ; 3 cycles->3*30ns*250=20.07us
    djnz R1, L2 ; 20.07us*50=1.004ms
    djnz R2, L3 ; number of millisecons to wait passed in R2
    pop AR1
    pop AR0
    ret
	
;---------------------------------;
; Toggles the 'E' pin in the LCD  ;
;---------------------------------;
ELCD_pulse:
	setb ELCD_E
	lcall Wait40uSec
	clr ELCD_E
    lcall Wait40uSec ; This line is needed in the DE1SoC running an 8051 because it is much faster than the AT89LP51RC2
    ret

;---------------------------------;
; Writes acc to LCD in 4-bit mode ;
;---------------------------------;
ELCD_byte:
	; Write high 4 bits first
	mov c, ACC.7
	mov ELCD_D7, c
	mov c, ACC.6
	mov ELCD_D6, c
	mov c, ACC.5
	mov ELCD_D5, c
	mov c, ACC.4
	mov ELCD_D4, c
    lcall ELCD_pulse
	; Write low 4 bits next
	mov c, ACC.3
	mov ELCD_D7, c
	mov c, ACC.2
	mov ELCD_D6, c
	mov c, ACC.1
	mov ELCD_D5, c
	mov c, ACC.0
	mov ELCD_D4, c
    lcall ELCD_pulse
	ret

;---------------------------------;
; Write data to LCD               ;
;---------------------------------;
WriteData mac
	mov a, %0
	lcall ?WriteData
endmac
	
?WriteData:
	setb ELCD_RS
	ljmp ELCD_byte

;---------------------------------;
; Write command to LCD            ;
;---------------------------------;
WriteCommand mac
	mov a, %0
	lcall ?WriteCommand
endmac

?WriteCommand:
	clr ELCD_RS
	ljmp ELCD_byte

;---------------------------------;
; Configure LCD in 4-bit mode     ;
;---------------------------------;
ELCD_4BIT:
	clr ELCD_E   ; Resting state of LCD's enable pin is zero
	;clr ELCD_RW  ; RW forced to zero
	
	; After power on, let the LCD start up before initializing
	Wait_Milli_Seconds(#40)
	
	; First make sure the LCD is in 8-bit mode and then change to 4-bit mode
	WriteCommand(#0x33)
	WriteCommand(#0x33)
	WriteCommand(#0x32) ; change to 4-bit mode

	; Configure the LCD
	WriteCommand(#0x28)
	WriteCommand(#0x0c)
	WriteCommand(#0x01) ;  Clear screen command (takes some time)

    ;Wait for the clear screen command to finish.
	Wait_Milli_Seconds(#2)
    ret

;---------------------------------;
; Send a constant string to LCD   ;
;---------------------------------;
Send_Constant_String mac
	push dph
	push dpl
	push acc
	mov dptr, %0
	lcall ?Send_Constant_String
	pop acc
	pop dpl
	pop dph
endmac

?Send_Constant_String:
    clr a
    movc a, @a+dptr
    jz ?Send_Constant_String_Done
    lcall ?WriteData
    inc dptr
    sjmp ?Send_Constant_String
?Send_Constant_String_Done:
    ret	

;---------------------------------;
; Set LCD cursor at row, column   ;
;---------------------------------;
Set_Cursor mac
	push acc
	mov a, #%1
	dec a
	lcall ?Set_Cursor_%0 ; Select column and row
	pop acc
endmac

?Set_Cursor_2:
	orl a, #01000000B
?Set_Cursor_1:
	orl a, #10000000B
	ljmp ?WriteCommand ; Select column and row

;---------------------------------;
; Display a BCD number in the LCD ;
;---------------------------------;
Display_BCD mac
	push ar0
	mov r0, %0
	lcall ?Display_BCD
	pop ar0
endmac

?Display_BCD:
	push acc
	; Write most significant digit
	mov a, r0
	swap a
	anl a, #0fh
	orl a, #30h
	lcall ?WriteData
	; write least significant digit
	mov a, r0
	anl a, #0fh
	orl a, #30h
	lcall ?WriteData
	pop acc
	ret

;------------------------------------;
; Display a char in the LCD          ;
;------------------------------------;
Display_char mac
	push acc
	mov a, %0
	lcall ?WriteData
	pop acc
endmac

	
