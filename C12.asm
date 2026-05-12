
; ============================================================
; - Group C12
; - LCD Dual-Page UI (no flashing cursor) + RESET button
; - Start/Stop pulses from UI: start_pulse / stop_pulse
; - Reset pulse from UI: reset_pulse (also forces stop + clears elapsed)
; - Reflow FSM uses UI parameters (soak/refl temp+time)
; - MAX10 ADC (CH2) temperature measurement (C*100)
; - 3-level power: 0%, 20% time-proportioning, 100%
; - SSR OUTPUT = P1.5
; - Timer0 ISR @ 1ms: 200ms flag, 1s flag, PWM timing
;   AND elapsed time increments ONLY while run_flag=1
; - 7-seg: HEX3..HEX0 temperature XXX.X, HEX5 shows fsm_state(0..5)
; ============================================================

$MODMAX10

; ----------------------------
; INTERRUPTS VECTORS
; ----------------------------
org 0000h
    ljmp main

org 000Bh
    ljmp Timer0_ISR


; Timer1 interrupt vector (buzzer tone)
org 001Bh
    ljmp Timer1_Buzzer_ISR
; Serial port interrupt vector
org 0023h
    ljmp Serial_ISR

; ----------------------------
; CLOCK AND TIMER0 (1ms tick)
; ----------------------------
CLK          EQU 33333333
T0_RATE      EQU 1000
T0_RELOAD    EQU (65536 - (CLK/(12*T0_RATE)))

; ----------------------------
; BUZZER TONE TIMER (Timer1)
; ----------------------------
BUZ_RATE     EQU 4096
BUZ_RELOAD   EQU (65536 - (CLK/(12*BUZ_RATE)))

; ----------------------------
; "Little Stars" notes
; ----------------------------
NOTE_DO_RATE   EQU 4096
NOTE_RE_RATE   EQU 4608
NOTE_MI_RATE   EQU 5184
NOTE_FA_RATE   EQU 5460
NOTE_SO_RATE   EQU 6144
NOTE_LA_RATE   EQU 6912

NOTE_DO_RELOAD EQU (65536 - (CLK/(12*NOTE_DO_RATE)))
NOTE_RE_RELOAD EQU (65536 - (CLK/(12*NOTE_RE_RATE)))
NOTE_MI_RELOAD EQU (65536 - (CLK/(12*NOTE_MI_RATE)))
NOTE_FA_RELOAD EQU (65536 - (CLK/(12*NOTE_FA_RATE)))
NOTE_SO_RELOAD EQU (65536 - (CLK/(12*NOTE_SO_RATE)))
NOTE_LA_RELOAD EQU (65536 - (CLK/(12*NOTE_LA_RATE)))

STARS_NOTES    EQU 14


; ----------------------------
; UART (Timer2 baud)
; ----------------------------
BAUD   EQU 115200
T2LOAD EQU 65536-(CLK/(32*BAUD))

; UART RX buffering 
UART_RB_SIZE EQU 32
UART_RB_MASK EQU (UART_RB_SIZE-1)

LINE_SIZE    EQU 8    ; enough for 'ST=ddd\n' (+ optional terminator)

MS1000_L     EQU 0E8h  ; 1000 = 0x03E8
MS1000_H     EQU 03h

; ----------------------------
; LCD/UI PINS 
; ----------------------------
ELCD_RS equ P1.7
ELCD_E  equ P1.1
ELCD_D4 equ P0.7
ELCD_D5 equ P0.5
ELCD_D6 equ P0.3
ELCD_D7 equ P0.1

; ----------------------------
; Buttons (active LOW)
; ----------------------------
BTN_LEFT_BIT    equ P2.0
BTN_RIGHT_BIT   equ P2.1
BTN_UP_BIT      equ P2.2
BTN_DOWN_BIT    equ P2.3
BTN_PAGE_BIT    equ P2.4
BTN_START_BIT   equ P2.5
BTN_RESET_BIT   equ P2.6

; ----------------------------
; SSR output
; ----------------------------
SSR_OUT equ P1.5

; ----------------------------
; BUZZER output
; ----------------------------
BUZZ_OUT equ P3.7


; ----------------------------
; INCLUDES
; ----------------------------
$NOLIST
$include(LCD_4bit_DE10Lite_no_RW.inc)
$LIST
$include(math32.asm)

; ----------------------------
; RAM
; ----------------------------
dseg at 30h

; ---- UI profile params (0..999) ----
soak_temp_lo:   ds 1
soak_temp_hi:   ds 1
soak_time_lo:   ds 1
soak_time_hi:   ds 1
refl_temp_lo:   ds 1
refl_temp_hi:   ds 1
refl_time_lo:   ds 1
refl_time_hi:   ds 1

; ---- ACTIVE profile (latched at START; used by FSM during run) ----
soak_tempA_lo:  ds 1
soak_tempA_hi:  ds 1
soak_timeA_lo:  ds 1
soak_timeA_hi:  ds 1
refl_tempA_lo:  ds 1
refl_tempA_hi:  ds 1
refl_timeA_lo:  ds 1
refl_timeA_hi:  ds 1

cursor_field:   ds 1    ; 0..3
page_sel:       ds 1    ; 0=profile, 1=status

; ---- button scan (non-blocking edge detect) ----
btn_prev:       ds 1    ; previous raw button bitmap (pressed=1)
btn_curr:       ds 1  ; current raw button bitmap (pressed=1)
btn_press:      ds 1    ; 1-shot pulses: bit=1 only on new press edge

; ---- UI scratch ----
val_lo:         ds 1
val_hi:         ds 1
dig_hund:       ds 1
dig_tens:       ds 1
dig_ones:       ds 1

; ---- elapsed time (driven by Timer0 ISR) ----
elapsed_lo:     ds 1
elapsed_hi:     ds 1

min_b:          ds 1
sec_b:          ds 1
tmp_q:          ds 1
tmp_r:          ds 1

; ---- math32 / temp ----
x:              ds 4
y:              ds 4
 bcd:            ds 5
temp_x100_lo:   ds 1
temp_x100_hi:   ds 1

; ---- Timer flags/counters ----
ms_count_lo:    ds 1
ms_count_hi:    ds 1

; ---- FSM ----
fsm_state:      ds 1     ; 0..5
pwm_mode:       ds 1   ; 0/20/100
state_sec_lo:   ds 1
state_sec_hi:   ds 1
thr_soak_lo:    ds 1
thr_soak_hi:    ds 1
thr_refl_lo:    ds 1
thr_refl_hi:    ds 1

; ---- BUZZER ----
buzz_ms:        ds 1 ; remaining ms for beep (0 TO 255)

; ---- BUZZER (tone reload + melody scheduler) ----
buz_reload_l:   ds 1
buz_reload_h:   ds 1
melody_step:    ds 1
melody_rep:     ds 1
old_fsm_state:  ds 1
; ---- UART RX buffers (Part 2: capture only))----
uart_rb_head:   ds 1
uart_rb_tail:   ds 1
; uart_rb_buf moved to XDATA in v16

line_idx:       ds 1
line_buf:       ds LINE_SIZE
line_len:       ds 1

rx_lines:       ds 1   ; debug: count of complete lines captured
 
; ---- Part 3 parse scratch (16-bit *10) ----
tmp0:           ds 1
tmp1:           ds 1
tmp2:           ds 1
tmp3:           ds 1

; ----------------------------
; BIT FLAGS 
; ----------------------------

; ---- UART RX ring buffer moved to XDATA to prevent internal RAM overflow and allow larger RB ----
xseg at 0000h
uart_rb_xbuf:   ds UART_RB_SIZE

bseg
; UI state bits (for LCD "State:" char)
ui_st1:          dbit 1
ui_st2:          dbit 1
ui_st3:          dbit 1
ui_st4:          dbit 1
ui_st5:          dbit 1
ui_st6:          dbit 1
ui_st7:          dbit 1

; UI interface bits (UI produces)
run_flag:        dbit 1
start_pulse:     dbit 1
stop_pulse:      dbit 1
reset_pulse:     dbit 1

; math32 uses mf
mf:              dbit 1

; ISR flags
flag_200ms:      dbit 1
flag_1s:         dbit 1

; UART flags
line_ready:      dbit 1

; main control latch for PWM/FSM
on_flag:         dbit 1

; ---- BUZZER bits ----
buzz_req:        dbit 1
buzz_active:     dbit 1

short_beep_mode: dbit 1   ; 1=Timer0 counts down buzz_ms
melody_active:   dbit 1     ; 1=playing Little Stars
melody_phase_on: dbit 1  ; 1=tone phase, 0=gap phase
melody_evt:      dbit 1  ; set by Timer0 when buzz_ms hits 0

; ----------------------------
; CONSTANT STRINGS + 7SEG LUT
; ----------------------------
cseg

STR_SOAK:   db 'Soak:',0
STR_RELF:   db 'Refl:',0
STR_TIME:   db 'Time:',0
STR_STATE:  db 'State:',0

myLUT:
    DB 0xC0, 0xF9, 0xA4, 0xB0, 0x99
    DB 0x92, 0x82, 0xF8, 0x80, 0x90
    DB 0x88, 0x83, 0xC6, 0xA1, 0x86, 0x8E
SEG_BLANK EQU 0FFh

; ----------------------------
; Delay ~50ms @ 33.33 MHz
; ----------------------------
Wait50ms:
    mov R0, #30
W50_L3:
    mov R1, #74
W50_L2:
    mov R2, #250
W50_L1:
    djnz R2, W50_L1
    djnz R1, W50_L2
    djnz R0, W50_L3
    ret

; -------------------------------
; Part 1: UART init (Timer2 baud)
; -------------------------------
InitSerialPort:
    clr TR2
    mov T2CON, #30H     ; RCLK=1, TCLK=1 (use Timer2 for UART)
    mov RCAP2H, #high(T2LOAD)
    mov RCAP2L, #low(T2LOAD)
    mov TH2,    #high(T2LOAD)
    mov TL2,    #low(T2LOAD)
    setb TR2

    mov SCON, #52H     ; 8-bit UART, REN=1
    clr TI
    clr RI
    ret

; ----------------------------
; Part 2: SERIAL ISR
; ----------------------------
Serial_ISR:
    push acc
    push psw

    push dpl
    push dph


    mov psw, #08h    ; RS1:RS0=01 (bank 1)

    ; clear TI to avoid interrupt storm if we use polled TX for test ACKs
    jnb TI, SI_chk_ri
    clr TI
SI_chk_ri:

    jnb RI, SI_done
    mov a, SBUF
    clr RI

    ; next_head = (head + 1) & MASK
    mov R7, a         ; save received byte
    mov a, uart_rb_head
    inc a
    anl a, #UART_RB_MASK
    mov R6, a      ; R6 = next_head

    ; if next_head == tail => buffer full, drop byte
    mov a, R6
    cjne a, uart_rb_tail, SI_store
    sjmp SI_done

SI_store:

    mov a, uart_rb_head
    mov dptr, #uart_rb_xbuf
    add a, dpl
    mov dpl, a
    clr a
    addc a, dph
    mov dph, a
    mov a, R7
    movx @dptr, a

    ; head = next_head
    mov a, R6
    mov uart_rb_head, a

SI_done:
    pop dph
    pop dpl
    pop psw
    pop acc
    reti

; ----------------------------
; UartServiceRx
; ----------------------------
UartServiceRx:
USR_loop:
    mov a, uart_rb_tail
    cjne a, uart_rb_head, USR_have
    ret

USR_have:

    mov a, uart_rb_tail
    mov dptr, #uart_rb_xbuf
    add a, dpl
    mov dpl, a
    clr a
    addc a, dph
    mov dph, a
    movx a, @dptr
    mov R7, a

    ; tail = (tail + 1) AND  MASK
    mov a, uart_rb_tail
    inc a
    anl a, #UART_RB_MASK
    mov uart_rb_tail, a

    ; ignore '"\r"'
    mov a, R7
    cjne a, #'\r', USR_chk_nl
    sjmp USR_loop

USR_chk_nl:
    cjne a, #'\n', USR_store

    ; newline => finalize line
    mov a, line_idx
    mov line_len, a
    clr a
    mov line_idx, a
    setb line_ready
    ret

USR_store:

    mov a, line_idx
    clr c
    subb a, #(LINE_SIZE-1)
    jc  USR_ok_store

    clr a
    mov line_idx, a
    sjmp USR_loop

USR_ok_store:

    mov a, R7
    clr c
    subb a, #'a'
    jc  USR_uc_done   ; < 'a'
    mov a, R7
    clr c
    subb a, #('z'+1)
    jnc USR_uc_done    ; >= 'z'+1
    mov a, R7
    anl a, #0DFh  ; clear bit5 => uppercase
    mov R7, a
USR_uc_done:
    ; line_buf[line_idx] = byte
    mov a, line_idx
    add a, #line_buf
    mov R0, a
    mov a, R7
    mov @R0, a

    ; line_idx++
    inc line_idx
    sjmp USR_loop

; ----------------------------
; Part 3: ParseProfileLine
; ----------------------------
ParseProfileLine:

    jnb run_flag, PPL_run_ok
    lcall Uart_SendERR
    ljmp PPL_ret
PPL_run_ok:
    ; require at least "ST=0" => len >= 4
    mov a, line_len
    clr c
    subb a, #4
    ; far-safe: if (line_len < 4) return
    jnc PPL_len_ok
PPL_ret_len:
    ljmp PPL_bad
PPL_len_ok:

    mov R0, #line_buf
    mov a, @R0    ; cmd0
    mov R7, a
    inc R0
     mov a, @R0     ; cmd1
    mov R6, a
    inc R0
   mov a, @R0   ; must be '='
    cjne a, #'=', PPL_ne_1
    sjmp PPL_okcj_1
PPL_ne_1:
    ljmp PPL_bad
PPL_okcj_1:
    inc R0    ; -> first digit

    ; ndigits = line_len - 3
    mov a, line_len
    clr c
    subb a, #3
    mov R5, a

    mov val_lo, #0
    mov val_hi, #0

PPL_dloop:
    mov a, R5
    jnz PPL_dloop_cont
	; finished digits -> clamp then store
    lcall Clamp_0_999
    ljmp PPL_store
PPL_dloop_cont:

    mov a, @R0
    inc R0

    ; digit = a minus '0'
    clr c
    subb a, #'0'
    ; if original char < "'0'" => invalid
    jnc PPL_digit_ge0
    ljmp PPL_bad
PPL_digit_ge0:
    mov R4, a   ; R4 = digit candidate
    mov a, R4
    clr c
    subb a, #10
    jc  PPL_digit_ok     ; carry=1 => <10 ok
    ljmp PPL_bad    ; >=10 invalid
PPL_digit_ok:

    ; val = val*10 + R4
    ; tmp2:tmp3 = val*2
    mov a, val_lo
    mov tmp0, a
    mov a, val_hi
    mov tmp1, a

    mov a, tmp0
    add a, tmp0
    mov tmp2, a
    mov a, tmp1
    addc a, tmp1
    mov tmp3, a

    ; tmp0:tmp1 = val times s 8 (shift left 3)
    mov a, val_lo
    mov tmp0, a
    mov a, val_hi
    mov tmp1, a

    clr c
    mov a, tmp0
    rlc a
    mov tmp0, a
    mov a, tmp1
    rlc a
    mov tmp1, a

    clr c
    mov a, tmp0
    rlc a
    mov tmp0, a
    mov a, tmp1
    rlc a
    mov tmp1, a

    clr c
    mov a, tmp0
    rlc a
   mov tmp0, a
    mov a, tmp1
    rlc a
    mov tmp1, a

    ; val = (x8 + x2)
    mov a, tmp2
    add a, tmp0
    mov val_lo, a
    mov a, tmp3
    addc a, tmp1
    mov val_hi, a

    ; val += digit(R4)
    mov a, val_lo
    add a, R4
    mov val_lo, a
    mov a, val_hi
    addc a, #0
    mov val_hi, a

    dec R5
    sjmp PPL_dloop

PPL_store:
    ; dispatch by cmd0/cmd1
    mov a, R7           ; cmd0
    cjne a, #'S', PPL_chkR

    mov a, R6     ; cmd1
    cjne a, #'T', PPL_S_notT
    ; ST
    mov soak_temp_lo, val_lo
    mov soak_temp_hi, val_hi
    lcall Uart_SendOK
    sjmp PPL_ret
PPL_S_notT:
    cjne a, #'D', PPL_ne_2
    sjmp PPL_okcj_2
PPL_ne_2:
    ljmp PPL_ret
PPL_okcj_2:
    ; SD
    mov soak_time_lo, val_lo
    mov soak_time_hi, val_hi
    lcall Uart_SendOK
    sjmp PPL_ret

PPL_chkR:
    cjne a, #'R', PPL_ne_3
    sjmp PPL_okcj_3
PPL_ne_3:
    ljmp PPL_ret
PPL_okcj_3:
    mov a, R6
    cjne a, #'T', PPL_R_notT
    ; RT  rt
    mov refl_temp_lo, val_lo
    mov refl_temp_hi, val_hi
    lcall Uart_SendOK
    sjmp PPL_ret
PPL_R_notT:
    cjne a, #'D', PPL_ne_4
    sjmp PPL_okcj_4
PPL_ne_4:
    ljmp PPL_ret
PPL_okcj_4:
    ; RD RD RD
    mov refl_time_lo, val_lo
    mov refl_time_hi, val_hi

    lcall Uart_SendOK

    sjmp PPL_ret

PPL_bad:
    lcall Uart_SendERR

PPL_ret:
    ret

; UART TX 
Uart_SendOK:
    mov a, #'O'
    lcall SendByte_Polled
    mov a, #'K'
    lcall SendByte_Polled
    mov a, #0Ah     ; '\n'
    lcall SendByte_Polled
    ret

Uart_SendERR:
    mov a, #'E'
    lcall SendByte_Polled
    mov a, #'R'
    lcall SendByte_Polled
    mov a, #'R'
    lcall SendByte_Polled
    mov a, #0Ah     ; '\n'
    lcall SendByte_Polled
    ret

SendByte_Polled:

    clr ES
    clr TI
    mov SBUF, a
SBP_Wait:
    jnb TI, SBP_Wait
    clr TI
    setb ES
    ret

; ---------------------------------------------
; UART TX: temperature as ASCII line for Python
; ---------------------------------------------
Uart_SendTempAscii:
    mov a, #'T'
    lcall SendByte_Polled
    mov a, #'='
    lcall SendByte_Polled

    ; hundredss
    mov a, bcd+2
    anl a, #0FH
    add a, #'0'
    lcall SendByte_Polled

    ;tens
    mov a, bcd+1
    swap a
    anl a, #0FH
    add a, #'0'
    lcall SendByte_Polled

    ; ones
    mov a, bcd+1
    anl a, #0FH
    add a, #'0'
    lcall SendByte_Polled

    mov a, #'.'
    lcall SendByte_Polled

  ; tenths
    mov a, bcd+0
    swap a
    anl a, #0FH
    add a, #'0'
    lcall SendByte_Polled

    mov a, #0Ah   ; '\n'
    lcall SendByte_Polled
    ret



; ----------------------------
; TIMER0 INIT + ISR (1ms tick)
; ----------------------------
Timer0_Init_1ms:
    anl TMOD, #0F0h
    orl TMOD, #01h

    mov TH0, #high(T0_RELOAD)
    mov TL0, #low(T0_RELOAD)

    setb ET0
    setb EA
    setb TR0
    ret

Timer0_ISR:
    push acc
    push psw

    mov TH0, #high(T0_RELOAD)
    mov TL0, #low(T0_RELOAD)

    ; BUZZ timing (1ms)
    jnb buzz_active, BUZZ_DONE
    ; short beep countdown only (melody uses buzz_active but not buzz_ms)
    jnb short_beep_mode, BUZZ_DONE
    mov a, buzz_ms
    jz  BUZZ_STOP
    dec buzz_ms
    sjmp BUZZ_DONE
BUZZ_STOP:
    clr buzz_active
    clr short_beep_mode
    clr BUZZ_OUT
    clr TR1
BUZZ_DONE:

    ; MELODY timing (1ms)
    jb  melody_active, MEL_TICK
    sjmp MEL_DONE
MEL_TICK:
    mov a, buzz_ms
    jz  MEL_SET_EVT
    dec buzz_ms
    sjmp MEL_DONE
MEL_SET_EVT:
    setb melody_evt
MEL_DONE:
    ;  ms_count++
    inc ms_count_lo
    mov a, ms_count_lo
    jnz T0_chk_marks
    inc ms_count_hi

T0_chk_marks:
    ; flag_200ms at 200/400/600/800/1000
    mov a, ms_count_hi
    cjne a, #00h, T0_chk_400
    mov a, ms_count_lo
    cjne a, #0C8h, T0_chk_400
    setb flag_200ms
    sjmp T0_chk_1000

T0_chk_400:
    mov a, ms_count_hi
    cjne a, #01h, T0_chk_600
    mov a, ms_count_lo
    cjne a, #090h, T0_chk_600
    setb flag_200ms
    sjmp T0_chk_1000

T0_chk_600:
    mov a, ms_count_hi
    cjne a, #02h, T0_chk_800
    mov a, ms_count_lo
    cjne a, #058h, T0_chk_800
    setb flag_200ms
    sjmp T0_chk_1000

T0_chk_800:
    mov a, ms_count_hi
    cjne a, #03h, T0_chk_1000
    mov a, ms_count_lo
    cjne a, #020h, T0_chk_1000
    setb flag_200ms

T0_chk_1000:
    mov a, ms_count_lo
    cjne a, #MS1000_L, T0_pwm
    mov a, ms_count_hi
    cjne a, #MS1000_H, T0_pwm

    setb flag_1s

    clr a
    mov ms_count_lo, a
    mov ms_count_hi, a

    ; elapsed++ only while RUN
    jnb run_flag, T0_pwm
    inc elapsed_lo
    mov a, elapsed_lo
    jnz T0_pwm
    inc elapsed_hi

; Apply PWM
T0_pwm:
    jnb on_flag, PWM_OFF

    mov a, pwm_mode
    cjne a, #0, PWM_not0
PWM_OFF:
    clr SSR_OUT
    sjmp T0_done

PWM_not0:
    cjne a, #100, PWM_20
    setb SSR_OUT
    sjmp T0_done

PWM_20:
    ; ON for first 200ms each 1s window
    mov a, ms_count_hi
    jnz PWM20_OFF
    mov a, ms_count_lo
    clr c
    subb a, #0C8h
    jc  PWM20_ON
PWM20_OFF:
    clr SSR_OUT
    sjmp T0_done
PWM20_ON:
    setb SSR_OUT

T0_done:
    pop psw
    pop acc
    reti

; ----------------------------
; TIMER1 BUZZER ISR (tone)
; ----------------------------
Timer1_Buzzer_ISR:
    push acc
    mov TH1, buz_reload_h
    mov TL1, buz_reload_l
    jnb buzz_active, T1_off
    cpl BUZZ_OUT
    pop acc
    reti
T1_off:
    clr BUZZ_OUT
    clr TR1
    pop acc
    reti

; ----------------------------
; Timer1_Buzzer_Init
; ----------------------------
Timer1_Buzzer_Init:
    ; Timer1: mode 1 (16-bit), preserve Timer0 settings
    anl TMOD, #0FH
    orl TMOD, #10H
    ; default tone reload
    mov buz_reload_h, #high(BUZ_RELOAD)
    mov buz_reload_l, #low(BUZ_RELOAD)
    mov TH1, buz_reload_h
    mov TL1, buz_reload_l
    clr TR1
    setb ET1
    ret


; ---------------------------------------------------------------------------------
; "Twinkle Twinkle Little Stars" melody (DO DO SO SO LA LA SO FA FA MI MI RE RE DO)
; ---------------------------------------------------------------------------------
MelodyTable:
    db low(NOTE_DO_RELOAD), high(NOTE_DO_RELOAD)
    db low(NOTE_DO_RELOAD), high(NOTE_DO_RELOAD)
    db low(NOTE_SO_RELOAD), high(NOTE_SO_RELOAD)
    db low(NOTE_SO_RELOAD), high(NOTE_SO_RELOAD)
    db low(NOTE_LA_RELOAD), high(NOTE_LA_RELOAD)
    db low(NOTE_LA_RELOAD), high(NOTE_LA_RELOAD)
    db low(NOTE_SO_RELOAD), high(NOTE_SO_RELOAD)
    db low(NOTE_FA_RELOAD), high(NOTE_FA_RELOAD)
    db low(NOTE_FA_RELOAD), high(NOTE_FA_RELOAD)
    db low(NOTE_MI_RELOAD), high(NOTE_MI_RELOAD)
    db low(NOTE_MI_RELOAD), high(NOTE_MI_RELOAD)
    db low(NOTE_RE_RELOAD), high(NOTE_RE_RELOAD)
    db low(NOTE_RE_RELOAD), high(NOTE_RE_RELOAD)
    db low(NOTE_DO_RELOAD), high(NOTE_DO_RELOAD)

Melody_Start_Stars:

    setb melody_active
    clr  short_beep_mode
    clr  buzz_active
    clr  TR1
    clr  BUZZ_OUT

    mov  melody_step, #0
    mov  melody_rep,  #3
    clr  melody_phase_on  ; 0 => next advance starts tone
    mov  buzz_ms, #0
    setb melody_evt    ; kick immediately
    ret

Melody_Advance:

    push acc
    push dpl
    push dph

    jnb melody_active, MA_ret_s

    ; If phase_on=0 -> start tone for current note
    jb  melody_phase_on, MA_gap_s

MA_tone_s:

    mov  a, melody_step
    add  a, acc       ; A = step*2
    mov  tmp0, a         ; save index*2 (avoid using R0)
    mov  dptr, #MelodyTable
    movc a, @a+dptr   ; low
    mov  buz_reload_l, a
    mov  a, tmp0
    inc  a
    movc a, @a+dptr    ; high
    mov  buz_reload_h, a

    mov  TH1, buz_reload_h
    mov  TL1, buz_reload_l
    setb buzz_active
    clr  BUZZ_OUT
    setb TR1

    mov  buzz_ms, #190
    setb melody_phase_on
    sjmp MA_ret_s

MA_gap_s:
    ; stop tone and schedule gap
    clr  buzz_active
    clr  BUZZ_OUT
    clr  TR1

    mov  buzz_ms, #50
    clr  melody_phase_on

	; advance note index after each tone+gap pair
    inc  melody_step
    mov  a, melody_step
   cjne a, #14, MA_ret_s

    mov  melody_step, #0
    mov  a, melody_rep
    jz   MA_done_s
    dec  melody_rep
    mov  a, melody_rep
    jnz  MA_ret_s

MA_done_s:
    ; finished
    clr  melody_active
    clr  buzz_active
    clr  BUZZ_OUT
    clr  TR1

MA_ret_s:
    pop dph
    pop dpl
    pop acc
    ret

Melody_Stop:
    push acc
    push dpl
    push dph
    clr melody_active
    clr buzz_active
    clr short_beep_mode
    clr melody_evt
    clr melody_phase_on
    mov buzz_ms, #0
    clr BUZZ_OUT
    clr TR1
    pop dph
    pop dpl
    pop acc
    ret

Melody_Step_200ms:
    ret


; ------------------------------------------------------------------------
; TEMPERATURE MEASUREMENT (MAX10 ADC CH2) -> x = C times 100, bcd for 7seg
; ------------------------------------------------------------------------
Measure_Temp_UpdateBCD:
    mov ADC_C, #2

    mov x+3, #0
    mov x+2, #0
    mov x+1, ADC_H
    mov x+0, ADC_L

    ;x = (ADC*5000)/4096 mV
    Load_y(5000)
    lcall mul32
    Load_y(4096)
    lcall div32

   ; x *= 1000 -> uV
    Load_y(1000)
    lcall mul32

    ; x = (uV times 100)/12464 -> C times 100
    Load_y(100)
    lcall mul32
    Load_y(12464)
    lcall div32

    ;+22.00C
    Load_y(2200)
    lcall add32

    mov temp_x100_lo, x+0
    mov temp_x100_hi, x+1

    lcall hex2bcd
    ret

; ------------------------------------------------------------
; 7-seg display: XXX.X on HEX3..HEX0
; HEX5 displays fsm_state (0..5), HEX4 blank
; ------------------------------------------------------------
Display_Temp_7seg_XXX_X:
    mov dptr, #myLUT

	; HEX3 hundreds blank if 0
    mov a, bcd+2
    anl a, #0FH
    jz  DT_blank_hund
    movc a, @a+dptr
    mov HEX3, a
    sjmp DT_tens
DT_blank_hund:
    mov HEX3, #SEG_BLANK

DT_tens:
    ; HEX2 tens blank if leading
    mov a, bcd+1
    swap a
    anl a, #0FH
    mov R7, a
    mov a, HEX3
    cjne a, #SEG_BLANK, DT_tens_show
    mov a, R7
    jz  DT_blank_tens
DT_tens_show:
    mov a, R7
    movc a, @a+dptr
    mov HEX2, a
    sjmp DT_ones
DT_blank_tens:
    mov HEX2, #SEG_BLANK

DT_ones:
    ; HEX1 ones with dp ON (active-low => clear bit7)
    mov a, bcd+1
    anl a, #0FH
    movc a, @a+dptr
    anl a, #7FH
    mov HEX1, a

    ;HEX0 tenths
    mov a, bcd+0
    swap a
    anl a, #0FH
    movc a, @a+dptr
    mov HEX0, a
    ret

Display_State_HEX5:
    mov HEX4, #SEG_BLANK
    mov dptr, #myLUT
    mov a, fsm_state
    anl a, #0FH
    movc a, @a+dptr
    mov HEX5, a
    ret

; ============== UI BLOCK W/ LATEST + RESET) ==================

ReadButtons:
    mov a, P2
    cpl a     ; pressed => 1
    anl a, #07Fh   ; keep bits 0..6
    ret

; ------------------------------------------------------------
; ScanButtons (NON-BLOCKING)
; ------------------------------------------------------------
ScanButtons:
    lcall ReadButtons
    mov btn_curr, a
    mov a, btn_prev
    cpl a
    anl a, btn_curr
    mov btn_press, a
    mov a, btn_curr
    mov btn_prev, a
    ret


WaitRelease:
WR_LOOP:
    lcall ReadButtons
    jnz WR_LOOP
    ret

Clamp_0_999:
    mov a, val_hi
    clr c
    subb a, #03h
    jc  CL_OK
    jnz CL_SET999
    mov a, val_lo
    clr c
    subb a, #0E7h
    jc  CL_OK
    jz  CL_OK
CL_SET999:
    mov val_hi,#03h
    mov val_lo,#0E7h
CL_OK:
    ret

IncVal_Clamp:
    inc val_lo
    mov a, val_lo
    jnz IV_OK
    inc val_hi
IV_OK:
    lcall Clamp_0_999
    ret

DecVal_Clamp:
    mov a, val_hi
    orl a, val_lo
    jz  DV_DONE
    mov a, val_lo
    jnz DV_NB
    dec val_hi
DV_NB:
    dec val_lo
DV_DONE:
    ret

ValTo3Digits:
    mov dig_hund,#'0'
    mov dig_tens,#'0'
    mov dig_ones,#'0'

VT_HUND_LOOP:
    mov a,val_hi
    jnz VT_HUND_SUB
    mov a,val_lo
    clr c
    subb a,#100
    jc  VT_TENS_START
VT_HUND_SUB:
    mov a,val_lo
    clr c
    subb a,#100
    mov val_lo,a
    mov a,val_hi
    subb a,#0
    mov val_hi,a
    inc dig_hund
    sjmp VT_HUND_LOOP

VT_TENS_START:
VT_TENS_LOOP:
    mov a,val_hi
    jnz VT_TENS_SUB
    mov a,val_lo
    clr c
    subb a,#10
    jc  VT_ONES
VT_TENS_SUB:
    mov a,val_lo
    clr c
    subb a,#10
    mov val_lo,a
    mov a,val_hi
    subb a,#0
    mov val_hi,a
    inc dig_tens
    sjmp VT_TENS_LOOP

VT_ONES:
    mov a,val_lo
    add a,#'0'
    mov dig_ones,a
    ret

LCD_Print3Digits:
    mov a,dig_hund
    lcall ?WriteData
    mov a,dig_tens
    lcall ?WriteData
    mov a,dig_ones
    lcall ?WriteData
    ret

SetCursorToField:
    mov a, cursor_field
    cjne a,#0, SC_F1
    Set_Cursor(1,6)
    ret
SC_F1:
    cjne a,#1, SC_F2
    Set_Cursor(1,11)
    ret
SC_F2:
    cjne a,#2, SC_F3
    Set_Cursor(2,6)
    ret
SC_F3:
    Set_Cursor(2,11)
    ret

LoadFieldToVal:
    mov a,cursor_field
    cjne a,#0, LF1
    mov val_lo, soak_temp_lo
    mov val_hi, soak_temp_hi
    ret
LF1:
    cjne a,#1, LF2
    mov val_lo, soak_time_lo
    mov val_hi, soak_time_hi
    ret
LF2:
    cjne a,#2, LF3
    jb  run_flag, UTH_reflA
UTH_reflUI:
    mov val_lo, refl_temp_lo
    mov val_hi, refl_temp_hi
    sjmp UTH_refl_go
UTH_reflA:
    mov val_lo, refl_tempA_lo
    mov val_hi, refl_tempA_hi
UTH_refl_go:
    ret
LF3:
    mov val_lo, refl_time_lo
    mov val_hi, refl_time_hi
    ret

StoreValToField:
    mov a,cursor_field
    cjne a,#0, SF1
    mov soak_temp_lo, val_lo
    mov soak_temp_hi, val_hi
    ret
SF1:
    cjne a,#1, SF2
    mov soak_time_lo, val_lo
    mov soak_time_hi, val_hi
    ret
SF2:
    cjne a,#2, SF3
    mov refl_temp_lo, val_lo
    mov refl_temp_hi, val_hi
    ret
SF3:
    mov refl_time_lo, val_lo
    mov refl_time_hi, val_hi
    ret

RenderProfilePage:
    mov a,#0Ch
    lcall ?WriteCommand

   Set_Cursor(1,1)
    Send_Constant_String(#STR_SOAK)

    ; Soak Temp (UI when idle, ACTIVE when running)
    jb  run_flag, RP_ST_A
RP_ST_UI:
    mov val_lo, soak_temp_lo
    mov val_hi, soak_temp_hi
    sjmp RP_ST_GO
RP_ST_A:
    mov val_lo, soak_tempA_lo
    mov val_hi, soak_tempA_hi
RP_ST_GO:
    lcall ValTo3Digits
    lcall LCD_Print3Digits
    mov a,#'C'
    lcall ?WriteData
    mov a,#' '
    lcall ?WriteData

    ; Soak Time (UI when idle, ACTIVE when running)
    jb  run_flag, RP_SD_A
RP_SD_UI:
    mov val_lo, soak_time_lo
    mov val_hi, soak_time_hi
    sjmp RP_SD_GO
RP_SD_A:
    mov val_lo, soak_timeA_lo
    mov val_hi, soak_timeA_hi
RP_SD_GO:
    lcall ValTo3Digits
    lcall LCD_Print3Digits
    mov a,#'s'
    lcall ?WriteData

    mov R7,#3
P0_R1PAD:
    mov a,#' '
    lcall ?WriteData
    djnz R7, P0_R1PAD

    Set_Cursor(2,1)
    Send_Constant_String(#STR_RELF)

    ; Reflow Temp (UI when idle, ACTIVE when running)
    jb  run_flag, RP_RT_A
RP_RT_UI:
    mov val_lo, refl_temp_lo
    mov val_hi, refl_temp_hi
    sjmp RP_RT_GO
RP_RT_A:
    mov val_lo, refl_tempA_lo
    mov val_hi, refl_tempA_hi
RP_RT_GO:
    lcall ValTo3Digits
    lcall LCD_Print3Digits
    mov a,#'C'
    lcall ?WriteData
    mov a,#' '
    lcall ?WriteData

    ; Reflow Time (UI when idle, ACTIVE when running)
    jb  run_flag, RP_RD_A
RP_RD_UI:
    mov val_lo, refl_time_lo
    mov val_hi, refl_time_hi
    sjmp RP_RD_GO
RP_RD_A:
    mov val_lo, refl_timeA_lo
    mov val_hi, refl_timeA_hi
RP_RD_GO:
    lcall ValTo3Digits
    lcall LCD_Print3Digits
    mov a,#'s'
    lcall ?WriteData

    mov R7,#3
P0_R2PAD:
    mov a,#' '
    lcall ?WriteData
    djnz R7, P0_R2PAD

	; Cursor only when idle (lock display during run)
    jb  run_flag, RP_NO_CURSOR
    mov a,#0Eh
    lcall ?WriteCommand
    lcall SetCursorToField
    ret

RP_NO_CURSOR:
    mov a,#0Ch
    lcall ?WriteCommand
    ret

DivMod60_16:
    mov tmp_q,#0
DM60_LOOP:
    mov a, elapsed_hi
    jnz DM60_SUB
    mov a, elapsed_lo
    clr c
    subb a,#60
    jc  DM60_DONE
DM60_SUB:
    mov a, elapsed_lo
    clr c
    subb a,#60
    mov elapsed_lo,a
    mov a, elapsed_hi
    subb a,#0
    mov elapsed_hi,a
    inc tmp_q
    sjmp DM60_LOOP
DM60_DONE:
    mov min_b, tmp_q
    mov sec_b, elapsed_lo
    ret

Print2DigitsA:
    mov tmp_q,#'0'
P2D_LOOP:
    clr c
    subb a,#10
    jc  P2D_DONE
    inc tmp_q
    sjmp P2D_LOOP
P2D_DONE:
    add a,#10
    mov tmp_r,a
    mov a,tmp_q
    lcall ?WriteData
    mov a,tmp_r
    add a,#'0'
    lcall ?WriteData
    ret

GetStateChar:
    mov R7,#0
    mov R6,#0

    jb ui_st1, GS1
    sjmp GS2
GS1: inc R7
     mov R6,#1
GS2: jb ui_st2, GS3
     sjmp GS4
GS3: inc R7
     mov R6,#2
GS4: jb ui_st3, GS5
     sjmp GS6
GS5: inc R7
     mov R6,#3
GS6: jb ui_st4, GS7
     sjmp GS8
GS7: inc R7
     mov R6,#4
GS8: jb ui_st5, GS9
     sjmp GS10
GS9: inc R7
     mov R6,#5
GS10: jb ui_st6, GS11
      sjmp GS12
GS11: inc R7
      mov R6,#6
GS12: jb ui_st7, GS_DONE
      sjmp GS_DONE2
GS_DONE:
    inc R7
    mov R6,#7
GS_DONE2:
    mov a,R7
    jz  GS_NONE
    cjne a,#1, GS_ERR

    mov a,R6
    dec a     ; FIX: sync with fsm_state (HEX5)
    add a,#'0'
    ret
GS_NONE:
    mov a,#'0'
    ret
GS_ERR:
    mov a,#'E'
    ret

RenderStatusPage:
    mov a,#0Ch
    lcall ?WriteCommand

    mov R4, elapsed_lo
    mov R5, elapsed_hi
    lcall DivMod60_16
    mov elapsed_lo, R4
    mov elapsed_hi, R5

    Set_Cursor(1,1)
    Send_Constant_String(#STR_TIME)
    mov a, min_b
    lcall Print2DigitsA
    mov a,#'m'
    lcall ?WriteData
    mov a, sec_b
    lcall Print2DigitsA
    mov a,#'s'
    lcall ?WriteData

    mov R7,#5
S1_PAD:
    mov a,#' '
    lcall ?WriteData
    djnz R7, S1_PAD

    Set_Cursor(2,1)
    Send_Constant_String(#STR_STATE)
    lcall GetStateChar
    lcall ?WriteData
    mov a,#' '
    lcall ?WriteData

    jb run_flag, SHOW_STOP
    sjmp SHOW_START
SHOW_STOP:
    mov a,#'S'
    lcall ?WriteData
    mov a,#'t'
    lcall ?WriteData
    mov a,#'o'
    lcall ?WriteData
    mov a,#'p'
    lcall ?WriteData
    sjmp S2_PAD
SHOW_START:
    mov a,#'S'
    lcall ?WriteData
    mov a,#'t'
    lcall ?WriteData
    mov a,#'a'
    lcall ?WriteData
    mov a,#'r'
    lcall ?WriteData
    mov a,#'t'
    lcall ?WriteData

S2_PAD:
    mov R7,#7
S2_PADLOOP:
    mov a,#' '
    lcall ?WriteData
    djnz R7, S2_PADLOOP
    ret

HandleStartStop:
    clr start_pulse
    clr stop_pulse

    ; Non-blocking: use press-edge pulse (generated by ScanButtons)
    mov a, btn_press
    jnb ACC.5, HS_DONE

    jb run_flag, HS_TO_STOP
HS_TO_START:
    setb run_flag
    setb start_pulse
    setb buzz_req   ;BUZZ: start beep
    lcall LatchProfileToActive
    sjmp HS_DONE
HS_TO_STOP:
    clr run_flag
    setb stop_pulse
HS_DONE:
    ret


; --------------------------------------------------------------
; Part 4: Latch UI profile into ACTIVE profile (called at START)
; --------------------------------------------------------------
LatchProfileToActive:
    ; copy temps/times (UI to ACTIVE)
    mov a, soak_temp_lo
    mov soak_tempA_lo, a
    mov a, soak_temp_hi
    mov soak_tempA_hi, a

    mov a, soak_time_lo
    mov soak_timeA_lo, a
    mov a, soak_time_hi
    mov soak_timeA_hi, a

    mov a, refl_temp_lo
    mov refl_tempA_lo, a
    mov a, refl_temp_hi
    mov refl_tempA_hi, a

    mov a, refl_time_lo
    mov refl_timeA_lo, a
    mov a, refl_time_hi
    mov refl_timeA_hi, a
    ret

HandleReset:
    clr reset_pulse

    ;Non-blocking: use press-edge pulse (generated by ScanButtons)
    mov a, btn_press
    jnb ACC.6, HR_DONE 

    ; Stop
    clr run_flag
    setb stop_pulse
    setb reset_pulse

    ;Clear elapsed time
    mov elapsed_lo,#0
    mov elapsed_hi,#0

    mov page_sel,#0
    mov cursor_field,#0

HR_DONE:
    ret

HandlePageToggle:

    mov a, btn_press
    jnb ACC.4, HP_DONE
    mov a,page_sel
    xrl a,#1
    mov page_sel,a
HP_DONE:
    ret

HandleEditorButtons:

    jb  run_flag, HEB_DONE ; lock edits while running

    mov a, btn_press
    jz HEB_DONE

    jb ACC.0, HEB_LEFT
    jb ACC.1, HEB_RIGHT
    jb ACC.2, HEB_UP
    jb ACC.3, HEB_DOWN
    sjmp HEB_DONE

HEB_LEFT:
    mov a,cursor_field
    jnz HEBL_OK
    mov cursor_field,#3
    sjmp HEB_DONE
HEBL_OK:
    dec cursor_field
    sjmp HEB_DONE

HEB_RIGHT:
    mov a,cursor_field
    cjne a,#3, HEBR_OK
    mov cursor_field,#0
    sjmp HEB_DONE
HEBR_OK:
    inc cursor_field
    sjmp HEB_DONE

HEB_UP:
    lcall LoadFieldToVal
    lcall IncVal_Clamp
    lcall StoreValToField
    sjmp HEB_DONE

HEB_DOWN:
    lcall LoadFieldToVal
    lcall DecVal_Clamp
    lcall StoreValToField
    sjmp HEB_DONE

HEB_DONE:
    ret

; ------------------------------------------------------------
; FSM SUPPORT FUNCTION BELOW
; ------------------------------------------------------------
MulValBy100_ToThr:
    mov R3, #0
    mov R4, #0

    ; val<<6
    mov R0, val_lo
    mov R1, val_hi
    mov R2, #6
MV_SHL6:
    clr c
    mov a, R0
    rlc a
    mov R0, a
    mov a, R1
   rlc a
    mov R1, a
    djnz R2, MV_SHL6
    mov a, R3
    add a, R0
    mov R3, a
    mov a, R4
    addc a, R1
    mov R4, a

    ; val less than 5
    mov R0, val_lo
    mov R1, val_hi
    mov R2, #5
MV_SHL5:
    clr c
    mov a, R0
    rlc a
    mov R0, a
    mov a, R1
    rlc a
    mov R1, a
    djnz R2, MV_SHL5
    mov a, R3
    add a, R0
    mov R3, a
   mov a, R4
    addc a, R1
    mov R4, a

    ; val<<2
    mov R0, val_lo
    mov R1, val_hi
    mov R2, #2
MV_SHL2:
    clr c
    mov a, R0
    rlc a
    mov R0, a
    mov a, R1
   rlc a
    mov R1, a
    djnz R2, MV_SHL2
    mov a, R3
    add a, R0
    mov R3, a
    mov a, R4
    addc a, R1
    mov R4, a
    ret

UpdateThresholds_FromUI:
    ; Part 4: during run, use ACTIVE profile (latched at START)
    jb  run_flag, UTH_useA
UTH_useUI:
    mov val_lo, soak_temp_lo
    mov val_hi, soak_temp_hi
    sjmp UTH_soak_go
UTH_useA:
    mov val_lo, soak_tempA_lo
    mov val_hi, soak_tempA_hi
UTH_soak_go:
    lcall MulValBy100_ToThr
    mov thr_soak_lo, R3
    mov thr_soak_hi, R4

    mov val_lo, refl_temp_lo
    mov val_hi, refl_temp_hi
    lcall MulValBy100_ToThr
    mov thr_refl_lo, R3
    mov thr_refl_hi, R4
    ret

; ------------------------------------------------------------
; Part 4: Hold-state temperature control (non-blocking)
; ------------------------------------------------------------
HYST_X100_LO EQU 0C8h
HYST_X100_HI EQU 00h

Control_UpdatePWM_200ms:
    jnb on_flag, CUP_done

    mov a, fsm_state
    cjne a, #2, CUP_chk4
	; state2: soak hold
    mov a, thr_soak_lo
    mov R2, a
    mov a, thr_soak_hi
    mov R3, a
    sjmp CUP_hold
CUP_chk4:
    cjne a, #4, CUP_done
	; state4: reflow hold
    mov a, thr_refl_lo
    mov R2, a
    mov a, thr_refl_hi
    mov R3, a

CUP_hold:
    ; low = target - HYST
    mov a, R2
    mov R0, a
    mov a, R3
    mov R1, a
    clr c
    mov a, R0
    subb a, #HYST_X100_LO
    mov R0, a
    mov a, R1
    subb a, #HYST_X100_HI
    mov R1, a

    ;if temp < low equal and greater than PWM=100
    lcall Temp_GE_Thr ; carry=1 if temp >= low
    jc  CUP_notbelow
    mov pwm_mode, #100
    sjmp CUP_done

CUP_notbelow:
    ; high = target plus HYST
    mov a, R2
    mov R0, a
    mov a, R3
    mov R1, a
    mov a, R0
    add a, #HYST_X100_LO
    mov R0, a
    mov a, R1
    addc a, #HYST_X100_HI
    mov R1, a

    ;if temp >= high => PWM=0
    lcall Temp_GE_Thr
    jnc CUP_midband
    mov pwm_mode, #0
    sjmp CUP_done

CUP_midband:
    mov pwm_mode, #20

CUP_done:
    ret


SAFETY_SEC_LO EQU 32h      ; 50s
SAFETY_SEC_HI EQU 00h

FSM_ClearStateBits:
    clr ui_st1
    clr ui_st2
    clr ui_st3
    clr ui_st4
    clr ui_st5
    clr ui_st6
    clr ui_st7
    ret

FSM_SetStateBits:
    lcall FSM_ClearStateBits
    mov a, fsm_state
    cjne a, #0, FSB_1
    setb ui_st1
    ret
FSB_1:
    cjne a, #1, FSB_2
    setb ui_st2
    ret
FSB_2:
    cjne a, #2, FSB_3
    setb ui_st3
    ret
FSB_3:
    cjne a, #3, FSB_4
    setb ui_st4
    ret
FSB_4:
    cjne a, #4, FSB_5
    setb ui_st5
    ret
FSB_5:
    setb ui_st6
    ret

FSM_EnterState:
    clr a
    mov state_sec_lo, a
    mov state_sec_hi, a
    ret

IncStateSeconds:
    inc state_sec_lo
    mov a, state_sec_lo
    jnz ISS_done
    inc state_sec_hi
ISS_done:
    ret

Temp_GE_Thr:
    clr c
    mov a, temp_x100_hi
    subb a, R1
    jc  TGE_false
    jnz TGE_true
    mov a, temp_x100_lo
    clr c
    subb a, R0
    jc  TGE_false
TGE_true:
    setb c
    ret
TGE_false:
    clr c
    ret

StateSec_GE_Target:
    clr c
    mov a, state_sec_hi
    subb a, R1
    jc  SGE_false
    jnz SGE_true
    mov a, state_sec_lo
    clr c
    subb a, R0
    jc  SGE_false
SGE_true:
    setb c
    ret
SGE_false:
    clr c
    ret

FSM_IDLE_ONLY:
    mov fsm_state, #0
    mov pwm_mode, #0
    clr on_flag

    clr a
    mov state_sec_lo, a
    mov state_sec_hi, a

    lcall FSM_SetStateBits
    ret

FSM_ResetToIdle:
    mov fsm_state, #0
    mov pwm_mode, #0
    clr on_flag

    clr a
    mov state_sec_lo, a
    mov state_sec_hi, a

    lcall FSM_SetStateBits
    ret

; ABORT helper: go idle and not-started
FSM_AbortToIdle:
    setb buzz_req  ; BUZZ: abort beep
    clr run_flag
    setb stop_pulse
    clr on_flag

    mov fsm_state, #0
    mov pwm_mode, #0

    clr a
    mov state_sec_lo, a
    mov state_sec_hi, a

    lcall FSM_SetStateBits
    ret

; ------------------------------------------------------------
; FSM DISPATCH 
; ------------------------------------------------------------
FSM_Dispatch:
    AJMP ST0
    AJMP ST1
    AJMP ST2
    AJMP ST3
    AJMP ST4
    AJMP ST5

FSM_Step_1Hz:
    jb  reset_pulse, F_RST
    sjmp F_CHKSTART
F_RST:
    clr reset_pulse
    clr on_flag
    lcall FSM_ResetToIdle
    ret

F_CHKSTART:
    jb  start_pulse, F_START
    sjmp F_CHKSTOP
F_START:
    clr start_pulse
    setb on_flag
    mov fsm_state, #1
    mov pwm_mode, #100
    lcall FSM_EnterState
    sjmp F_RUN

F_CHKSTOP:
    jb  stop_pulse, F_STOP
    sjmp F_RUNCHK
F_STOP:
    clr stop_pulse
    clr on_flag
    lcall FSM_ResetToIdle
    ret

F_RUNCHK:
    jb  on_flag, F_RUN
    ljmp FSM_IDLE_ONLY

F_RUN:
    lcall UpdateThresholds_FromUI
    lcall IncStateSeconds

    mov a, fsm_state
    anl a, #07h
    rl  a
    mov dptr, #FSM_Dispatch
    jmp @a+dptr

ST0:
    mov pwm_mode, #0
    jnb on_flag, ST0_done
    mov fsm_state, #1
    mov pwm_mode, #100
    lcall FSM_EnterState
ST0_done:
    lcall FSM_SetStateBits
    ret

ST1:
    mov pwm_mode, #100

	; safety: if greater and equal than 50s and not reached thr_soak equal and greater than abort
    mov R0, #SAFETY_SEC_LO
    mov R1, #SAFETY_SEC_HI
    lcall StateSec_GE_Target
    jnc ST1_chk_temp

    mov a, thr_soak_lo
    mov R0, a
    mov a, thr_soak_hi
    mov R1, a
    lcall Temp_GE_Thr
    jc  ST1_to2

    lcall FSM_AbortToIdle
    ret

ST1_chk_temp:
    mov a, thr_soak_lo
    mov R0, a
    mov a, thr_soak_hi
    mov R1, a
    lcall Temp_GE_Thr
    jnc ST1_stay
ST1_to2:
    mov fsm_state, #2
    mov pwm_mode, #20
    lcall FSM_EnterState
ST1_stay:
    lcall FSM_SetStateBits
    ret

ST2:
    mov pwm_mode, #20
    mov R0, soak_timeA_lo
    mov R1, soak_timeA_hi
    lcall StateSec_GE_Target
    jnc ST2_stay
    mov fsm_state, #3
    mov pwm_mode, #100
    lcall FSM_EnterState
ST2_stay:
    lcall FSM_SetStateBits
    ret

ST3:
    mov pwm_mode, #100
    mov a, thr_refl_lo
    mov R0, a
    mov a, thr_refl_hi
    mov R1, a
    lcall Temp_GE_Thr
    jnc ST3_stay
    mov fsm_state, #4
    mov pwm_mode, #20
    lcall FSM_EnterState
ST3_stay:
    lcall FSM_SetStateBits
    ret

ST4:
    mov pwm_mode, #20
    mov R0, refl_timeA_lo
    mov R1, refl_timeA_hi
    lcall StateSec_GE_Target
    jnc ST4_stay
    mov fsm_state, #5
    mov pwm_mode, #0
    lcall FSM_EnterState
ST4_stay:
    lcall FSM_SetStateBits
    ret

ST5:
    mov pwm_mode, #0
    mov R0, #071h   ; 6001 = 0x1771
    mov R1, #017h
    lcall Temp_GE_Thr
    jc  ST5_keep

    setb buzz_req  ; BUZZ: finish beep (state5->idle)
    lcall FSM_ResetToIdle
    ret
ST5_keep:
    lcall FSM_SetStateBits
    ret


; ------------------------------------------------------------
; Sound_OnTransition
; ------------------------------------------------------------
Sound_OnTransition:
    ; if no change, return
    mov a, R6

    clr c
    subb a, R7
    jnz SOT_chk
    ret
SOT_chk:
    ; 1->0 or 5->0 => Little Stars
    mov a, R6
    cjne a, #1, SOT_50
    mov a, R7
    cjne a, #0, SOT_50
    lcall Melody_Start_Stars
    ret
SOT_50:
    mov a, R6
    cjne a, #5, SOT_short
    mov a, R7
    cjne a, #0, SOT_short
    lcall Melody_Start_Stars
    ret

SOT_short:
    ; 0->1
    mov a, R6
    cjne a, #0, SOT_12
    mov a, R7
    cjne a, #1, SOT_12
    setb buzz_req
    ret
SOT_12:
    ; 1->2
    mov a, R6
    cjne a, #1, SOT_23
    mov a, R7
    cjne a, #2, SOT_23
    setb buzz_req
    ret
SOT_23:
    ; 2->3
    mov a, R6
    cjne a, #2, SOT_45
    mov a, R7
    cjne a, #3, SOT_45
    setb buzz_req
    ret
SOT_45:
    ; 4->5
    mov a, R6
    cjne a, #4, SOT_ret
    mov a, R7
    cjne a, #5, SOT_ret
    setb buzz_req
SOT_ret:
    ret

; ------------------------------------------------------------
; MAIN
; ------------------------------------------------------------
main:
    mov SP,#7Fh

    ; LCD pins outputs
    mov P0MOD,#10101010b

    ; P1 outputs: P1.7, P1.5, P1.1  (P1.6 unused now)
    mov P1MOD,#11100010b

    ; Buttons inputs
    mov P2MOD,#00000000b

    mov P2, #0FFh

    ; Ensure Port-3 latches are high (helps when using P3.7 as GPIO output)
    mov P3, #0FFh

    ; SSR off + BUZZ off
    clr SSR_OUT
    clr BUZZ_OUT

    ; LCD init
    lcall ELCD_4BIT

    ; UART init (Part 1)
    lcall InitSerialPort

	; UART buffers init (Part 2)
    clr a
    mov uart_rb_head, a
    mov uart_rb_tail, a
    mov line_idx, a
    mov line_len, a
    mov rx_lines, a
    clr line_ready

    ; button edge-detect init
    mov btn_prev, a
    mov btn_curr, a
    mov btn_press, a

    ; init UI defaults (and ACTIVE defaults)
    mov soak_temp_hi,#0
    mov soak_temp_lo,#150
    mov soak_time_hi,#0
    mov soak_time_lo,#90
    mov refl_temp_hi,#0
    mov refl_temp_lo,#230
    mov refl_time_hi,#0
    mov refl_time_lo,#40
    ; ACTIVE defaults mirror UI until START latches
    mov soak_tempA_hi,#0
    mov soak_tempA_lo,#150
    mov soak_timeA_hi,#0
    mov soak_timeA_lo,#90
    mov refl_tempA_hi,#0
    mov refl_tempA_lo,#230
    mov refl_timeA_hi,#0
    mov refl_timeA_lo,#40

    mov cursor_field,#0
    mov page_sel,#0

    ; clear bits
    clr run_flag
    clr start_pulse
    clr stop_pulse
    clr reset_pulse
    clr flag_200ms
    clr flag_1s
    clr on_flag

    ; clear UI state bits
    clr ui_st1
    clr ui_st2
    clr ui_st3
    clr ui_st4
    clr ui_st5
    clr ui_st6
    clr ui_st7

	; Configure buzzer pin P3.7 as push-pull output (MAX10)
    orl P3MOD,#10000000b
	; BUZZ clear
    clr buzz_req
    clr buzz_active
    clr short_beep_mode
    clr melody_active
    mov buzz_ms,#0
    mov buz_reload_h, #high(BUZ_RELOAD)
    mov buz_reload_l, #low(BUZ_RELOAD)
	; init counters
    clr a
    mov ms_count_lo, a
    mov ms_count_hi, a
    mov elapsed_lo, a
    mov elapsed_hi, a
    mov state_sec_lo, a
    mov state_sec_hi, a
    mov fsm_state, #0
    mov pwm_mode, #0

    lcall FSM_SetStateBits

    ; start Timer0
    lcall Timer0_Init_1ms


    ; start Timer1 (buzzer tone generator, TR1 off until beep)
    lcall Timer1_Buzzer_Init
    ; enable serial interrupts (RX capture)
    setb ES
    setb EA

    ;Reset ADC
    mov ADC_C, #80h
    lcall Wait50ms

; ----------------------------
; MAIN LOOP
; ----------------------------
MAIN_LOOP:
    ; UART RX service (drain up to 4 complete lines per loop so UI stays responsive)
    mov R7, #4
UART_DRAIN_LOOP:
    lcall UartServiceRx
    jnb line_ready, NoLine
    clr line_ready
    inc rx_lines    ; debug counter only
    lcall ParseProfileLine
    djnz R7, UART_DRAIN_LOOP
    ; fall-through to UI even if more lines are waiting
NoLine:

    ; Non-blocking button scan (creates 1-shot press pulses)
    lcall ScanButtons

    ; UI always active
    lcall HandleReset
    lcall HandlePageToggle
    lcall HandleStartStop

    ; FAST sync: stop immediately when STOP
    jb  run_flag, FAST_ON
    clr on_flag
    sjmp FAST_DONE
FAST_ON:
    setb on_flag
FAST_DONE:


    jb  buzz_req, DO_BEEP
    sjmp BEEP_DONE
DO_BEEP:
    clr buzz_req
    jb  melody_active, BEEP_DONE

    setb buzz_active
    setb short_beep_mode
    mov buzz_ms, #100  ; 100ms

    ;use default tone reload
    mov buz_reload_h, #high(BUZ_RELOAD)
    mov buz_reload_l, #low(BUZ_RELOAD)
    mov TH1, buz_reload_h
    mov TL1, buz_reload_l
    clr BUZZ_OUT
    setb TR1
BEEP_DONE:

    ;-- Melody advance (non-blocking, event-driven) ----
    jb  melody_evt, DO_MELADV
    sjmp MELADV_DONE
DO_MELADV:
    clr melody_evt
    lcall Melody_Advance
MELADV_DONE:

    ; Render page
    mov a, page_sel
    jz  DO_PAGE0
DO_PAGE1:
    lcall RenderStatusPage
    sjmp AFTER_RENDER
DO_PAGE0:
    lcall RenderProfilePage
    lcall HandleEditorButtons

AFTER_RENDER:
    ; 200ms tasks
    jb  flag_200ms, DO_200MS
    sjmp CHECK_1S
DO_200MS:
    clr flag_200ms
    ; melody timing handled by 1ms countdown + event
    lcall Measure_Temp_UpdateBCD
    lcall Control_UpdatePWM_200ms
    lcall Display_Temp_7seg_XXX_X
    lcall Display_State_HEX5

CHECK_1S:
    jb  flag_1s, DO_1S
    ljmp LOOP_PACE
DO_1S:
    clr flag_1s

    ;---- detect FSM state transition for sound effects ----
    mov a, fsm_state
    mov old_fsm_state, a

    lcall FSM_Step_1Hz

    mov a, old_fsm_state
    mov R6, a    ; old
    mov a, fsm_state
    mov R7, a   ; new
    lcall Sound_OnTransition
    ;--- UART temp to PC as displaying ASCII: T=XXX.X\n ---
    lcall Uart_SendTempAscii

LOOP_PACE:

    ljmp MAIN_LOOP

END