# planwright Plan — cpp fixture

- [ ] Harden clamp against inverted bounds
      Mode: repair
      Rationale: clamp returns lo even when lo > hi, masking caller bugs.
      Evidence: src/calc.cpp:5 returns lo before checking lo <= hi.
      Surfaces: src/calc.cpp, include/calc.h
      Development: in clamp() add an assert(lo <= hi) before the comparisons.
      Acceptance: clamp with lo > hi is rejected; existing cases unchanged.
      Verification: ctest --test-dir build -R calc_tests --output-on-failure

- [ ] Add a sub() helper alongside add()
      Mode: develop
      Rationale: callers need subtraction; only add() exists today.
      Evidence: include/calc.h declares add() but no sub().
      Surfaces: include/calc.h, src/calc.cpp, tests/calc_test.cpp
      Development: declare int sub(int,int) in calc.h, define it in calc.cpp, assert in calc_test.cpp.
      Acceptance: sub(5,3)==2 and the test target passes.
      Verification: ctest --test-dir build -R calc_tests --output-on-failure
