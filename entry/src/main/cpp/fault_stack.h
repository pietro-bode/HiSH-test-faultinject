#ifndef FAULT_STACK_H
#define FAULT_STACK_H

extern bool g_stack_fault_triggered;
void trigger_stack_overflow();
void trigger_stack_uar();

#endif