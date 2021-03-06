/*
    ChibiOS - Copyright (C) 2006..2018 Giovanni Di Sirio.

    This file is part of ChibiOS.

    ChibiOS is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 3 of the License, or
    (at your option) any later version.

    ChibiOS is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

/**
 * @file    compilers/GCC/chcoreasm_v7m.S
 * @brief   ARMv7-M architecture port low level code.
 *
 * @addtogroup ARMCMx_GCC_CORE
 * @{
 */

#if !defined(FALSE) || defined(__DOXYGEN__)
#define FALSE   0
#endif

#if !defined(TRUE) || defined(__DOXYGEN__)
#define TRUE    1
#endif

#define _FROM_ASM_
#include "chlicense.h"
#include "chconf.h"
#include "chcore.h"

#if !defined(__DOXYGEN__)

/*
 * RTOS-specific context offset.
 */
#if defined(_CHIBIOS_RT_CONF_)
#if CH_CFG_USE_REGISTRY
#define CURRENT_OFFSET  20          /* ch.rlist.current */
#define CONTEXT_OFFSET  20
#else
#define CURRENT_OFFSET  12
#define CONTEXT_OFFSET  12
#endif

#elif defined(_CHIBIOS_NIL_CONF_)
#define CURRENT_OFFSET  0           /* nil.current */
#define CONTEXT_OFFSET  0

#else
#error "invalid chconf.h"
#endif

/* MPU-related constants.*/
#define MPU_RBAR        0xE000ED9C

/* Other constants.*/
#define SCB_ICSR        0xE000ED04
#define SCB_VTOR_NS     0xE002ED08
#define ICSR_PENDSVSET  0x10000000

                .syntax unified
                .cpu    cortex-m33
#if CORTEX_USE_FPU
                .fpu    fpv4-sp-d16
#else
                .fpu    softvfp
#endif

                .thumb
                .text

/*--------------------------------------------------------------------------*
 * Context switch macros depending on various options.
 *--------------------------------------------------------------------------*/

#if !CH_DBG_ENABLE_STACK_CHECK
                .macro  PORT_STORE_INTEGER_CONTEXT_R1
                mrs     r2, PSP
                mrs     r3, BASEPRI
                stmia   r1!, {r2-r11,lr}
                .endm

                .macro  PORT_RESTORE_INTEGER_CONTEXT_R0
                ldmia   r0!, {r2-r11, lr}
                msr     PSP, r2
                msr     BASEPRI, r3
                .endm
#else /* CH_DBG_ENABLE_STACK_CHECK */
                .macro  PORT_STORE_INTEGER_CONTEXT_R1
                mrs     r2, PSP
                mrs     r3, BASEPRI
                mrs     r12, PSPLIM
                stmia   r1!, {r2-r12,lr}
                .endm

                .macro  PORT_RESTORE_INTEGER_CONTEXT_R0
                ldmia   r0!, {r2-r12, lr}
                /* Note the following is not required because this sentence
                   in the ARMv8-M architecture manual:
                       Updates to the stack pointer by the MSR instruction
                       targeting SP_NS are subject to stack limit checking.
                       Updates to the stack pointer and stack pointer limit
                       by any other MSR instruction are not subject to
                       stack limit checking.*/
//                movs    r1, #0
//                msr     PSPLIM, r1      /* Temporarily disabling stack check.*/
                msr     PSP, r2
                msr     BASEPRI, r3
                msr     PSPLIM, r12
                .endm
#endif

#if CORTEX_USE_FPU
                .macro  PORT_STORE_FLOAT_CONTEXT_R1
                vstmia  r1!, {s16-s31}
                .endm

                .macro  PORT_RESTORE_FLOAT_CONTEXT_R0
                vldmia  r0!, {s16-s31}
                .endm
#else
                .macro  PORT_STORE_FLOAT_CONTEXT_R1
                .endm

                .macro  PORT_RESTORE_FLOAT_CONTEXT_R0
                .endm
#endif

/*--------------------------------------------------------------------------*
 * Performs a context switch between two threads using SVC.
 *--------------------------------------------------------------------------*/
                .thumb_func
                .globl  SVC_Handler
SVC_Handler:
                /* Saving callee context of thread being swapped out.*/
                adds    r1, #CONTEXT_OFFSET

                /* Storing integer and control context through R1.*/
                PORT_STORE_INTEGER_CONTEXT_R1

                /* Storing float context through R1.*/
                PORT_STORE_FLOAT_CONTEXT_R1

                /* Restoring calle context of thread being swapped in.*/
                adds    r0, #CONTEXT_OFFSET

                /* Restoring integer and control context through R0.*/
                PORT_RESTORE_INTEGER_CONTEXT_R0

                /* Restoring float context through R0.*/
                PORT_RESTORE_FLOAT_CONTEXT_R0

                bx      lr

/*--------------------------------------------------------------------------*
 * Tail preemption check using PENDSV.
 *--------------------------------------------------------------------------*/
                .thumb_func
                .globl  PendSV_Handler
PendSV_Handler:
                /* Pointer to the current thread.*/
                ldr     r1, =ch
//                movw    r1, #:lower16:ch
//                movt    r1, #:upper16:ch
                ldr     r1, [r1, #CURRENT_OFFSET]

                /* Saving callee context of thread being swapped out.*/
                adds    r1, #CONTEXT_OFFSET

                /* Storing integer and control context through R1.*/
                PORT_STORE_INTEGER_CONTEXT_R1

                /* Storing float context through R1.*/
                PORT_STORE_FLOAT_CONTEXT_R1

                /* Selecting the thread to be swapped in, R0 points to it.*/
                bl      port_schedule_next

                /* Restoring calle context of thread being swapped in.*/
                adds    r0, #CONTEXT_OFFSET

                /* Restoring integer and control context through R0.*/
                PORT_RESTORE_INTEGER_CONTEXT_R0

                /* Restoring float context through R0.*/
                PORT_RESTORE_FLOAT_CONTEXT_R0

                bx      lr

/*--------------------------------------------------------------------------*
 * Start a thread by invoking its work function.
 *
 * Threads execution starts here, the code leaves the system critical zone
 * and then jumps into the thread function passed in register R4. The
 * register R5 contains the thread parameter. The function chThdExit() is
 * called on thread function return.
 *--------------------------------------------------------------------------*/
                .thumb_func
                .globl  __port_thread_start
__port_thread_start:
#if CH_DBG_STATISTICS
                bl      _stats_stop_measure_crit_thd
#endif
                movs    r3, #CORTEX_BASEPRI_DISABLED
                msr     BASEPRI, r3
                mov     r0, r5
                blx     r4
                movs    r0, #0              /* MSG_OK */
                bl      chThdExit
_zombies:       b       _zombies

#if PORT_KERNEL_MODE == PORT_KERNEL_MODE_HOST
/*--------------------------------------------------------------------------*
 * Safe jump in non-secure code zone. All registers are cleared.
 *--------------------------------------------------------------------------*/
                .thumb_func
                .globl  __port_ns_boot
__port_ns_boot:
                movs    r3, #0
                movs    r4, #0
                movs    r5, #0
                movs    r6, #0
                movs    r7, #0
                movs    r8, #0
                movs    r9, #0
                movs    r10, #0
                movs    r11, #0
                movs    r12, #0
                movs    lr, #0
#if CORTEX_USE_FPU
                vldr.64 d0, =0
                vldr.64 d1, =0
                vldr.64 d2, =0
                vldr.64 d3, =0
                vldr.64 d4, =0
                vldr.64 d5, =0
                vldr.64 d6, =0
                vldr.64 d7, =0
                vldr.64 d8, =0
                vldr.64 d9, =0
                vldr.64 d10, =0
                vldr.64 d11, =0
                vldr.64 d12, =0
                vldr.64 d13, =0
                vldr.64 d14, =0
                vldr.64 d15, =0
#endif
                msr     PSPLIM_NS, r3
                msr     MSPLIM_NS, r3
                msr     BASEPRI, r3
                ldr     r1, =SCB_VTOR_NS
                str     r0, [r1, #0]
                ldr     r1, [r0, #0]    /* MSP from vectors table.*/
                msr     MSP_NS, r1
                ldr     r2, [r0, #4]    /* PC from vectors table.*/
                ldr     r3, =0x30000000
                str     r0, [r3, #0]
                str     r1, [r3, #4]
                str     r2, [r3, #8]
                bxns    r2
#endif

#endif /* !defined(__DOXYGEN__) */

/** @} */
