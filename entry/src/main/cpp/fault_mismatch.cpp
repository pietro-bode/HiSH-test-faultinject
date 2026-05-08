#include "fault_mismatch.h"
#include "hilog/log.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3300
#define LOG_TAG "HiSH"

void trigger_mismatched_new_delete() {
    int *arr = new int[20];
    OH_LOG_ERROR(LOG_APP, "[FAULT] MismatchedNewDelete addr=%{public}p, new int[20] -> delete", (void*)arr);
    arr[0] = 123;
    delete arr;
}