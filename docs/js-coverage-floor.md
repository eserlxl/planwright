<!--
SPDX-FileCopyrightText: 2026 Eser KUBALI
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Dashboard JS coverage floor

The dashboard client modules under [`scripts/dashboard/views/`](../scripts/dashboard/views) are
the recurring untested hotspot (see [the coverage map](dashboard-js-coverage-map.md)). To stop a
silent regression that drops their coverage, CI gates a measured JS coverage percentage — the analog
of the Python `coverage report --fail-under=90` gate in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## How it is measured

[`scripts/js-coverage-report.py`](../scripts/js-coverage-report.py) reduces the
[`NODE_V8_COVERAGE`](https://nodejs.org/api/cli.html#node_v8_coveragedir) output of the shared
collector ([`tests/cases/lib/dashboard-coverage-load.js`](../tests/cases/lib/dashboard-coverage-load.js),
which loads every view's full and degraded render path) to one deterministic **byte-coverage**
percentage over `scripts/dashboard/`, excluding `scripts/dashboard/vendor/`. The CI `JS coverage
(dashboard)` step runs the collector then the reporter with `--fail-under`.

## The floor and its deliberate slack

- **Measured baseline (post-Phase-1.2/1.3):** ~72.9% byte coverage over `scripts/dashboard/`.
- **Committed floor:** **65%** (`--fail-under 65` in CI, and pinned locally in the
  `DASH-JS-COV-PCT` block of [`tests/cases/dashboard.sh`](../tests/cases/dashboard.sh) so a drop also
  fails `bash tests/run.sh`, not only CI).

The floor sits a few points below the baseline on purpose. The slack absorbs:

- **Harness under-counting.** The node-gated render harness uses a lightweight DOM shim
  ([`tests/cases/lib/dashboard-vm.js`](../tests/cases/lib/dashboard-vm.js)); some browser-only paths
  (e.g. the shim's `textContent = ''` does not clear children like a real DOM) are not exercised, so
  the measured percentage is a floor on, not an exact measure of, real coverage.
- **Refactor headroom.** A behavior-preserving refactor that moves a few uncovered bytes should not
  trip the gate; the floor flags a *meaningful* coverage loss, not noise.

`vendor/` is excluded because the vendored renderers are not this project's code to test.

## Raising the floor

When a coverage sub-phase lands new view assertions and the baseline rises durably, raise the floor
toward the new baseline (keeping a few points of slack) in two places that must stay in lockstep: the
`--fail-under` value in `.github/workflows/ci.yml` and the `--fail-under` value in the
`DASH-JS-COV-PCT` block of `tests/cases/dashboard.sh`.
