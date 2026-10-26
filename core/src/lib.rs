//! Sand picture simulation core, shared by the web (wasm) and Apple (C ABI)
//! hosts. See docs/native-plan.md.

pub mod engine;
pub mod fluid;
pub mod jsmath;
pub mod rng;
pub mod seed;
pub mod sim;
pub mod snapshot;
pub mod tune;

use engine::Engine;

// ---------- C ABI ----------
// Hand-written so the grid is shared without copying. In wasm the same
// functions are the module's exports and pointers are offsets into its memory;
// any call that allocates (new, snapshot, restore, alloc) may grow that memory,
// so a host's views of it must be renewed afterwards.

/// A new engine with a w x h grain grid, ticking tps times a second at normal
/// speed; the same seed number always gives the same pictures.
#[no_mangle]
pub extern "C" fn sand_new(w: u32, h: u32, tps: f64, seed: u32) -> *mut Engine {
    Box::into_raw(Box::new(Engine::new(w as usize, h as usize, tps, seed)))
}

/// # Safety
/// `e` must come from `sand_new` and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn sand_free(e: *mut Engine) {
    drop(Box::from_raw(e));
}

/// New sand at the top as you see it (`upside_down`: the frame rests flipped).
/// # Safety
/// `e` must come from `sand_new`.
#[no_mangle]
pub unsafe extern "C" fn sand_reseed(e: *mut Engine, upside_down: u32) {
    (*e).reseed(upside_down != 0);
}

/// One frame: dt seconds, gravity (gx, gy) in grid space (x right, y down,
/// |g| = 1 upright), at most max_ticks ticks. Returns the ticks run; the grain
/// moves are in `sand_moves`.
/// # Safety
/// `e` must come from `sand_new`.
#[no_mangle]
pub unsafe extern "C" fn sand_frame(e: *mut Engine, dt: f64, gx: f64, gy: f64, max_ticks: u32) -> u32 {
    let s = (*e).frame(dt, gx, gy, max_ticks);
    (*e).last_moves = s.moves;
    s.ticks
}

/// Grain moves in the last frame.
/// # Safety
/// `e` must come from `sand_new`.
#[no_mangle]
pub unsafe extern "C" fn sand_moves(e: *const Engine) -> u32 {
    (*e).last_moves
}

/// The grid: (w + 2) x (h + 2) cells of RGBA8 (type, shade, energy, clock),
/// one cell of wall all round. Valid until `sand_free`.
/// # Safety
/// `e` must come from `sand_new`.
#[no_mangle]
pub unsafe extern "C" fn sand_grid_ptr(e: *const Engine) -> *const u32 {
    (*e).sim.cells.as_ptr()
}

/// Padded grid width (w + 2).
/// # Safety
/// `e` must come from `sand_new`.
#[no_mangle]
pub unsafe extern "C" fn sand_grid_width(e: *const Engine) -> u32 {
    (*e).sim.pw as u32
}

/// Padded grid height (h + 2).
/// # Safety
/// `e` must come from `sand_new`.
#[no_mangle]
pub unsafe extern "C" fn sand_grid_height(e: *const Engine) -> u32 {
    (*e).sim.ph as u32
}

/// Grid rows changed since the last call, as first << 16 | last, or
/// 0xffffffff if none.
/// # Safety
/// `e` must come from `sand_new`.
#[no_mangle]
pub unsafe extern "C" fn sand_take_dirty(e: *mut Engine) -> u32 {
    match (*e).sim.take_dirty() {
        Some((a, b)) => (a as u32) << 16 | b as u32,
        None => u32::MAX,
    }
}

/// Live tuning: `len` bytes of UTF-8 JSON in the shape the debug panel's "Copy
/// settings" produces ({"sim": {...}, "fluid": {...}, "seed": {...},
/// "engine": {...}}, keys as in src/). Returns how many values were applied
/// (unknown keys and the host's "render" group are skipped), or -1 if it isn't
/// valid JSON. Seed settings take effect on the next reseed.
/// # Safety
/// `e` must come from `sand_new`; `json` must point to `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn sand_tune(e: *mut Engine, json: *const u8, len: usize) -> i32 {
    match std::str::from_utf8(std::slice::from_raw_parts(json, len)).ok().and_then(|s| (*e).tune(s)) {
        Some(n) => n as i32,
        None => -1,
    }
}

/// The liquid's velocity field, for the flow overlay: nx x ny cells, each
/// covering 2^fs x 2^fs grid cells, with one cell of wall all round (fluid
/// cell (x, y) is centred on grid cell ((x - 1) << fs) + (1 << fs) / 2).
#[repr(C)]
pub struct SandFlow {
    /// Velocity in grid cells per tick, f32 per cell.
    pub u: *const f32,
    pub v: *const f32,
    /// 1 where the cell is packed sand or wall (no flow), u8 per cell.
    pub solid: *const u8,
    pub nx: u32,
    pub ny: u32,
    pub fs: u32,
}

/// Safe to hand to another thread with the engine: it only points into it.
unsafe impl Send for SandFlow {}

/// The struct and its pointers stay valid until `sand_free`; the values
/// change with every frame.
/// # Safety
/// `e` must come from `sand_new`.
#[no_mangle]
pub unsafe extern "C" fn sand_flow(e: *mut Engine) -> *const SandFlow {
    let e = &mut *e;
    let f = &e.fluid;
    e.flow_view = SandFlow { u: f.u.as_ptr(), v: f.v.as_ptr(), solid: f.solid.as_ptr(), nx: f.nx as u32, ny: f.ny as u32, fs: f.fs };
    &e.flow_view
}

/// Takes a snapshot of the whole picture in motion (src/snapshot.rs) and
/// returns its length; the bytes are at `sand_snapshot_ptr` until the next
/// snapshot. Tuning and the tick rate aren't included.
/// # Safety
/// `e` must come from `sand_new`.
#[no_mangle]
pub unsafe extern "C" fn sand_snapshot(e: *mut Engine) -> usize {
    (*e).snapshot = snapshot::snapshot(&*e);
    (*e).snapshot.len()
}

/// # Safety
/// `e` must come from `sand_new`.
#[no_mangle]
pub unsafe extern "C" fn sand_snapshot_ptr(e: *const Engine) -> *const u8 {
    (*e).snapshot.as_ptr()
}

/// Carries on from a snapshot taken on an engine of the same grid size.
/// Returns 1, or 0 (engine untouched) if the bytes don't fit.
/// # Safety
/// `e` must come from `sand_new`; `data` must point to `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn sand_restore(e: *mut Engine, data: *const u8, len: usize) -> u32 {
    snapshot::restore(&mut *e, std::slice::from_raw_parts(data, len)) as u32
}

/// `len` bytes for passing JSON or a snapshot in from a host that can't
/// point into its own memory (wasm). Free with `sand_dealloc`.
#[no_mangle]
pub extern "C" fn sand_alloc(len: usize) -> *mut u8 {
    unsafe { std::alloc::alloc(byte_layout(len)) }
}

/// # Safety
/// `p` and `len` must come from one `sand_alloc` call.
#[no_mangle]
pub unsafe extern "C" fn sand_dealloc(p: *mut u8, len: usize) {
    std::alloc::dealloc(p, byte_layout(len));
}

fn byte_layout(len: usize) -> std::alloc::Layout {
    std::alloc::Layout::from_size_align(len.max(1), 1).unwrap()
}
