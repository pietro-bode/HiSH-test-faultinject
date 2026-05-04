#include "fault_stack.h"
#include <cstring>
#include <cstdio>
#include "hilog/log.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3300
#define LOG_TAG "HiSH"

bool g_stack_fault_triggered = false;

static char *get_stack_string() {
    char local_buf[32] = "stack_secret_data";
    return local_buf;
}

void trigger_stack_overflow() {
    if (g_stack_fault_triggered) {
        OH_LOG_ERROR(LOG_APP, "[FAULT] Stack fault already triggered, skipping StackOverflow");
        return;
    }
    
    g_stack_fault_triggered = true;
    
    char stack_buf[16];
    OH_LOG_ERROR(LOG_APP, "[FAULT] StackOverflow addr=%{public}p, buf_size=16", (void*)stack_buf);
    strcpy(stack_buf, "This is a very long string that exceeds 16 bytes");
}

void trigger_stack_uar() {
    if (g_stack_fault_triggered) {
        OH_LOG_ERROR(LOG_APP, "[FAULT] Stack fault already triggered, skipping StackUAR");
        return;
    }
    
    g_stack_fault_triggered = true;
    
    char *bad_ptr = get_stack_string();
    OH_LOG_ERROR(LOG_APP, "[FAULT] StackUAR addr=%{public}p", (void*)bad_ptr);
    printf("%s\n", bad_ptr);
}