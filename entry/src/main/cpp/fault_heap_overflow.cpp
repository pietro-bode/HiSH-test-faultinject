#include "fault_heap_overflow.h"
#include <cstdlib>
#include <cstring>
#include "hilog/log.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3300
#define LOG_TAG "HiSH"

void trigger_heap_overflow_loop() {
    char *buf = (char *)malloc(16);
    if (buf) {
        OH_LOG_ERROR(LOG_APP, "[FAULT] HeapOverflow(loop) addr=%{public}p, alloc_size=16, write_size=64", (void*)buf);
        for (int i = 0; i < 64; i++) {
            buf[i] = 'A';
        }
        free(buf);
    }
}

void trigger_heap_overflow_strcpy() {
    char *buf = (char *)malloc(10);
    if (buf) {
        OH_LOG_ERROR(LOG_APP, "[FAULT] HeapOverflow(strcpy) addr=%{public}p, alloc_size=10", (void*)buf);
        strcpy(buf, "This_string_is_way_longer_than_10_bytes");
        free(buf);
    }
}

void trigger_heap_overflow_off_by_one() {
    int *arr = (int *)malloc(sizeof(int) * 10);
    if (arr) {
        OH_LOG_ERROR(LOG_APP, "[FAULT] HeapOverflow(off-by-one) addr=%{public}p, alloc_count=10, access_index=10", (void*)arr);
        for (int i = 0; i <= 10; i++) {
            arr[i] = i * i;
        }
        free(arr);
    }
}