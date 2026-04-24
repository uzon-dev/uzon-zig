// Test entry point. Imports the library root (which pulls in every
// library module) and the test-only files. Build as `zig build test` —
// the library artifact builds from `root.zig` and does not include
// these test modules.

comptime {
    _ = @import("root.zig");
    _ = @import("eval_test.zig");
    _ = @import("conformance.zig");
}
