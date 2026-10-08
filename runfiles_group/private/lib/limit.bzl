"""Merging groups down to a maximum count."""

load("//runfiles_group/private/lib:constants.bzl", "INT_TYPE", "LABEL_TYPE", "STRING_TYPE")
load("//runfiles_group/private/lib:names.bzl", "described_name", "name_str", "sort_key")
load("//runfiles_group/private/lib:packager.bzl", "check_ctx", "check_ops")
load("//runfiles_group/private/lib:partial.bzl", "relabel")
load("//runfiles_group/private/lib:resolve.bzl", "disjoint_inputs", "make_merged")
load("//runfiles_group/private/lib:resolved.bzl", "ordered_groups", "raise_executable_group")

def _effective_weight(entry, default_weight):
    return entry.weight if entry.weight != None else default_weight

def _bucket_add(buckets, key, name):
    bucket = buckets.get(key)
    if bucket == None:
        buckets[key] = [name]
    else:
        bucket.append(name)

def _bucket_remove(buckets, key, name):
    bucket = buckets.get(key)
    if bucket != None and name in bucket:
        bucket.remove(name)

def _affinity_key(entry):
    return (entry.rank, entry.merge_affinity)

def _cheapest_pair(buckets, by_name, sort_keys, default_weight):
    """Returns the cheapest mergeable pair as (lighter, heavier), or None.

    Cost is the combined effective weight of the two lightest groups in a bucket.
    Ties break deterministically on (cost, rank, lighter, heavier).

    The two lightest are found with a linear two-minimum scan rather than by
    sorting: this runs once per merge step, and sorting allocated a decorator, a
    key tuple and a Starlark frame per element per bucket per step.

    Names are compared through `sort_keys`, which holds one form-discriminated
    token per group, built once by the caller. Comparing the names directly would
    fail as soon as a per-target (Label) group and a named (string) group land in
    the same bucket.
    """
    best = None
    for _key, names in buckets.items():
        if len(names) < 2:
            continue
        w1 = None
        n1 = None
        k1 = None
        w2 = None
        n2 = None
        k2 = None
        for name in names:
            entry = by_name.get(name)
            if entry == None:
                continue  # merged away in an earlier step
            weight = _effective_weight(entry, default_weight)
            key = sort_keys[name]
            if n1 == None or weight < w1 or (weight == w1 and key < k1):
                w2 = w1
                n2 = n1
                k2 = k1
                w1 = weight
                n1 = name
                k1 = key
            elif n2 == None or weight < w2 or (weight == w2 and key < k2):
                w2 = weight
                n2 = name
                k2 = key
        if n2 == None:
            continue
        candidate = (w1 + w2, by_name[n1].rank, k1, k2)
        if best == None or candidate < best[0]:
            best = (candidate, n1, n2)
    if best == None:
        return None
    return (best[1], best[2])

def limit(ctx, ops, resolved, *, max_groups, default_weight = 0, merged_group_name = None, executable_group_last = True):
    """Merges groups until at most max_groups remain.

    finalize(..., max_groups = N) is this, applied to finalize()'s own result. Call
    it separately when the limit depends on what finalize() returned -- on whether
    an executable_group survived the hint transforms, say. Merges stay within a
    rank and never touch a do_not_merge group, prefer pairs that share a
    merge_affinity ("" is the shared "no affinity" bucket), and then the two
    lightest by weight. Each merged group is built with one ops.merge call.

    Args:
        ctx: The rule or aspect context, handed to ops.merge.
        ops: From packager_ops(): the same ops the groups were finalized with.
        resolved: The result of finalize() (or of an earlier limit()).
        max_groups: Maximum number of groups to leave. The caller MUST check
            group_count: do_not_merge and rank constraints can make it
            unreachable.
        default_weight: Weight to assume for groups whose weight is None.
        merged_group_name: Optional function
            (lighter_name, lighter_weight, heavier_name, heavier_weight) -> name
            naming a merged group. If None, the heavier group's name is kept.
        executable_group_last: If True, the executable group takes the highest rank
            of all present groups before merging and comes last, as in finalize().
            Pass the value finalize() was called with.

    Returns:
        struct(groups, by_name, executable_group, group_count).
    """
    check_ctx("runfiles_groups.limit", ctx)
    check_ops("runfiles_groups.limit", ops)
    if type(max_groups) != INT_TYPE or max_groups < 0:
        fail("runfiles_groups.limit: max_groups must be an int >= 0, got ", repr(max_groups))
    if type(default_weight) != INT_TYPE or default_weight < 0:
        fail("runfiles_groups.limit: default_weight must be an int >= 0, got ", repr(default_weight))
    executable_group = resolved.executable_group
    by_name = resolved.by_name
    if executable_group_last:
        by_name = raise_executable_group(by_name, executable_group)
    if len(by_name) <= max_groups:
        return struct(
            groups = ordered_groups(by_name, executable_group, executable_group_last),
            by_name = by_name,
            executable_group = executable_group,
            group_count = len(by_name),
        )

    by_name = dict(by_name)

    # Canonical forms of the surviving names, so that a merged_group_name callback
    # returning the string spelling of a Label-named group is caught. The raw
    # `out_name in by_name` test below cannot see that: the two are different keys
    # that render identically, and overwriting would drop a group's runfiles.
    name_strs = {}
    if merged_group_name != None:
        for name in by_name:
            name_strs[name_str(name)] = name

    # The groups of a merged group are accumulated and handed to ops.merge once at
    # the end, so a packager builds each merged group once rather than once per
    # merge step -- and the identity packager's union never deepens the artifact
    # DAG pairwise.
    parts = {}

    # Buckets are built once and patched incrementally: a merge only touches the
    # two groups involved and their replacement. sort_keys holds one comparison
    # token per group so tie-breaking never compares a Label against a string.
    by_rank_affinity = {}
    by_rank = {}
    sort_keys = {}
    for name, entry in by_name.items():
        if entry.do_not_merge:
            # Never bucketed, so never compared: no sort key needed. It cannot
            # become bucketed later either -- the only name added below is
            # out_name, and a collision with an existing group already fails.
            continue
        sort_keys[name] = sort_key(name)
        _bucket_add(by_rank_affinity, _affinity_key(entry), name)
        _bucket_add(by_rank, entry.rank, name)

    for _ in range(len(by_name)):
        if len(by_name) <= max_groups:
            break

        # Tier 1: prefer pairs sharing a (rank, merge_affinity).
        # Tier 2: fall back to the cheapest same-rank pair across affinities.
        pair = _cheapest_pair(by_rank_affinity, by_name, sort_keys, default_weight)
        if pair == None:
            pair = _cheapest_pair(by_rank, by_name, sort_keys, default_weight)
        if pair == None:
            break

        lighter, heavier = pair
        light = by_name.pop(lighter)
        heavy = by_name.pop(heavier)
        _bucket_remove(by_rank_affinity, _affinity_key(light), lighter)
        _bucket_remove(by_rank_affinity, _affinity_key(heavy), heavier)
        _bucket_remove(by_rank, light.rank, lighter)
        _bucket_remove(by_rank, heavy.rank, heavier)

        light_weight = _effective_weight(light, default_weight)
        heavy_weight = _effective_weight(heavy, default_weight)
        if merged_group_name != None:
            out_name = merged_group_name(lighter, light_weight, heavier, heavy_weight)
            if type(out_name) != LABEL_TYPE and (type(out_name) != STRING_TYPE or not out_name):
                fail(
                    "runfiles_groups.limit: merged_group_name must return a Label or a non-empty string, got ",
                    repr(out_name),
                )

            # Silently overwriting a third, untouched group would drop its
            # runfiles and violate its do_not_merge. Compared in canonical form so
            # that a string spelling of a Label-named group is caught too.
            out_str = name_str(out_name)
            existing = name_strs.get(out_str)
            if existing != None:
                fail("runfiles_groups.limit: merged_group_name({}, {}) returned {}, which is an existing group ({})".format(
                    described_name(lighter),
                    described_name(heavier),
                    described_name(out_name),
                    described_name(existing),
                ))
        else:
            out_name = heavier

        acc = parts.pop(heavier, None)
        if acc == None:
            acc = [heavy]
        light_parts = parts.pop(lighter, None)
        if light_parts == None:
            acc.append(light)
        else:
            acc.extend(light_parts)
        parts[out_name] = acc

        merged = relabel(heavy, {
            "name": out_name,
            "do_not_merge": False,
            "weight": light_weight + heavy_weight,
        })
        by_name[out_name] = merged
        if merged_group_name != None:
            name_strs.pop(name_str(lighter), None)
            name_strs.pop(name_str(heavier), None)
            name_strs[out_str] = out_name
        sort_keys[out_name] = sort_key(out_name)
        _bucket_add(by_rank_affinity, _affinity_key(merged), out_name)
        _bucket_add(by_rank, merged.rank, out_name)
        if executable_group == lighter or executable_group == heavier:
            executable_group = out_name

    for name, acc in parts.items():
        # Groups of different names can still share a raw piece -- one binary
        # re-labeled it into a repository's group, another kept it per target -- so
        # the inputs go through the same disjoint decomposition as a name collision.
        merged = by_name[name]
        by_name[name] = make_merged(ctx, ops, name, disjoint_inputs(acc), merged, merged.weight)

    return struct(
        groups = ordered_groups(by_name, executable_group, executable_group_last),
        by_name = by_name,
        executable_group = executable_group,
        group_count = len(by_name),
    )
