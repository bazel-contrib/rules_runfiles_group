"""Checks the contributor invariant of raw piece keys."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//runfiles_group/private/providers:runfiles_group_partial_info.bzl", "RunfilesGroupPartialInfo")
load(":resolve.bzl", "disjoint_inputs", "piece_key")

def _partial(contributor):
    return RunfilesGroupPartialInfo(
        name = "test",
        contributor = contributor,
        handle = "content",
        pieces = depset(),
        kind = "data",
        rank = 0,
        do_not_merge = False,
        weight = None,
        merge_affinity = "",
    )

def _valid_impl(ctx):
    env = unittest.begin(ctx)
    contributor = Label(":raw")
    asserts.equals(env, (contributor, "content"), piece_key(_partial(contributor)))
    first = _partial(Label(":a"))
    second = _partial(Label(":b"))
    asserts.equals(env, [first, second], disjoint_inputs([second, first]))
    return unittest.end(env)

_valid_test = unittest.make(_valid_impl)

def _invalid_impl(_ctx):
    piece_key(_partial(None))
    return []

_invalid = rule(implementation = _invalid_impl)

def _invalid_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "A raw runfiles group piece must have a contributor")
    return analysistest.end(env)

_invalid_test = analysistest.make(_invalid_test_impl, expect_failure = True)

def resolve_test_suite(name):
    """Checks valid raw pieces and rejects a missing contributor at the boundary."""
    _valid_test(name = name + "_valid")
    _invalid(name = name + "_missing_contributor", tags = ["manual"])
    _invalid_test(
        name = name + "_invalid",
        target_under_test = name + "_missing_contributor",
    )
    native.test_suite(name = name, tests = [name + "_valid", name + "_invalid"])
