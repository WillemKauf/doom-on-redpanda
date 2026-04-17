#include <assert.h>
#include <stdio.h>

#include "../src/doom_input_queue.h"

int main(void) {
    doom_input_queue_reset();

    // Empty queue: pop returns 0.
    int pressed; unsigned char key;
    assert(doom_input_queue_pop(&pressed, &key) == 0);

    // Push one event, pop it back.
    assert(doom_input_queue_push(1, 0x41) == 1);
    assert(doom_input_queue_pop(&pressed, &key) == 1);
    assert(pressed == 1);
    assert(key == 0x41);

    // Queue now empty again.
    assert(doom_input_queue_pop(&pressed, &key) == 0);

    // FIFO ordering.
    doom_input_queue_push(1, 0x10);
    doom_input_queue_push(0, 0x20);
    doom_input_queue_push(1, 0x30);
    assert(doom_input_queue_pop(&pressed, &key) == 1 && pressed == 1 && key == 0x10);
    assert(doom_input_queue_pop(&pressed, &key) == 1 && pressed == 0 && key == 0x20);
    assert(doom_input_queue_pop(&pressed, &key) == 1 && pressed == 1 && key == 0x30);
    assert(doom_input_queue_pop(&pressed, &key) == 0);

    // Overflow: the ring reserves one slot to distinguish full from empty,
    // so real capacity is CAP-1. Reset first so prior state doesn't skew the
    // count.
    doom_input_queue_reset();
    for (int i = 0; i < DOOM_INPUT_QUEUE_CAP - 1; i++) {
        assert(doom_input_queue_push(1, (unsigned char)i) == 1);
    }
    assert(doom_input_queue_push(1, 0xFF) == 0);  // rejected

    printf("input_queue_test: ok\n");
    return 0;
}
