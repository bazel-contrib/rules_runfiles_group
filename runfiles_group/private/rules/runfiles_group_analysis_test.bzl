"""A test verifying the runfiles groups a target describes.

Each target under test is walked with the identity packager
(runfiles_groups_identity_aspect), its groups are finalized, and their union is
checked for completeness, overlap and ordering against DefaultInfo.default_runfiles.

Usage:

```starlark
load("@rules_runfiles_group//runfiles_group:runfiles_group_analysis_test.bzl", "runfiles_group_analysis_test")

runfiles_group_analysis_test(
    name = "test_runfiles_group_invariants",
    binaries = [
        ":my_binary",
        ":my_other_binary",
    ],
    overlapping_group_behavior = "error",
)
```
"""

load("@bazel_skylib//lib:sets.bzl", "sets")
load("//runfiles_group/private:lib.bzl", "runfiles_groups")
load("//runfiles_group/private/aspects:identity.bzl", "RunfilesGroupIdentityInfo", "runfiles_groups_identity_aspect")

_INDENT = "    "

def _indent(text):
    return "\n".join([_INDENT + line for line in text.split("\n")])

def _get_files(rf):
    return rf.files

def _get_empty_filenames(rf):
    return rf.empty_filenames

def _get_symlinks(rf):
    return rf.symlinks

def _get_root_symlinks(rf):
    return rf.root_symlinks

_RUNFILES_COMPONENTS = [
    ("files", _get_files),
    ("empty_filenames", _get_empty_filenames),
    ("symlinks", _get_symlinks),
    ("root_symlinks", _get_root_symlinks),
]

def _join_group_names(lighter_name, _lighter_weight, heavier_name, _heavier_weight):
    return runfiles_groups.name_str(lighter_name) + "+" + runfiles_groups.name_str(heavier_name)

def _make_join_group_names(prefix):
    def _join(lighter_name, _lighter_weight, heavier_name, _heavier_weight):
        stripped = runfiles_groups.name_str(heavier_name)
        if stripped.startswith(prefix):
            stripped = stripped[len(prefix):]
        return runfiles_groups.name_str(lighter_name) + "+" + stripped

    return _join

def _test_one(ctx, binary_attr):
    issues = []
    success = True
    default_info = binary_attr[DefaultInfo]
    default_runfiles = default_info.default_runfiles

    # Finalizing also validates every group and that executable_group names a
    # surviving group, so a malformed description fails here with the binary's
    # label rather than inside somebody's packaging rule.
    info = binary_attr[RunfilesGroupIdentityInfo]
    resolved = runfiles_groups.finalize(
        ctx,
        info,
        runfiles_groups.IDENTITY_OPS,
        aspect_hints = [],
        executable_group_last = ctx.attr.executable_group_last,
    )
    if default_runfiles == None:
        return (False, ["doesn't have default_runfiles to compare to."])

    check_overlap = ctx.attr.overlapping_group_behavior != "ignore"

    # Materialized once per group, outside the per-component loop: a group whose
    # contents are a files-only depset has no symlinks, root symlinks or empty
    # filenames to read, and runfiles_groups.runfiles() is what turns "no symlinks"
    # into the empty depsets the comparison below needs. Doing it inside the loop
    # would build four runfiles objects per group instead of one. The identity
    # packager's handles are the contents themselves.
    groups = [
        (runfiles_groups.name_str(group.name), runfiles_groups.runfiles(ctx, group.handle))
        for group in resolved.groups
    ]

    # Note: the following calculations are expensive.
    # This analysis test is only meant to be used to test the correctness of
    # rules describing runfiles groups. Do not use for all of your *_binary targets in prod.
    for component_name, get_depset in _RUNFILES_COMPONENTS:
        all_default = sets.make(get_depset(default_runfiles).to_list())
        all_grouped = sets.make()

        # Overlap is detected in the same pass, by remembering the first group that
        # claimed each entry. Intersecting every pair of groups instead meant
        # flattening and re-hashing every group O(G) times.
        first_owner = {}
        overlaps = {}  # (first owner, other group) -> [entries]

        # `group` is the canonical string form, so the diagnostics read the same
        # whether a group is identified by a Label or by a name.
        for group, group_runfiles in groups:
            for item in get_depset(group_runfiles).to_list():
                sets.insert(all_grouped, item)
                if not check_overlap:
                    continue
                owner = first_owner.get(item)
                if owner == None:
                    first_owner[item] = group
                    continue
                pair = (owner, group)
                if pair in overlaps:
                    overlaps[pair].append(item)
                else:
                    overlaps[pair] = [item]

        if not sets.is_equal(all_default, all_grouped):
            success = False
            missing_from_groups = sets.difference(all_default, all_grouped)
            extra_in_groups = sets.difference(all_grouped, all_default)
            if sets.length(missing_from_groups) > 0:
                issues.append(
                    "{} in default_runfiles missing from every runfiles group:\n".format(component_name) +
                    "\n".join([_INDENT + str(item) for item in sets.to_list(missing_from_groups)]),
                )
            if sets.length(extra_in_groups) > 0:
                issues.append(
                    "{} in runfiles groups missing from default_runfiles:\n".format(component_name) +
                    "\n".join([_INDENT + str(item) for item in sets.to_list(extra_in_groups)]),
                )

        for pair, items in overlaps.items():
            msg = (
                "{}: groups '{}' and '{}' overlap:\n".format(component_name, pair[0], pair[1]) +
                "\n".join([_INDENT + str(item) for item in items])
            )
            if ctx.attr.overlapping_group_behavior == "error":
                success = False
                issues.append(msg)
            else:
                # buildifier: disable=print
                print("WARNING [{}]: {}".format(binary_attr.label, msg))

    # Apply the optional group limit and check the resulting names and count.
    if ctx.attr.max_groups >= 0:
        join_fn = _make_join_group_names(ctx.attr.group_name_prefix) if ctx.attr.group_name_prefix else _join_group_names
        resolved = runfiles_groups.finalize(
            ctx,
            info,
            runfiles_groups.IDENTITY_OPS,
            aspect_hints = [],
            max_groups = ctx.attr.max_groups,
            merged_group_name = join_fn,
            executable_group_last = ctx.attr.executable_group_last,
        )
        if ctx.attr.expected_group_count >= 0:
            if resolved.group_count != ctx.attr.expected_group_count:
                success = False
                issues.append(
                    "expected {} groups after merging but got {}".format(
                        ctx.attr.expected_group_count,
                        resolved.group_count,
                    ),
                )
        elif resolved.group_count > ctx.attr.max_groups:
            success = False
            issues.append(
                "max_groups={} requested but merging could only reduce to {} groups".format(
                    ctx.attr.max_groups,
                    resolved.group_count,
                ),
            )

    # Expectations are written as strings in BUILD files, so both name forms are
    # compared in their canonical string form.
    actual_names = [runfiles_groups.name_str(group.name) for group in resolved.groups]
    if ctx.attr.expected_group_names:
        if actual_names != ctx.attr.expected_group_names:
            success = False
            issues.append(
                "expected ordered group names:\n" +
                _INDENT + str(ctx.attr.expected_group_names) + "\n" +
                "actual ordered group names:\n" +
                _INDENT + str(actual_names),
            )

    actual_executable_group = runfiles_groups.name_str(resolved.executable_group) if resolved.executable_group != None else None
    if ctx.attr.expected_executable_group and actual_executable_group != ctx.attr.expected_executable_group:
        success = False
        issues.append("expected executable_group '{}' but got {}".format(
            ctx.attr.expected_executable_group,
            repr(actual_executable_group),
        ))

    return (success, issues)

def _runfiles_group_analysis_test_impl(ctx):
    if len(ctx.attr.binaries) == 0:
        return [AnalysisTestResultInfo(
            success = False,
            message = "runfiles_group_analysis_test with no binaries.",
        )]

    success = True
    sections = []
    for binary_attr in ctx.attr.binaries:
        ok, issues = _test_one(ctx, binary_attr)
        if not ok:
            success = False
            if len(issues) > 0:
                sections.append(
                    "Issues with {}:\n{}".format(
                        binary_attr.label,
                        "\n".join([_indent(issue) for issue in issues]),
                    ),
                )

    return [AnalysisTestResultInfo(
        success = success,
        message = "\n".join(sections),
    )]

runfiles_group_analysis_test = rule(
    implementation = _runfiles_group_analysis_test_impl,
    doc = """\
Checks the runfiles groups a target describes by walking it with the identity
packager and comparing all runfiles components (files, empty_filenames, symlinks,
root_symlinks) of DefaultInfo.default_runfiles with the union of all groups.

Finalizing also validates every group and that executable_group, if set, names a
surviving group.

Additionally, it can warn about entries appearing in multiple groups (overlapping),
verify the expected ordered group names, verify which group carries the executable,
and optionally merge down to a group limit before ordering.
""",
    attrs = {
        "binaries": attr.label_list(
            aspects = [runfiles_groups_identity_aspect],
            mandatory = True,
            doc = "List of *_binary targets to test.",
        ),
        "check_disabled": attr.bool(
            default = True,
            doc = """\
Deprecated and ignored. This used to analyze every binary a second time with the
global @rules_runfiles_group//runfiles_group:enabled switch off, which nothing
reads any more.
""",
        ),
        "expected_group_names": attr.string_list(
            doc = """\
If set, the test verifies that the ordered group names (after optional merging and rank-based ordering)
match this list exactly. Applies to all binaries in the test.

Names are compared in canonical string form (runfiles_groups.name_str), so a group
named by a Label is written as its canonical label string, e.g. "@@//src:lib_a".
""",
        ),
        "expected_executable_group": attr.string(
            doc = """\
If set, the test verifies that the finalized executable_group (after optional
merging) is exactly this group name, in canonical string form
(runfiles_groups.name_str) -- so a group named by a Label is written as its
canonical label string. Applies to all binaries in the test.
""",
        ),
        "executable_group_last": attr.bool(
            default = True,
            doc = "Passed to runfiles_groups.finalize(): whether the executable group comes last.",
        ),
        "max_groups": attr.int(
            doc = "If >= 0, finalize with max_groups set to this limit. -1 means no limit.",
            default = -1,
        ),
        "expected_group_count": attr.int(
            doc = """\
If >= 0, verify the exact number of groups after merging (requires max_groups >= 0).
Use this when merging cannot reach max_groups (e.g., due to do_not_merge or rank constraints)
to assert the actual reachable count. -1 means no check (the test fails if group_count > max_groups instead).
""",
            default = -1,
        ),
        "group_name_prefix": attr.string(
            doc = """\
If set, merged group names will strip this prefix from the second (heavier) group name
before joining with '+'. This avoids repeating a common prefix in merged names.
For example, with prefix "p#", merging "p#foo" and "p#bar" produces "p#foo+bar" instead of "p#foo+p#bar".
Names are canonicalized first, so this also applies to groups named by a Label.
""",
        ),
        "overlapping_group_behavior": attr.string(
            doc = "How to handle overlapping groups (the same entry being present in more than one group).",
            default = "warn",
            values = ["warn", "ignore", "error"],
        ),
    },
    analysis_test = True,
)
