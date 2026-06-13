# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Direct unit tests for status.py's convergence gate and the mechanized coach
# (the codmaster / `planwright advise` decision surface). The smoke suite
# (tests/run.sh) exercises the CLI; these pin the broken-validator contract, the
# shared coach truth table (cross-pinned against derive.js via
# tests/fixtures/coach-table.json + coach-graph.json), and the repo-size
# constants' boundaries.
#
# Run: python3 -m unittest discover -s tests/unit -p "test_*.py"

import importlib.util
import json
import os
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(os.path.dirname(_HERE))
_SCRIPTS = os.path.join(_ROOT, "scripts")


def _load_status():
    """Import scripts/status.py by path (it does `import plan_parse`, so scripts/ must be
    importable)."""
    if _SCRIPTS not in sys.path:
        sys.path.insert(0, _SCRIPTS)
    path = os.path.join(_SCRIPTS, "status.py")
    spec = importlib.util.spec_from_file_location("planwright_status", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _load_lint_final():
    """Import scripts/lint-final.py by path (hyphenated name, so not import-able directly)."""
    path = os.path.join(_SCRIPTS, "lint-final.py")
    spec = importlib.util.spec_from_file_location("planwright_lint_final", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


st = _load_status()


class TestConvergenceValidator(unittest.TestCase):
    def test_lint_final_unloadable_fails_gate(self):
        # A present-but-broken validator must NOT certify convergence — _final_valid
        # returns False so --exit-code refuses rather than passing a CI gate blind.
        with tempfile.TemporaryDirectory() as root:
            saved = (st._LINT_FINAL, st._LINT_FINAL_STATUS)
            try:
                st._LINT_FINAL, st._LINT_FINAL_STATUS = None, "broken"
                self.assertFalse(st._final_valid(root))
                # A genuinely absent validator still degrades permissively.
                st._LINT_FINAL, st._LINT_FINAL_STATUS = None, "absent"
                self.assertTrue(st._final_valid(root))
            finally:
                st._LINT_FINAL, st._LINT_FINAL_STATUS = saved

    def test_validator_runtime_error_fails_gate(self):
        # A loaded validator that RAISES at runtime must not certify convergence either:
        # _final_valid catches the error and returns False (fail closed), mirroring the
        # present-but-broken load-time branch. Companion: lint-final.collect() reports a
        # present-but-unreadable final.md as present + not-ok rather than masquerading as
        # 'no final point', while a genuinely absent file stays present=False / ok=True.
        with tempfile.TemporaryDirectory() as root:
            saved = (st._LINT_FINAL, st._LINT_FINAL_STATUS)
            try:
                class _Raising:
                    @staticmethod
                    def collect(_root):
                        raise RuntimeError("validator boom")
                st._LINT_FINAL, st._LINT_FINAL_STATUS = _Raising, "ok"
                self.assertFalse(st._final_valid(root))
            finally:
                st._LINT_FINAL, st._LINT_FINAL_STATUS = saved

            lf = _load_lint_final()
            pdir = os.path.join(root, ".planwright")
            os.makedirs(pdir, exist_ok=True)
            fp = os.path.join(pdir, "final.md")
            with open(fp, "w", encoding="utf-8") as fh:
                fh.write("sha: deadbeef\n")
            # A genuinely absent final.md is a valid open state (present=False, ok=True).
            os.remove(fp)
            absent = lf.collect(root)
            self.assertFalse(absent["present"])
            self.assertTrue(absent["ok"])
            # A present-but-unreadable final.md fails closed (present=True, ok=False). chmod-000
            # does not restrict root (or some filesystems), so only assert when the file is
            # genuinely unreadable for this process.
            with open(fp, "w", encoding="utf-8") as fh:
                fh.write("sha: deadbeef\n")
            os.chmod(fp, 0)
            try:
                try:
                    with open(fp, encoding="utf-8"):
                        unreadable = False
                except OSError:
                    unreadable = True
                if unreadable:
                    res = lf.collect(root)
                    self.assertTrue(res["present"])
                    self.assertFalse(res["ok"])
            finally:
                os.chmod(fp, 0o600)


_FIXTURES = os.path.join(_ROOT, "tests", "fixtures")


def _snake_signals(sig):
    """Map the fixture's camelCase (JS-native) signal keys to the Python port's names,
    defaulting absent keys the way coach_signals would."""
    key_map = {"cycles": "cycles", "hotUncovered": "hot_uncovered",
               "articulation": "articulation", "pendRepairImprove": "pend_repair_improve",
               "pending": "pending", "fpFlag": "fp_flag"}
    out = {"cycles": 0, "hot_uncovered": 0, "articulation": 0,
           "pend_repair_improve": 0, "pending": 0, "fp_flag": ""}
    for k, v in sig.items():
        out[key_map[k]] = v
    return out


class TestCoachTable(unittest.TestCase):
    def test_shared_truth_table_parity(self):
        # The same rows tests/cases/derive.sh asserts against derive.js coachRecommend —
        # the cross-pin that keeps the CLI brain and the dashboard brain identical.
        with open(os.path.join(_FIXTURES, "coach-table.json"), encoding="utf-8") as fh:
            tbl = json.load(fh)
        for row in tbl["rows"]:
            got = st.coach_recommend(_snake_signals(row["signals"]))["key"]
            self.assertEqual(got, row["expect"], "coach-table row: %s" % row["name"])

    def test_shared_graph_fixture_derivation(self):
        # The debt-signal derivation (hot-tercile tie semantics included), pinned to the
        # same expected numbers derive.sh asserts from derive.js metrics().
        with open(os.path.join(_FIXTURES, "coach-graph.json"), encoding="utf-8") as fh:
            fx = json.load(fh)
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, ".planwright"))
            with open(os.path.join(root, ".planwright", "graph.json"), "w",
                      encoding="utf-8") as fh:
                json.dump(fx["graph"], fh)
            got = st._graph_signals(root)
        self.assertEqual(got, {
            "import_cycles": fx["expected"]["import_cycles"],
            "articulation": fx["expected"]["articulation"],
            "hot_uncovered": fx["expected"]["hot_uncovered"],
            "coverage_pct": fx["expected"]["coverage_pct"],
        })


class TestCoachEvidence(unittest.TestCase):
    # _evidence is the chip line shown beneath the recommendation — served at /recommend.json
    # and rendered by the dashboard front-door panel (and `planwright advise`). It is a port of
    # derive.js coachEvidence, but the `codshard` leg is Python-only (the JS coach never
    # dispatches codshard), so it cannot be cross-pinned via coach-table.json — it needs a
    # Python-side assertion. The CLI/dashboard only smoke-tested it as a non-empty list, so a
    # single-sided edit to any branch could silently change what a user sees. Pin every branch's
    # exact chip list against fixed signals.
    BASE = {"has_graph": True, "pending": 7, "completed": 5, "rejected": 3,
            "cycles": 2, "hot_uncovered": 4, "articulation": 1, "pend_repair_improve": 2,
            "converged": False}

    def test_no_graph_short_circuit_for_any_command(self):
        s = {**self.BASE, "has_graph": False}
        expect = ["7 pending", "5 accepted", "3 rejected"]
        # the no-graph branch wins regardless of which command was recommended
        for cmd in ("codvisor", "codshard", "codinventor", "codcycle", "execute"):
            self.assertEqual(st._evidence(cmd, s), expect, "no-graph evidence for %s" % cmd)

    def test_codvisor_and_codshard_show_the_debt_chips(self):
        expect = ["2 import cycles", "4 untested hotspots",
                  "1 articulation risks", "2 repair/improve pending"]
        # codshard is the Python-only leg: dropping it from the ("codvisor","codshard") tuple
        # makes _evidence fall through to the default ["7 pending","5 accepted so far"], which
        # this assertion catches (the old non-empty-list smoke check did not).
        self.assertEqual(st._evidence("codvisor", self.BASE), expect)
        self.assertEqual(st._evidence("codshard", self.BASE), expect)

    def test_codinventor_toggles_on_converged(self):
        self.assertEqual(st._evidence("codinventor", self.BASE),
                         ["7 pending", "2 cycles", "no open debt"])
        self.assertEqual(st._evidence("codinventor", {**self.BASE, "converged": True}),
                         ["7 pending", "2 cycles", "converged"])

    def test_default_branch_for_codcycle_execute_reset(self):
        expect = ["7 pending", "5 accepted so far"]
        for cmd in ("codcycle", "execute", "reset"):
            self.assertEqual(st._evidence(cmd, self.BASE), expect, "default evidence for %s" % cmd)


class TestResetNecessity(unittest.TestCase):
    # The reset decision must be SHOWN necessary, never assumed: a seeded invent-dry point
    # is seed-scoped (re-survey), an undrained or unknown frontier still has non-destructive
    # moves (harden), and only unseeded + drained leaves reset as the one remaining move.
    def test_seeded_point_resurveys(self):
        self.assertEqual(st._reset_necessity({"invent_seed": 3}, {"never_audited": 0}),
                         "reinvent")

    def test_undrained_or_unknown_frontier_hardens(self):
        self.assertEqual(st._reset_necessity({"invent_seed": None}, {"never_audited": 2}),
                         "harden")
        self.assertEqual(st._reset_necessity({"invent_seed": None}, None), "harden")
        self.assertEqual(st._reset_necessity({"invent_seed": None}, {}), "harden")

    def test_unseeded_drained_is_really_necessary(self):
        self.assertEqual(st._reset_necessity({"invent_seed": None}, {"never_audited": 0}),
                         "reset")


class TestRepoSizeCall(unittest.TestCase):
    def test_large_boundaries(self):
        # The mechanical size call — pinned at both boundaries so the constants cannot
        # drift silently (LARGE_REPO_TRACKED_FILES = 120, SHARD_MIN_DIRS = 2).
        self.assertTrue(st._is_large(120, 2))
        self.assertFalse(st._is_large(119, 2))
        self.assertFalse(st._is_large(120, 1))

    def test_pct_rank_ties_and_edges(self):
        # derive.js pctRank parity: singleton/empty -> 0; strictly-less rank; ties share.
        self.assertEqual(st._pct_rank([5], 5), 0.0)
        self.assertEqual(st._pct_rank([], 0), 0.0)
        self.assertAlmostEqual(st._pct_rank([1, 2, 3, 4], 3), 2 / 3)
        self.assertAlmostEqual(st._pct_rank([1, 2, 2, 4], 2), 1 / 3)


class TestRecommendOverlay(unittest.TestCase):
    """Pin recommend()'s dispatcher overlay — the ladder codmaster dispatches mutating
    commands from. The shared coach base is fixture-pinned (TestCoachTable); these pin
    the overlay rows' precedence, routing, invent_class marking, follow_up composite,
    blockers, and the reset nudge, with the mechanical sensors (graph signals, repo
    size, dirty tree, doctor) patched so each row is driven deterministically."""

    HEAD = "f" * 40
    GSIG_CLEAN = {"import_cycles": 0, "hot_uncovered": 0, "articulation": 0,
                  "coverage_pct": 100}
    REPO_SMALL = {"tracked_files": 10, "shardable_dirs": ["a", "b"],
                  "folded_dirs": [], "large": False}
    REPO_LARGE = {"tracked_files": 200, "shardable_dirs": ["a", "b", "c"],
                  "folded_dirs": [], "large": True}

    def _recommend(self, root, gsig=GSIG_CLEAN, repo=REPO_SMALL, dirty=(), doctor=()):
        from unittest import mock
        with mock.patch.object(st, "_graph_signals", lambda r: gsig), \
             mock.patch.object(st, "_repo_block", lambda r: repo), \
             mock.patch.object(st, "_dirty_paths", lambda r: list(dirty)), \
             mock.patch.object(st, "_doctor_blockers", lambda r, m: list(doctor)), \
             mock.patch.object(st, "_head_sha", lambda r: self.HEAD), \
             mock.patch.object(st, "_final_valid", lambda r: True):
            return st.recommend(root)

    def _root(self, plan=None, final=None, digest=None, graph=None):
        root = tempfile.mkdtemp(prefix="pw-overlay-")
        self.addCleanup(__import__("shutil").rmtree, root, True)
        pw = os.path.join(root, ".planwright")
        os.makedirs(pw)
        for name, text in (("plan.md", plan), ("final.md", final), ("digest.md", digest)):
            if text is not None:
                with open(os.path.join(pw, name), "w", encoding="utf-8") as fh:
                    fh.write(text)
        if graph is not None:
            with open(os.path.join(pw, "graph.json"), "w", encoding="utf-8") as fh:
                json.dump(graph, fh)
        return root

    def _pending(self, mode):
        return ("- [ ] An item\n      Mode: %s\n      Verification: true\n" % mode)

    def _final(self, tier, seed=None):
        text = "sha: %s\ndate: 2026-06-12\ndeepest_tier: %s\n" % (self.HEAD, tier)
        if seed is not None:
            text += "invent_seed: %s\ninvent_framing: power-user\n" % seed
        return text

    def _graph(self, never_audited):
        return {"graph_built_at_sha": self.HEAD, "nodes": {},
                "dirty": {"nodes": []},
                "frontier": {"never_audited": never_audited, "stale": 1}}

    def test_first_contact_routes_to_harden(self):
        rec = self._recommend(self._root(), gsig=None)
        self.assertEqual(rec["command"], "codvisor")
        self.assertEqual(rec["args"], "cycle 10 depth 10 explore")
        self.assertIn("first contact", rec["why"])
        self.assertFalse(rec["invent_class"])

    def test_pending_drains_first_even_with_debt(self):
        # A repair-mode pending item is itself coach debt — execute still wins the row.
        rec = self._recommend(self._root(plan=self._pending("repair")))
        self.assertEqual(rec["command"], "execute")
        self.assertIn("1 pending", rec["why"])
        self.assertEqual(rec["base"]["key"], "codvisor")

    def test_pending_healthy_mix_notes_the_codcycle_shadow(self):
        # base says codcycle (pending, no debt); the drain-first rule shadows it and the
        # divergence is explained in notes, never silent.
        rec = self._recommend(self._root(plan=self._pending("develop")))
        self.assertEqual(rec["command"], "execute")
        self.assertEqual(rec["base"]["key"], "codcycle")
        self.assertTrue(any("codcycle" in n for n in rec["notes"]))

    def test_carried_backlog_hardens_before_growing(self):
        digest = ("# digest\n\n## Carried dossier candidates\n"
                  "[repair sev2, CUT — capacity] foo.py:10 — claim; fix: bar\n")
        rec = self._recommend(self._root(digest=digest))
        self.assertEqual(rec["command"], "codvisor")
        self.assertIn("carried 1", rec["why"])

    def test_clean_but_unconverged_earns_convergence(self):
        rec = self._recommend(self._root())
        self.assertEqual(rec["command"], "codvisor")
        self.assertIn("earn convergence", rec["why"])
        self.assertIsNone(rec["reset_nudge"])

    def test_converged_grows_with_invent_class_and_nudge(self):
        rec = self._recommend(self._root(final=self._final("expand")))
        self.assertEqual(rec["command"], "codinventor")
        self.assertEqual(rec["args"], "cycle 10 depth 10 invent")
        self.assertTrue(rec["invent_class"])
        self.assertIsNotNone(rec["reset_nudge"])

    def test_invent_dry_seeded_resurveys(self):
        rec = self._recommend(self._root(final=self._final("invent", seed=3)))
        self.assertEqual(rec["command"], "codinventor")
        self.assertTrue(rec["invent_class"])
        self.assertIn("SEED-SCOPED", rec["why"])

    def test_invent_dry_undrained_frontier_hardens(self):
        rec = self._recommend(self._root(final=self._final("invent"),
                                         graph=self._graph(never_audited=2)))
        self.assertEqual(rec["command"], "codvisor")
        self.assertFalse(rec["invent_class"])
        self.assertIn("not shown drained", rec["why"])

    def test_invent_dry_unknown_frontier_hardens(self):
        # No graph.json at all: the frontier is unknown, so reset is NOT shown necessary.
        rec = self._recommend(self._root(final=self._final("invent")))
        self.assertEqual(rec["command"], "codvisor")
        self.assertIn("not shown drained", rec["why"])

    def test_invent_dry_unseeded_drained_resets_with_follow_up(self):
        rec = self._recommend(self._root(final=self._final("invent"),
                                         graph=self._graph(never_audited=0)))
        self.assertEqual(rec["command"], "reset")
        self.assertIn("really necessary", rec["why"])
        self.assertEqual(rec["follow_up"]["command"], "codvisor")
        self.assertIsNone(rec["reset_nudge"])  # the rec IS the reset — no nudge on top

    def test_large_repo_routes_harden_to_codshard(self):
        rec = self._recommend(self._root(), repo=self.REPO_LARGE)
        self.assertEqual(rec["command"], "codshard")
        self.assertEqual(rec["args"], "explore")
        self.assertTrue(any("codshard" in n for n in rec["notes"]))

    GSIG_DEBT = {"import_cycles": 0, "hot_uncovered": 0, "articulation": 6,
                 "coverage_pct": 90}

    def test_converged_outranks_static_debt(self):
        # Articulation is intrinsic and undrainable on a documented repo (the README/docs
        # link-web cut vertices). A current final point is the proof those signals were
        # surveyed dry at this HEAD — without this precedence the converged row is
        # unreachable and the record recommends a provable no-op harden forever.
        rec = self._recommend(self._root(final=self._final("expand")), gsig=self.GSIG_DEBT)
        self.assertEqual(rec["command"], "codinventor")
        self.assertEqual(rec["base"]["key"], "codvisor")
        self.assertTrue(any("outranks re-derived debt" in n for n in rec["notes"]))

    def test_unconverged_debt_still_hardens(self):
        rec = self._recommend(self._root(), gsig=self.GSIG_DEBT)
        self.assertEqual(rec["command"], "codvisor")
        self.assertFalse(rec["invent_class"])

    def test_converged_with_carried_backlog_still_hardens(self):
        digest = ("# digest\n\n## Carried dossier candidates\n"
                  "[repair sev2, DEFERRED — env] foo.py:10 — claim; fix: bar\n")
        rec = self._recommend(self._root(final=self._final("expand"), digest=digest))
        self.assertEqual(rec["command"], "codvisor")
        self.assertIn("carried 1", rec["why"])

    def test_first_contact_shadows_drain_first(self):
        # A never-audited root (no graph, zero completed) hardens BEFORE executing
        # hand-seeded pending items — deliberate (the dispatched cycle drains them
        # anyway); one completed item exits first contact and drain-first takes over.
        root = self._root(plan=self._pending("develop"))
        rec = self._recommend(root, gsig=None)
        self.assertEqual(rec["command"], "codvisor")
        self.assertIn("first contact", rec["why"])
        with open(os.path.join(root, ".planwright", "completed.md"), "w",
                  encoding="utf-8") as fh:
            fh.write("- [x] Done thing\n      Mode: develop\n")
        rec = self._recommend(root, gsig=None)
        self.assertEqual(rec["command"], "execute")

    def test_dirty_tree_blocks_a_mutating_dispatch(self):
        rec = self._recommend(self._root(), dirty=["?? wip.c"])
        self.assertTrue(rec["mutating"])
        self.assertEqual([b["kind"] for b in rec["blockers"]], ["dirty-tree"])
        self.assertIn("wip.c", rec["blockers"][0]["detail"])


class TestGitSensorTimeouts(unittest.TestCase):
    """A hung git must degrade the read-only sensors exactly as their docstrings
    document (None / empty list), never stall the sense surface or raise: the
    timeout=5 guard matches _head_sha, and TimeoutExpired is a SubprocessError,
    not a CalledProcessError, so the except clauses must stay widened."""

    def _timeout_run(self, *a, **kw):
        raise st.subprocess.TimeoutExpired(cmd="git", timeout=5)

    def test_repo_block_degrades_on_timeout(self):
        from unittest import mock
        with mock.patch.object(st.subprocess, "run", self._timeout_run):
            self.assertIsNone(st._repo_block("."))

    def test_dirty_paths_degrade_on_timeout(self):
        from unittest import mock
        with mock.patch.object(st.subprocess, "run", self._timeout_run):
            self.assertEqual(st._dirty_paths("."), [])


class TestRepoBlockShardable(unittest.TestCase):
    """_repo_block exposes the `shardable` fact (>= SHARD_MIN_DIRS partitionable dirs),
    INDEPENDENT of `large` (which additionally needs the tracked-file floor). codmaster's
    loop reads `shardable` to route its post-growth harden to codshard even on a not-large
    repo; the routing POLICY is codmaster's, the FACT is the engine's."""

    @staticmethod
    def _ls(out):
        return lambda *a, **k: st.subprocess.CompletedProcess(["git"], 0, stdout=out, stderr="")

    def test_shardable_independent_of_large(self):
        from unittest import mock
        # SHARD_MIN_DIRS dirs * 3 files each: shardable, but far below the tracked floor.
        many = "\n".join("d%d/f%d.py" % (d, f)
                         for d in range(st.SHARD_MIN_DIRS) for f in range(3)) + "\n"
        with mock.patch.object(st.subprocess, "run", self._ls(many)):
            rb = st._repo_block(".")
        self.assertTrue(rb["shardable"], "SHARD_MIN_DIRS shardable dirs -> shardable")
        self.assertFalse(rb["large"], "below the tracked-file floor -> not large")

    def test_below_floor_is_not_shardable(self):
        from unittest import mock
        # one shardable dir (< SHARD_MIN_DIRS): a scoped run, not a shard.
        one = "\n".join("only/f%d.py" % f for f in range(3)) + "\n"
        with mock.patch.object(st.subprocess, "run", self._ls(one)):
            rb = st._repo_block(".")
        self.assertFalse(rb["shardable"], "fewer than SHARD_MIN_DIRS dirs -> not shardable")


class TestDoctorBlockers(unittest.TestCase):
    # _doctor_blockers is the live status->doctor dispatch-gating seam: a FAIL always blocks; a
    # git-identity WARN blocks only a MUTATING dispatch (per-item commits need an identity); a
    # non-identity WARN never blocks; a missing doctor.py degrades to []. recommend() consumes it
    # to gate dispatch, but every other test mocks the whole function away, so the classification
    # was unpinned — a single-sided edit passes the full suite. _doctor_blockers re-imports
    # doctor.py by path each call, so inject a synthetic payload by stubbing the importlib load.
    @staticmethod
    def _run(payload, mutating):
        import importlib.util
        import types
        from unittest import mock
        fake = types.SimpleNamespace(collect=lambda root: payload)
        spec = types.SimpleNamespace(loader=types.SimpleNamespace(exec_module=lambda mod: None))
        with mock.patch.object(importlib.util, "spec_from_file_location", return_value=spec), \
             mock.patch.object(importlib.util, "module_from_spec", return_value=fake):
            return st._doctor_blockers("/synthetic/root", mutating)

    def test_fail_always_blocks(self):
        payload = {"checks": [{"name": "git", "status": "fail", "detail": "missing"}]}
        for mut in (True, False):
            out = self._run(payload, mut)
            self.assertEqual([b["kind"] for b in out], ["doctor-fail"],
                             "a fail must block (mutating=%s)" % mut)

    def test_identity_warn_blocks_only_mutating(self):
        payload = {"checks": [{"name": "git commit identity", "status": "warn",
                               "detail": "no user.name/email"}]}
        self.assertEqual([b["kind"] for b in self._run(payload, True)],
                         ["doctor-warn-identity"])
        self.assertEqual(self._run(payload, False), [])

    def test_non_identity_warn_never_blocks(self):
        payload = {"checks": [{"name": "rg (ripgrep)", "status": "warn", "detail": "absent"}]}
        self.assertEqual(self._run(payload, True), [])
        self.assertEqual(self._run(payload, False), [])

    def test_missing_doctor_degrades_to_empty(self):
        import os as _os
        from unittest import mock
        with mock.patch.object(_os.path, "exists", return_value=False):
            self.assertEqual(st._doctor_blockers("/synthetic/root", True), [])


if __name__ == "__main__":
    unittest.main()
