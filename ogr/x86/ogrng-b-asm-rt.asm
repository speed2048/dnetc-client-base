cpu	586

%ifdef __OMF__ ; Watcom and Borland compilers/linkers
	[SECTION _DATA USE32 ALIGN=16 CLASS=DATA]
%else
	[SECTION .data]
%endif

%ifdef __OMF__ ; Borland and Watcom compilers/linkers
	[SECTION _TEXT FLAT USE32 align=16 CLASS=CODE]
%else
	[SECTION .text]
%endif

	; Core can be created with SCALAR_BITS=32 or 64.
	; In general, SCALAR_BITS=64 must be better - we can shift more bits
	; during one operation of COMP_LEFT_LIST_RIGHT, also implementaion of
	; COMP_LEFT_LIST_RIGHT_WORD becomes trivial. But implementaion of
	; LOOKUP_FIRSTBLANK becomes more complex (must be done in two passes,
	; includes extra jump between passes).
	; In my benchmarks, SCALAR_BITS=64 is faster.

	%define SCALAR_BITS	64

	global	_ogr_cycle_256_rt1_mmx, ogr_cycle_256_rt1_mmx

_ogr_cycle_256_rt1_mmx:
ogr_cycle_256_rt1_mmx:

	%define regsavesize	10h	; 4 registers saved
	%define worksize	20h

	%define	work_depth	esp+00h
	%define work_halfdepth	esp+04h
	%define work_halfdepth2	esp+08h
	%define work_nodes	esp+0Ch

	%define	param_oState	esp+regsavesize+worksize+04h
	%define param_pnodes	esp+regsavesize+worksize+08h
	%define param_pchoose	esp+regsavesize+worksize+0Ch

	%define oState_max		00h

	%define oState_maxdepthm1	08h
	%define oState_half_depth	0Ch
	%define oState_half_depth2	10h

	%define oState_stopdepth	18h
	%define	oState_depth		1Ch
	%define oState_Levels		20h

; It's possible to put ebp (current level) a little forward and reference
; elements as 'ebp-nn' and 'ebp+nn' (with signed byte offsets) to avoid
; long command 'ebp+nnnnnnnn' (dword offset).
	%define ebp_shift		128	; may be up to 128
	%define sizeof_level		104	; (32*3+8)
	%define level_list		00h
	%define level_dist		20h
	%define level_comp		40h
	%define level_mark		60h
	%define level_limit		64h

%define cur(el, index)   [ebp+level_ %+ el + ((index)*8) - ebp_shift]
%define next(el, index)  [ebp+sizeof_level+level_ %+ el + ((index)*8) - ebp_shift]

	push	ebx
	push	esi
	push	edi
	push	ebp			; note: regsavesize bytes pushed
	sub	esp, worksize

	mov	ebx, [param_oState]
	mov	ecx, [ebx+oState_depth]
	mov	[work_depth], ecx	; depth = oState->depth (cached for SETUP_TOP_STATE)
	imul	eax, ecx, sizeof_level
	lea	ebp, [eax+ebx+oState_Levels+ebp_shift]	; lev = &oState->Levels[oState->depth]
	mov	eax, [param_pnodes]
	mov	eax, [eax]
	mov	[work_nodes], eax	; nodes = *pnodes
	mov	eax, [ebx+oState_half_depth]
	mov	[work_halfdepth], eax	; halfdepth = oState->half_depth
	mov	eax, [ebx+oState_half_depth2]
	mov	[work_halfdepth2], eax	; halfdepth2 = oState->half_depth2

%define mm_comp0	mm0
%define mm_comp1	mm1
%define mm_comp2	mm2
%define	mm_newbit	mm3
%define mm_temp_a	mm4
%define mm_temp_b	mm5
%define mm_temp_s	mm6
%define mm_temp_ss	mm7

	; SETUP_TOP_STATE(lev);
	; !!!
	movq	mm_comp0, cur(comp, 0)	; SCALAR comp0 = lev->comp[0];
	movq	mm_comp1, cur(comp, 1)
	movq	mm_comp2, cur(comp, 2)
	; movq	mm3, cur(comp, 3)	; comp[3] not cached!
	; int newbit = (depth < oState->maxdepthm1) ? 1 : 0;
	xor	eax, eax
	cmp	ecx, [ebx+oState_maxdepthm1]	; depth still in ecx
	setl	al
	movd	mm_newbit, eax

	; mm0..mm3 = comp
	; mm4 = newbit

	; split loop header
	mov	ebx, [ebp+level_mark-ebp_shift]	; mark  = lev->mark;

	align	16

; Jump probabilies calculated from summary statistic of 'dnetc -test'.
; Main loop was entered 0x0B5ACBE2 times. For each jump, we measured
; number of times this jump was reached (percents from main loop
; means importance of this code path) and probability of this jump to
; be taken (for branch prediction of important jumps).

do_loop_split:
for_loop:

	; esi = comp0
	; edi = newbit
	; ebx = mark

	;      if (comp0 < (SCALAR)~1) {
%if SCALAR_BITS == 32

	movq	mm_temp_a, mm_comp0
	punpckhdq mm_temp_a, mm_temp_a
	movd	esi, mm_temp_a
	cmp	esi, 0FFFFFFFEh
	jnb	comp0_ge_fffe		; ENTERED: 0x0B5ACBE2(100%), taken: 33-35%
	;        int s = LOOKUP_FIRSTBLANK_SAFE(comp0);
	not	esi
	mov	ecx, 20H
	bsr	edx, esi
	sub	ecx, edx			; s

%else

	movq	mm_temp_a, mm_comp0
	punpckhdq mm_temp_a, mm_temp_a
	movd	esi, mm_temp_a
	mov	ecx, 32
	xor	esi, 0FFFFFFFFh		; implies 'not esi' below
	jne	use_this_word		; ENTERED: 0x????????(??%), taken: ??%
	movd	esi, mm_comp0
	cmp	esi, 0FFFFFFFEh
	jnb	comp0_ge_fffe		; ENTERED: 0x????????(??%), taken: ??%
	not	esi
	mov	ecx, 64			; add ecx, 32 ??? shorter but no gain
use_this_word:
	bsr	eax, esi
	sub	ecx, eax		; s = ecx-bsr

%endif
	;        if ((mark += s) > limit) {
	;          break;
	;        }
	add	ebx, ecx
	cmp	ebx, [ebp+level_limit-ebp_shift] ; limit (==lev->limit)
	jg	break_for		; ENTERED: 0x07A5D5F7(67.35%), taken 30-34%

	;        COMP_LEFT_LIST_RIGHT(lev, s);
	; !!!

%if SCALAR_BITS == 32
	add	edx, 32			; ss = (64-s) = 64-(32-bsr) = 32+bsr
%else
	mov	edx, 64
	sub	edx, ecx		; ss = (64-s)
%endif
	movd	mm_temp_ss, edx		; mm7 = ss
	movd	mm_temp_s,  ecx		; mm6 = s

	; newbit + list goes right

	psllq	mm_newbit, mm_temp_ss	; insert newbit
	movq	mm_temp_a, cur(list, 0)
	movq	mm_temp_b, mm_temp_a	; list[0] cached in mm_temp_b
	psrlq	mm_temp_a, mm_temp_s
	por	mm_newbit, mm_temp_a
	movq	cur(list, 0), mm_newbit

	movq	mm_temp_a, cur(list, 1)
	movq	mm_newbit, mm_temp_a	; list[1] cached in mm_newbit
	psllq	mm_temp_b, mm_temp_ss
	psrlq	mm_temp_a, mm_temp_s
	por	mm_temp_b, mm_temp_a
	movq	cur(list, 1), mm_temp_b

	movq	mm_temp_a, cur(list, 2)
	movq	mm_temp_b, mm_temp_a	; list[2] cached in mm_tempb
	psllq	mm_newbit, mm_temp_ss
	psrlq	mm_temp_a, mm_temp_s
	por	mm_newbit, mm_temp_a
	movq	cur(list, 2), mm_newbit

	movq	mm_temp_a, cur(list, 3)
	psllq	mm_temp_b, mm_temp_ss
	psrlq	mm_temp_a, mm_temp_s
	por	mm_temp_b, mm_temp_a
	movq	cur(list, 3), mm_temp_b

	; comp goes left

	psllq	mm_comp0, mm_temp_s
	movq	mm_temp_a, mm_comp1
	psrlq	mm_temp_a, mm_temp_ss
	por	mm_comp0, mm_temp_a
	psllq	mm_comp1, mm_temp_s
	movq	mm_temp_a, mm_comp2
	psrlq	mm_temp_a, mm_temp_ss
	por	mm_comp1, mm_temp_a
	psllq	mm_comp2, mm_temp_s
	movq	mm_temp_a, cur(comp, 3)
	movq	mm_temp_b, mm_temp_a
	psrlq	mm_temp_a, mm_temp_ss
	por	mm_comp2, mm_temp_a
	psllq	mm_temp_b, mm_temp_s
	movq	cur(comp, 3), mm_temp_b

	pxor	mm_newbit, mm_newbit		; newbit = 0

after_if:
	; ebx = mark

	;      lev->mark = mark;
	mov	[ebp+level_mark-ebp_shift], ebx

	;      if (depth == oState->maxdepthm1) {
	;        goto exit;         /* Ruler found */
	;      }
	mov	eax, [param_oState]
	mov	eax, [eax+oState_maxdepthm1]
	cmp	eax, [work_depth]
	je	exit			; ENTERED: 0x0513FD1B(44.72%), taken: 0%

	;      PUSH_LEVEL_UPDATE_STATE(lev);
	; !!!
	; **   LIST[lev+1] = LIST[lev]
	; **   DIST[lev+1] = (DIST[lev] | LIST[lev+1])
	; **   COMP[lev+1] = (COMP[lev] | DIST[lev+1])
	; **   newbit = 1;

	movq	cur(comp, 0), mm_comp0
	movq	cur(comp, 1), mm_comp1
	movq	cur(comp, 2), mm_comp2

	movq	mm_temp_b, cur(list, 0)
	movq	next(list, 0), mm_temp_b
	por	mm_temp_b, cur(dist, 0)		; dist0 ready in mm_temp_b
	movq	next(dist, 0), mm_temp_b
	por	mm_comp0, mm_temp_b

	movq	mm_temp_a, cur(list, 1)
	movq	next(list, 1), mm_temp_a
	por	mm_temp_a, cur(dist, 1)
	movq	next(dist, 1), mm_temp_a
	por	mm_comp1, mm_temp_a

	movq	mm_temp_a, cur(list, 2)
	movq	next(list, 2), mm_temp_a
	por	mm_temp_a, cur(dist, 2)
	movq	next(dist, 2), mm_temp_a
	por	mm_comp2, mm_temp_a

	movq	mm_temp_a, cur(list, 3)
	movq	next(list, 3), mm_temp_a
	por	mm_temp_a, cur(dist, 3)
	movq	next(dist, 3), mm_temp_a
	por	mm_temp_a, cur(comp, 3)
	movq	next(comp, 3), mm_temp_a

;	!! delay init !!
;	newbit = 1

	;      lev++;
	add	ebp, sizeof_level
	;      depth++;
	inc	dword [work_depth]

	%define CHOOSE_DIST_BITS	16     ; /* number of bits to take into account  */

	; /* Compute the maximum position for the next level */
	; #define choose(dist,seg) pchoose[(dist >> (SCALAR_BITS-CHOOSE_DIST_BITS)) * 32 + (seg)]
	; limit = choose(dist0, depth);

	punpckhdq mm_temp_b, mm_temp_b	; dist0 >> 32
	movd	ecx, mm_temp_b		; dist0 in ecx

	mov	eax, ecx ; dist 0
	shr	eax, 16
	shl	eax, 5
	add	eax, [work_depth]
	mov	edx, [param_pchoose]
	movzx	edi, word [edx+eax*2]

	;      if (depth > oState->half_depth && depth <= oState->half_depth2) {
	;;;      if (depth > halfdepth && depth <= halfdepth2) {
	mov	eax, [work_depth]
	cmp	eax, [work_halfdepth]
	jle	skip_if_depth		; ENTERED: 0x0513FD14(44.72%), taken 0.5%
	cmp	eax, [work_halfdepth2]
	jg	skip_if_depth		; ENTERED: 0x050D5B51(44.49%), taken 97.02%

;        int temp = maxlen_m1 - oState->Levels[oState->half_depth].mark;
;;        int temp = oState->max - 1 - oState->Levels[halfdepth].mark;

	mov	edx, [param_oState]
	mov	eax, [work_halfdepth]
	imul	eax, sizeof_level
	mov	eax, [eax+edx+oState_Levels+level_mark]
	mov	edx, [edx+oState_max]
	sub	edx, eax

;        if (limit > temp) {
;          limit = temp;
;        }

	cmp	edi, edx
	jl	limitok		; ENTERED: 0x00267D08(1.32%), taken 17.35%
	lea	edi, [edx-1]
limitok:

;        if (depth < oState->half_depth2) {
	mov	eax, [work_depth]
	cmp	eax, [work_halfdepth2]
	jge	skip_if_depth	; ENTERED: 0x00267D08(1.32%), taken 78.38%

;          limit -= LOOKUP_FIRSTBLANK(dist0); // "33" version
;;;        limit -= LOOKUP_FIRSTBLANK(dist0 & -((SCALAR)1 << 32));
;;;        (we already have upper part of dist0 in ecx)

	xor	ecx, -1		; "not ecx" does not set flags!
	mov	edx, -1
	je	skip_bsr	; ENTERED: 0x00085254(0.29%), taken 0.00%
	bsr	edx, ecx
skip_bsr:
	add	edi, edx
	sub	edi, 32

skip_if_depth:
	mov	[ebp+level_limit-ebp_shift], edi

	mov	eax, 1		; newbit = 1 (delayed)
	movd	mm_newbit, eax

	;      if (--nodes <= 0) {

	dec	dword [work_nodes]
	jg	for_loop	; ENTERED: 0x0513FD14(44.72%), taken 99.99%

	;        lev->mark = mark;
	;        goto exit;
	mov	[ebp+level_mark-ebp_shift], ebx
	jmp	exit

	align	16

comp0_ge_fffe:
	;      else {         /* s >= SCALAR_BITS */

	;        if ((mark += SCALAR_BITS) > limit) {
	;          break;
	;        }
	add	ebx, SCALAR_BITS
	cmp	ebx, [ebp+level_limit-ebp_shift] ; limit (==lev->limit)
	jg	break_for		; ENTERED: 0x03B4F5EB(32.64%), taken 66.70%

	;        if (comp0 == ~0u) {
	;          COMP_LEFT_LIST_RIGHT_WORD(lev);
	;          continue;
	;        }
	;        COMP_LEFT_LIST_RIGHT_WORD(lev);

	cmp	esi,0ffffffffH		; if (comp0 == ~0u)

	; COMP_LEFT_LIST_RIGHT_WORD(lev);
	; !!!

%if SCALAR_BITS == 32
	; newbit + list goes right

	movq	mm_temp_a,  cur(list, 0)	; 01
	movq	mm_temp_b,  cur(list, 1)	; 23
	movq	mm_temp_s,  cur(list, 2)	; 45
	movq	mm_temp_ss, cur(list, 3)	; 67
						; nN 01 23 45 67
	punpckhdq mm_temp_ss, mm_temp_ss	;             66
	punpckldq mm_temp_ss, mm_temp_s		;             56
	movq	cur(list, 3), mm_temp_ss
	punpckhdq mm_temp_s,  mm_temp_s		;          44 56
	punpckldq mm_temp_s,  mm_temp_b		;          34
	movq	cur(list, 2), mm_temp_s
	punpckhdq mm_temp_b,  mm_temp_b		;       22 34 56
	punpckldq mm_temp_b,  mm_temp_a		;       12 34 56
	movq	cur(list, 1), mm_temp_b
	punpckhdq mm_temp_a,  mm_temp_a		;    00 12 34 56
	punpckldq mm_temp_a,  mm_newbit		;    N0 12 34 56
	movq	cur(list, 0), mm_temp_a

	; comp goes left			; 01 23 45 67 --

	movq	mm_temp_a, mm_comp1		; 01 23 45 67 23
	psllq	mm_comp0,  32
	psrlq	mm_temp_a, 32			; 1z 23 45 67 z2
	por	mm_comp0,  mm_temp_a		; 12 23 45 67 --
	movq	mm_temp_a, mm_comp2		;             45
	psllq	mm_comp1,  32			;    3z       45
	psrlq	mm_temp_a, 32			;    3z       z4
	por	mm_comp1, mm_temp_a		; 12 34 45 67 --
	movq	mm_temp_b, cur(comp, 3)
	movq	mm_temp_a, mm_temp_b		;             67
	psllq	mm_comp2,  32			;       5z    67
	psrlq	mm_temp_a, 32			;             z6
	por	mm_comp2, mm_temp_a		; 12 34 56 67 --
	psllq	mm_temp_b, 32			; 12 34 56 7z
	movq	cur(comp, 3), mm_temp_b

	pxor	mm_newbit, mm_newbit		; newbit = 0

%else
	; newbit + list goes right
	movq	mm_temp_a,  cur(list, 0)
	movq	mm_temp_b,  cur(list, 1)
	movq	mm_temp_s,  cur(list, 2)
	movq	cur(list, 0), mm_newbit
	movq	cur(list, 1), mm_temp_a
	movq	cur(list, 2), mm_temp_b
	movq	cur(list, 3), mm_temp_s
	pxor	mm_newbit, mm_newbit		; newbit = 0

	; comp goes left			; 01 23 45 67 --
	movq	mm_comp0, mm_comp1
	movq	mm_comp1, mm_comp2
	movq	mm_comp2, cur(comp, 3)
	movq	cur(comp, 3), mm_newbit		; newbit is zero

%endif

	je	for_loop		; ENTERED: 0x013BFDCE(10.87%), taken 97.10%
	jmp	after_if

	align	16
break_for:

	;    lev--;
	sub	ebp, sizeof_level
	;    depth--;
	dec	dword [work_depth]
	;    POP_LEVEL(lev);
	; !!!
	movq	mm_comp0, cur(comp, 0)	; SCALAR comp0 = lev->comp[0];
	movq	mm_comp1, cur(comp, 1)
	movq	mm_comp2, cur(comp, 2)
	; unused here; mov	e??, [ebp+level_dist+0]	;      dist0 = lev->dist[0];
	pxor	mm_newbit, mm_newbit	;      newbit = 0;

	;  } while (depth > oState->stopdepth);
	mov	eax, [param_oState]
	mov	eax, [eax+oState_stopdepth]
	cmp	eax, [work_depth]

	; split loop header
	mov	ebx, [ebp+level_mark-ebp_shift]	; mark  = lev->mark;

	jl	do_loop_split		; ENTERED: 0x0513FCC2(44.72%), taken 99.99%

exit:
	;  SAVE_FINAL_STATE(lev);
	; !!!
	movq	cur(comp, 0), mm_comp0
	movq	cur(comp, 1), mm_comp1
	movq	cur(comp, 2), mm_comp2

	mov	ebx, [param_pnodes]	; *pnodes -= nodes;
	mov	eax, [work_nodes]
	sub	[ebx], eax

	mov	eax, [work_depth]	; return depth;

	add	esp, worksize
	pop	ebp
	pop	edi
	pop	esi
	pop	ebx
	emms
	ret

	end