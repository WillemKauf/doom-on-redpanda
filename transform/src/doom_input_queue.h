#ifndef DOOM_INPUT_QUEUE_H
#define DOOM_INPUT_QUEUE_H

// Ring buffer that backs doomgeneric's DG_GetKey hook.
// Single-threaded: the transform is per-shard-per-partition.

#define DOOM_INPUT_QUEUE_CAP 256

#ifdef __cplusplus
extern "C" {
#endif

void doom_input_queue_reset(void);

// Returns 1 on success, 0 if full.
int doom_input_queue_push(int pressed, unsigned char doom_key);

// Returns 1 and fills *pressed/*doom_key if an event was available,
// 0 if empty. Signature matches DG_GetKey by design.
int doom_input_queue_pop(int *pressed, unsigned char *doom_key);

#ifdef __cplusplus
}
#endif

#endif
