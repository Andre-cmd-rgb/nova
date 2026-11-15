//! Chance, without a crate: one generator to set a scene up, and a hash for
//! what has to be the same every time a frame is drawn again.

pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Rng {
        Rng(seed)
    }

    /// SplitMix64.
    pub fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        scramble(self.0)
    }

    /// From 0 up to, not including, 1.
    pub fn unit(&mut self) -> f64 {
        unit(self.next())
    }

    /// From 0 up to, not including, `count`; 0 when there is nothing to pick.
    pub fn below(&mut self, count: usize) -> usize {
        if count == 0 {
            0
        } else {
            (self.next() % count as u64) as usize
        }
    }
}

fn scramble(mut x: u64) -> u64 {
    x = (x ^ (x >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    x ^ (x >> 31)
}

fn unit(x: u64) -> f64 {
    (x >> 11) as f64 / (1u64 << 53) as f64
}

/// The same number, from 0 up to 1, for the same three every time: what a
/// cell shows at one tick must not depend on how often it was drawn.
pub fn noise(seed: u64, which: u64, tick: u64) -> f64 {
    unit(pick(seed, which, tick))
}

/// The same, as a whole number to choose with.
pub fn pick(seed: u64, which: u64, tick: u64) -> u64 {
    scramble(
        scramble(seed ^ which.wrapping_mul(0x9e37_79b9_7f4a_7c15))
            ^ tick.wrapping_mul(0xd6e8_feb8_6659_fd93),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_same_seed_gives_the_same_run() {
        let (mut a, mut b) = (Rng::new(7), Rng::new(7));
        for _ in 0..50 {
            assert_eq!(a.next(), b.next());
        }
        assert_ne!(Rng::new(7).next(), Rng::new(8).next());
    }

    #[test]
    fn units_stay_in_range_and_spread() {
        let mut rng = Rng::new(1);
        let values: Vec<f64> = (0..2000).map(|_| rng.unit()).collect();
        assert!(values.iter().all(|v| (0.0..1.0).contains(v)));
        let mean = values.iter().sum::<f64>() / values.len() as f64;
        assert!((mean - 0.5).abs() < 0.05, "mean {mean}");
        assert!((0..2000).all(|_| rng.below(6) < 6));
        assert_eq!(rng.below(0), 0);
    }

    #[test]
    fn noise_is_the_same_for_the_same_cell_and_tick() {
        assert_eq!(noise(3, 10, 20), noise(3, 10, 20));
        assert_ne!(noise(3, 10, 20), noise(3, 10, 21));
        assert_ne!(noise(3, 10, 20), noise(3, 11, 20));
        assert!((0..500).all(|i| (0.0..1.0).contains(&noise(9, i, i * 3))));
    }
}
