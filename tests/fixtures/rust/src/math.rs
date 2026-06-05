pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

pub fn clamp(v: i32, lo: i32, hi: i32) -> i32 {
    if v < lo {
        lo
    } else if v > hi {
        hi
    } else {
        v
    }
}
