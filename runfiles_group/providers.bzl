"""Public API for runfiles group providers."""

load("//runfiles_group/private/providers:runfiles_group_describer_info.bzl", _RunfilesGroupDescriberInfo = "RunfilesGroupDescriberInfo")
load("//runfiles_group/private/providers:runfiles_group_info.bzl", _RunfilesGroupInfo = "RunfilesGroupInfo")
load("//runfiles_group/private/providers:runfiles_group_partial_info.bzl", _RunfilesGroupPartialInfo = "RunfilesGroupPartialInfo")
load("//runfiles_group/private/providers:runfiles_group_transform_info.bzl", _RunfilesGroupTransformInfo = "RunfilesGroupTransformInfo")

RunfilesGroupDescriberInfo = _RunfilesGroupDescriberInfo
RunfilesGroupInfo = _RunfilesGroupInfo
RunfilesGroupPartialInfo = _RunfilesGroupPartialInfo
RunfilesGroupTransformInfo = _RunfilesGroupTransformInfo
