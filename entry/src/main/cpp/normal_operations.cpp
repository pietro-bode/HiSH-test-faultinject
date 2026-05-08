#include "normal_operations.h"
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <fstream>
#include <sys/stat.h>
#include <random>
#include "hilog/log.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3300
#define LOG_TAG "HiSH"

static std::random_device rd;
static std::mt19937 gen(rd());
static std::uniform_int_distribution<> size_dis(16, 64);
static std::uniform_int_distribution<> byte_dis(0, 255);

struct AviRiffHeader {
    char riff[4];
    uint32_t file_size;
    char avi[4];
};

struct AviListHeader {
    char list[4];
    uint32_t list_size;
    char type[4];
};

struct AviChunkHeader {
    char chunk_id[4];
    uint32_t chunk_size;
};

void parse_avi_header() {
    OH_LOG_ERROR(LOG_APP, "[NORMAL] === Starting real AVI file header parsing ===");
    
    const char *avi_paths[] = {
        "/data/storage/el2/base/files/media/test.avi",
        "/data/service/el2/base/native/rm/entry/resources/rawfile/video/test.avi",
        "/data/app/el2/100/base/com.hish.hish/haps/entry/files/test.avi",
        "/tmp/test.avi"
    };
    
    const char *avi_path = nullptr;
    for (int i = 0; i < 4; i++) {
        struct stat st;
        if (stat(avi_paths[i], &st) == 0) {
            avi_path = avi_paths[i];
            OH_LOG_ERROR(LOG_APP, "[NORMAL] AVI file found at: %{public}s", avi_path);
            break;
        }
    }
    
    if (!avi_path) {
        OH_LOG_ERROR(LOG_APP, "[NORMAL] AVI file not found, creating mock header for testing");
        
        size_t buf_size = 64;
        char *mock_header = (char *)malloc(buf_size);
        if (mock_header) {
            memcpy(mock_header, "RIFF", 4);
            uint32_t file_size = 1024 * 1024;
            memcpy(mock_header + 4, &file_size, 4);
            memcpy(mock_header + 8, "AVI ", 4);
            
            OH_LOG_ERROR(LOG_APP, "[NORMAL] Mock AVI header created: RIFF+AVI, size=%{public}u bytes", file_size);
            free(mock_header);
        }
        return;
    }
    
    FILE *fp = fopen(avi_path, "rb");
    if (!fp) {
        OH_LOG_ERROR(LOG_APP, "[NORMAL] Failed to open AVI file: %{public}s", avi_path);
        return;
    }
    
    AviRiffHeader riff_header;
    size_t bytes_read = fread(&riff_header, 1, sizeof(riff_header), fp);
    
    size_t header_buf_size = 64;
    char *header_buf = (char *)malloc(header_buf_size);
    if (header_buf) {
        memset(header_buf, 0, header_buf_size);
        memcpy(header_buf, &riff_header, bytes_read);
        
        OH_LOG_ERROR(LOG_APP, "[NORMAL] AVI RIFF header read: %{public}zu bytes, sig=%{public}.4s, type=%{public}.4s", 
                     bytes_read, riff_header.riff, riff_header.avi);
        
        OH_LOG_ERROR(LOG_APP, "[NORMAL] RIFF bytes: %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x", 
                     header_buf[0], header_buf[1], header_buf[2], header_buf[3],
                     header_buf[4], header_buf[5], header_buf[6], header_buf[7],
                     header_buf[8], header_buf[9], header_buf[10], header_buf[11]);
        
        free(header_buf);
    }
    
    AviListHeader list_header;
    bytes_read = fread(&list_header, 1, sizeof(list_header), fp);
    
    char *list_buf = (char *)malloc(32);
    if (list_buf) {
        memcpy(list_buf, &list_header, sizeof(list_header));
        OH_LOG_ERROR(LOG_APP, "[NORMAL] AVI LIST header: %{public}.4s, type=%{public}.4s, size=%{public}u", 
                     list_header.list, list_header.type, list_header.list_size);
        
        OH_LOG_ERROR(LOG_APP, "[NORMAL] LIST bytes: %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x", 
                     list_buf[0], list_buf[1], list_buf[2], list_buf[3],
                     list_buf[4], list_buf[5], list_buf[6], list_buf[7],
                     list_buf[8], list_buf[9], list_buf[10], list_buf[11]);
        
        free(list_buf);
    }
    
    std::uniform_int_distribution<> chunk_count_dis(5, 10);
    int chunk_count = chunk_count_dis(gen);
    
    for (int i = 0; i < chunk_count; i++) {
        AviChunkHeader chunk;
        bytes_read = fread(&chunk, 1, sizeof(chunk), fp);
        
        if (bytes_read < sizeof(chunk)) {
            break;
        }
        
        size_t chunk_buf_size = size_dis(gen);
        char *chunk_buf = (char *)malloc(chunk_buf_size);
        if (chunk_buf) {
            size_t data_to_read = (chunk.chunk_size < chunk_buf_size) ? chunk.chunk_size : chunk_buf_size;
            fread(chunk_buf, 1, data_to_read, fp);
            
            OH_LOG_ERROR(LOG_APP, "[NORMAL] AVI chunk #%{public}d: id=%{public}.4s, size=%{public}u, read=%{public}zu bytes", 
                         i, chunk.chunk_id, chunk.chunk_size, data_to_read);
            
            size_t print_len = (data_to_read < 16) ? data_to_read : 16;
            if (print_len >= 8) {
                OH_LOG_ERROR(LOG_APP, "[NORMAL] chunk #%{public}d data[0-7]: %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x", 
                             i, chunk_buf[0], chunk_buf[1], chunk_buf[2], chunk_buf[3],
                             chunk_buf[4], chunk_buf[5], chunk_buf[6], chunk_buf[7]);
            }
            if (print_len >= 16) {
                OH_LOG_ERROR(LOG_APP, "[NORMAL] chunk #%{public}d data[8-15]: %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x", 
                             i, chunk_buf[8], chunk_buf[9], chunk_buf[10], chunk_buf[11],
                             chunk_buf[12], chunk_buf[13], chunk_buf[14], chunk_buf[15]);
            }
            
            free(chunk_buf);
        }
        
        long remaining = chunk.chunk_size - chunk_buf_size;
        if (remaining > 0) {
            fseek(fp, remaining, SEEK_CUR);
        }
    }
    
    fclose(fp);
    OH_LOG_ERROR(LOG_APP, "[NORMAL] === AVI file parsing completed ===");
}

void fetch_baidu_homepage() {
    OH_LOG_ERROR(LOG_APP, "[NORMAL] === Simulating HTTP request to www.baidu.com ===");
    
    std::uniform_int_distribution<> request_count_dis(3, 10);
    int request_count = request_count_dis(gen);
    
    for (int req = 0; req < request_count; req++) {
        size_t buf_size = size_dis(gen);
        char *http_buf = (char *)malloc(buf_size);
        if (http_buf) {
            memset(http_buf, 0, buf_size);
            
            const char *http_response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: BWS\r\n\r\n<!DOCTYPE html><html>";
            size_t response_len = strlen(http_response);
            
            size_t copy_len = (response_len < buf_size) ? response_len : buf_size;
            memcpy(http_buf, http_response, copy_len);
            
            OH_LOG_ERROR(LOG_APP, "[NORMAL] HTTP response #%{public}d simulated: size=%{public}zu, copied=%{public}zu bytes, header=%{public}.20s", 
                         req, buf_size, copy_len, http_buf);
            
            free(http_buf);
        }
    }
    
    OH_LOG_ERROR(LOG_APP, "[NORMAL] === HTTP simulation completed (%{public}d requests) ===", request_count);
}

void perform_normal_operations() {
    OH_LOG_ERROR(LOG_APP, "[NORMAL] === Starting normal operations ===");
    
    parse_avi_header();
    
    fetch_baidu_homepage();
    
    std::uniform_int_distribution<> extra_ops_dis(10, 50);
    int extra_ops = extra_ops_dis(gen);
    
    for (int i = 0; i < extra_ops; i++) {
        size_t buf_size = size_dis(gen);
        char *temp_buf = (char *)malloc(buf_size);
        if (temp_buf) {
            for (size_t j = 0; j < buf_size; j++) {
                temp_buf[j] = (char)byte_dis(gen);
            }
            
            if (i % 10 == 0) {
                OH_LOG_ERROR(LOG_APP, "[NORMAL] Memory operation #%{public}d, size=%{public}zu", i, buf_size);
            }
            
            free(temp_buf);
        }
    }
    
    OH_LOG_ERROR(LOG_APP, "[NORMAL] === Normal operations completed (%{public}d extra ops) ===", extra_ops);
}