# Lifecycle

Lifecycle provides cleanup composition. The category has no plugin leaves, activation entry, or runtime services.

## Public library

[Cleanup](cleanup.luau), `@lunette-plugins/lifecycle/cleanup`, runs every supplied operation in order and raises the collected failures after all operations run. One failure does not skip later resource releases.

The caller supplies the operations and invokes them at its own cleanup boundary. The library acquires no resources and maintains no teardown registry. Plugin effects and caller-owned resources still follow the [ownership contract](../../lunette-plugin/ownership.md); cleanup composition does not replace context registration.

[Shipped plugins and public imports](../README.md)
