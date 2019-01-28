load("@bazel_rules_purescript//purescript:purescript.bzl", "purescript_bundle", "purescript_library", "purescript_test")
load("@build_bazel_rules_nodejs//:defs.bzl", "nodejs_binary")
package(default_visibility = ["//visibility:public"])

generated_files = [
    "Ledger/Index.purs",
    "Ledger/Types.purs",
    "Ledger/Interval.purs",
    "Playground/Usecases.purs",
    "Playground/API.purs",
    "Playground/Server.purs",
    "Wallet/Graph.purs",
    "Wallet/API.purs",
    "Wallet/Emulator/Types.purs",
]

genrule(
    name = "psgenerator",
    srcs = [],
    outs = generated_files,
    cmd = "$(location //plutus-playground/plutus-playground-server:plutus-playground-server-app) psgenerator $(@D)",
    tools = ["//plutus-playground/plutus-playground-server:plutus-playground-server-app"],
)

purescript_library(
    name = "playground_purs",
    srcs = glob(["src/**/*.purs"]) + glob(["src/**/*.js"]) + glob(["generated/**/*.purs"]) + generated_files,
    deps = [
        "@purescript-ace-halogen//:pkg",
        "@purescript-ace//:pkg",
        "@purescript-aff//:pkg",
        "@purescript-argonaut-codecs//:pkg",
        "@purescript-console//:pkg",
        "@purescript-debug//:pkg",
        "@purescript-halogen-echarts//:pkg",
        "@purescript-halogen//:pkg",
        "@purescript-js-date//:pkg",
        "@purescript-maybe//:pkg",
        "@purescript-prelude//:pkg",
        "@purescript-remotedata//:pkg",
        "@purescript-servant-support//:pkg",
        "@purescript-transformers//:pkg",
        "@purescript-undefinable//:pkg",
    ],
)

purescript_bundle(
    name = "playground_bundle",
    srcs = ["//plutus-playground/plutus-playground-client/static:static_files"],
    config = "webpack-bazel.config.js",
    entry = "entry-bazel.js",
    node_modules = "@npm//:node_modules",
    webpack = "@npm//webpack-cli/bin:webpack-cli",
    deps = [":playground_purs"],
)

# // TODO: can we get rid of these runtime_deps?
# // Also we need to check that nix isn't building the whole project
# // just to get the dependencies!
purescript_test(
    name = "playground_test",
    srcs = glob(["test/**/*.purs"]) + glob(["test/**/*.js"]) + glob(["test/**/*.json"]),
    runtime_deps = ["@npm//ace-builds", "@npm//echarts"],
    main_module = "test/Test/Main.purs",
    deps = [
      "@purescript-test-unit//:pkg",
      "@purescript-node-fs//:pkg",
      ":playground_purs"
      ],
    node = "@nodejs//:node",
)

# nodejs_binary(
#     name = "webpack",
#     args = [
#         "--config webpack.config.js",
#         "--entry ./entry.js",
#         # "--watch",
#         # "--mode development",
#     ],
#     data = [
#       "webpack.config.js",
#       "//static:static_files",
#       "entry.js",
#     ],
#     entry_point = "webpack/bin/webpack.js",
#     node_modules = "@npm//:node_modules",
#     templated_args = ["--node_options=--preserve-symlinks"],
#     visibility = ["//visibility:public"],
# )

# rollup_bundle(
#   name = "rollup",
#   srcs = ["main.js"],
#   deps = ["//static:sass_main", ":playground_purs"],
#   entry_point = "main.js",
# )

# # Defines an application with default entrypoint (Main.main):
# purescript_app(
#     name = "playground",
#     srcs = glob(["src/**/*.purs"]) + glob(["src/**/*.js"]) + glob(["generated/**/*.purs"]),
#     entry_function = "main",
#     entry_module = "Main",
#     visibility = ["//visibility:public"],
#     deps = dependencies,
# )
