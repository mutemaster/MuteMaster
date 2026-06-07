//
//  ZMRingBuffer.c
//

#include "ZMRingBuffer.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct ZMRingBuffer {
    float*   data;            // capacityFrames * channels floats
    uint32_t capacityFrames;  // power of two
    uint32_t mask;            // capacityFrames - 1
    uint32_t channels;
    _Atomic uint32_t writeIndex; // frame index, monotonically increasing (wraps via mask)
    _Atomic uint32_t readIndex;  // frame index, monotonically increasing (wraps via mask)
};

static bool is_power_of_two(uint32_t x) { return x != 0 && (x & (x - 1)) == 0; }

ZMRingBuffer* zm_ring_create(uint32_t capacityFrames, uint32_t channels)
{
    if (!is_power_of_two(capacityFrames) || channels == 0) { return NULL; }
    ZMRingBuffer* ring = (ZMRingBuffer*)calloc(1, sizeof(ZMRingBuffer));
    if (!ring) { return NULL; }
    ring->data = (float*)calloc((size_t)capacityFrames * channels, sizeof(float));
    if (!ring->data) { free(ring); return NULL; }
    ring->capacityFrames = capacityFrames;
    ring->mask = capacityFrames - 1;
    ring->channels = channels;
    atomic_store_explicit(&ring->writeIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->readIndex, 0, memory_order_relaxed);
    return ring;
}

void zm_ring_destroy(ZMRingBuffer* ring)
{
    if (!ring) { return; }
    free(ring->data);
    free(ring);
}

void zm_ring_reset(ZMRingBuffer* ring)
{
    if (!ring) { return; }
    atomic_store_explicit(&ring->writeIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->readIndex, 0, memory_order_relaxed);
    memset(ring->data, 0, (size_t)ring->capacityFrames * ring->channels * sizeof(float));
}

uint32_t zm_ring_capacity_frames(const ZMRingBuffer* ring)
{
    return ring ? ring->capacityFrames : 0;
}

uint32_t zm_ring_fill_frames(const ZMRingBuffer* ring)
{
    if (!ring) { return 0; }
    uint32_t w = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    uint32_t r = atomic_load_explicit(&ring->readIndex, memory_order_acquire);
    return w - r; // unsigned wrap-around gives correct fill as long as fill <= capacity
}

uint32_t zm_ring_write(ZMRingBuffer* ring, const float* frames, uint32_t frameCount)
{
    if (!ring || !frames || frameCount == 0) { return 0; }
    uint32_t w = atomic_load_explicit(&ring->writeIndex, memory_order_relaxed);
    uint32_t r = atomic_load_explicit(&ring->readIndex, memory_order_acquire);
    uint32_t freeFrames = ring->capacityFrames - (w - r);
    uint32_t toWrite = frameCount < freeFrames ? frameCount : freeFrames;

    uint32_t ch = ring->channels;
    for (uint32_t i = 0; i < toWrite; ++i) {
        uint32_t slot = (w + i) & ring->mask;
        memcpy(ring->data + (size_t)slot * ch, frames + (size_t)i * ch, ch * sizeof(float));
    }
    atomic_store_explicit(&ring->writeIndex, w + toWrite, memory_order_release);
    return toWrite;
}

uint32_t zm_ring_read(ZMRingBuffer* ring, float* out, uint32_t frameCount)
{
    if (!ring || !out || frameCount == 0) { return 0; }
    uint32_t r = atomic_load_explicit(&ring->readIndex, memory_order_relaxed);
    uint32_t w = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    uint32_t available = w - r;
    uint32_t toRead = frameCount < available ? frameCount : available;

    uint32_t ch = ring->channels;
    for (uint32_t i = 0; i < toRead; ++i) {
        uint32_t slot = (r + i) & ring->mask;
        memcpy(out + (size_t)i * ch, ring->data + (size_t)slot * ch, ch * sizeof(float));
    }
    // Zero-fill any shortfall so the consumer always gets a full buffer (underrun = silence).
    if (toRead < frameCount) {
        memset(out + (size_t)toRead * ch, 0, (size_t)(frameCount - toRead) * ch * sizeof(float));
    }
    atomic_store_explicit(&ring->readIndex, r + toRead, memory_order_release);
    return toRead;
}
