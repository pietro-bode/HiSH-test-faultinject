#include "fault_injection.h"
#include "fault_uaf.h"
#include "fault_double_free.h"
#include "fault_stack.h"
#include "fault_heap_overflow.h"
#include "fault_mismatch.h"
#include <cstdlib>
#include <cstdio>
#include <unistd.h>
#include <random>
#include <atomic>
#include "hilog/log.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3300
#define LOG_TAG "HiSH"

static unsigned int trigger_fault_cnt = 0;
static std::atomic<bool> g_gwpasan_detected{false};
static std::random_device rd;
static std::mt19937 gen(rd());
static std::uniform_int_distribution<> prob_dis(0, 99);
static std::uniform_int_distribution<> alloc_count_dis(10, 1000);
static std::uniform_int_distribution<> size_dis(16, 128);
static std::uniform_int_distribution<> byte_dis(0, 255);

// 只随机选择一次故障类型，后续一直复用
static int selected_fault_type = -1;

static int pick_fault_type_once() {
    // 概率分布（百分比）：
    // 栈故障(types 3,4): 5%
    // 堆溢出(types 5,6,8): 10%
    // trigger_mismatched_new_delete(type 7): 1%
    // trigger_uaf_global_ptr(type 9): 1%
    // double_free(type 2): 1%
    // 其他(types 0,1): 82%
    int prob = prob_dis(gen);
    int fault_type;

    if (prob < 2) {              // 0-1:  2%
        fault_type = 3;          // stack_overflow
    } else if (prob < 5) {       // 2-4:  3%
        fault_type = 4;          // stack_uar
    } else if (prob < 8) {       // 5-7:  3%
        fault_type = 5;          // heap_overflow_loop
    } else if (prob < 11) {      // 8-10: 3%
        fault_type = 6;          // heap_overflow_strcpy
    } else if (prob < 15) {      // 11-14: 4%
        fault_type = 8;          // heap_overflow_off_by_one
    } else if (prob < 16) {      // 15:   1%
        fault_type = 7;          // mismatched_new_delete
    } else if (prob < 17) {      // 16:   1%
        fault_type = 9;          // uaf_global_ptr
    } else if (prob < 18) {      // 17:   1%
        fault_type = 2;          // double_free
    } else if (prob < 59) {      // 18-58: 41%
        fault_type = 0;          // uaf_read
    } else {                     // 59-99: 41%
        fault_type = 1;          // uaf_write
    }
    return fault_type;
}

void random_trigger_fault() {
    if (selected_fault_type < 0) {
        selected_fault_type = pick_fault_type_once();
        OH_LOG_ERROR(LOG_APP, "[FAULT] First trigger, randomly selected type=%{public}d, all subsequent injections will use this type",
                     selected_fault_type);
    }

    int fault_type = selected_fault_type;

    OH_LOG_ERROR(LOG_APP, "[FAULT] trigger #%{public}u, type=%{public}d (fixed)",
                 trigger_fault_cnt++, fault_type);
    
    // 先进行大量随机内存分配/释放，搅动堆状态（防止编译优化）
    volatile int alloc_count = alloc_count_dis(gen);
    for (volatile int i = 0; i < alloc_count; i++) {
        volatile int size = size_dis(gen);
        volatile unsigned char *tmp = (volatile unsigned char *)malloc((size_t)size);
        if (tmp) {
            for (volatile int j = 0; j < size / 4; j++) {
                tmp[j] = (unsigned char)byte_dis(gen);
            }
            printf("%x\n", tmp[0]);
            free((void *)tmp);
        }
    }

    if (fault_type == 0) {
        trigger_uaf_read();
    }
    else if (fault_type == 1) {
        trigger_uaf_write();
    }
    else if (fault_type == 2) {
        trigger_double_free();
    }
    else if (fault_type == 3) {
        trigger_stack_overflow();
    }
    else if (fault_type == 4) {
        trigger_stack_uar();
    }
    else if (fault_type == 5) {
        trigger_heap_overflow_loop();
    }
    else if (fault_type == 6) {
        trigger_heap_overflow_strcpy();
    }
    else if (fault_type == 7) {
        trigger_mismatched_new_delete();
    }
    else if (fault_type == 8) {
        trigger_heap_overflow_off_by_one();
    }
    else if (fault_type == 9) {
        trigger_uaf_global_ptr();
    }
}

void set_gwpasan_detected(bool detected) {
    g_gwpasan_detected.store(detected);
    if (detected) {
        OH_LOG_ERROR(LOG_APP, "[GWP-ASAN] Fault injection gated - GWP-ASAN event detected");
    }
}

bool is_gwpasan_detected() {
    return g_gwpasan_detected.load();
}

void trigger_fault(){
    if (g_gwpasan_detected.load()) {
        OH_LOG_INFO(LOG_APP, "[GWP-ASAN] Skipping fault injection #%{public}u - GWP-ASAN event previously detected",
                     trigger_fault_cnt);
        return;
    }
    random_trigger_fault();
}
