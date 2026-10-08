"""The Starlark runtime -- interpreter and standard library -- and its runfiles groups.

starlark_binary gets its runtime from the Starlark toolchain where a packager's
aspect can walk toolchains (runfiles_groups.TOOLCHAINS_ASPECTS: Bazel 8.8+), and
from private attributes before that. Either way the runtime arrives as the same
two groups, described here once.
"""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")

STARLARK_TOOLCHAIN_TYPE = Label("//producer/interpreter:toolchain_type")

# Whether starlark_binary resolves the toolchain. Without toolchain walking, a
# packager's aspect could not reach the runtime's runfiles.
USE_STARLARK_TOOLCHAIN = bool(runfiles_groups.TOOLCHAINS_ASPECTS)

GROUP_PREFIX = "starlark_runfiles_group#"

# Merge affinity stamped on every group this ruleset produces. See the
# matching comment in starlark_library.bzl.
AFFINITY = "starlark"

# Module-level so the boxed int is allocated once at load time. StarlarkInt only
# caches [-128, 99871], so evaluating `runfiles_groups.RANK_FOUNDATION + 100` in
# the rule implementation would allocate a fresh 16-byte object per target and
# retain it inside the metadata struct.
_RANK_STD = runfiles_groups.RANK_FOUNDATION + 100

# Fixed group names, built once at load time rather than per target. A group name
# is retained inside its entry, so concatenating a constant in the rule
# implementation retains one copy of the same string per binary.
_GROUP_INTERPRETER = GROUP_PREFIX + "interpreter"
_GROUP_STD = GROUP_PREFIX + "std"

def runtime_merge_from(interpreter_attr, standard_library_attr):
    """The merge_from() specs of the interpreter and standard library attributes.

    Args:
        interpreter_attr: Name of the attribute holding the interpreter.
        standard_library_attr: Name of the attribute holding the standard library.

    Returns:
        A list of runfiles_groups.merge_from() values.
    """
    return [
        # Special group: interpreter. The interpreter does not describe its
        # runfiles groups, so its DefaultInfo is synthesized into one group.
        runfiles_groups.merge_from(
            interpreter_attr,
            fallback = "synthesize",
            into = _GROUP_INTERPRETER,
            kind = "foundation",
            rank = runfiles_groups.RANK_FOUNDATION,
            do_not_merge = True,
            merge_affinity = AFFINITY,
        ),
        # Special group: std. @std puts its whole closure into this one named
        # group itself (starlark_library's runfiles_group), so it arrives here
        # as a single piece that every binary shares, and this edge only sets
        # its metadata.
        runfiles_groups.merge_from(
            standard_library_attr,
            into = _GROUP_STD,
            kind = "foundation",
            rank = _RANK_STD,
            merge_affinity = AFFINITY,
        ),
    ]

def starlark_runtime(ctx, interpreter, standard_library):
    """What a binary needs from the runtime, read from its interpreter and standard library.

    Args:
        ctx: The rule context.
        interpreter: The interpreter's Target.
        standard_library: The standard library's Target.

    Returns:
        A struct of interpreter (File), interpreter_runfiles,
        standard_library_runfiles and standard_library_repo (a canonical
        repository name).
    """
    interpreter_info = interpreter[DefaultInfo]
    return struct(
        interpreter = interpreter_info.files_to_run.executable,
        interpreter_runfiles = ctx.runfiles(transitive_files = interpreter_info.files).merge(interpreter_info.default_runfiles),
        standard_library_runfiles = standard_library[DefaultInfo].default_runfiles,
        standard_library_repo = standard_library.label.repo_name or "_main",
    )
