# kernelfix.s - a tiny x86-64 shared library that replaces uname().
#
# Why: SP Flash Tool v5 can stop on a kernel that is new enough with
#   "Invalid linux kervel version. Please upgrade linux kernel up to at least 4.19.14!"
# It seems to compare the versions as text, and the text "4.19.127" sorts before "4.19.14".
#
# What it does: uname() works as always (it makes the real system call). Then, when the file
# /tmp/spft-fake-kernel exists, the first line of that file (at most 64 characters) is written over
# the "release" field. spft-run writes that file, and loads this library through box64's
# BOX64_LD_PRELOAD, only when it is needed, so for everything else nothing changes.
#
# It needs no libc and has no relocations: raw system calls only.
# struct utsname: six fields of 65 bytes: sysname 0, nodename 65, release 130, version 195, machine 260, domainname 325.
        .intel_syntax noprefix
        .text
        .globl  uname
        .type   uname, @function
uname:
        push    rbx
        push    r12
        push    r13
        sub     rsp, 72                      # room for the first 64 bytes of the file
        mov     rbx, rdi                     # rbx = struct utsname * (the system calls keep it)
        mov     byte ptr [rbx + 325], 0      # domainname = "": an emulated uname call may not set it
        mov     eax, 63                      # SYS_uname
        syscall
        test    rax, rax
        jnz     .Lfailed
        lea     rdi, [rip + .Lpath]          # open("/tmp/spft-fake-kernel", O_RDONLY)
        xor     esi, esi
        xor     edx, edx
        mov     eax, 2                       # SYS_open
        syscall
        test    rax, rax
        js      .Lreal                       # no such file: the real release stays
        mov     r12, rax                     # r12 = the file descriptor
        mov     rdi, r12                     # read(fd, buffer, 64)
        mov     rsi, rsp
        mov     edx, 64
        xor     eax, eax                     # SYS_read
        syscall
        mov     r13, rax                     # r13 = bytes read
        mov     rdi, r12                     # close(fd)
        mov     eax, 3                       # SYS_close
        syscall
        test    r13, r13
        jle     .Lreal
        xor     ecx, ecx                     # copy the first line into release
.Lcopy:
        cmp     rcx, r13
        jae     .Lend
        movzx   eax, byte ptr [rsp + rcx]
        cmp     al, 10                       # a newline ends the line
        je      .Lend
        test    al, al
        jz      .Lend
        mov     byte ptr [rbx + 130 + rcx], al
        inc     rcx
        jmp     .Lcopy
.Lend:
        test    rcx, rcx
        jz      .Lreal                       # an empty first line: keep the real release
        mov     byte ptr [rbx + 130 + rcx], 0
.Lreal:
        xor     eax, eax
        jmp     .Lreturn
.Lfailed:
        mov     rax, -1
.Lreturn:
        add     rsp, 72
        pop     r13
        pop     r12
        pop     rbx
        ret
        .size   uname, .-uname
        .section .rodata
.Lpath: .asciz  "/tmp/spft-fake-kernel"
        .section .note.GNU-stack,"",@progbits
