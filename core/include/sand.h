/* C ABI of the sand picture core (core/src/lib.rs), for the Apple hosts.
 * Hand-written: keep it in step with lib.rs, where each function is
 * documented. The grid is shared without copying. */
#ifndef SAND_H
#define SAND_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SandEngine SandEngine;

/* The liquid's velocity field: nx x ny cells of 2^fs x 2^fs grid cells, one
 * cell of wall all round. Velocity in grid cells per tick; solid is 1 for
 * packed sand or wall. */
typedef struct SandFlow {
    const float *u;
    const float *v;
    const uint8_t *solid;
    uint32_t nx;
    uint32_t ny;
    uint32_t fs;
} SandFlow;

/* A w x h grain grid ticking tps times a second at normal speed; the same
 * seed always gives the same pictures. */
SandEngine *sand_new(uint32_t w, uint32_t h, double tps, uint32_t seed);
void sand_free(SandEngine *e);
/* New sand at the top as you see it (upside_down: the frame rests flipped). */
void sand_reseed(SandEngine *e, uint32_t upside_down);
/* JSON in the "Copy settings" shape; returns values applied, or -1. */
int32_t sand_tune(SandEngine *e, const uint8_t *json, size_t len);
/* dt seconds, gravity in grid space (x right, y down, |g| = 1 upright), at
 * most max_ticks ticks. Returns the ticks run. */
uint32_t sand_frame(SandEngine *e, double dt, double gx, double gy, uint32_t max_ticks);
/* Grain moves in the last frame. */
uint32_t sand_moves(const SandEngine *e);
/* (w + 2) x (h + 2) cells of RGBA8 (type, shade, energy, clock), one cell of
 * wall all round. Valid until sand_free. */
const uint32_t *sand_grid_ptr(const SandEngine *e);
uint32_t sand_grid_width(const SandEngine *e);
uint32_t sand_grid_height(const SandEngine *e);
/* Rows changed since the last call, first << 16 | last, or 0xffffffff. */
uint32_t sand_take_dirty(SandEngine *e);
/* Valid until sand_free; the values change with every frame. */
const SandFlow *sand_flow(SandEngine *e);
/* Snapshot length; the bytes are at sand_snapshot_ptr until the next one. */
size_t sand_snapshot(SandEngine *e);
const uint8_t *sand_snapshot_ptr(const SandEngine *e);
/* 1, or 0 (engine untouched) if the bytes don't fit this grid. */
uint32_t sand_restore(SandEngine *e, const uint8_t *data, size_t len);
uint8_t *sand_alloc(size_t len);
void sand_dealloc(uint8_t *p, size_t len);

#ifdef __cplusplus
}
#endif

#endif
