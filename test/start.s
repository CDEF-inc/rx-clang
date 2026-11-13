; Start-up code for the QEMU check (scripts/check-dist.sh): set SP, clear
; .bss, run the C++ constructors (.init_array), call main, record its
; result in `exit_code` and set `finished`, then spin. check-dist.sh reads
; the variables through the QEMU monitor.
	.section .text.start, "ax"
	.global	_start
_start:
	mov.l	#__stack, r0
	; .bss: sstr.b stores R2's low byte R3 times from [R1].
	mov.l	#__bss_start, r1
	mov.l	#__bss_end, r3
	sub	r1, r3
	mov.l	#0, r2
	sstr.b
	; The constructors: R6 / R7 are callee-saved.
	mov.l	#__init_array_start, r6
	mov.l	#__init_array_end, r7
1:	cmp	r7, r6
	bgeu	2f
	mov.l	[r6+], r1
	jsr	r1
	bra	1b
2:	bsr.a	_main
	mov.l	#_exit_code, r2
	mov.l	r1, [r2]
	mov.l	#_finished, r2
	mov.l	#1, r1
	mov.l	r1, [r2]
	.global	_done
_done:
	bra.b	_done

	.section .bss
	.global	_exit_code, _finished
	.balign	4
_exit_code:
	.long	0
_finished:
	.long	0
