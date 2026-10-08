"""RunfilesGroupInfo construction and validation."""

load(
    "//runfiles_group/private/lib:constants.bzl",
    "BOOL_TYPE",
    "ENTRY_FIELDS",
    "INT_TYPE",
    "RANK_EXECUTABLE",
    "RELABEL_FIELDS",
    "STRING_TYPE",
)
load("//runfiles_group/private/lib:content.bzl", "stored_content")
load("//runfiles_group/private/lib:names.bzl", "check_name")
load("//runfiles_group/private/providers:runfiles_group_info.bzl", "KINDS", "RunfilesGroupInfo")

def check_metadata(where, field, value):
    """Fails unless value is legal for the metadata field (or for `name`).

    Args:
        where: Call-site description for error messages.
        field: One of RELABEL_FIELDS.
        value: The value to check.
    """
    if field == "name":
        check_name(where, value)
    elif field == "kind":
        if value not in KINDS:
            fail("{}: kind must be one of {}, got {}".format(where, KINDS, repr(value)))
    elif field == "rank":
        if type(value) != INT_TYPE:
            fail("{}: rank must be an int, got {}".format(where, type(value)))
    elif field == "do_not_merge":
        if type(value) != BOOL_TYPE:
            fail("{}: do_not_merge must be a bool, got {}".format(where, type(value)))
    elif field == "weight":
        if value != None:
            if type(value) != INT_TYPE:
                fail("{}: weight must be an int or None, got {}".format(where, type(value)))
            if value < 0:
                fail("{}: weight must be >= 0, got {}".format(where, value))
    elif field == "merge_affinity":
        if type(value) != STRING_TYPE:
            fail("{}: merge_affinity must be a string, got {}".format(where, type(value)))
    else:
        fail("{}: unknown field '{}', expected one of {}".format(where, field, RELABEL_FIELDS))

def make_entry(*, name, content, kind = "", rank = RANK_EXECUTABLE, do_not_merge = False, weight = None, merge_affinity = ""):
    """Creates one validated group entry.

    Args:
        name: The group's identity, in one of two forms.

            A **Label** for a per-target group -- "the runfiles this one target
            contributes". Pass `ctx.label` for your own, or a dependency's
            `dep.label`. A Label is globally unique, so it needs no ruleset prefix,
            and it costs nothing: Bazel already interns it.

            A **string** for a named group that several targets contribute to --
            "interpreter", "std", "third_party". Strings live in a namespace shared
            by every provider merged into the same binary, so prefix them with
            something unique to your ruleset, e.g. "my_rules#interpreter".
        content: The group's contents, in one of two forms.

            A **depset of File** for a group that is only files, which most
            *_library groups are. Hand over the depset you already built: the entry
            then points at it, where wrapping it in a runfiles object would retain
            an extra ~64 bytes per group -- a 7-field Runfiles plus the nested set
            node its compile-order builder has to allocate -- carrying no
            information the depset does not.

            A **runfiles object** for anything else, and for contents you received
            from another rule. This is the general form: it is the only one that can
            carry symlinks, root symlinks and empty filenames.

            Consumers read either form through runfiles_groups.files() and
            runfiles_groups.runfiles().
        kind: One of runfiles_groups.KINDS. A stable selector for packagers,
            unaffected by renaming. Does not influence ordering or merging. Default "".
        rank: Partial ordering key. Lower rank = earlier layer. Default 0.
        do_not_merge: If True, packagers must not merge this group. Default False.
        weight: Merge priority hint (int >= 0 or None). Lighter groups merge
            first. Default None.
        merge_affinity: Merge grouping hint. Groups that share an affinity are
            preferred merge partners. "" means no affinity. Default "".

    Returns:
        A RunfilesGroupInfo, for runfiles_groups.node(add = ...).
    """
    check_name("runfiles_groups.entry", name)
    content = stored_content("runfiles_groups.entry", content)
    check_metadata("runfiles_groups.entry", "kind", kind)
    check_metadata("runfiles_groups.entry", "rank", rank)
    check_metadata("runfiles_groups.entry", "do_not_merge", do_not_merge)
    check_metadata("runfiles_groups.entry", "weight", weight)
    check_metadata("runfiles_groups.entry", "merge_affinity", merge_affinity)
    return RunfilesGroupInfo(
        name = name,
        content = content,
        kind = kind,
        rank = rank,
        do_not_merge = do_not_merge,
        weight = weight,
        merge_affinity = merge_affinity,
    )

def check_entry(where, entry):
    for field in ENTRY_FIELDS:
        if not hasattr(entry, field):
            fail(("{}: expected a RunfilesGroupInfo built with runfiles_groups.entry(), " +
                  "got a value without field '{}'").format(where, field))
