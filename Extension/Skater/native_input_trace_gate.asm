; The unknown lane must never acquire a C++ prototype. Save only the volatile
; register used to inspect the return address, then restore the original entry
; stack and tail-jump to the permanent Detours relay. No argument/SIMD slots move.
OPTION CASEMAP:NONE
EXTERN reskate_native_input_trace_relay:QWORD
EXTERN reskate_native_input_trace_interpreter_return:QWORD
EXTERN reskate_native_input_trace_alternate_return:QWORD
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
    mov rax, QWORD PTR [rsp]
    add rsp, 18h
    jmp QWORD PTR [reskate_native_input_trace_relay]
known_lane:
    mov rax, QWORD PTR [rsp]
    add rsp, 18h
    jmp QWORD PTR [known_target]
reskate_native_input_trace_gate ENDP
END
