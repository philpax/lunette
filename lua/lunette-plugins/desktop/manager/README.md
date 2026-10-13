# Runtime plugin manager

`@lunette-plugins/desktop/manager` provides the shipped VR panel for inspecting and managing the running composition. The shipped desktop uses entry `desktop/manager`. It starts hidden and registers the Plugins action in the wrist menu.

The entry requires `lunette/composition`, `lunette/frame`, `lunette/ui`, `lunette/theme`, and `lunette/menu`. Its configuration schema and defaults are owned by [`config.luau`](config.luau). The panel uses the shared UI contract; another UI provider can render it. See [Runtime manager behavior](docs/runtime-manager-behavior.md) for inspection, refresh, and recovery boundaries.

[Runtime manager](../../../../docs/guide/runtime-manager.md) documents the VR workflow. The service lifecycle and snapshot guarantees remain in [Composition](../../../../docs/dev/lua-api.md#composition) and [Architecture](../../../../docs/dev/architecture.md#plugin-runtime). Tests: [`controller.luau`](tests/controller.luau), [`editor.luau`](tests/editor.luau), [`graph.luau`](tests/graph.luau), [`toolbar-layout.luau`](tests/toolbar-layout.luau), [`view.luau`](tests/view.luau), and [`vr-workflow.luau`](tests/vr-workflow.luau).

The manager's inspection limits are specified in [Runtime manager behavior](docs/runtime-manager-behavior.md#known-gaps).
