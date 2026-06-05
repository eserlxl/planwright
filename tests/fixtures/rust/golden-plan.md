# planwright Plan — rust fixture

- [ ] Cover clamp's three branches with a unit test
      Mode: improve
      Rationale: math::clamp has below/above/in-range branches but no test.
      Evidence: src/math.rs defines clamp with three branches and no #[test].
      Surfaces: src/math.rs
      Development: add a #[cfg(test)] mod with cases for v<lo, v>hi, and in-range.
      Acceptance: cargo test exercises all three clamp branches and passes.
      Verification: cargo test --manifest-path Cargo.toml
