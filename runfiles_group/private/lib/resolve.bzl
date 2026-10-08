"""Combining partials that share a group name."""

load("//runfiles_group/private/lib:constants.bzl", "NO_PIECES")
load("//runfiles_group/private/lib:partial.bzl", "check_partial", "combine", "max_weight")
load("//runfiles_group/private/providers:runfiles_group_partial_info.bzl", "RunfilesGroupPartialInfo")

def piece_key(raw):
    """A raw piece's identity, ignoring metadata.

    Re-labeled copies of one piece carry different names or ranks but the same
    contributor and handle. Merged partials record their pieces by this key.

    Args:
        raw: A raw RunfilesGroupPartialInfo (one without pieces).

    Returns:
        (contributor, handle).
    """
    return (raw.contributor, raw.handle)

def _coverage(partial):
    """dict of piece key -> True, for everything a partial's handle holds."""
    if partial.pieces:
        return {key: True for key in partial.pieces.to_list()}
    return {piece_key(partial): True}

def _coverage_order(entry):
    # entry is (partial, coverage). Larger coverage first; then by contributors,
    # which are always Labels on raw pieces; remaining ties keep depset order.
    coverage = entry[1]
    return (-len(coverage), sorted([key[0] for key in coverage]))

def _piece_as_input(part, key):
    """A raw piece of a merged partial, as a merge input on its own.

    A merged partial records its pieces by key, so the piece is rebuilt from its
    contributor and handle, with the group's metadata. Its own weight is not
    recorded, so it contributes none.
    """
    return RunfilesGroupPartialInfo(
        name = part.name,
        contributor = key[0],
        handle = key[1],
        pieces = NO_PIECES,
        kind = part.kind,
        rank = part.rank,
        do_not_merge = part.do_not_merge,
        weight = None,
        merge_affinity = part.merge_affinity,
    )

def disjoint_inputs(parts):
    """Turns parts into merge inputs whose coverages are pairwise disjoint.

    Greedy, largest coverage first: a part is taken whole if none of its pieces is
    taken yet, and otherwise contributes only its pieces that are not, each as a
    merge input of its own.

    Args:
        parts: Partials, none of which covers another.

    Returns:
        The merge inputs: a list of RunfilesGroupPartialInfo.
    """
    ordered = sorted([(part, _coverage(part)) for part in parts], key = _coverage_order)
    taken = {}
    inputs = []
    for part, coverage in ordered:
        if not [key for key in coverage if key in taken]:
            inputs.append(part)
            taken.update(coverage)
            continue
        for key in coverage:
            if key not in taken:
                taken[key] = True
                inputs.append(part if not part.pieces else _piece_as_input(part, key))
    return inputs

def _inputs_weight(inputs):
    """Max within one raw contributor (its pieces overlap), summed across inputs."""
    per_contributor = {}
    merged = None
    for part in inputs:
        if part.weight == None:
            continue
        if part.pieces:
            merged = (merged or 0) + part.weight
        else:
            per_contributor[part.contributor] = max(per_contributor.get(part.contributor, 0), part.weight)
    if not per_contributor:
        return merged
    weight = merged or 0
    for value in per_contributor.values():
        weight += value
    return weight

def make_merged(ctx, ops, name, inputs, metadata, weight):
    """A merged partial built by ops.merge from disjoint inputs.

    Its pieces reference the merged inputs' pieces rather than copying them, so a
    group merged again further up costs O(inputs), not O(pieces).

    Args:
        ctx: The rule or aspect context, handed to ops.merge.
        ops: From packager_ops().
        name: The merged group's name.
        inputs: The merge inputs, from disjoint_inputs().
        metadata: A partial whose kind, rank, do_not_merge and merge_affinity the
            merged group takes.
        weight: The merged group's weight.

    Returns:
        A merged RunfilesGroupPartialInfo.
    """
    return RunfilesGroupPartialInfo(
        name = name,
        contributor = None,
        handle = ops.merge(ctx, name, inputs),
        pieces = depset(
            [piece_key(part) for part in inputs if not part.pieces],
            transitive = [part.pieces for part in inputs if part.pieces],
        ),
        kind = metadata.kind,
        rank = metadata.rank,
        do_not_merge = metadata.do_not_merge,
        weight = weight,
        merge_affinity = metadata.merge_affinity,
    )

def resolve_name(ctx, ops, name, parts):
    """Resolves the distinct partials of one group name to a single partial.

    1. Identical partials (equal values) were already collapsed by the caller --
       a depset, or a dict -- so the same instance is forwarded once.
    2. A partial whose raw pieces another partial already holds is dropped: the
       same piece reached along two paths, possibly re-labeled differently on
       each, or the same pieces merged at two different targets.
    3. One partial left: it is forwarded, handle untouched.
    4. Otherwise ops.merge combines them, from inputs with pairwise disjoint
       coverage (see disjoint_inputs), so no piece is merged twice.

    Metadata combines order-independently over every partial: min rank, or of
    do_not_merge, the non-empty kind and merge_affinity (lexicographic min if
    both are set). Weight is the max over the partials when one is kept, and the
    sum over the merge inputs -- max within one contributor -- when merged.

    Args:
        ctx: The rule or aspect context, handed to ops.merge.
        ops: From packager_ops().
        name: The group name all of `parts` share.
        parts: The distinct partials of that name; at least two.

    Returns:
        One RunfilesGroupPartialInfo for the name.
    """
    metadata = parts[0]
    weight = parts[0].weight
    for part in parts[1:]:
        weight = max_weight(weight, part.weight)
        metadata = combine(metadata, part, weight)

    kept = []
    kept_coverage = []
    for part, coverage in sorted([(part, _coverage(part)) for part in parts], key = _coverage_order):
        covered = False
        for other in kept_coverage:
            if not [key for key in coverage if key not in other]:
                covered = True
                break
        if not covered:
            kept.append(part)
            kept_coverage.append(coverage)

    if len(kept) == 1:
        return combine(kept[0], metadata, weight)
    inputs = disjoint_inputs(kept)
    return make_merged(ctx, ops, name, inputs, metadata, _inputs_weight(inputs))

def fold(ctx, ops, partials):
    """Folds partials into a dict of group name -> one partial per name.

    `partials` comes from a flattened depset, so equal partials appear once.
    Names with a single partial are handed through untouched; the others go
    through resolve_name.

    Args:
        ctx: The rule or aspect context, handed to ops.merge.
        ops: From packager_ops().
        partials: List of RunfilesGroupPartialInfo.

    Returns:
        dict of group name -> RunfilesGroupPartialInfo.
    """
    by_name = {}
    for partial in partials:
        check_partial("runfiles_groups.finalize", partial)
        parts = by_name.get(partial.name)
        if parts == None:
            by_name[partial.name] = [partial]
        else:
            parts.append(partial)
    folded = {}
    for name, parts in by_name.items():
        folded[name] = parts[0] if len(parts) == 1 else resolve_name(ctx, ops, name, parts)
    return folded
