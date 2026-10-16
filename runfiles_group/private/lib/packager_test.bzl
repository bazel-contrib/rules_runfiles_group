"""Checks the foreign rule attribute boundary used by propagation callbacks."""

load("@bazel_features//:features.bzl", "bazel_features")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(":packager.bzl", "ATTR_ASPECTS", "TOOLCHAINS_ASPECTS")

def _context(attrs):
    return struct(rule = struct(label = Label(":propagation_test"), attr = attrs))

def _valid_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], ATTR_ASPECTS(_context(struct())))
    asserts.equals(env, [], TOOLCHAINS_ASPECTS(_context(struct())))
    asserts.equals(env, ["deps"], ATTR_ASPECTS(_context(struct(
        _aspect_rule_hints = struct(value = []),
        deps = struct(value = []),
    ))))
    for strings in [[], ["deps", "data"]]:
        asserts.equals(env, strings, ATTR_ASPECTS(_context(struct(
            _runfiles_group_attrs = struct(value = strings, is_tool = False),
        ))))
    for labels in [[], [Label(":toolchain_type")]]:
        asserts.equals(env, labels, TOOLCHAINS_ASPECTS(_context(struct(
            _aspect_rule_hints = struct(value = labels, is_tool = False),
        ))))
    return unittest.end(env)

_valid_test = unittest.make(_valid_impl)

def _invalid_impl(ctx):
    element = "//tools:type" if ctx.attr.check_toolchains else 1
    value = [element] if ctx.attr.bad_element else "not a list"
    if ctx.attr.check_toolchains:
        TOOLCHAINS_ASPECTS(_context(struct(_aspect_rule_hints = struct(value = value))))
    else:
        ATTR_ASPECTS(_context(struct(_runfiles_group_attrs = struct(value = value))))
    return []

_invalid = rule(
    implementation = _invalid_impl,
    attrs = {
        "bad_element": attr.bool(),
        "check_toolchains": attr.bool(),
    },
)

def _invalid_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "must be a list of")
    return analysistest.end(env)

_invalid_test = analysistest.make(_invalid_test_impl, expect_failure = True)

def packager_test_suite(name):
    """Exercises callable propagation filters on hosts that support them."""
    tests = []
    if bazel_features.rules.aspect_propagation_context:
        _valid_test(name = name + "_valid")
        tests.append(name + "_valid")
        for toolchains in [False, True]:
            for bad_element in [False, True]:
                target = name + ("_toolchains" if toolchains else "_attrs") + ("_element" if bad_element else "_container")
                _invalid(
                    name = target,
                    bad_element = bad_element,
                    check_toolchains = toolchains,
                    tags = ["manual"],
                )
                _invalid_test(name = target + "_test", target_under_test = target)
                tests.append(target + "_test")
    native.test_suite(name = name, tests = tests)
