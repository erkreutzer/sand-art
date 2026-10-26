//! Maths that must round exactly as in JavaScript, so the core matches the JS
//! reference bit for bit. Everything else uses the platform's libm, which
//! agrees with V8 to the last bit or close enough not to matter: results feed
//! comparisons against integers or are stored as f32.

/// V8's Math.hypot for two arguments: a Kahan sum of the squares, normalised
/// by the larger magnitude.
pub fn hypot(a: f64, b: f64) -> f64 {
    let (a, b) = (a.abs(), b.abs());
    if a.is_nan() || b.is_nan() {
        return if a.is_infinite() || b.is_infinite() { f64::INFINITY } else { f64::NAN };
    }
    let max = a.max(b);
    if max == f64::INFINITY {
        return max;
    }
    if max == 0.0 {
        return 0.0;
    }
    let (mut sum, mut comp) = (0.0f64, 0.0f64);
    for x in [a, b] {
        let n = x / max;
        let s = n * n - comp;
        let pre = sum + s;
        comp = (pre - sum) - s;
        sum = pre;
    }
    sum.sqrt() * max
}

/// Math.round: to the nearest integer, halves toward +infinity.
pub fn round(x: f64) -> f64 {
    let f = x.floor();
    if x - f >= 0.5 { f + 1.0 } else { f }
}
