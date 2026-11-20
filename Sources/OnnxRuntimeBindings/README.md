# ONNX Runtime's Objective-C bindings

The Objective-C layer the Mac app's stem separation (`Sources/StemSplit`, PRD § 12) talks to ONNX Runtime through.

These files are a copy, unmodified, of the `objectivec` folder of Microsoft's Swift package
`microsoft/onnxruntime-swift-package-manager`, version 1.24.2 (commit b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2),
without its tests, its docs and the training API. MIT license, Microsoft: see `LICENSE`.

They are kept here because that repository, like `microsoft/onnxruntime`, was no longer reachable on GitHub from
18 November 2026, which broke every build from scratch. The ONNX Runtime library itself is still downloaded at
build time from Microsoft (`download.onnxruntime.ai`, same version, same checksum): see `Package.swift`.
