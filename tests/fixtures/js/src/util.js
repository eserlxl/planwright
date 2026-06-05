function add(a, b) {
  return a + b;
}

function clamp(v, lo, hi) {
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

module.exports = { add, clamp };
