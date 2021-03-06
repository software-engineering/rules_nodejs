# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""js_library can be used to expose and share any library package.

DO NOT USE - this is not fully designed yet and it is a work in progress.
"""

load(
    "//:providers.bzl",
    "DeclarationInfo",
    "JSModuleInfo",
    "JSNamedModuleInfo",
    "LinkablePackageInfo",
    "NpmPackageInfo",
    "declaration_info",
    "js_module_info",
    "js_named_module_info",
)
load(
    "//third_party/github.com/bazelbuild/bazel-skylib:rules/private/copy_file_private.bzl",
    "copy_bash",
    "copy_cmd",
)

_ATTRS = {
    "amd_names": attr.string_dict(
        doc = """Non-public legacy API, not recommended to make new usages.
        See documentation on AmdNamesInfo""",
    ),
    "deps": attr.label_list(),
    "is_windows": attr.bool(
        doc = "Internal use only. Automatically set by macro",
        mandatory = True,
    ),
    # module_name for legacy ts_library module_mapping support
    # which is still being used in a couple of tests
    # TODO: remove once legacy module_mapping is removed
    "module_name": attr.string(
        doc = "Internal use only. It will be removed soon.",
    ),
    "named_module_srcs": attr.label_list(
        doc = """Non-public legacy API, not recommended to make new usages.
        A subset of srcs that are javascript named-UMD or
        named-AMD for use in rules such as ts_devserver.
        They will be copied into the package bin folder if needed.""",
        allow_files = True,
    ),
    "package_name": attr.string(),
    "srcs": attr.label_list(allow_files = True),
}

AmdNamesInfo = provider(
    doc = "Non-public API. Provides access to the amd_names attribute of js_library",
    fields = {"names": """Mapping from require module names to global variables.
        This allows devmode JS sources to load unnamed UMD bundles from third-party libraries."""},
)

def write_amd_names_shim(actions, amd_names_shim, targets):
    """Shim AMD names for UMD bundles that were shipped anonymous.

    These are collected from our bootstrap deps (the only place global scripts should appear)

    Args:
      actions: starlark rule execution context.actions
      amd_names_shim: File where the shim is written
      targets: dependencies to be scanned for AmdNamesInfo providers
    """

    amd_names_shim_content = """// GENERATED by js_library.bzl
// Shim these global symbols which were defined by a bootstrap script
// so that they can be loaded with named require statements.
"""
    for t in targets:
        if AmdNamesInfo in t:
            for n in t[AmdNamesInfo].names.items():
                amd_names_shim_content += "define(\"%s\", function() { return %s });\n" % n
    actions.write(amd_names_shim, amd_names_shim_content)

def _impl(ctx):
    input_files = ctx.files.srcs + ctx.files.named_module_srcs
    all_files = []
    typings = []
    js_files = []
    named_module_files = []
    include_npm_package_info = False

    for idx, f in enumerate(input_files):
        file = f

        # copy files into bin if needed
        if file.is_source and not file.path.startswith("external/"):
            dst = ctx.actions.declare_file(file.basename, sibling = file)
            if ctx.attr.is_windows:
                copy_cmd(ctx, file, dst)
            else:
                copy_bash(ctx, file, dst)

            # re-assign file to the one now copied into the bin folder
            file = dst

        # register js files
        if file.basename.endswith(".js") or file.basename.endswith(".js.map") or file.basename.endswith(".json"):
            js_files.append(file)

        # register typings
        if (
            (
                file.path.endswith(".d.ts") or
                file.path.endswith(".d.ts.map") or
                # package.json may be required to resolve "typings" key
                file.path.endswith("/package.json")
            ) and
            # exclude eg. external/npm/node_modules/protobufjs/node_modules/@types/node/index.d.ts
            # these would be duplicates of the typings provided directly in another dependency.
            # also exclude all /node_modules/typescript/lib/lib.*.d.ts files as these are determined by
            # the tsconfig "lib" attribute
            len(file.path.split("/node_modules/")) < 3 and file.path.find("/node_modules/typescript/lib/lib.") == -1
        ):
            typings.append(file)

        # auto detect if it entirely an npm package
        #
        # NOTE: it probably can be removed once we support node_modules from more than
        # a single workspace
        if file.is_source and file.path.startswith("external/"):
            # We cannot always expose the NpmPackageInfo as the linker
            # only allow us to reference node modules from a single workspace at a time.
            # Here we are automatically decide if we should or not including that provider
            # by running through the sources and check if we have a src coming from an external
            # workspace which indicates we should include the provider.
            include_npm_package_info = True

        # ctx.files.named_module_srcs are merged after ctx.files.srcs
        if idx >= len(ctx.files.srcs):
            named_module_files.append(file)

        # every single file on bin should be added here
        all_files.append(file)

    files_depset = depset(all_files)
    js_files_depset = depset(js_files)
    named_module_files_depset = depset(named_module_files)
    typings_depset = depset(typings)

    files_depsets = [files_depset]
    npm_sources_depsets = [files_depset]
    direct_sources_depsets = [files_depset]
    direct_named_module_sources_depsets = [named_module_files_depset]
    typings_depsets = [typings_depset]
    js_files_depsets = [js_files_depset]

    for dep in ctx.attr.deps:
        if NpmPackageInfo in dep:
            npm_sources_depsets.append(dep[NpmPackageInfo].sources)
        else:
            if JSModuleInfo in dep:
                js_files_depsets.append(dep[JSModuleInfo].direct_sources)
                direct_sources_depsets.append(dep[JSModuleInfo].direct_sources)
            if JSNamedModuleInfo in dep:
                direct_named_module_sources_depsets.append(dep[JSNamedModuleInfo].direct_sources)
                direct_sources_depsets.append(dep[JSNamedModuleInfo].direct_sources)
            if DeclarationInfo in dep:
                typings_depsets.append(dep[DeclarationInfo].declarations)
                direct_sources_depsets.append(dep[DeclarationInfo].declarations)
            if DefaultInfo in dep:
                files_depsets.append(dep[DefaultInfo].files)

    providers = [
        DefaultInfo(
            files = depset(transitive = files_depsets),
            runfiles = ctx.runfiles(
                files = all_files,
                transitive_files = depset(transitive = files_depsets),
            ),
        ),
        AmdNamesInfo(names = ctx.attr.amd_names),
        js_module_info(
            sources = depset(transitive = js_files_depsets),
            deps = ctx.attr.deps,
        ),
        js_named_module_info(
            sources = depset(transitive = direct_named_module_sources_depsets),
            deps = ctx.attr.deps,
        ),
    ]

    if ctx.attr.package_name:
        path = "/".join([p for p in [ctx.bin_dir.path, ctx.label.workspace_root, ctx.label.package] if p])
        providers.append(LinkablePackageInfo(
            package_name = ctx.attr.package_name,
            path = path,
            files = depset(transitive = direct_sources_depsets),
        ))

    if include_npm_package_info:
        workspace_name = ctx.label.workspace_name if ctx.label.workspace_name else ctx.workspace_name
        providers.append(NpmPackageInfo(
            direct_sources = depset(transitive = direct_sources_depsets),
            sources = depset(transitive = npm_sources_depsets),
            workspace = workspace_name,
        ))

    # Don't provide DeclarationInfo if there are no typings to provide.
    # Improves error messaging downstream if DeclarationInfo is required.
    if len(typings) or len(typings_depsets) > 1:
        providers.append(declaration_info(
            declarations = depset(transitive = typings_depsets),
            deps = ctx.attr.deps,
        ))

    return providers

_js_library = rule(
    implementation = _impl,
    attrs = _ATTRS,
)

def js_library(
        name,
        srcs = [],
        package_name = None,
        deps = [],
        **kwargs):
    """Groups JavaScript code so that it can be depended on like an npm package.

    ### Behavior

    This rule doesn't perform any build steps ("actions") so it is similar to a `filegroup`.
    However it produces several Bazel "Providers" for interop with other rules.

    > Compare this to `pkg_npm` which just produces a directory output, and therefore can't expose individual
    > files to downstream targets and causes a cascading re-build of all transitive dependencies when any file
    > changes

    These providers are:
    - DeclarationInfo so this target can be a dependency of a TypeScript rule
    - NpmPackageInfo so this target can interop with rules that expect third-party npm packages
    - LinkablePackageInfo for use with our "linker" that makes this package importable (similar to `npm link`)
    - JsModuleInfo so rules like bundlers can collect the transitive set of .js files

    `js_library` also copies any source files into the bazel-out folder.
    This is the same behavior as the `copy_to_bin` rule.
    By copying the complete package to the output tree, we ensure that the linker (our `npm link` equivalent)
    will make your source files available in the node_modules tree where resolvers expect them.
    It also means you can have relative imports between the files
    rather than being forced to use Bazel's "Runfiles" semantics where any program might need a helper library
    to resolve files between the logical union of the source tree and the output tree.

    ### Usage

    `js_library` is intended to be used internally within Bazel, such as between two libraries in your monorepo.

    > Compare this to `pkg_npm` which is intended to publish your code for external usage outside of Bazel, like
    > by publishing to npm or artifactory.

    The typical example usage of `js_library` is to expose some sources with a package name:

    ```python
    ts_project(
        name = "compile_ts",
        srcs = glob(["*.ts"]),
    )

    js_library(
        name = "my_pkg",
        # Code that depends on this target can import from "@myco/mypkg"
        package_name = "@myco/mypkg",
        # Consumers might need fields like "main" or "typings"
        srcs = ["package.json"],
        # The .js and .d.ts outputs from above will be part of the package
        deps = [":compile_ts"],
    )
    ```

    To help work with "named AMD" modules as required by `ts_devserver` and other Google-style "concatjs" rules,
    `js_library` has some undocumented advanced features you can find in the source code or in our examples.
    These should not be considered a public API and aren't subject to our usual support and semver guarantees.

    Args:
        name: a name for the target
        srcs: the list of files that comprise the package
        package_name: the name it will be imported by. Should match the "name" field in the package.json file.
        deps: other targets that provide JavaScript code
        **kwargs: used for undocumented legacy features
    """

    # Undocumented features
    amd_names = kwargs.pop("amd_names", {})
    module_name = kwargs.pop("module_name", None)
    named_module_srcs = kwargs.pop("named_module_srcs", [])

    if module_name:
        fail("use package_name instead of module_name in target //%s:%s" % (native.package_name(), name))
    if kwargs.pop("is_windows", None):
        fail("is_windows is set by the js_library macro and should not be set explicitly")

    _js_library(
        name = name,
        amd_names = amd_names,
        srcs = srcs,
        named_module_srcs = named_module_srcs,
        deps = deps,
        package_name = package_name,
        # module_name for legacy ts_library module_mapping support
        # which is still being used in a couple of tests
        # TODO: remove once legacy module_mapping is removed
        module_name = package_name,
        is_windows = select({
            "@bazel_tools//src/conditions:host_windows": True,
            "//conditions:default": False,
        }),
        **kwargs
    )
