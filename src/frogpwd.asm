; frogpwd - secure password generator (Linux x86_64) using getrandom()
; build: fasm frogpwd.asm frogpwd
;
; Supports options in any order:
;   frogpwd 24 --url --copy
;   frogpwd --url 24
;   frogpwd --copy --url 24
;   frogpwd 32 --nosym
;   frogpwd / frogpwd -h / frogpwd --help  => help

format ELF64 executable 3
entry _start

; syscalls (x86_64 Linux)
SYS_write      equ 1
SYS_close      equ 3
SYS_pipe       equ 22
SYS_dup2       equ 33
SYS_fork       equ 57
SYS_execve     equ 59
SYS_exit       equ 60
SYS_wait4      equ 61
SYS_getrandom  equ 318

STDOUT         equ 1
STDERR         equ 2

MAXLEN         equ 4096
POOLSIZE       equ 256

F_NOSYM        equ 1
F_URL          equ 2
F_COPY         equ 4

segment readable writeable

outbuf      rb MAXLEN
rndbuf      rb POOLSIZE

flags_dw    dd 0
poolpos_dd  dd 0
len_q       dq 0
envp_cache  dq 0

; Charsets
cs_default db 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
           db 'abcdefghijklmnopqrstuvwxyz'
           db '0123456789'
           db '!@#$%^&*()-_=+[]{}:,.?'
cs_default_end:
cs_default_len equ (cs_default_end - cs_default)

cs_nosym  db 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
          db 'abcdefghijklmnopqrstuvwxyz'
          db '0123456789'
cs_nosym_end:
cs_nosym_len equ (cs_nosym_end - cs_nosym)

cs_url    db 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
          db 'abcdefghijklmnopqrstuvwxyz'
          db '0123456789'
          db '-_'
cs_url_end:
cs_url_len equ (cs_url_end - cs_url)

; Help / errors
help_text db \
'frogpwd - secure password generator (Linux) [FASM x86-64]',10,\
'Made by Victor Duarte Melo (2025).',10,\
'Built with Flat Assembler (FASM) and Linux getrandom().',10,\
10,\
'Usage:',10,\
'  frogpwd                     Show this help',10,\
'  frogpwd [options] <length>  Generate a password of <length>',10,\
10,\
'Options:',10,\
'  --nosym                  Use only A-Z a-z 0-9',10,\
'  --url                    URL-safe charset (A-Z a-z 0-9 - _)',10,\
'  --copy                   Copy to clipboard (wl-copy or xclip). If missing, prints.',10,\
'  -h, --help               Show this help',10,\
10,\
'Examples:',10,\
'  frogpwd 24',10,\
'  frogpwd 32 --nosym',10,\
'  frogpwd --url 24 --copy',10,\
10,\
'Tip:',10,\
'  On Wayland, install: wl-clipboard',10,\
'  On X11, install: xclip',10,\
10,\
'Libertas Per Croack.',10
help_end:
help_len equ (help_end - help_text)

msg_err db 'error: invalid arguments. Use frogpwd --help',10
msg_err_end:
msg_err_len equ (msg_err_end - msg_err)

nl db 10

; clipboard tools
path_wlcopy db '/usr/bin/wl-copy',0
path_xclip  db '/usr/bin/xclip',0
xclip_arg1  db '-selection',0
xclip_arg2  db 'clipboard',0
wl_argv    dq path_wlcopy, 0
xclip_argv dq path_xclip, xclip_arg1, xclip_arg2, 0

; option strings
opt_h     db '-h',0
opt_help  db '--help',0
opt_nosym db '--nosym',0
opt_url   db '--url',0
opt_copy  db '--copy',0

segment readable executable

_start:
    ; Linux ABI: argc/argv on stack
    mov r12, [rsp]          ; argc
    lea r13, [rsp+8]        ; argv base
    call validate_argc_argv
    test eax, eax
    jz .show_help

    mov dword [flags_dw], 0
    mov qword [len_q], 0

    ; no args => help
    cmp r12, 1
    je .show_help

    ; parse argv[1..argc-1] in any order
    mov r11, 1
.arg_loop:
    cmp r11, r12
    jae .arg_done

    mov rdx, [r13 + r11*8]
    test rdx, rdx
    jz .arg_done

    ; option?
    mov al, [rdx]
    cmp al, '-'
    jne .try_length

    ; -h / --help
    mov rdi, rdx
    lea rsi, [opt_h]
    call streq
    test eax, eax
    jnz .show_help

    mov rdi, rdx
    lea rsi, [opt_help]
    call streq
    test eax, eax
    jnz .show_help

    ; --nosym
    mov rdi, rdx
    lea rsi, [opt_nosym]
    call streq
    test eax, eax
    jz .chk_url
    or dword [flags_dw], F_NOSYM
    jmp .arg_next

.chk_url:
    mov rdi, rdx
    lea rsi, [opt_url]
    call streq
    test eax, eax
    jz .chk_copy
    or dword [flags_dw], F_URL
    jmp .arg_next

.chk_copy:
    mov rdi, rdx
    lea rsi, [opt_copy]
    call streq
    test eax, eax
    jz .bad_args
    or dword [flags_dw], F_COPY
    jmp .arg_next

.try_length:
    ; parse length (numeric)
    mov rbx, rdx
    call parse_u64
    jc .bad_args

    ; only one length allowed
    cmp qword [len_q], 0
    jne .bad_args
    mov [len_q], rax

.arg_next:
    inc r11
    jmp .arg_loop

.arg_done:
    ; length must exist
    mov rax, [len_q]
    test rax, rax
    jz .bad_args
    cmp rax, MAXLEN
    ja .bad_args
    mov r8, rax             ; length

    ; choose charset: RBX ptr, EBP len
    mov eax, [flags_dw]
    test eax, F_URL
    jz .maybe_nosym
    lea rbx, [cs_url]
    mov ebp, cs_url_len
    jmp .charset_ok

.maybe_nosym:
    test eax, F_NOSYM
    jz .default_cs
    lea rbx, [cs_nosym]
    mov ebp, cs_nosym_len
    jmp .charset_ok

.default_cs:
    lea rbx, [cs_default]
    mov ebp, cs_default_len

.charset_ok:
    ; rejection sampling limit = floor(256/len)*len
    mov eax, 256
    xor edx, edx
    mov ecx, ebp
    div ecx
    imul eax, ecx
    mov r15d, eax           ; limit

    ; counters
    xor r14d, r14d          ; out_index
    xor r9d, r9d            ; pool_size
    mov dword [poolpos_dd], 0

.gen_loop:
    cmp r14, r8
    jae .gen_done

    mov eax, [poolpos_dd]
    cmp eax, r9d
    jb .have_byte

.refill_pool:
    mov eax, SYS_getrandom
    lea rdi, [rndbuf]
    mov esi, POOLSIZE
    xor edx, edx
    syscall
    test rax, rax
    jle .fatal_exit
    mov dword [poolpos_dd], 0
    mov r9d, eax            ; pool_size = bytes read

.have_byte:
    mov ecx, [poolpos_dd]
    movzx eax, byte [rndbuf + rcx]
    inc ecx
    mov [poolpos_dd], ecx

    cmp eax, r15d
    jae .gen_loop           ; reject to avoid bias

    xor edx, edx
    mov ecx, ebp
    div ecx                 ; edx = idx
    mov al, [rbx + rdx]
    mov [outbuf + r14], al
    inc r14
    jmp .gen_loop

.gen_done:
    mov eax, [flags_dw]
    test eax, F_COPY
    jz .print_pw

    call copy_to_clipboard
    test eax, eax
    jnz .exit_ok

.print_pw:
    mov eax, SYS_write
    mov edi, STDOUT
    lea rsi, [outbuf]
    mov rdx, r8
    syscall

    mov eax, SYS_write
    mov edi, STDOUT
    lea rsi, [nl]
    mov edx, 1
    syscall

.exit_ok:
    xor edi, edi
    mov eax, SYS_exit
    syscall

.show_help:
    mov eax, SYS_write
    mov edi, STDOUT
    lea rsi, [help_text]
    mov edx, help_len
    syscall
    xor edi, edi
    mov eax, SYS_exit
    syscall

.bad_args:
    mov eax, SYS_write
    mov edi, STDERR
    lea rsi, [msg_err]
    mov edx, msg_err_len
    syscall
    mov edi, 1
    mov eax, SYS_exit
    syscall

.fatal_exit:
    mov edi, 2
    mov eax, SYS_exit
    syscall

; Validate argc/argv and cache envp
validate_argc_argv:
    test r12, r12
    jz .bad
    cmp r12, 256
    ja .bad

    mov rax, [r13]          ; argv[0]
    test rax, rax
    jz .bad

    mov rax, [r13 + r12*8]  ; argv[argc] must be NULL
    test rax, rax
    jnz .bad

    lea rax, [r13 + (r12+1)*8] ; envp = &argv[argc+1]
    mov [envp_cache], rax
    mov eax, 1
    ret
.bad:
    xor eax, eax
    ret

; Copy to clipboard via wl-copy or xclip
; returns eax=1 on success, 0 on failure
copy_to_clipboard:
    sub rsp, 32
    lea rdi, [rsp]
    mov eax, SYS_pipe
    syscall
    test rax, rax
    js .fail

    mov eax, SYS_fork
    syscall
    test rax, rax
    js .fail

    cmp rax, 0
    je .child

    ; parent: write password to pipe
    mov edi, [rsp]          ; close read end
    mov eax, SYS_close
    syscall

    mov edi, [rsp+4]        ; write end
    mov eax, SYS_write
    lea rsi, [outbuf]
    mov rdx, r8
    syscall

    mov edi, [rsp+4]
    mov eax, SYS_close
    syscall

    ; wait child
    mov edi, -1
    lea rsi, [rsp+16]
    xor edx, edx
    xor r10d, r10d
    mov eax, SYS_wait4
    syscall

    mov eax, dword [rsp+16]
    test eax, eax
    jne .fail_parent

    add rsp, 32
    mov eax, 1
    ret

.fail_parent:
    add rsp, 32
    xor eax, eax
    ret

.child:
    ; pipefd[0] -> stdin
    mov edi, [rsp]
    xor esi, esi
    mov eax, SYS_dup2
    syscall

    ; close both ends
    mov edi, [rsp]
    mov eax, SYS_close
    syscall
    mov edi, [rsp+4]
    mov eax, SYS_close
    syscall

    add rsp, 32

    mov rdx, [envp_cache]   ; inherit env

    ; try wl-copy
    mov eax, SYS_execve
    lea rdi, [path_wlcopy]
    lea rsi, [wl_argv]
    syscall

    ; fallback xclip
    mov eax, SYS_execve
    lea rdi, [path_xclip]
    lea rsi, [xclip_argv]
    syscall

    mov edi, 1
    mov eax, SYS_exit
    syscall

.fail:
    add rsp, 32
    xor eax, eax
    ret

; streq: rdi = s1, rsi = s2
; returns eax=1 if equal else 0
streq:
    push rbx
.loop:
    mov al, [rdi]
    mov bl, [rsi]
    cmp al, bl
    jne .no
    test al, al
    je .yes
    inc rdi
    inc rsi
    jmp .loop
.yes:
    mov eax, 1
    pop rbx
    ret
.no:
    xor eax, eax
    pop rbx
    ret

; parse_u64: rbx points to decimal string
; returns rax=value, CF=0 ok, CF=1 error (non-digit or empty)
parse_u64:
    xor rax, rax
    xor rcx, rcx
.ploop:
    mov dl, [rbx]
    test dl, dl
    jz .pend
    cmp dl, '0'
    jb .perr
    cmp dl, '9'
    ja .perr
    sub dl, '0'
    movzx edx, dl
    lea rax, [rax*4 + rax]
    lea rax, [rax*2]
    add rax, rdx
    inc rcx
    inc rbx
    jmp .ploop
.pend:
    test rcx, rcx
    jz .perr
    clc
    ret
.perr:
    stc
    ret
