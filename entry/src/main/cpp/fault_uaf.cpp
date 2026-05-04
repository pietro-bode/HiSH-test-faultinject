#include "fault_uaf.h"
#include <cstdlib>
#include <cstring>
#include "hilog/log.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3300
#define LOG_TAG "HiSH"

static char *g_uaf_ptr = nullptr;

void trigger_uaf_read() {
    char *buf = (char *)malloc(64);
    if (buf) {
        OH_LOG_ERROR(LOG_APP, "[FAULT] UAF-Read addr=%{public}p, alloc_size=64", (void*)buf);
        strcpy(buf, "sensitive info");
        free(buf);
        OH_LOG_ERROR(LOG_APP, "[FAULT] UAF-Read accessing freed addr=%{public}p", (void*)buf);
    }
}

void trigger_uaf_write() {
    char *buf = (char *)malloc(32);
    if (buf) {
        OH_LOG_ERROR(LOG_APP, "[FAULT] UAF-Write addr=%{public}p, alloc_size=32", (void*)buf);
        strcpy(buf, "test data");
        free(buf);
        buf[0] = 'X';
    }
}

void trigger_uaf_global_ptr() {
    g_uaf_ptr = (char *)malloc(48);
    if (g_uaf_ptr) {
        OH_LOG_ERROR(LOG_APP, "[FAULT] UAF-GlobalPtr addr=%{public}p, alloc_size=48", (void*)g_uaf_ptr);
        strcpy(g_uaf_ptr, "global uaf test");
        free(g_uaf_ptr);
        g_uaf_ptr[0] = 'G';
        g_uaf_ptr = nullptr;
    }
}