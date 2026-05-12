# Oven Reflow Control System

ELEC 291 Project 1, Group C12.

This repository contains the source code and project materials for a microcontroller-based oven reflow control system. The controller runs on a MAX10/8051-compatible platform and manages a solder reflow profile using temperature feedback, a finite-state machine, LCD controls, seven-segment display output, UART communication, SSR power control, and buzzer feedback.

## Features

- Reflow finite-state machine with idle, ramp, soak, reflow, and cooling states.
- Adjustable soak and reflow temperature/time parameters from the LCD user interface.
- Active profile latching when START is pressed, so settings remain stable during a run.
- MAX10 ADC channel 2 temperature measurement, stored as degrees Celsius times 100.
- Three-level heater power control through SSR output on `P1.5`: 0%, 20%, and 100%.
- Timer0 1 ms interrupt for UI timing, elapsed-time tracking, and time-proportional PWM.
- UART interface at 115200 baud for profile commands and temperature output.
- Seven-segment display output for current temperature and FSM state.
- Reset/start/stop button handling with non-blocking edge detection.
- Buzzer and melody feedback for state transitions and completion.

## Repository Contents

| File | Description |
| --- | --- |
| `Main.asm` | Main assembly source for the oven reflow controller. |
| `video presentation link.txt` | YouTube link for the project presentation/demo. |

## Hardware Notes

The assembly source is written for the course MAX10/8051 environment and uses the following notable I/O assignments:

- LCD: `P1.7`, `P1.1`, `P0.7`, `P0.5`, `P0.3`, `P0.1`
- Buttons: `P2.0` to `P2.6`
- SSR output: `P1.5`
- Buzzer output: `P3.7`
- ADC temperature input: MAX10 ADC channel 2
- UART baud rate: 115200

## Build Notes

`C12.asm` includes the course support files:

- `LCD_4bit_DE10Lite_no_RW.inc`
- `math32.asm`

Make sure those files are available in the assembler include path before building the program in the ELEC 291 toolchain.

## UART Profile Commands

The firmware accepts profile updates over UART while the oven is not running. Commands use two-letter keys with numeric values, for example:

```text
ST=150
RT=230
```

Values are clamped to the firmware's supported profile range.

## Demo

Presentation/demo video: https://www.youtube.com/watch?v=hFFiqIETEzM
