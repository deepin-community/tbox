;           Copyright Oliver Kowalke 2009.
;  Distributed under the Boost Software License, Version 1.0.
;     (See accompanying file LICENSE_1_0.txt or copy at
;           http://www.boost.org/LICENSE_1_0.txt)
;

; Boost Software License - Version 1.0 - August 17th, 2003
;
; Permission is hereby granted, free of charge, to any person or organization
; obtaining a copy of the software and accompanying documentation covered by
; this license (the "Software") to use, reproduce, display, distribute,
; execute, and transmit the Software, and to prepare derivative works of the
; Software, and to permit third-parties to whom the Software is furnished to
; do so, all subject to the following:
;
; The copyright notices in the Software and this entire statement, including
; the above license grant, this restriction and the following disclaimer,
; must be included in all copies of the Software, in whole or in part, and
; all derivative works of the Software, unless such copies or derivative
; works are solely in the form of machine-executable object code generated by
; a source language processor.
;
; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
; FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
; SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
; FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
; ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
; DEALINGS IN THE SOFTWARE.
;;

; modified by ruki
;
; - modify stack layout
; - remove trampoline to optimize switch performance
;;

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; prefix
;;

.386
.model flat, c

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; declaration
;;

; exit(value)
_exit proto, value:sdword

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Contents of the TIB (32-bit Windows)
;;

; FS:[0x00]     * Current Structured Exception Handling (SEH) frame
; FS:[0x04]     * Stack Base / Bottom of stack (high address)
; FS:[0x08]     * Stack Limit / Ceiling of stack (low address)
; FS:[0x0C]       SubSystemTib
; FS:[0x10]     * Fiber data
; FS:[0x14]       Arbitrary data slot
; FS:[0x18]     * Linear address of TEB
; FS:[0x1C]       Environment Pointer
; FS:[0x20]       Process ID (in some windows distributions this field is used as 'DebugContext')
; FS:[0x24]       Current thread ID
; FS:[0x28]       Active RPC Handle
; FS:[0x2C]       Linear address of the thread-local storage array
; FS:[0x30]       Linear address of Process Environment Block (PEB)
; FS:[0x34]       Last error number
; FS:[0x38]       Count of owned critical sections
; FS:[0x3C]       Address of CSR Client Thread
; FS:[0x40]       Win32 Thread Information
; FS:[0x44]       Win32 client information (NT), user32 private data (Wine), 0x60 = LastError (Win95), 0x74 = LastError (WinME)
; FS:[0xC0]       Reserved for Wow64. Contains a pointer to FastSysCall in Wow64.
; FS:[0xC4]       Current Locale
; FS:[0xC8]       FP Software Status Register
; FS:[0xCC]       Reserved for OS (NT), kernel32 private data (Wine)
; FS:[0x1A4]      Exception code
; FS:[0x1A8]      Activation context stack
; FS:[0x1BC]      Spare bytes (NT), ntdll private data (Wine)
; FS:[0x1D4]      Reserved for OS (NT), ntdll private data (Wine)
; FS:[0x1FC]      GDI TEB Batch (OS), vm86 private data (Wine)
; FS:[0x6DC]      GDI Region
; FS:[0x6E0]      GDI Pen
; FS:[0x6E4]      GDI Brush
; FS:[0x6E8]      Real Process ID
; FS:[0x6EC]      Real Thread ID
; FS:[0x6F0]      GDI cached process handle
; FS:[0x6F4]      GDI client process ID (PID)
; FS:[0x6F8]      GDI client thread ID (TID)
; FS:[0x6FC]      GDI thread locale information
; FS:[0x700]      Reserved for user application
; FS:[0x714]      Reserved for GL
; FS:[0xBF4]      Last Status Value
; FS:[0xBF8]      Static UNICODE_STRING buffer
; FS:[0xE0C]    * Pointer to deallocation stack
; FS:[0xE10]      TLS slots, 4 byte per slot
; FS:[0xF10]      TLS links (LIST_ENTRY structure)
; FS:[0xF18]      VDM
; FS:[0xF1C]      Reserved for RPC
; FS:[0xF28]      Thread error mode (RtlSetThreadErrorMode)

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Structured Exception Handling (SEH) frame
;;

;               ----------      ----------
; FS:[0x00] -> |   prev   | -> |   prev   | -> ... -> 0xffffffff (end)
;              |----------|    |----------|
;              |  handler |    |  handler |
;               ----------      ----------

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; implementation
;;
.code

; make context (refer to boost.context)
;
;             -----------------------------------------------------------------------------------------
; stackdata: |                                                          |         context        |||||||
;             -----------------------------------------------------------------------------------|-----
;                                                                                           (16-align)
;
;
;             -------------------------------------------------
; context:   |  fiber  | dealloc |  limit  |  base   |   seh   | ----------------------------
;             -------------------------------------------------                              |
;            0         4         8         12        16                                      | seh chain for context function
;                                                                                            |
;                                                                                            |
;                                    func     __end    __entry        arguments(from)       \|/
;             -----------------------------------------------------------------------------------------------------------------------------------------
;            |   edi   |   esi   |   ebx   |   ebp   |   eip   | context |  priv  |  unused  | seh.prev (0xffffffff) | seh.handler | padding |
;             -----------------------------------------------------------------------------------------------------------------------------------------
;            20        24        28        32        36        40        44       48         52                     56             60
;                                                              |
;                                                              | 16-align
;                                                              |
;                                                   esp when jump to function
;
; @param stackdata     the stack data (esp + 4)
; @param stacksize     the stack size (esp + 8)
; @param func          the entry function (esp + 12)
;
; @return              the context pointer (eax)
;;
tb_context_make proc

    ; save the stack top to eax
    mov eax, [esp + 4]
    add eax, [esp + 8]
    mov ecx, eax

    ; reserve space for first argument(from) and seh item of context-function
    ; 5 * 4 = 20
    lea eax, [eax - 20]

    ; 16-align of the stack top address
    and eax, -16

    ; reserve space for context-data on context-stack
    lea eax, [eax - 40]

    ; save top address of context stack as 'base'
    mov [eax + 12], ecx

    ; save bottom address of context-stack as 'limit'
    mov ecx, [esp + 4]
    mov [eax + 8], ecx

    ; save bottom address of context-stack as 'dealloction stack'
    mov [eax + 4], ecx

    ; set fiber-storage as zero
    xor ecx, ecx
    mov [eax], ecx

    ; context.ebx = func
    mov ecx, [esp + 12]
    mov [eax + 28], ecx

    ; context.eip = __entry
    mov ecx, __entry
    mov [eax + 36], ecx

    ; context.ebp = the address of label __end
    mov ecx, __end
    mov [eax + 32], ecx

    ; install seh chain when enter into the context function
    ;
    ; traverse current seh chain to get the last exception handler installed by Windows
    ; note that on Windows Server 2008 and 2008 R2, SEHOP is activated by default
    ;
    ; the exception handler chain is tested for the presence of ntdll.dll!FinalExceptionHandler
    ; at its end by RaiseException all seh-handlers are disregarded if not present and the
    ; program is aborted
    ;
    ; load the current seh chain from TIB
    assume fs:nothing
    mov ecx, fs:[0h]
    assume fs:error

__walkchain:

    ; if (sehitem.prev == 0xffffffff) (last?) goto __found
    mov edx, [ecx]
    inc edx
    jz __found

    ; sehitem = sehitem.prev
    dec edx
    xchg edx, ecx
    jmp __walkchain

__found:

    ; context.seh.handler = sehitem.handler
    mov ecx, [ecx + 4]
    mov [eax + 56], ecx

    ; context.seh.prev = 0xffffffff
    mov ecx, 0ffffffffh
    mov [eax + 52], ecx

    ; context.seh = the address of context.seh.prev
    lea ecx, [eax + 52]
    mov [eax + 16], ecx

    ; return pointer to context-data
    ret

__entry:

    ; pass old-context(context: eax, priv: edx) arguments to the context function
    mov  [esp], eax
    mov  [esp + 4], edx

    ; patch return address: __end
    push ebp

    ; jump to the context function entry(eip)
    ;
    ;
    ;                           old-context
    ;              ------------------------------------------
    ; context: .. |   end   | context |   priv   |    ...    |
    ;              ------------------------------------------
    ;             0         4    arguments
    ;             |         |
    ;            esp     16-align
    ;           (now)
    ;;
    jmp ebx

__end:

    ; exit(0)
    xor eax, eax
    mov [esp], eax
    call _exit
    hlt

tb_context_make endp

; jump context (refer to boost.context)
;
; optimzation (jump context faster 30% than boost.context):
;    - adjust context stack layout (patch end behind eip)
;    - remove trampoline and jump to context function directly
;
; @param context       the to-context (esp + 4)
; @param priv          the passed user private data (esp + 8)
;
; @return              the from-context (context: eax, priv: edx)
;;
tb_context_jump proc

    ; save registers and construct the current context
    push ebp
    push ebx
    push esi
    push edi

    ; load TIB to edx
    assume fs:nothing
    mov edx, fs:[018h]
    assume fs:error

    ; load and save current seh exception list
    mov eax, [edx]
    push eax

    ; load and save current stack base
    mov eax, [edx + 04h]
    push eax

    ; load and save current stack limit
    mov eax, [edx + 08h]
    push eax

    ; load and save current deallocation stack
    mov eax, [edx + 0e0ch]
    push eax

    ; load and save fiber local storage
    mov eax, [edx + 010h]
    push eax

    ; save the old context(esp) to eax
    mov eax, esp

    ; switch to the new context(esp) and stack
    mov ecx, [esp + 40]
    mov esp, ecx

    ; load TIB to edx
    assume fs:nothing
    mov edx, fs:[018h]
    assume fs:error

    ; restore fiber local storage (context.fiber)
    pop ecx
    mov [edx + 010h], ecx

    ; restore current deallocation stack (context.dealloc)
    pop ecx
    mov [edx + 0e0ch], ecx

    ; restore current stack limit (context.limit)
    pop ecx
    mov [edx + 08h], ecx

    ; restore current stack base (context.base)
    pop ecx
    mov [edx + 04h], ecx

    ; restore current seh exception list (context.seh)
    pop ecx
    mov [edx], ecx

    ; restore registers of the new context
    pop edi
    pop esi
    pop ebx
    pop ebp

    ; restore the return or function address(ecx)
    pop ecx

    ; return from-context(context: eax, priv: edx) from jump
    ;
    ; edx = [eax + 44] = [esp_jump + 44] = jump.argument(priv)
    ;
    mov edx, [eax + 44]

    ; jump to the return or function address(eip)
    ;
    ;
    ;              old-context
    ;              --------------------------------
    ; context: .. | context |   priv   |    ...    |
    ;              --------------------------------
    ;             0     arguments
    ;             |
    ;            esp
    ;           (now)
    ;;
    jmp ecx

tb_context_jump endp

end

