#ifndef FAULT_INJECTION_H
#define FAULT_INJECTION_H

void trigger_fault();
void random_trigger_fault();
void set_gwpasan_detected(bool detected);
bool is_gwpasan_detected();

#endif // FAULT_INJECTION_H
