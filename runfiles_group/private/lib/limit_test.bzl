"""Checks names chosen by the group count limit callback."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(":entry.bzl", "make_entry")
load(":limit.bzl", "limit")
load(":names.bzl", "described_name", "name_str")
load(":packager.bzl", "IDENTITY_OPS")
load(":partial.bzl", "make_partial")
load(":resolved.bzl", "resolved_groups")

def _partial(name, weight, do_not_merge = False):
    entry = make_entry(name = name, content = depset(), weight = weight, do_not_merge = do_not_merge)
    return make_partial(entry, contributor = Label(":piece_{}".format(weight)), handle = entry.content)

def _lighter(lighter, _light_weight, _heavier, _heavy_weight):
    return lighter

def _heavier(_lighter, _light_weight, heavier, _heavy_weight):
    return heavier

def _fresh_label(_lighter, _light_weight, _heavier, _heavy_weight):
    return Label(":merged")

def _valid_impl(ctx):
    env = unittest.begin(ctx)
    groups = [_partial(Label(":first"), 1), _partial("second", 2)]
    resolved = resolved_groups(groups)
    for callback, expected in [(_lighter, Label(":first")), (_heavier, "second")]:
        result = limit(ctx, IDENTITY_OPS, resolved, max_groups = 1, merged_group_name = callback)
        asserts.equals(env, [expected], [group.name for group in result.groups])
    result = limit(
        ctx,
        IDENTITY_OPS,
        resolved_groups(groups + [_partial("third", 10)]),
        max_groups = 1,
        merged_group_name = _fresh_label,
    )
    asserts.equals(env, [Label(":merged")], [group.name for group in result.groups])
    result = limit(
        ctx,
        IDENTITY_OPS,
        resolved_groups([
            _partial("third", 5),
            _partial("second", 2),
            _partial("first", 2),
            _partial("heavy", 9),
        ]),
        max_groups = 3,
        merged_group_name = _lighter,
    )
    asserts.equals(env, ["first", "heavy", "third"], [group.name for group in result.groups])
    return unittest.end(env)

_valid_test = unittest.make(_valid_impl)

def _collision_names(consume_label):
    label = Label(":same_name")
    return (label, name_str(label)) if consume_label else (name_str(label), label)

def _invalid_impl(ctx):
    consumed, surviving = _collision_names(ctx.attr.consume_label)
    resolved = resolved_groups([
        _partial(consumed, 1),
        _partial("other", 2),
        _partial(surviving, 3, do_not_merge = True),
    ])
    limit(ctx, IDENTITY_OPS, resolved, max_groups = 2, merged_group_name = _lighter)
    return []

_invalid = rule(implementation = _invalid_impl, attrs = {"consume_label": attr.bool()})

def _invalid_test_impl(ctx):
    env = analysistest.begin(ctx)
    _, surviving = _collision_names(ctx.attr.consume_label)
    asserts.expect_failure(env, "which is an existing group ({})".format(described_name(surviving)))
    return analysistest.end(env)

_invalid_test = analysistest.make(_invalid_test_impl, attrs = {"consume_label": attr.bool()}, expect_failure = True)

def limit_test_suite(name):
    """Exercises retained names and collisions with a surviving group."""
    _valid_test(name = name + "_valid")
    tests = [name + "_valid"]
    for consume_label in [False, True]:
        target = name + ("_label" if consume_label else "_string")
        _invalid(name = target, consume_label = consume_label, tags = ["manual"])
        _invalid_test(name = target + "_test", consume_label = consume_label, target_under_test = target)
        tests.append(target + "_test")
    native.test_suite(name = name, tests = tests)
