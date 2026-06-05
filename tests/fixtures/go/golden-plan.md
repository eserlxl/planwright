# planwright Plan — go fixture

- [ ] Cover Clamp's three branches with a unit test
      Mode: improve
      Rationale: math.Clamp has below/above/in-range branches but no test exercises them.
      Evidence: math/math.go defines Clamp with three branches and the package has no _test.go.
      Surfaces: math/math.go
      New Surfaces: math/math_test.go
      Development: add math/math_test.go with cases for v<lo, v>hi, and in-range Clamp.
      Acceptance: go test ./... exercises all three Clamp branches and passes.
      Verification: go test ./...
