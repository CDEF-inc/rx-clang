; Hand-written functions that test/main.c calls, assembled by clang's
; integrated assembler (llvm-mc's RX assembler). C names get a leading
; underscore, as in GCC and CC-RX.
;
; asm_fifth follows the calling convention the C side was compiled with:
; check-dist.sh assembles this file with -Wa,--defsym,GNU_ABI=1 when the C
; code is compiled with -mabi=gnu.
	.text

; int asm_sum3(int a, int b, int c): R1 + R2 + R3.
	.global	_asm_sum3
_asm_sum3:
	add	r2, r1
	add	r3, r1
	rts

; int asm_fifth(int a, int b, int c, long long d, int e): e + (int)d.
; a, b and c are in R1-R3; d does not fit in R4 and goes on the stack, at
; [R0 + 4] (after the return address). In CC-RX's convention e then takes
; the register left free (R4); in GNURX's every argument after d is on the
; stack too, so e is at [R0 + 12].
	.global	_asm_fifth
_asm_fifth:
	mov.l	4[r0], r1
.ifdef GNU_ABI
	mov.l	12[r0], r2
	add	r2, r1
.else
	add	r4, r1
.endif
	rts
