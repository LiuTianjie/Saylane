# Vendored MLXASR runtime

Source: https://github.com/ontypehq/mlx-swift-asr
Revision: f8ea5e6e76824eae903580fcfab0ef15e207b479
License: MIT (see LICENSE).

Only Sources and the license are vendored; NO model weights or test audio are included.
The upstream manifest follows `main` branches, which currently resolve to a Swift 6.3-only
MLX release. This local manifest pins MLX 0.31.4, MLXLMCommon 2.31.3, and
swift-transformers 1.2.0 for the project's Xcode 26.2 / Swift 6.2 toolchain.
Source changes, if any, must be documented here.

2026-09-08 memory-lifetime patch in Qwen3ASRSTT.swift:
- configureMemoryBudget caps the active backend's reusable allocator cache at 128 MiB.
- flushMemoryPool synchronizes GPU work, sets cache limit to zero and clears unused buffers.
- trimMemoryPool clears per-utterance temporaries after inference locals have been destroyed.
- memoryUsage exposes counters for explicitly requested diagnostics only.
