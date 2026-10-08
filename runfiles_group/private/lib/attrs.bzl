"""Walking Label-typed attribute values, and synthesizing groups for targets that don't have a describer."""

load(
    "//runfiles_group/private/lib:constants.bzl",
    "DICT_TYPE",
    "LIST_TYPE",
    "STRING_TYPE",
    "TARGET_TYPE",
    "TUPLE_TYPE",
)
load("//runfiles_group/private/lib:entry.bzl", "make_entry")

def attr_targets(where, attrs):
    """Flattens an iterable of rule attribute values to the Targets inside them.

    Every Label-typed attribute kind hands ctx.attr a differently shaped value,
    and a Target can sit at any of three depths:

        attr.label                    Target
        attr.label_list               list of Target
        attr.label_keyed_string_dict  dict Target -> string
        attr.string_keyed_label_dict  dict string -> Target
        attr.label_list_dict          dict string -> list of Target

    Which side of a keyed dict holds the Targets depends on the kind, so both are
    inspected and the string side is skipped rather than rejected. That is also
    why the dict kinds cannot be told apart from each other here -- and need not
    be: what a caller wants from any of them is the Targets.

    Starlark has no recursion, and this needs none: those five are the whole set,
    and Bazel cannot add a deeper shape without adding an attribute kind.

    Args:
        where: Call-site description for error messages.
        attrs: Iterable of ctx.attr values.

    Returns:
        A flat list of Targets. One short-lived list per call, and no copy of
        anything a Target holds.
    """
    targets = []
    for value in attrs:
        kind = type(value)
        if kind == TARGET_TYPE:
            targets.append(value)
        elif kind == LIST_TYPE or kind == TUPLE_TYPE:
            _append_targets(where, targets, value)
        elif kind == DICT_TYPE:
            for key, item in value.items():
                _append_dict_half(where, targets, key)
                _append_dict_half(where, targets, item)
        else:
            fail(("{}: expected a Target, a list of Targets or a dict from a Label-typed " +
                  "attribute, got {}. Pass each attribute value as one element, e.g. " +
                  "[ctx.attr.deps, ctx.attr.exports].").format(where, kind))
    return targets

def _append_targets(where, targets, values):
    """Appends a list of Targets, rejecting anything else."""
    for value in values:
        if type(value) != TARGET_TYPE:
            fail(("{}: expected a Target, got {}. Pass ctx.attr values, not ctx.files " +
                  "values or plain Labels.").format(where, type(value)))
        targets.append(value)

def _append_dict_half(where, targets, value):
    """Appends the Targets on one side of a dict-shaped attribute value.

    The string side of a keyed dict is skipped: it is the key of a
    string_keyed_label_dict or a label_list_dict, or the value of a
    label_keyed_string_dict, and none of those name a dependency.
    """
    kind = type(value)
    if kind == TARGET_TYPE:
        targets.append(value)
    elif kind == LIST_TYPE or kind == TUPLE_TYPE:
        _append_targets(where, targets, value)
    elif kind != STRING_TYPE:
        fail(("{}: expected a Target, a list of Targets or a string in a dict-shaped " +
              "attribute value, got {}.").format(where, kind))

def synthesized_entry(ctx, target):
    """Synthesizes the entry for a target that does not describe its runfiles groups.

    It is a per-target group named by the target's Label, holding the target's
    files and default runfiles. A packager's aspect builds it on the target itself
    when the target's rule has no describer, so the partial is materialized once and
    shared by every parent that merges it in with fallback = "synthesize". A file
    target never gets an aspect, so for one the parent builds it instead.

    Args:
        ctx: The aspect context.
        target: A Target: the aspect's own target, or a dependency of it.

    Returns:
        A RunfilesGroupInfo covering the target's files and default runfiles.
    """

    # Read DefaultInfo once: on a target that does not return it explicitly every
    # access constructs a fresh delegating instance, and every `.files` read a
    # fresh depset wrapper.
    default_info = target[DefaultInfo]
    runfiles = default_info.default_runfiles

    # default_runfiles is declared nullable on the Starlark API surface, and
    # RunfilesProvider's factories accept null unchecked. No path through
    # target[DefaultInfo] appears to produce None today, so this branch costs one
    # comparison and never runs -- keep it rather than depend on that.
    if runfiles == None:
        runfiles = ctx.runfiles()
    files = default_info.files

    # Truth-testing a depset is O(1). Skipping the wrapper for a target that
    # contributes no files avoids a runfiles object and a nested set per target.
    #
    # The dependency's depset is laundered through depset(transitive = ) before it
    # reaches ctx.runfiles(transitive_files = ), which accepts only default and
    # postorder. Starlark cannot read an order back to check for a bad one, but it
    # can neutralize it: the rewrap yields a default-ordered depset, and hands back
    # the original object when it already was one. Without it, a target
    # publishing DefaultInfo(files = depset(..., order = "topological")) could not
    # be synthesized at all.
    #
    # This synthesized entry keeps the runfiles form: deciding to hand over `files`
    # alone would mean inspecting a foreign runfiles object to see whether it holds
    # anything besides files, and reading its empty_filenames is O(all files) for a
    # target that carries a real empty-files supplier.
    if files:
        runfiles = ctx.runfiles(transitive_files = depset(transitive = [files])).merge(runfiles)
    return make_entry(name = target.label, content = runfiles)
