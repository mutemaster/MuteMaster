//
//  ZMRingBuffer.h
//  A lock-free single-producer / single-consumer ring buffer of interleaved Float32 frames.
//
//  Used by the routing engine to pass audio from a capture callback (producer) to a playback
//  callback (consumer) running on different real-time threads. Lock-free so neither audio
//  thread ever blocks. (We use our own small ring instead of pulling in TPCircularBuffer to
//  keep the project dependency-free and easy to read.)
//
//  Safety contract: exactly ONE thread calls zm_ring_write and exactly ONE (other) thread calls
//  zm_ring_read. Any thread may call zm_ring_fill_frames. capacityFrames must be a power of two.
//

#ifndef ZMRingBuffer_h
#define ZMRingBuffer_h

#include <stdint.h>
#include <stdbool.h>

typedef struct ZMRingBuffer ZMRingBuffer;

#ifdef __cplusplus
extern "C" {
#endif

/// Create a ring holding `capacityFrames` (power of two) frames of `channels` interleaved floats.
ZMRingBuffer* zm_ring_create(uint32_t capacityFrames, uint32_t channels);
void          zm_ring_destroy(ZMRingBuffer* ring);

/// Discard all buffered audio (call when (re)starting a stream; not while both ends are running).
void          zm_ring_reset(ZMRingBuffer* ring);

/// Producer: write up to `frameCount` frames. Returns frames actually written (may be fewer if full).
uint32_t      zm_ring_write(ZMRingBuffer* ring, const float* frames, uint32_t frameCount);

/// Consumer: read up to `frameCount` frames into `out`. Any shortfall is zero-filled (silence).
/// Returns the number of REAL frames read (excludes the zero-fill).
uint32_t      zm_ring_read(ZMRingBuffer* ring, float* out, uint32_t frameCount);

/// Frames currently available to read. Safe to call from any thread.
uint32_t      zm_ring_fill_frames(const ZMRingBuffer* ring);

/// Total capacity in frames.
uint32_t      zm_ring_capacity_frames(const ZMRingBuffer* ring);

#ifdef __cplusplus
}
#endif

#endif /* ZMRingBuffer_h */
