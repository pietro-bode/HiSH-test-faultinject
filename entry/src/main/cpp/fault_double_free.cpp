#include "fault_double_free.h"
#include <cstdlib>
#include <thread>
#include <chrono>
#include <vector>
#include <random>
#include "hilog/log.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3300
#define LOG_TAG "HiSH"

bool g_double_free_triggered = false;

static std::random_device rd;
static std::mt19937 gen(rd());
static std::uniform_int_distribution<> interference_dis(0, 3);
static std::uniform_int_distribution<> delay_dis(0, 99);

void delayed_free_task(std::vector<char*> buffers, int delay_seconds) {
    OH_LOG_ERROR(LOG_APP, "[FAULT] DoubleFree delayed_thread started, will free after %{public}d seconds", delay_seconds);
    std::this_thread::sleep_for(std::chrono::seconds(delay_seconds));
    
    for (size_t i = 0; i < buffers.size(); i++) {
        if (buffers[i]) {
            OH_LOG_ERROR(LOG_APP, "[FAULT] DoubleFree delayed_thread freeing #%{public}zu addr=%{public}p", 
                         i, (void*)buffers[i]);
            free(buffers[i]);
        }
    }
    OH_LOG_ERROR(LOG_APP, "[FAULT] DoubleFree delayed_thread completed, freed %{public}zu buffers", buffers.size());
}

void trigger_double_free() {
    if (g_double_free_triggered) {
        OH_LOG_ERROR(LOG_APP, "[FAULT] DoubleFree already triggered, skipping");
        return;
    }
    
    g_double_free_triggered = true;
    
    const size_t alloc_size = 24;
    char *buf = (char *)malloc(alloc_size);
    if (buf) {
        OH_LOG_ERROR(LOG_APP, "[FAULT] DoubleFree addr=%{public}p, alloc_size=%{public}zu", (void*)buf, alloc_size);
        free(buf);
        
        int interference_count = interference_dis(gen);
        OH_LOG_ERROR(LOG_APP, "[FAULT] DoubleFree interference_alloc_count=%{public}d", interference_count);
        
        std::vector<char*> delayed_free_bufs;
        
        for (int i = 0; i < interference_count; i++) {
            char *interference_buf = (char *)malloc(alloc_size);
            if (interference_buf) {
                OH_LOG_ERROR(LOG_APP, "[FAULT] DoubleFree interference_alloc #%{public}d addr=%{public}p", 
                             i, (void*)interference_buf);
                
                int delay_prob = delay_dis(gen);
                bool delay_free = (delay_prob < 90);
                if (delay_free) {
                    delayed_free_bufs.push_back(interference_buf);
                    OH_LOG_ERROR(LOG_APP, "[FAULT] DoubleFree interference #%{public}d delayed_free=true (90%%, prob=%{public}d)", i, delay_prob);
                } else {
                    free(interference_buf);
                    OH_LOG_ERROR(LOG_APP, "[FAULT] DoubleFree interference #%{public}d freed immediately (10%%, prob=%{public}d)", i, delay_prob);
                }
            }
        }
        
        free(buf);
        
        if (!delayed_free_bufs.empty()) {
            OH_LOG_ERROR(LOG_APP, "[FAULT] DoubleFree starting delayed_free_thread for %{public}zu buffers", delayed_free_bufs.size());
            std::thread(delayed_free_task, delayed_free_bufs, 10).detach();
        }
    }
}