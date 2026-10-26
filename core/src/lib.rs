//! Sand picture simulation core, shared by the web (wasm) and Apple (C ABI)
//! hosts. See docs/native-plan.md.

pub mod engine;
pub mod fluid;
pub mod jsmath;
pub mod rng;
pub mod seed;
pub mod sim;

use engine::Engine;

// ---------- C ABI ----------
// Hand-written so the grid is shared without copying. In wasm the same
// functions are the module's exports and pointers are offsets into its memory.

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
