; The unknown lane must never acquire a C++ prototype. Save the scratch
; registers used by the diagnostic, then restore the original entry
; stack and tail-jump to the permanent Detours relay. No argument/SIMD slots move.
OPTION CASEMAP:NONE
EXTERN reskate_native_input_trace_relay:QWORD
EXTERN reskate_native_input_trace_interpreter_return:QWORD
EXTERN reskate_native_input_trace_alternate_return:QWORD
EXTERN reskate_native_input_trace_unknown_calls:QWORD
EXTERN reskate_native_input_trace_unknown_returns:QWORD
EXTERN reskate_native_input_trace_known:PROC
PUBLIC reskate_native_input_trace_gate

.CONST
; RIP-indirect tail jumps also have the documented x64 epilog form. This target
; is a linker relocation in read-only data, never a runtime dispatch setting.
known_target QWORD reskate_native_input_trace_known

.CODE
reskate_native_input_trace_gate PROC FRAME
    sub rsp, 18h
    .allocstack 18h
    .endprolog
    mov QWORD PTR [rsp], rax
    mov rax, QWORD PTR [rsp+18h]
    cmp rax, QWORD PTR [reskate_native_input_trace_interpreter_return]
    je known_lane
    cmp rax, QWORD PTR [reskate_native_input_trace_alternate_return]
    je known_lane
    ; Only SDK-owned counters/PC slots are touched. No unknown argument is
    ; inspected and no C++/native/OS helper is called on this lane.
    mov QWORD PTR [rsp+8h], rcx
    mov QWORD PTR [rsp+10h], rdx
    mov ecx, 1
    lock xadd QWORD PTR [reskate_native_input_trace_unknown_calls], rcx
    cmp rcx, 10h
    jae unknown_done
    lea rdx, [reskate_native_input_trace_unknown_returns]
    lea rdx, [rdx+rcx*8]
    mov rcx, QWORD PTR [rsp+18h]
    xor eax, eax
    ; Publish once without retry. Nonzero is ready; a wrapped reservation can
    ; never overwrite a slot that an earlier entry already published.
    lock cmpxchg QWORD PTR [rdx], rcx
unknown_done:
    mov rdx, QWORD PTR [rsp+10h]
    mov rcx, QWORD PTR [rsp+8h]
    mov rax, QWORD PTR [rsp]
    add rsp, 18h
    jmp QWORD PTR [reskate_native_input_trace_relay]
known_lane:
    mov rax, QWORD PTR [rsp]
    add rsp, 18h
    jmp QWORD PTR [known_target]
reskate_native_input_trace_gate ENDP
END
