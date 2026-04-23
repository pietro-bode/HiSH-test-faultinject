#include "fault_injection.h"
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <unistd.h>
#include "hilog/log.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3300
#define LOG_TAG "HiSH"

static unsigned int trigger_fault_cnt = 0;
static char *g_uaf_ptr = nullptr;

static char *get_stack_string() {
    char local_buf[32] = "stack_secret_data";
    return local_buf; // 返回栈局部变量的地址，函数返回后该内存失效
}

void random_trigger_fault() {
    // 随机选择故障类型 (0~9)
    int fault_type = rand() % 5;
    OH_LOG_ERROR(LOG_APP, "[FAULT] trigger #%{public}u, type=%{public}d", trigger_fault_cnt++, fault_type);
    
    // 先进行大量随机内存分配/释放，搅动堆状态（防止编译优化）
    volatile int alloc_count = (rand() % 991) + 10; // 10~1000 次
        for (volatile int i = 0; i < alloc_count; i++) {
            volatile int size = (rand() % 113) + 16; // 16~128 字节
            volatile unsigned char *tmp = (volatile unsigned char *)malloc((size_t)size);
            if (tmp) {
                // 填充数据，volatile 写入确保不会被编译优化掉
                for (volatile int j = 0; j < size / 4; j++) {
                    tmp[j] = (unsigned char)(rand() % 256);
                }
                printf("%x\n", tmp[0]);
                free((void *)tmp);
            }
        }

    if (fault_type == 0) {
        // Use-After-Free — 读取已释放内存
        char *buf = (char *)malloc(64);
        if (buf) {
            OH_LOG_ERROR(LOG_APP, "[FAULT] UAF-Read addr=%{public}p, alloc_size=64", (void*)buf);
            strcpy(buf, "sensitive info");
            free(buf);
            OH_LOG_ERROR(LOG_APP, "[FAULT] UAF-Read accessing freed addr=%{public}p", (void*)buf);
        }
    }
    else if (fault_type == 1) {

        // Use-After-Free — 写入已释放内存
        char *buf = (char *)malloc(32);
        if (buf) {
            OH_LOG_ERROR(LOG_APP, "[FAULT] UAF-Write addr=%{public}p, alloc_size=32", (void*)buf);
            strcpy(buf, "test data");
            free(buf);
            buf[0] = 'X';
        }
    }
    else if (fault_type == 2) {
        char *buf = (char *)malloc(24);
        if (buf) {
            OH_LOG_ERROR(LOG_APP, "[FAULT] DoubleFree addr=%{public}p, alloc_size=24", (void*)buf);
            free(buf);
            free(buf);
        }
    }
    else if (fault_type == 3) {
        // Stack Buffer Overflow — 栈缓冲区溢出
        char stack_buf[16];
        OH_LOG_ERROR(LOG_APP, "[FAULT] StackOverflow addr=%{public}p, buf_size=16", (void*)stack_buf);
        strcpy(stack_buf, "This is a very long string that exceeds 16 bytes");
    }
    else if (fault_type == 4) {
        // Stack Use-After-Return — 返回后访问栈变量
        char *bad_ptr = get_stack_string();
        OH_LOG_ERROR(LOG_APP, "[FAULT] StackUAR addr=%{public}p", (void*)bad_ptr);
        printf("%s\n", bad_ptr);
    }
    else if (fault_type == 5) {
        // Heap Buffer Overflow — loop 越界写入
        char *buf = (char *)malloc(16);
        if (buf) {
            OH_LOG_ERROR(LOG_APP, "[FAULT] HeapOverflow(loop) addr=%{public}p, alloc_size=16, write_size=64", (void*)buf);
            for (int i = 0; i < 64; i++) {
                buf[i] = 'A';
            }
            free(buf);
        }
    }
    else if (fault_type == 6) {
        // Heap Buffer Overflow — strcpy 导致堆溢出
        char *buf = (char *)malloc(10);
        if (buf) {
            OH_LOG_ERROR(LOG_APP, "[FAULT] HeapOverflow(strcpy) addr=%{public}p, alloc_size=10", (void*)buf);
            strcpy(buf, "This_string_is_way_longer_than_10_bytes");
            free(buf);
        }
    }
    else if (fault_type == 7) {
        // Mismatched new/delete — new[] 配 delete（不匹配）
        int *arr = new int[20];
        OH_LOG_ERROR(LOG_APP, "[FAULT] MismatchedNewDelete addr=%{public}p, new int[20] -> delete", (void*)arr);
        arr[0] = 123;
        delete arr;
    }
    else if (fault_type == 8) {
        // Heap Buffer Overflow — off-by-one 越界
        int *arr = (int *)malloc(sizeof(int) * 10);
        if (arr) {
            OH_LOG_ERROR(LOG_APP, "[FAULT] HeapOverflow(off-by-one) addr=%{public}p, alloc_count=10, access_index=10", (void*)arr);
            for (int i = 0; i <= 10; i++) {
                arr[i] = i * i;
            }
            free(arr);
        }
    }
    else if (fault_type == 9) {
        // Use-After-Free — 通过全局/静态指针访问已释放内存
        g_uaf_ptr = (char *)malloc(48);
        if (g_uaf_ptr) {
            OH_LOG_ERROR(LOG_APP, "[FAULT] UAF-GlobalPtr addr=%{public}p, alloc_size=48", (void*)g_uaf_ptr);
            strcpy(g_uaf_ptr, "global uaf test");
            free(g_uaf_ptr);
            g_uaf_ptr[0] = 'G';
            g_uaf_ptr = nullptr;
        }
    }
}

void trigger_fault(){
    random_trigger_fault();
}
