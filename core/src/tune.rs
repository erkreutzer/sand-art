//! Live tuning from the JSON the debug panel's "Copy settings" produces:
//! `{ "sim": { "fallSeconds": 3.5 }, "fluid": { ... }, "seed": { ... }, "engine": { ... } }`,
//! keys as in src/sim.js, fluid.js, seed.js and engine.js. Other groups (the
//! host's "render") and non-numeric values are skipped.

use crate::engine::EngineParams;
use crate::fluid::FluidParams;
use crate::seed::SeedParams;
use crate::sim::SimParams;

impl SimParams {
    pub fn set(&mut self, key: &str, v: f64) -> bool {
        let f = match key {
            "fallSeconds" => &mut self.fall_seconds,
            "riseSeconds" => &mut self.rise_seconds,
            "jitter" => &mut self.jitter,
            "fallAir" => &mut self.fall_air,
            "hole" => &mut self.hole,
            "narrow" => &mut self.narrow,
            "flat" => &mut self.flat,
            "tip" => &mut self.tip,
            "thinAir" => &mut self.thin_air,
            "leakFalloff" => &mut self.leak_falloff,
            "thickAir" => &mut self.thick_air,
            "slide" => &mut self.slide,
            "slideRest" => &mut self.slide_rest,
            "slideWall" => &mut self.slide_wall,
            "airSpread" => &mut self.air_spread,
            "bubbleDepth" => &mut self.bubble_depth,
            "seep" => &mut self.seep,
            _ => return false,
        };
        *f = v;
        true
    }
}

impl FluidParams {
    pub fn set(&mut self, key: &str, v: f64) -> bool {
        let f = match key {
            "sandWeight" => &mut self.sand_weight,
            "airLift" => &mut self.air_lift,
            "damping" => &mut self.damping,
            "vorticity" => &mut self.vorticity,
            "maxSpeed" => &mut self.max_speed,
            // JS loops `it < iterations`, which runs ceil(v) sweeps (none for NaN).
            "iterations" => {
                self.iterations = v.max(0.0).ceil() as u32;
                return true;
            }
            _ => return false,
        };
        *f = v;
        true
    }
}

impl SeedParams {
    pub fn set(&mut self, key: &str, v: f64) -> bool {
        let f = match key {
            "sand" => &mut self.sand,
            "air" => &mut self.air,
            _ => return false,
        };
        *f = v;
        true
    }
}

impl EngineParams {
    pub fn set(&mut self, key: &str, v: f64) -> bool {
        match key {
            "timeScale" => self.time_scale = v,
            _ => return false,
        }
        true
    }
}

/// Every (group, key, number) two levels down, in order; None if `s` isn't JSON
/// with an object at the top.
pub fn parse(s: &str) -> Option<Vec<(String, String, f64)>> {
    let mut p = Parser { b: s.as_bytes(), i: 0 };
    let mut out = Vec::new();
    p.object(|p, group| {
        if p.peek() != Some(b'{') {
            return p.skip();
        }
        p.object(|p, key| match p.number_or_skip()? {
            Some(v) => {
                out.push((group.clone(), key, v));
                Some(())
            }
            None => Some(()),
        })
    })?;
    p.ws();
    (p.i == p.b.len()).then_some(out)
}

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}

impl Parser<'_> {
    fn ws(&mut self) {
        while matches!(self.b.get(self.i), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.i += 1;
        }
    }

    fn peek(&mut self) -> Option<u8> {
        self.ws();
        self.b.get(self.i).copied()
    }

    fn eat(&mut self, c: u8) -> Option<()> {
        (self.peek()? == c).then(|| self.i += 1)
    }

    /// `{ "key": value, ... }`, handing each key to `member` to read its value.
    fn object(&mut self, mut member: impl FnMut(&mut Self, String) -> Option<()>) -> Option<()> {
        self.eat(b'{')?;
        if self.eat(b'}').is_some() {
            return Some(());
        }
        loop {
            let key = self.string()?;
            self.eat(b':')?;
            member(self, key)?;
            if self.eat(b',').is_none() {
                return self.eat(b'}');
            }
        }
    }

    fn string(&mut self) -> Option<String> {
        self.eat(b'"')?;
        let mut s = String::new();
        loop {
            let c = *self.b.get(self.i)?;
            self.i += 1;
            match c {
                b'"' => return Some(s),
                b'\\' => {
                    let e = *self.b.get(self.i)?;
                    self.i += 1;
                    s.push(match e {
                        b'n' => '\n',
                        b't' => '\t',
                        b'r' => '\r',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'u' => {
                            let hex = std::str::from_utf8(self.b.get(self.i..self.i + 4)?).ok()?;
                            self.i += 4;
                            char::from_u32(u32::from_str_radix(hex, 16).ok()?).unwrap_or('\u{fffd}')
                        }
                        _ => e as char,
                    });
                }
                _ => {
                    // Copy a run of plain UTF-8 bytes at once.
                    let start = self.i - 1;
                    while matches!(self.b.get(self.i), Some(&c) if c != b'"' && c != b'\\') {
                        self.i += 1;
                    }
                    s.push_str(std::str::from_utf8(&self.b[start..self.i]).ok()?);
                }
            }
        }
    }

    /// A number's value, or None after skipping any other value.
    fn number_or_skip(&mut self) -> Option<Option<f64>> {
        if !matches!(self.peek()?, b'-' | b'0'..=b'9') {
            return self.skip().map(|_| None);
        }
        let start = self.i;
        while matches!(self.b.get(self.i), Some(b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')) {
            self.i += 1;
        }
        // Rust's parse rounds correctly, as JSON.parse does.
        std::str::from_utf8(&self.b[start..self.i]).ok()?.parse().ok().map(Some)
    }

    fn skip(&mut self) -> Option<()> {
        match self.peek()? {
            b'{' => self.object(|p, _| p.skip()),
            b'[' => {
                self.eat(b'[')?;
                if self.eat(b']').is_some() {
                    return Some(());
                }
                loop {
                    self.skip()?;
                    if self.eat(b',').is_none() {
                        return self.eat(b']');
                    }
                }
            }
            b'"' => self.string().map(|_| ()),
            b't' | b'f' | b'n' => {
                for w in [&b"true"[..], b"false", b"null"] {
                    if self.b[self.i..].starts_with(w) {
                        self.i += w.len();
                        return Some(());
                    }
                }
                None
            }
            _ => self.number_or_skip().map(|_| ()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copy_settings_shape() {
        let got = parse(r#"{
  "fluid": { "vorticity": 0.6, "iterations": 12 },
  "render": { "liquidTint": 1.5, "x": [1, {"y": null}], "s": "a\"b" },
  "sim": { "thinAir": 1e-3, "flag": true },
  "engine": 3
}"#)
        .unwrap();
        let want = [("fluid", "vorticity", 0.6), ("fluid", "iterations", 12.0), ("render", "liquidTint", 1.5), ("sim", "thinAir", 1e-3)];
        assert_eq!(got.len(), want.len());
        for ((g, k, v), (wg, wk, wv)) in got.iter().zip(want) {
            assert_eq!((g.as_str(), k.as_str(), *v), (wg, wk, wv));
        }
        assert_eq!(parse("{}").unwrap().len(), 0);
        assert!(parse("{\"sim\": {\"jitter\": 0.1}").is_none());
        assert!(parse("[1]").is_none());
        assert!(parse("{} x").is_none());
    }

    #[test]
    fn iterations_round_up_like_js() {
        let mut f = FluidParams::default();
        for (v, n) in [(12.0, 12), (12.2, 13), (-3.0, 0), (f64::NAN, 0)] {
            f.set("iterations", v);
            assert_eq!(f.iterations, n);
        }
    }
}
