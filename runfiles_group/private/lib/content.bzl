"""Runfiles content values: a depset of File or a runfiles object."""

load("//runfiles_group/private/lib:constants.bzl", "DEPSET_TYPE")

def _check_content(where, content):
    """Fails unless content is one of the two legal forms. Allocates nothing."""
    if type(content) == DEPSET_TYPE:
        return
    if not hasattr(content, "merge_all"):
        fail("{}: content must be a runfiles object or a depset of File, got {}".format(
            where,
            type(content),
        ))

def stored_content(where, content):
    """Validates content and returns the form an entry stores.

    Args:
        where: Call-site description for error messages.
        content: A depset of File or a runfiles object.

    Returns:
        The runfiles object unchanged, or the depset rewrapped in default order.
    """
    _check_content(where, content)
    if type(content) != DEPSET_TYPE:
        return content

    # Rewrapped in default order rather than stored as handed over:
    # ctx.runfiles(transitive_files = ) rejects preorder and topological depsets --
    # unconditionally, empty ones included -- and Starlark can neither read a
    # depset's order back nor probe it soundly. Laundering here is the only way a
    # producer's depset cannot fail inside somebody else's packaging rule, and it is
    # free for the case that matters: depset(transitive = [d]) hands back d itself
    # when d is already default-ordered.
    return depset(transitive = [content])

def content_files(content):
    """Returns every File in a runfiles content value, as a depset.

    The read path for a packager that only needs paths -- a manifest, an output
    group, a layer's contents. It allocates nothing for a files-only group and, for
    a runfiles-form group, only the depset wrapper Bazel builds per `.files` access.

    Note that it deliberately does not include the symlinks, root symlinks, and
    empty filenames of a runfiles-form group. A packager that must place a complete
    runfiles tree wants runfiles_groups.runfiles() instead.

    Args:
        content: A depset of File or a runfiles object -- an entry's content, or
            an identity packager's handle.

    Returns:
        A depset of File.
    """
    if type(content) == DEPSET_TYPE:
        return content
    return content.files

def content_runfiles(ctx, content):
    """Returns a runfiles content value as a runfiles object.

    Identity for a group that already carries one; for a files-only group it builds
    one, which is why this takes a ctx. Never store the result in a provider: doing
    so re-retains, per consuming target, exactly the object the producer avoided.

    Args:
        ctx: The rule or aspect context. ctx.runfiles() is available in both.
        content: A depset of File or a runfiles object.

    Returns:
        A runfiles object holding the same contents.
    """
    if type(content) == DEPSET_TYPE:
        return ctx.runfiles(transitive_files = content)
    return content

def union_contents(ctx, contents):
    """Unions several groups' contents into one content value.

    For a packager whose handles are runfiles contents -- the identity packager's
    merge is exactly this. Pass `entry.content` values and/or runfiles objects of
    your own; the result is itself a content value.

    Stays in the depset form when every part is one, so aggregating files-only
    groups still retains no runfiles object. A mixed union is the only thing in the
    protocol that must build one, because Bazel offers no way to merge a depset into
    a runfiles object other than ctx.runfiles().

    Args:
        ctx: The rule or aspect context.
        contents: List of content values (runfiles objects or depsets of File).

    Returns:
        A content value: a depset of File if every part was one, else a runfiles
        object.
    """
    files = []
    runfiles = []
    for content in contents:
        if type(content) == DEPSET_TYPE:
            files.append(content)
        else:
            _check_content("runfiles_groups.union", content)
            runfiles.append(content)
    if not runfiles:
        # Returns the sole part itself when there is only one.
        return depset(transitive = files)
    if files:
        runfiles.append(ctx.runfiles(transitive_files = depset(transitive = files)))
    if len(runfiles) == 1:
        return runfiles[0]

    # One merge_all over all parts, not a pairwise fold: a fold retains a two-slot
    # array per step and deepens the artifact DAG once per part.
    return runfiles[0].merge_all(runfiles[1:])
