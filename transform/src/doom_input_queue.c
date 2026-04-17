#include "doom_input_queue.h"

static unsigned short s_queue[DOOM_INPUT_QUEUE_CAP];
static unsigned int   s_read_idx;
static unsigned int   s_write_idx;

void doom_input_queue_reset(void) {
    s_read_idx  = 0;
    s_write_idx = 0;
}

int doom_input_queue_push(int pressed, unsigned char doom_key) {
    unsigned int next = (s_write_idx + 1) % DOOM_INPUT_QUEUE_CAP;
    if (next == s_read_idx) return 0;   // full
    unsigned short packed = ((pressed ? 1 : 0) << 8) | (unsigned short)doom_key;
    s_queue[s_write_idx] = packed;
    s_write_idx = next;
    return 1;
}

int doom_input_queue_pop(int *pressed, unsigned char *doom_key) {
    if (s_read_idx == s_write_idx) return 0;
    unsigned short packed = s_queue[s_read_idx];
    s_read_idx = (s_read_idx + 1) % DOOM_INPUT_QUEUE_CAP;
    *pressed  = packed >> 8;
    *doom_key = packed & 0xFF;
    return 1;
}
