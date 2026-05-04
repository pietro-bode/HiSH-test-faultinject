#ifndef FAULT_DOUBLE_FREE_H
#define FAULT_DOUBLE_FREE_H

extern bool g_double_free_triggered;
void trigger_double_free();

#endif