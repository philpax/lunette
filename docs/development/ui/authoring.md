# Authoring

Plugin authors write function components that receive props and return elements. The [React-like library guide](../../../lua/lunette-plugins/ui/react/README.md) owns the authoring API, and the [widget gallery](../../../dev/plugins/ui-gallery/) provides checked usage. The host accepts elements independently of the framework that produces them, as [Extension](extension.md#the-element-format) describes.

## An example

The widget gallery demonstrates components, stores, controlled values, overlays, and panel mounting. Examples stay with the checked source rather than a second copy of signatures and props here. Conditional content uses Luau control flow, lists use stable keys, and derived values can remain ordinary locals. Services publish observable stores so components do not poll them each frame.

## Mounting

Mounting binds a panel's root mount point and schedules the first render. It does not synchronously produce layout. `MountHandle:committed()` is a boolean query for whether the mount has committed, not a callback. A consumer that needs current geometry reads it after the host's scene update; mounting alone does not make bounds available.

## Elements and children

Named fields are props, and positional entries are children. `nil` and `false` render nothing but retain their slot position. Arrays flatten in place within their own key scope. A conditional child therefore does not change the identity of later positional children.

Explicit keys identify items among siblings and form inspection paths. Lists need stable keys rather than labels or indices that change when an item moves. Keys cannot contain the separators used by inspection paths. The [element contract](../../../lua/lunette-contracts/ui-host.luau) and [library guide](../../../lua/lunette-plugins/ui/react/README.md) own the precise child and props types.

The host validates a kind's props when they change. Validation errors are reported through the protected boundary; they do not establish that an invalid node is rejected or that its props are replaced with defaults.

## Components

A component re-renders when its state, its props, a context it reads, or a store it reads changes. Shallow props comparison ignores the identity of function-valued props while retaining the latest callback. A fresh table-valued prop still defeats shallow comparison. Frequently rendered components keep reusable tables stable where that matters.

## Hooks

Hooks follow call order. Conditional calls or a changed number of calls raise at runtime, because Luau does not statically check hook order. Effects receive the mount's effective owner for service resources and run their returned cleanup before replacement and on unmount.

`useEffect` and `useLayoutEffect` use the same implementation. They run after the library submits rendered elements, before the host computes layout. They do not provide current-layout reads, a post-layout callback, or a same-frame render loop for layout-dependent state. A ref can identify a retained node, but an effect must not assume its newly submitted geometry is already computed. The library has no `usePresentation` hook.

The library's source and guide own the available hooks and node-handle requests. A feature absent from those declarations is not supplied by the design terminology used elsewhere.

## Stores

A store publishes a current value and subscriptions. The library subscribes while the component is mounted and unsubscribes on unmount. Read-only store vocabulary belongs to the neutral contracts, so services do not depend on an authoring library to expose state.

Services whose state is shown in panels publish it through stores. Asynchronous requests also need observable progress when a panel must display their outcome. This avoids polling and gives non-UI consumers the same state.

## Scheduling

State and store changes schedule work for the next scene-update commit. Several changes before that commit can be rendered together. A change during pointer delivery does not trigger a second commit in that frame. [Architecture](architecture.md#data-flow) states the ordering and the consequences for input.

## Transient state

Hover, press, dragging, focus, scroll offset, and animation channels belong to retained nodes. They can change without re-running components. A component that needs a semantic result uses a callback and stores the application value it owns. Components do not need to mirror every hover or press transition.

## Controlled values

The component owns a controlled value. A kind can retain a transient draft while the user manipulates it and report changes through callbacks. The [standard kinds guide](../../../lua/lunette-plugins/ui/standard/README.md) and their checked implementations own each control's draft and commit behavior. The toolkit does not guarantee a general same-frame reconciliation or asynchronous acknowledgement protocol for every value control.

## Reload

Source reload discards local component state and remounts the consumer's tree during activation. Persistent application settings belong to their services. World-panel pose persistence belongs to the host's saved setting, not component state. Maintained arrangements remain deferred in [#71](https://github.com/philpax/lunette/issues/71).

## Comparison with other models

Signals make individual updates precise, but require reactive helpers for conditional content and lists. A store read outside a reactive closure can silently lose its subscription. Function components retain ordinary Luau control flow, and the session's small trees do not justify that authoring cost. Stores provide the observable service boundary without requiring signals as the component model.

Immediate-mode APIs suit small tools, but repeatedly execute widget logic and commonly derive identity from call order or labels. Dense session interfaces need retained identity for scrolling, overlays, and focus. The host still permits another authoring framework: the framework binds mount points and produces the same elements.

The library does not diff every panel on every frame. It renders scheduled component work. [Research](research.md#authoring-models) records the alternatives and their rationale.
