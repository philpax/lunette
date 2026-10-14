# Lifecycle

Lifecycle provides cleanup composition without plugin leaves, an activation entry, or runtime services. [Cleanup](cleanup.luau), `@lunette-plugins/lifecycle/cleanup`, runs every supplied operation in order and raises collected failures afterward, so one failure does not skip later releases.

The caller supplies operations and invokes them at its cleanup boundary. The library acquires no resources and maintains no teardown registry. The [ownership contract](../../lunette-plugin/ownership.md) still governs plugin effects and caller-owned resources; composition does not replace context registration. [Shipped plugins](../README.md) defines public imports.
