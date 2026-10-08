# The Lua API

## Two roots

```lua
local lunette = require '@lunette'        -- native mechanism.
local plugin = require '@lunette-plugin'  -- the plugin facade, written in Lua.
```

The two have separate responsibilities. `lunette` exposes native mechanism for surfaces, textures, sinks, seats, outputs, processes, layers, clipboard, and capture. Policy is Lua: the plugin facade, its neutral contracts, the built-in plugins, and the desktop that composes them have separate roots under `@lunette-plugin`, `@lunette-contracts`, `@lunette-plugins`, and `@lunette-desktop`.

The plugin facade does not replace the native root. It provides lifecycle and service wiring for typed Lua components. The native `lunette` API remains usable without the plugin providers. The Lua roots use public APIs and contracts; they do not access private native state.

[Module roots](build-and-development.md#module-roots) lists the aliases and their runtime resolution, and [the standard library's module roots](stdlib.md#module-roots) states how a relative require, `./`, `../`, or `@self`, resolves against the requiring file. The runtime and static checker run in separate processes. Starting lunette does not run the static checker.

## The config

`~/.config/lunette/main.luau` is a LÖVR project. It defines `lovr.draw`, `lovr.update`, and the other LÖVR callbacks, and it `require`s lunette's libraries like any other module. Nothing is hidden, and no loop runs on the user's behalf without being defined in this file.

If this file does not exist, `$SYSCONFDIR/xdg/lunette/main.luau` is used directly. This matches awesome's approach, and avoids stale copies of a configuration the user never edited. `lunette --dump-config` produces a copy for the user to start editing.

The shipped configuration runs the `@lunette-desktop` composition of the built-in providers and desktop consumers under `@lunette-plugins`. A configuration that uses `lunette` alone, or only some of the providers, is supported.

## Plugin authoring

[Writing plugins](../guide/writing-plugins.md) walks through writing a plugin for a configuration; this section and the ones after it are the specification it follows.

`require '@lunette-plugin'` provides the typed authoring facade. A contract module defines a service type, declares the contract with `plugin.capability`, and exports the resulting capability. The service type is named by explicit type instantiation, and the fields name the contract and its schema:

```lua
local capability = plugin.capability<<Service>> { name = 'example/service', schema = 1 }
```

The name is authority-qualified and the schema is a positive integer. Its service type describes the methods and fields that callers may use. The capability wrapper is frozen and binds to one native token when it is created, so the facade never hands out an unbound token. Declarations use that exact wrapper, and a Lua state cannot declare the same name and schema twice in one epoch. Contract vocabulary modules can hold shared types without creating a runtime dependency between service implementations.

A definition is a table of named fields. `name` labels the definition in logs, reports, and diagnostics. `requires` and `provides` declare capabilities by field name and default to empty. `init` is the initializer, which receives a `Context`, typed configuration, and init-only `Publisher`:

```lua
return plugin.define {
  name = 'my-layout',
  requires = { tags = tags.capability },
  provides = { layout = myLayout.capability },
  init = function(context: plugin.Context, _config: {}, publish: plugin.Publisher)
    local service: tags.Service = context:require(tags.capability)
    publish:provide(myLayout.capability, create(context, service))
  end,
}
```

The facade rejects a spec with a field outside `name`, `requires`, `provides`, and `init`, a `name` that is not a non-empty string, an `init` that is not a function, and a `requires` or `provides` that is not a table. `plugin.capability` rejects a field outside `name` and `schema`, a `name` that is not a non-empty string, and a `schema` that is not a positive integer. Each error names the problem and points at the call. Definition names need not be unique.

`Context:require<T>(capability)` has the capability's service type. `Publisher:provide<T>(capability, value)` accepts the matching service type. The publisher is valid only while that initializer is active. `Definition<C>` carries configuration type `C`; service types belong to capabilities, not to a mapped services record. Raw `plugin.define` infers `C` from the initializer and does not validate configuration values. Configured providers and consumers derive their input and resolved types from a configuration descriptor and validate through it, as [Provider modules](#provider-modules) states. A capability's service type is fixed by the explicit instantiation. A call that omits it produces a `Capability<unknown>`, which Luau accepts without an error of its own and through which no service read is checked, so `lunette check` reports every call whose result is a capability with an unknown service type.

Luau checks local service shapes, methods, and configuration annotations in source modules. Runtime wiring remains a separate concern. The runtime matches authority-qualified contract name and exact schema. A required capability without a provider does not activate its consumer, and neither does a provider of another schema of the same name. The runtime rejects undeclared capability access, undeclared or duplicate provisions, missing or nil provided fields, extra fields, and calls to an expired publisher. A membership error names the contract and the plugin code that made the call. It does not inspect service table shapes or validate configuration values against Luau types.

The initializer stages all provided values. The native runtime publishes them as one provider generation only after the initializer succeeds and the graph confirms its bindings remain valid. If initialization fails or is cancelled, the provider publishes nothing and acquired effects are rolled back. An error an initializer raises keeps its own position and traceback. Plugin callbacks are synchronous and do not yield.

### Context operations

`Context:effect` registers a resource and its inverse with the activation. If the activation is cancelled while the acquisition runs, the call raises and the inverse is not left registered: it runs at once. Disposing an effect whose activation, instance, or runtime has ended does nothing. An inverse can read its retained services but cannot acquire resources or create children. Successful explicit disposal restores resource authority only if no inverse has failed in the activation. Catching a nested disposal failure does not restore that authority.

`Context:on { event = subscribe, run = handler }` registers an event subscription as an effect. `event` is a function that takes a handler and answers the function that cancels it, which is the shape of every `lunette.on*` event, so `context:on { event = lunette.onWindowOpened, run = handler }` subscribes for the life of the activation. A field other than `event` and `run` raises. The subscription is cancelled when the activation ends, and a handler that is reached after the activation has ended but before the cancellation runs, such as an error reported during cleanup, is not called.

`Context:child` installs a child instance owned by the current activation and enables it, so the child loads with its parent and is retired when the activation that installed it ends. `Context:active` checks whether the activation is live.

`Context:checkOwner` checks that a caller is a live context bound to the owning provider's current generation, and raises otherwise. `Context:owns` answers the same question with a boolean. `Context:acquire(owner, acquire)` checks the owner and registers the resource with the owner's lifetime, which is the common shape of an owner-scoped provider method. `Context:resource(owner, acquire)` accepts an acquisition that returns a value and its inverse, and returns the value and effect only after registration succeeds. The owner can be the context itself or a checked dependent caller. Cancellation runs the returned inverse and raises without returning the value. An acquisition that raises before returning an inverse must release its partial resources itself. The adapter accepts only a context it wrapped as an owner, so passing something else as the owner by mistake raises rather than registering a resource nothing will release.

`plugin.ownerLabel(owner)` returns the definition name registered for an owner, or `unregistered owner` when no label is registered. It reads diagnostic metadata without invoking the owner's callbacks or methods. The label is not an identity or a liveness check and grants no resource authority.

### Services

A consumer receives each provision through a frozen view rather than the provider's own value. Every consumer of one provider generation receives the same view. Reading a field, calling a method, iterating, or calling a callable provision through the view raises an error naming the contract once the provider's activation has ended, including through a reference the consumer kept past its own activation. The view stays readable while the provider's activation is published and has not begun unloading, whatever the provider's resource authority: a provider whose explicit disposal failed acquires nothing more but keeps serving until it unloads. Assigning a field raises at any time. A method receives the view as `self`, so a provider reads its own fields through `self` and keeps mutable state in its own locals. The view checks a method when it is read rather than wrapping the call, so it adds no stack frame and a provider error raised at level 2 still names the consumer's call site. A function value read while the provider was live remains callable afterwards, as does any object a method returned; those objects carry their own `dead` state. `pairs` and `#` see an empty table; a service is read by field or iterated with generalized iteration.

### Confinement

A plugin changes state outside itself only through its context. Every resource, subscription, and child an initializer creates is registered through `Context:effect`, `Context:on`, `Context:child`, or an owner-scoped provider method, so unloading the instance reverts it. A direct `lunette.onWindowOpened` call in an initializer is not tracked: the subscription survives instance reload and disable, and a reloaded instance subscribes a second time. Source reload clears native subscriptions, which hides the leak only until the next instance reload.

Effects are flat. An effect created inside another effect's acquisition is registered with the context it was created through, as a sibling of the outer effect, and it is registered before the outer one because the outer inverse is registered only when its acquisition returns. Inverses run in reverse registration order when the activation ends, so the outer inverse runs before the inner one. An outer inverse that must release the inner resource first disposes the inner effect itself; disposing it again later does nothing.

An owner-scoped provider method registers the resource on the caller's owner, so the resource ends with the caller. When the provider needs a service of its own to do that work, it calls the service with its own context as the owner, inside the effect it registers on the caller's owner. It does not forward the caller's owner: that would require the caller to depend on the provider's dependencies. The adoption provider's `install` follows this pattern with its rules binding.

Two active instances cannot provide the same contract and schema. Several implementations of one contract are composed through a broker, as section 6.2 of the Cordis paper describes: one plugin provides the contract, implementations register with it through an owner-scoped method, and it chooses between them or multiplexes them. The rules provider's sources have this shape.

### Instances

Runtime instances expose `enable`, `disable`, `dispose`, and `reload`; runtime shutdown disposes every instance. A request takes effect immediately, in the order it is made, and raises at the call that made it when the graph rejects it: an unknown or removed instance, an enable of a retired or quarantined instance, or an enable whose provided contract another enabled instance already reserves. `instance:state()` reports `inactive`, `loading`, `active`, `unloading`, `failed`, `quarantined`, or `removed`. `instance:diagnostic()` describes why the instance last failed or is not loading, or returns nil. Logs, reports, and diagnostics name instances by their definition's `name`. The native `define` takes the name as an optional argument and otherwise names a definition for where its initializer is defined. An initializer or inverse that fails while lifecycle work drains is reported through [the error path](#errors) rather than raised from the request that started the drain. [Architecture](architecture.md#plugin-runtime) states the reservation, retry, and quarantine rules. The adapter contains all erased casts; plugin modules use no compatibility facade for the earlier mapped `Services<R>` and `Provisions<P>` design.

Contract tokens and frozen capability wrappers are shared by runtime graphs in one Lua state's epoch. A runtime graph owns its plugin instances, service values, and effects. Source reload retires the old epoch, so a new configuration may declare the same contract names and schema numbers again, and a declaration that still holds a capability from the retired epoch is rejected as retired. Instance reload replaces one plugin activation without replacing the runtime or epoch. See [Architecture](architecture.md#plugin-runtime) for lifecycle ownership and cleanup.

The native plugin handles in `lua/lunette/init.luau` are nominal. Each declares a phantom field that exists only in the declaration, so a table, or another plugin handle, does not satisfy a parameter that takes a contract token, definition, runtime, instance, context, or effect.

`Instance:requestReload(config)` accepts replacement intent and configuration without invoking lifecycle callbacks. Rejection raises before the configuration changes. An explicit `Runtime:drain()` applies accepted work; an error during that drain does not revoke the accepted request. Ordinary `Instance:reload(config)` retains its automatic drain behavior. The composition service uses deferred acceptance so its configuration history agrees with the native runtime even when draining stops at its action budget.

### Runtime inspection

`Instance:id()` returns its exact decimal string identity. `Runtime:owns(instance)` checks whether an instance belongs to that runtime. `Runtime:ownerId(context)` returns the owning instance's identity or nil for a foreign context. An ended activation can still identify its owner; this query grants no resource authority.

`Runtime:snapshot()` returns a coherent detached snapshot of the graph and its activation effects. It invokes no callbacks, drains no pending work, and consumes no diagnostic. Records and collection indexers are read-only, and retained snapshots do not change when the runtime changes. Instance, activation, and provider-generation identities are exact decimal strings rather than floating-point approximations.

Instance records distinguish declarations, actual allocation bindings, and failed activation bindings. They describe parent ownership, children, actual dependents, enabled intent, phase, retirement, authority, quarantine, replacement, cleanup, current and previous failures, and blockers. Binding records identify the provider instance and generation and whether that generation is current. Effect records identify the owning instance, activation, ordinal, and armed, cleaning, or disarmed state. Their source identity is the acquisition owner; it does not identify an inferred broker caller.

Disarmed effect metadata remains available for the complete activation history, while its callable inverse is released. Storage and snapshot work grow with that history. A new activation or removal ends it. Broker inspection adds detached logical registration metadata through neutral service contracts; [Session composition and inspection](stdlib.md#session-composition-and-inspection) states that policy and its unavailable-fact rules.

### Provider modules

Every built-in provider module answers one table:

```lua
local laser = require '@lunette-plugins/laser'
laser.definition                                   -- the default definition
laser.define { name = 'long-laser', style = { length = 3 } } -- a definition with other defaults
laser.build(context, { style = { length = 3 } })   -- the service, not published
laser.requires                                     -- the declaration build reads from
```

A provider's options are its configuration. `graph:use(laser.definition, config)`, a composition's `config` patch, `define`, and `build` all take the provider's `Config`. Its descriptor supplies defaults and validates values. Declared objects merge recursively; arrays, maps, unions, and atomic values replace. An empty map therefore clears the map instead of inheriting its keys. `define` takes the options and an optional `name`, which defaults to the provider's own, and answers a definition with the resolved settings bound as its base. A configuration given to that definition resolves over that base. Each activation resolves its configuration afresh and receives frozen schema-declared containers. Callbacks, custom values, and native vectors retain their references or values. A provider module exports descriptor-derived `Config`, the table a caller writes, and `Settings`, the resolved value its builder receives.

`build(context, config)` makes the service without publishing it, so a plugin can wrap it and publish the wrapper under the same contract. The plugin declares `requires` among its own requirements, because `build` reads them from the context it is given. Effects `build` registers, such as the frame provider's binding to the LÖVR callbacks, belong to that context's activation.

```lua
plugin.define {
  name = 'counting-laser',
  requires = laser.requires,
  provides = { laser = laserContract.capability },
  init = function(context, config, publish)
    local inner = laser.build(context, config)
    publish:provide(laserContract.capability, setmetatable({
      attach = function(_self, owner, options)
        attached += 1
        return inner:attach(owner, options)
      end,
    }, { __index = inner }))
  end,
}
```

A wrapper changes only what reaches the service from outside. A built-in calls its own methods through closures rather than through `self`, so a wrapper that replaces `matches` on the rules provider does not change what the rule lists `setRules` registers match, and a wrapper of a returned laser does not change what the provider draws. Variation inside a provider is a hook. A hook is an option whose value is a function, and it follows the around convention: it receives its arguments followed by the default implementation, `hook(args..., base)`, and calls `base` to keep the default behaviour, as in `drawKey = function(pass, key, state, base) base(pass, key, state) end`. A hook is plain data, frozen at build time like every other option. Its default is a function that calls `base`, so option validation checks that a hook is given a function. A hook runs on the stack of whatever reached the provider: the keyboard's `onKey` runs inside the pointer update that pressed the key, and `drawKey` inside the owner's draw, so an error a hook raises is reported where theirs would be. The built-in hooks are the keyboard's `onKey` and `drawKey`, which [Keyboard](#keyboard) states; the interaction provider's `drive` and `constrain`, which [Pointers and interaction](#pointers-and-interaction) states; the laser's `readInput` and `draw`, which [Lasers](#lasers) states; the panels provider's `shape.raycast`, `shape.draw`, and `shape.applyLayer`, which [Panels](#panels) states; the placement provider's `panelOptions`, which [Rules and placement](#rules-and-placement) states; and the pacing provider's `choose` and the scale provider's `ideal`, which [Frame pacing and output scale](#frame-pacing-and-output-scale) states.

`plugin.provider<<Config, Settings, Service>> { name, capability, requires, schema, validate, build }` makes such a module from a builder and a descriptor. Every configurable built-in provider uses a descriptor. `Config` is `schema.Input<typeof(descriptor)>`, and `Settings` is `schema.Output<typeof(descriptor)>`. Closed objects reject unknown fields, collection children validate every entry, literal unions describe closed choices, and optional fields represent absence without a sentinel. The descriptor validates initial settings at module construction, bound settings at `define`, build options at `build`, and instance configuration at activation. `validate` is optional and receives the resolved settings and definition name at each resolution. It adds integration constraints rather than a second field declaration. Descriptor failures carry a structured path, code, and message. [Configuration schemas](../guide/configuration-schema.md) states the constructor and error contracts.

Configured definitions expose immutable `schema` metadata with their bound base and a `resolve` function for configuration preflight without acquiring resources. Management requires both members before offering configuration controls. Raw definitions remain valid without them. The authoring helpers retain `defaults` for legacy modules but reject a spec containing both `defaults` and `schema`. A module that takes no options may omit both; options given to it are rejected.

`plugin.consumer<<Config, Settings>> { name, requires, schema, validate, init }` makes a configured consumer module with `definition`, `define`, and `requires`. Its initializer receives the resolved `Settings` and reads services explicitly with `context:require`. Providers and consumers share descriptor resolution and configured definition construction. Constructing a definition validates initial and bound settings but does not run its initializer or acquire resources. A malformed declaration, descriptor, or initial setting raises at construction. A consumer initializer must return no values, including no explicit nil; an invalid return fails activation and rolls back its effects. A definition factory still runs once per runtime start when state must persist across that runtime's activations.

`plugin.options { name = ..., defaults = ..., config = ... }` retains the legacy default-table resolver. It merges string-keyed tables recursively and validates against default value types. `plugin.merge { base = ..., over = ... }` retains that unvalidated merge for raw or legacy composition entries. Schema-backed entries resolve `config` patches through the definition's descriptor instead, so collection replacement and validation follow the descriptor.

`plugin.rejectUnknownFields(prefix, value, allowed, fields, level)` checks the fields of a table a service method receives, and the built-in providers check their arguments with it. It raises `<prefix>: unknown field <key>; the fields are <fields>` for the first key `allowed` does not name, with `the field is` when `allowed` names one, and refuses a value that is not a table. `level` counts as `error`'s does from the function that calls it, so a method passes 2 to name its caller.

`plugin.checkNumbers(name, option, value, count)` checks a fixed-size numeric list, such as a colour. It raises `plugin <name>: option <option> ...` for a value that is not a table, a key that is not one of the `count` positions, an element that is not a number or not finite, or a length other than `count`. `plugin.checkVector(name, option, value)` checks a native `vector` and rejects non-finite x, y, or z components with the component name. Three-dimensional positions, directions, and offsets use native vectors in configuration and resolved settings. Vector methods return new values; a caller must retain the result of `normalize`. Vectors replace defaults atomically and are not copied as tables. Colours, two-dimensional coordinates, numeric lists, and full pose matrices keep their own representations.

### Composition

A composition is a list of entries, `{ id, definition, config }`, or `{ id, factory, config }` for a definition made once for each start, so the definition can keep state across its own provider outages. `plugin.compose(entries, patches)` answers the entries with the patches applied, validated and frozen, and defines and enables nothing. `plugin.start(entries)` makes one runtime, uses and enables each entry in order with its `config`, and drains it, and answers `{ runtime, instances }`, the instance made for each id. A failure during `plugin.start` closes the runtime and is raised; an option a plugin does not take fails that instance's activation, is reported, and leaves the rest started. Managed startup instead preflights every resolvable configuration before creating the runtime, so a preflight error aborts startup without activating entries. Desktop settings also validate during composition. Initializer failures remain local to their instances. `frame.run`, in [Frame and surfaces](#frame-and-surfaces), binds a composition to LÖVR's callbacks. [Session composition and inspection](stdlib.md#session-composition-and-inspection) describes entry management, recovery, and inspection. `lua/lunette-plugin/compose.luau` is the source of truth for the rules below.

A patch names an entry by `id`:

```lua
plugin.compose(entries, {
  { id = 'keyboard', disabled = true },
  { id = 'laser', definition = myLaser },
  { id = 'interaction', config = { tuning = { reach = 4 } } },
  { insert = { id = 'my-hud', definition = hud, config = {} }, before = 'desktop/adoption' },
})
```

`disabled = true` removes the entry. `definition` or `factory` replaces what the entry is made from and keeps its configuration. `config` resolves over the entry's configuration through its descriptor when the definition exposes one. Declared objects merge recursively; arrays, maps, unions, and atomic values replace. Raw and legacy definitions retain the rule `plugin.merge` follows: string-keyed tables merge recursively, and lists and other values replace. A patch may replace and configure at once. `insert` adds an entry at the end, or just `before` or `after` the entry another field names, and carries no other field; an insert may name an entry an earlier insert added. A patch with an `id` cannot move its entry. Each id names one patch. The graph orders activation by dependency; among entries that do not depend on each other, the list order is the order they are enabled in and the order the graph loads them again after an outage of something they share.

A patch that names an unknown id, an insert whose id is already an entry, an insert positioned before or after an id that is not an entry or both before and after, a keyed patch that gives `before` or `after`, two entries or two patches with one id, a field the patch or entry does not name, a patch that disables an entry and also changes it, one that gives both a definition and a factory, and one that changes nothing raise from `compose`, with an error that names the id.

`plugin.configure(definition)` answers a function that makes the patch `{ id = definition.name, config = config }`, so `plugin.configure(laser.definition) { style = { length = 3 } }` configures the entry whose id is the laser's name. It also takes a factory, which it calls once for its definition's name. Luau infers the configuration type from the definition alone, so the configuration is checked against the definition's `Config`. A plain patch's `config` stays `{ [string]: any }`. Typing `config` by `id` would make the patch type a union of one arm per entry, and the union would need an arm for any other id as well, because a patch also names entries a configuration inserted; a mistyped option satisfies that arm, so the union checks nothing. Luau does not report a key a table type does not name in a literal, so a misspelt option still reaches the plugin's validation, which raises naming it.

`plugin.configureEntry(id, definitionOrFactory)` answers the same typed configuration function but targets the supplied entry id. It never calls a factory. The definition or factory supplies only the configuration type, so an entry can use another id without evaluating its factory during configuration. `desktop.configureEntry` aliases it. `plugin.configure` retains its definition-name behaviour for compatibility.

### Frame and surfaces

LÖVR's frame and input callbacks reach plugins through `lunette/frame` at schema 2 and `lunette/surfaces`, which the built-in `@lunette-plugins/frame` and `@lunette-plugins/surfaces` providers implement. A plugin that draws, updates, takes keys, or offers something a pointer can pick requires them like any other contract and needs nothing from the configuration. `lua/lunette-contracts/frame.luau` is the source of truth for the frame service and event types.

```lua
frame:onBatch(owner, { run = function(batch) end })
frame:onUpdate(owner, { phase = 'scene', order = 0, run = function(dt) end })
frame:onDraw(owner, { phase = 'overlay', run = function(pass) end })
frame:onKey(owner, { phase = 'binding', run = function(event) return event.key == 'f5' end })
frame:onText(owner, { phase = 'delivery', run = function(event) end })
frame:onQuit(owner, { run = function() end })
surfaces:offer(owner, { name = 'my-hud', list = function() return { hud } end })
surfaces:all()
```

Each registration is owner-scoped and answers an effect; it ends when the effect is disposed or the owner unloads. Update handlers use `UpdatePhase` and run in the order `input`, `scene`, `pointing`, `overlay`. Draw handlers use `DrawPhase` and run in the order `input`, `scene`, `pointing`, `overlay`, `feedback`. `@lunette-contracts/frame` exports those ordered, frozen sets as `UPDATE_PHASES` and `DRAW_PHASES`. The legacy `Phase` type and `PHASES` array retain the shared update-phase set. The provider validates each registration against its operation's phase set; `feedback` is draw-only.

`input` reads devices before the scene moves and draws beneath the scene. `scene` updates and draws panels and other scene surfaces. `pointing` updates picking against this frame's surface poses before overlay reactions. Its draw slot remains available before overlays. `overlay` draws UI such as the manager and error display over the scene. `feedback` draws pointer beams and landing indicators after all scene and overlay UI. `desktop/pointing` updates in `pointing` and draws in `feedback`, so an overlay cannot paint over its landing indicator when depth testing is disabled. Within a phase, handlers run by ascending `order`, which defaults to 0, and then in registration order. An overlay's order cannot move it after feedback. The phase is required, so each handler states where it belongs.

Key and text handlers run `binding` handlers before `delivery` handlers, then by `order` and registration. The phase defaults to `binding`. A handler that answers `true` consumes that event, and no later handler sees it. The shipped `desktop/input` routes input in `delivery`, so a binding that consumes a key keeps that activation from the target. A frozen key event carries `batch`, `key`, `scancode`, `isRepeat`, and optional `modifiers`. `isRepeat` is LÖVR's `isrepeat` argument; `repeat` is reserved. `modifiers` is the physical event snapshot with readonly boolean fields `shift`, `control`, `alt`, `super`, `capsLock`, and `numLock`, or nil when unavailable. It is distinct from the destination seat's array of modifier names. A frozen text event carries `batch`, `text`, and `code`, the first code point LÖVR reports. Key and text remain separate callbacks. Physical routed text also obeys the batch eligibility rules in [Input](input.md#physical-input-batches), so a consumed binding key, a consumed or failed local key, or a route transition can refuse later text. Quit handlers run in registration order and cannot veto the quit.

`frame:onBatch(owner, { run })` observes each input batch as a frozen `{ id, textBlocked }`. Identifiers increase within one frame provider activation and may restart when the provider is replaced. A batch opens with `textBlocked=false`. A binding-phase key handler that returns true changes it to true and notifies observers with a new frozen record carrying the same id before another physical callback. `frame:blockText(id)` records the same invalidation for a delivery consumer. It commits state before notifying observers and returns true for accepted or repeated current-batch requests, without duplicate notification. It returns false for a stale id, an absent batch, or a cached method called after its provider activation ends. A fresh method lookup through an ended service still raises the normal service-lifetime error. It does not mutate an earlier frozen batch record. A reentrant invalidation supersedes an in-progress notification; later observers receive no stale open record after the blocked record. Replacement consumers immediately observe the blocked current batch. Later text remains blocked until a new batch. A raising binding handler continues dispatch without blocking text. Each update opens a batch before update handlers. A key or text callback opens one if no batch exists. Subsequent key and text callbacks share it until the next update. Batch observers run in registration order before update, binding, and delivery handlers. Registration immediately reports the same current batch when one exists, without opening a new batch. Both immediate and boundary notifications protect and report each callback independently. An observer that raises does not stop later observers. `onBatch` accepts only `run`; it has no phase or order. `frame:inspect()` returns detached handler registration metadata, including batch observers, phases, order, sequence, and owners, without invoking a handler or opening a batch.

Every handler, and every offer's `list`, runs under its own protected call. Its error is reported through `lunette.reportError`, under `lovr.update`, `lovr.draw`, `lovr.keypressed`, `lovr.textinput`, or `lovr.quit` for a handler and `surfaces: <name>` for an offer, and the handlers after it still run. A key or text handler that raises consumes nothing. An offer whose `list` raises or answers something other than a table contributes no surfaces. An offer name names one offer, and offering a name that is already offered raises. A registration with a field the contract does not name, a phase outside its set, an `order` that is not a finite number, or a `run` that is not a function raises at the call.

`frame.install { start = ..., stop = ... }` binds the LÖVR callbacks to the frame provider. It assigns `lovr.load`, which calls `start`, and `lovr.update`, `lovr.draw`, `lovr.keypressed`, `lovr.textinput`, and `lovr.quit`, which reach whichever frame activation is loaded and do nothing while none is. `lovr.quit` runs the quit handlers and then `stop` under a protected call, and answers `false`. One frame activation receives the callbacks at a time; a second raises as it loads. A configuration calls `install` once, before the runtime exists, and creates its runtime in `start`. `frame.run(entries)` does this for a [composition](#composition): it checks the entries with `plugin.compose` at the call, starts them with `plugin.start` from `lovr.load`, and closes the runtime from `lovr.quit`. `@lunette-desktop`'s `run` calls it.

### Keyboard

The `lunette/keyboard` schema 2 contract is what a consumer of an on-screen keyboard uses. `service:new(owner, options)` makes a keyboard the owner places, offers, and draws. It ends when the owner unloads or `destroy` is called. A keyboard is a surface with `pose`, `width`, `height`, `visible`, `setPose`, `setSize`, `setVisible`, `pressKey(code)`, `typeText(text)`, `modifiers()`, `draw(pass)`, and `destroy()`. `service:inspect()` returns detached registration metadata without drawing, resolving targets, or computing legends. Each owner draws and offers only what it made. `lua/lunette-contracts/keyboard.luau` is the source of truth for the contract.

`Options` are `rows`, `layers`, and `style`, which override the provider's for that keyboard and are validated the same way; `pose`; `target`; and `onVisibilityChanged`. `target` is a native-only callback answering `(seat?, sink?)`. Without it, the keyboard uses the current `lunette/focus` route. With it, a focused local receiver still takes precedence, and the callback is not called while that receiver is current. A nil seat preserves omitted-seat native delivery; a nil sink is unavailable. This adapter cannot select a local receiver.

`onVisibilityChanged(change)` belongs to the keyboard's owner and receives `{ visible, reason }`. `setVisible(true)` reports `show`, `setVisible(false)` reports `hide`, the hide action reports `user-hide`, and destruction reports `destroy`. An unchanged visibility request reports nothing. Visibility, latches, locks, and hover state change before the callback runs; destruction sets `dead`, removes the board and route listener registrations, destroys its input source, and clears the retained visibility callback before the final notification. Cleanup attempts each independent inverse even when another raises. The callback runs under a protected call and its error is reported with the owner's diagnostic label without undoing the change.

Each built-in keyboard uses a virtual focus source. It sends evdev activations with explicit modifiers and routes explicit text separately. `pressKey` and `typeText` answer true only for a consumed result. A non-modifier activation clears latches before delivery; hiding, destruction, and every route change immediately clear both latches and locks and reset source input. Legends and local virtual translation use the same live keymap-seat selection, described in [Input](input.md#virtual-activations-and-committed-text). No live seat means no keymap-derived text. The keyboard has no stateful dead-key, compose, IME, or preedit support.

Rows are data in the contract, so a configuration writes them for whichever provider serves it. A row is a list of keys laid out left to right. A key is a table of `code`, an evdev code; `action`, what a key that sends no code does; `label`, the legend in place of the keymap's; `width` and `height`, in key units, default one; and `x`, room left empty before the key, in key units, default zero. A key with neither a code nor an action is a spacer: it takes room and is neither drawn nor pressed. A row moves the next one down by the height of its shortest key, so a two-unit key reaches into the row below, which leaves a spacer where it lands, and an empty row moves it by one unit. An action is one of `{ kind = 'hide' }`, `{ kind = 'layer', layer }`, `{ kind = 'text', text }`, `{ kind = 'chord', code, modifiers }`, which sends one key with the named modifiers held, and `{ kind = 'custom', name }`, which does nothing by default and is for a hook.

```lua
local keyboard = require '@lunette-plugins/keyboard'
local codes = require('@lunette-contracts/keys').CODES

local numpad: { keyboard.KeyRow } = {
  { { code = codes.digit7 }, { code = codes.digit8 }, { code = codes.digit9 }, { code = codes.minus } },
  { { code = codes.digit4 }, { code = codes.digit5 }, { code = codes.digit6 }, { action = { kind = 'text', text = '+' }, height = 2 } },
  { { code = codes.digit1 }, { code = codes.digit2 }, { code = codes.digit3 }, { width = 1 } },
  { { action = { kind = 'layer', layer = 'base' }, label = 'abc', width = 4 } },
}
```

The built-in provider's options are `rows`, the base layer, which defaults to a compact ANSI arrangement in `@lunette-plugins/keyboard/rows`; `layers`, further layers by name, which a `layer` action shows and `base` names the rows of; `style`; `modifierKeys`, which code latches which modifier, defaulting to `MODIFIER_KEYS` in `@lunette-contracts/keys`; `locks`, the modifiers that stay on until pressed again, defaulting to `lunette.lockingModifierNames()`; and the hooks `onKey` and `drawKey`. A keyboard is as wide and tall as the largest of its layers, so the plate does not change size when a layer changes. Rows, layers, actions, modifier names, and locks are validated when `define` is called and at each activation, and an error names the option by path, as in `plugin keyboard: option rows[1][1] has an unknown field widht`. A layer action that names no layer, a key with both a code and an action, a size that is not a positive number, and a modifier name the runtime does not have are each refused.

Keyboard drawing clears the inherited shader and material and selects the default font. Faces retain the caller's depth testing and writing. Legends retain depth testing but disable depth writing so transparent glyph bounds do not occlude later drawing. Each key hook and the complete keyboard draw restore pass state and transforms on success and error. Hooks must balance their own stack operations. A thick key face must remain behind its legend. `examples/keyboard/rounded.luau` places the rounded key's front face on the interaction plane and its body behind that plane, leaving the default legend in front.

`onKey(keyboard, key, pointer, base)` runs for every key a pointer presses, action keys included, and `base` sends the code or performs the action. `drawKey(pass, key, state, base)` runs for every key a keyboard draws, after the plate, and `base` draws the face and then the legend. `state` holds `keyboard`, `pose`, the centre of the key's face, `style`, `held`, which is true for a latched or locked modifier and for a layer key while its layer shows, and `hovered`. `@lunette-plugins/keyboard/draw` exports the default's halves, `face` and `legend`, and `faceColor`, so a hook that draws its own face keeps the default legend. The keyboard a hook receives is the provider's `Board`: the contract's keyboard with `layer`, `setLayer(name)`, and `keys()`, the laid-out keys of the layer showing. A laid-out key carries `source`, the row entry it was made from, which stays the same table while the keyboard shows the same rows, so a hook can remember a key across frames. `@lunette-plugins/keyboard/layout` holds the pure layout functions, `keysOf`, `extentOf`, `keyAt`, and `legendFor`.

```lua
return keyboard.define {
  name = 'clicky-keyboard',
  layers = { numpad = numpad },
  onKey = function(board, key, pointer, base)
    pointer:vibrate { strength = 0.2, duration = 0.01 }
    base(board, key, pointer)
  end,
}
```

A pointer pulses the device that drives it with `pointer:vibrate { strength, duration }`, which answers whether a pulse was sent. The device is whatever the pointer's creator gave `interaction:newPointer` as `vibrate`; the laser gives each pointer its hand's controller, and a pointer made without one answers false. Protocol surfaces receive the pointer as `event.pointer` in `onPointer`; legacy surfaces receive it in `onPress`, `onHover`, and `onLeave`. A surface can therefore pulse the hand that pressed it.

`desktop/keyboard` provides the shared keyboard display and configures only keyboard placement through `settings.wristKeyboard.placement`, with `distance`, `drop`, and `tilt`. The wrist menu is a separate consumer, `desktop/menu`, configured through `settings.menu`; its settings include the menu hand, button size and offset, haptic feedback, and expanded-list geometry. The removed `wristKeyboard.hand`, `wristKeyboard.size`, `wristKeyboard.offset`, and `wristKeyboard.haptic` fields each raise a validation diagnostic that directs configuration to `settings.menu`. The keyboard remains lazily created and is shared by focused local controls. [Menu actions](#menu-actions) specifies the menu service.

### Keyboard display

`@lunette-contracts/keyboard-display` declares `lunette/keyboard-display` at schema 1. `desktop/keyboard` implements it and requires keyboard, focus, frame, and surfaces. The service exposes `dead`, `show()`, `hide()`, `toggle()`, `isVisible()`, and `onChanged(owner, { run })`. Its public methods name `Service` as the receiver, and listener registration returns an owner-scoped effect. Frozen change records carry `visible`, a reason of `show`, `hide`, `user-hide`, or `destroy`, the current local focus `target` when applicable, and the display's `revision`. The contract module is the source of truth for these types.

Manual show records manual visibility. A local focus change requesting a keyboard shows the existing board automatically and records the target identity and focus revision. Field-to-field focus retains its pose; a hidden-to-visible transition applies configured placement. Ending editing hides automatic visibility but preserves manual visibility for application input. Explicit hide, toggle-to-hidden, and the board's user-hide action clear visibility intent and blur only the matching current local target. State changes precede observer callbacks, and reentrant focus changes cannot cause a stale hide to blur a replacement field. Field drafts survive blur. Display teardown invalidates retained callbacks and state. A replacement activation does not replay an old focus target; a new live focus notification can show its board.

### Pointers and interaction

The `lunette/interaction` schema 2 contract makes pointers: `interaction:newPointer(owner, { seat, tuning, vibrate })` answers a pointer released when the owner unloads or `destroy` is called, and `interaction:pointers()` lists the live ones. `tuning` merges over the provider's. A pointer answers `seat`, `tuning`, `hovered`, `hitX`, `hitY`, `distance`, `grabbed`, and `dead`, read-only: assigning any field raises, and grab and press bookkeeping is not exposed. Its methods are the primitives a driver uses, `hover(surface)`, `setButton { button, pressed, sink, surface }`, `focus(sink)`, `beginGrab(surface, handPose)`, `dragTo(handPose)`, `push { deflection, dt }`, `scaleWith(handPose)`, `endGrab()`, `withdraw()`, `cancel(surface, reason)`, `vibrate { strength, duration }`, and `destroy()`, and `update(input, surfaces)`, which drives them from one frame of input. `setButton` presses a `lunette.PointerButton`, `left` when none is named, and each button is pressed and released on its own. `endGrab` answers whether the pointer was carrying a surface.

One frame of input is `{ pose, origin, direction, buttons, grip, scrollX, scrollY, dt }`, `@lunette-contracts/vocabulary`'s `Input`. `buttons` maps each held pointer button to `true`; a button it does not name is up. The default mapping, which `update` runs, grips to grab and releases the grip to drop; while a surface is carried it pushes it along the ray with the stick and scales it with a second grip; otherwise it picks the nearest surface within `tuning.reach`, moves and scrolls the sink under the ray, and presses on the hovered sink or surface each button `buttons` holds, in `vocabulary.POINTER_BUTTONS` order. A press of a sink gives the pointer's seat's keyboard to it through `lunette/focus` while the provider's `focusOnPress` option is true, which it is by default.

Surface event and projection declarations live in `@lunette-contracts/surface` and the shared vocabulary. `onPointer(surface, event)` opts into readonly `enter`, `move`, `leave`, `press`, `release`, `scroll`, and `cancel` events and suppresses legacy callbacks for that surface. Common fields are `pointer`, optional `x` and `y`, `captured`, and `inside`. Press and release have a `button`; captured move has its button, while hover move has none. Scroll has scaled `dx` and `dy`. Cancel has a button and one reason: `tracking-loss`, `pointer-destroyed`, `surface-dead`, `surface-withdrawn`, `provider-replaced`, `hidden`, `control-removed`, `disabled`, or `grab`. Owner cleanup uses `pointer-destroyed`, including dependent teardown before a provider ends; an inactive provider's remaining-pointer cleanup uses `provider-replaced`. A native sink remains a native delivery target rather than receiving duplicate surface events.

A pointer retains one capture per pressed button. Captured movement and release reach the original surface even after hover changes. `surface:project(origin, direction)` can return unbounded surface-local coordinates and distance for that motion; `raycast` remains the bounded picking operation. `@lunette-contracts/quad` exports both `project` and bounded `hit`, with identical top-left logical conversion. An absent projection leaves coordinates unavailable when the original surface is no longer hit. A release carries its current `inside` state, so a control can distinguish release inside from a cancelled or outside gesture.

`pointer:withdraw()` cancels Lua captures for tracking loss, attempts native button releases, leaves hover, and ends spatial grabs. It quarantines pointer buttons until tracked input reports all buttons up. `pointer:cancel(surface, reason)` cancels only that surface's gestures on the pointer; a still-held cancelled button requires an up sample and a new press. Hide, disable, and control removal can therefore cancel immediately without fabricating a release. Grip-driven grabbing cancels UI captures before moving the surface. A surface with `triggerGrabbable = true` also starts a grab on a primary-button press and drops on its release. An optional `surface:grabTarget()` directs that gesture to another live surface offered in the same input frame. A nil, dead, or unoffered target does not begin a grab. This lets titlebar button surfaces move their owning panel on grip while retaining trigger clicks. Cleanup commits cleared state before callbacks, attempts every inverse, and reports combined failures. An external surface with only legacy callbacks retains its prior release callback behavior and cannot distinguish those cancellation reasons.

The provider's options are `tuning`, `focusOnPress`, and two around hooks. `drive(pointer, input, surfaces, base)` runs for every `update`, and `base` is the default mapping, so a hook that remaps buttons calls `base` with other input, and one that drives the primitives itself calls nothing. `constrain(surface, pose, base)` answers the pose a carried surface takes for the pose the hand would give it, in every drag and every scaling frame, and `base` answers the pose unchanged; a hook that keeps panels level, or snaps them to a grid, is a function of the pose. A `constrain` that answers nothing raises. `@lunette-plugins/interaction/picking` holds the default mapping's arithmetic, `pick(surfaces, origin, direction, reach)`, `deadZone(value, dead)`, and `scrollDelta { x, y, dt, tuning }`, for a hook that replaces it.

```lua
local interaction = require '@lunette-plugins/interaction'

return interaction.define {
  name = 'level-interaction',
  focusOnPress = false,
  constrain = function(surface, pose, base)
    local kept = base(surface, pose)
    local x, y, z = kept:getPosition()
    return lovr.math.newMat4():translate(x, math.max(y, 0.5), z)
  end,
}
```

A pointer gives focus and announces drops through separate contracts, which the interaction provider requires. It registers a native target with `lunette/focus` and focuses that target on a press while `focusOnPress` is enabled. The keyboard and `desktop/input` require focus rather than interaction. [Focus](#focus) states target ownership, native seat authority, and routed delivery.

`lunette/drops` is a broker for the end of a grab. `drops:onDropped(owner, { run })` hears every drop, `{ surface, pointer }`, and `drops:emit(owner, { surface, pointer })` announces one; the interaction provider emits whenever a grab ends while it is live, before the pointer forgets the surface. Listeners run in registration order, each under its own protected call, and one that raises is reported without stopping the others. The surface is what the pointer carried: a panel offered as a surface is its own, and a decoration that moves a panel carries the panel's `kind` and `source`, so a listener finds the panel with `panels:forSource`. The desktop's pose memory, its arrangement save, and its arrangement of unplaced windows hear drops only here, so a provider that replaces interaction, or any plugin that carries surfaces for a pointer, emits a drop when a grab ends; one that does not loses the remembered pose across a reload, the save until quit, and the dropped window's exemption from the arrangement, without an error.

### Focus

The `lunette/focus` schema 2 contract owns one current keyboard route and input sources that deliver to it. `lua/lunette-contracts/focus.luau` defines its public types. A target is `{ kind = 'native', seat?, sink }` or `{ kind = 'local', receiver, keymapSeat?, wantsKeyboard }`. A local receiver has `key(event)` and `text(utf8)` callbacks returning booleans, plus optional `onFocus(change)` and `onBlur(change)` notifications. `wantsKeyboard` describes a local target's keyboard request; it does not show a keyboard by itself.

```lua
local target = focus:register(owner, {
  kind = 'local',
  receiver = { key = function(event) return false end, text = function(text) return true end },
  wantsKeyboard = true,
})
target:focus()
focus:focused()       -- the current TargetHandle, or nil.
focus:revision()      -- changes on each route transition.
target:blur()
target:destroy()
```

`register` copies and validates a plain target description and registers its lifetime on the owner. It returns a read-only `TargetHandle` with `dead`, `focus()`, `blur()`, and `destroy()`. Dead handles refuse focus and blur. Destroying an already destroyed target answers false. Focusing the current target is idempotent. Blurring or destroying the current target leaves no route and never restores an older target. A non-current native target can still hold seat authority; its blur or destruction withdraws only authority it still owns. A native withdrawal refusal or exception is reported, and cleared bookkeeping never restores the old route. An inverse that raises directly reaches the disposing caller; one that raises during owner unload follows the runtime's quarantine rules.

A native window target calls `seat:setFocus(sink)` before acquiring the route or sending keys. A nil seat is normalized with `lunette.defaultSeat()` for authority and keymap queries, but remains nil in native sink delivery. Native authority is keyed by stable seat identity, independently of the one current route. A later native target on the same seat replaces it; selecting a different seat leaves the earlier seat's authority intact. Entering a local target clears the previous route's native window authority. A host target never calls `seat:setFocus`, because the host compositor controls focus. Native target comparison uses seat, window, and monitor identifiers, not wrapper equality. [Input](input.md#keyboard-routing) states the ordering and failure rules.

`focus:onChanged(owner, { run })` registers an owner-scoped listener and answers its effect. Its frozen `Change` carries `target`, the current live handle or nil; `revision`; `kind`, `none`, `native`, or `local`; and `wantsKeyboard`, false unless the current local target requests it. State and source cleanup change before notifications. The previous live local receiver's `onBlur` runs before the current live local receiver's `onFocus`, then listeners run in registration order. Each callback is protected and reported with ownership context. If a callback changes the revision, remaining notifications for the superseded change stop. An ended receiver gets no callbacks.

`focus:newSource(owner, { mode?, nativeTarget? })` creates an owner-scoped source. `mode` is `virtual` by default or `physical`. The optional native-only `nativeTarget()` answers `(seat?, sink?)` and reconciles that target before delivery. It is not called while a local target is current and cannot supersede that target. A nil or dead sink is refused. The source exposes `dead`, `key(activation)`, `text(utf8, batch?)`, `keymapSeat()`, `beginBatch(id)`, `reset()`, and `destroy()`. `key` takes `{ code, modifiers?, isRepeat?, batch?, physicalModifiers? }`; `physicalModifiers` is the optional readonly six-boolean event snapshot, distinct from `modifiers`, the array of destination modifier names. Native keypad mode selection requires a reliable snapshot and refuses an unavailable one; [Input](input.md#physical-keypad-modes) records the supported PC behavior and limits. `code` is a finite non-negative evdev code. A local receiver sees a frozen `{ code, modifiers, source, isRepeat }`, with a detached frozen modifier list and `source` equal to the mode.

Each delivery returns a frozen `Result`: `{ kind = 'consumed' }`, `{ kind = 'unhandled' }`, `{ kind = 'refused', message }`, or `{ kind = 'failed', message }`. `consumed` means the selected receiver or native operation accepted it. `unhandled` means no route or a receiver that declined; it never forwards to another target. `refused` describes unavailable, stale, re-entrant, invalid, or natively rejected delivery. `failed` describes an exception already reported through `lunette.reportError`. Local refusal and failure remain isolated from native clients. A virtual unhandled key may become printable text only for that same unchanged local target; physical keys never use that fallback. Commands and C0/C1 characters do not use implicit text fallback.

`keymapSeat()` returns the live selection used for virtual legends and local translation: the current local target's explicit live seat, the most recent live native seat, then the first live native seat. It returns nil when none is available. `beginBatch(id)` records a physical source's route revision before binding and delivery. Text without that batch, from an old batch, or after a transition or consumed or failed local key is refused until the next batch. A frame observer resets the source when a binding key blocks the batch. `reset()` invalidates pending text and attempts original-target native cleanup. `destroy()` ends the source and its registrations and clears its native selector and routing callbacks before cleanup notifications. Retained dead handles cannot invoke those callbacks. Native inverse refusal or failure blocks further source delivery; no result retries or redirects an operation. Multi-character native text can deliver a prefix before refusal. [Input](input.md#virtual-activations-and-committed-text) states the text and modifier rules.

`focus:inspect()` returns detached logical registration metadata for targets, listeners, and sources, with owner labels, current kind, keyboard request, observed seat identity, revision, source count, and failure state where available. It invokes no receiver or native-target callback and does not prune dead targets. Receiver callbacks remain private and are marked unavailable. Inspection metadata grants no focus or resource authority.

### Lasers

The `lunette/laser` contract makes a laser for a hand: `laser:new(owner, hand, options)` and `laser:attach(owner, options)`, which answers a laser for each free hand. A laser reads one frame of its hand's input with its `readInput`, drives its pointer with it, and draws its beam with its `draw`; `laser:update(surfaces)` and `laser:draw(pass)` do the same for every live laser, so a laser's own methods and the service's bulk calls agree. A laser's `options` are `seat`, `name`, `readInput`, which replaces the provider's reader for that laser, `tuning`, `style`, and `aim`. The style and aim overrides merge over the provider's defaults.

The provider's options are `style`, `aim`; `buttons`, a list of `{ control, button }` that maps a LÖVR controller button, such as `trigger` or `a`, to the pointer button it presses, by default the trigger to `left`; and two around hooks. `readInput(hand, base)` answers a hand's frame, and `base` reads the headset through `buttons`; `draw(laser, pass, base)` draws a laser, and `base` draws the beam and the cursor. The list replaces its default wholesale, and each entry is checked at `define` and at activation. `@lunette-plugins/laser/input` holds the hand devices, the controllers, the controller buttons, and `fromHeadset(hand, headset, buttons)`. `desktop/pointing` takes `laser`, the options it attaches both lasers with.

The built-in provider applies adaptive low-pass stabilization to the sampled origin and direction before `Pointer:update`. `Laser.input` contains that same stabilized frame for rendering. `Input.pose`, buttons, grip, and scroll values remain unchanged. Each laser owns independent history, cleared on tracking loss or a zero ray. Missing or zero `dt`, or an interval exceeding `aim.resetAfter`, reacquires the current ray without smoothing. The aim descriptor in `lua/lunette-plugins/laser/aim.luau` defines `enabled`, `minCutoff`, `derivativeCutoff`, `angularBeta`, `positionBeta`, and `resetAfter`. Cutoffs are positive hertz values, betas are nonnegative speed gains, and the reset interval is positive seconds. `enabled = false` passes the sample through. The [desktop guide](../guide/desktop-configuration.md#pointer-aim) describes tuning and the shared feedback draw order.

### Panels

The built-in panels provider's `rendering` setting is `'plane'` by default. It draws window and monitor textures in the scene with sRGB decoding. Setting it to `'layer'` enables window layer claims, with scene rendering when a claim is not granted; monitors remain scene-rendered. Layer content is composited after scene geometry and does not participate in its depth testing. [Rendering](rendering.md#colour-transfer) defines colour and alpha handling.

A panel's options are `pose`, `width`, `height`, `priority`, `title`, `chrome`, and `curve`. A panel answers the same fields and `hidden`, `highlighted`, and `granted`. Panels draw no border or title unless the provider's `chrome` option, false by default, or the panel's own says so; decorations a configuration chooses are a consumer's, and the desktop's are `desktop/decorations`.

`panel:close(owner)` checks a live caller owner. A window panel sends its source's application close request without retiring the panel. A monitor panel dismisses capture and retires itself without changing the host monitor's connection. A dead panel or source returns false. A refused native window request returns false. `panel:destroy(owner)` remains restricted to the owner that created the panel.

Specifying only `width` or only `height` preserves that axis and derives the other from the source aspect ratio. Updates recompute the derived axis when source geometry changes or first becomes available. Monitor sizing uses oriented logical geometry, so a rotated output has a portrait panel even when its native mode is landscape. Specifying both dimensions retains the explicit rectangle. `panel:setSize(width?, height?)` selects the same sizing policy. `lua/lunette-plugins/panels/panel.luau` owns this behavior.

A panel is hidden while the most recent live visibility override says so. `panel:setHidden(owner, { hidden })` sets the owner's override and answers an effect; an owner holds one, so a later call moves it, making it the most recent, and answers the same effect. The override ends when the effect is disposed, the owner unloads, or the panel ends. A hidden panel is not drawn and is not picked, gives up its layer claim at once, and claims none while hidden; it stays in the registry, so `all` and `forSource` answer it, and `desktop/render` does not offer it to pointers.

A positive `curve` makes a panel a piece of a vertical cylinder of radius `1 / curve` whose centre is in front of the panel, as LÖVR curves a layer, with the panel's centre at its pose and its width measured along the arc. The provider's `shape` option holds three around hooks for a panel's geometry: `raycast(panel, origin, direction, backFace, base)`, `draw(panel, pass, base)`, which draws the content when the panel is not on a layer, and `applyLayer(panel, layer, base)`, which places a granted layer. The defaults pick the flat quad or the arc, draw the texture on a plane or on an arc mesh, and set the layer's position, orientation, dimensions, and curve. `@lunette-plugins/panels/shape` is the pure geometry. A rule's `curve` property reaches the panel it places.

### UI panels

`@lunette-contracts/ui` declares `lunette/ui` at schema 1. Its service creates owner-scoped flat VR panels through `newPanel(owner, options)` and returns a read-only list of live panels through `panels()`. The public types in `lua/lunette-contracts/ui.luau` are the source of truth. `@lunette-plugins/ui` implements the contract, requires focus and surfaces, and takes `theme` and `draw` configuration. It offers each live visible panel as a surface and installs no frame draw handler. The consumer draws its panels in its chosen frame phase. The [UI guide](../guide/ui.md) gives a small contract-only fixture.

A panel declares its unique `name`, world-space `width` and `height` in metres, and `logicalWidth` and `logicalHeight`. It optionally declares a pose, visibility, grabbability, an owning `grabTarget` surface, theme overrides, and a draw hook. `grabTarget` retains the owning surface's identity rather than copying it; grip moves that surface when it is live and offered alongside the panel. Trigger retains normal control input. Logical coordinates start at the top-left corner, with x increasing rightward and y increasing downward. Control bounds are finite half-open rectangles; left and top edges are inside, and right and bottom edges are outside. Panel dimensions are finite and positive. Control widths and heights are finite and nonnegative; zero-area controls do not receive input. Input picking, drawing, and descriptions use the same declared geometry and panel clipping. Higher `z` wins an overlap, and later registration wins a tie. A custom region declares item bounds and optional routes instead of deriving input geometry from its drawing.

Panels create buttons, single-line text fields, choices, lists, and regions through owner-scoped methods. Each control has an `id` unique for its actual creation owner across all live panels in the UI provider, bounds, optional label, enabled state, z order, theme overrides, draw hook, and capture exclusivity. Different owners can reuse an id within the same panel. One owner cannot duplicate it across live panels until the earlier control ends; the panel's creation owner does not determine the control's id namespace. Buttons call `onActivate()`. Choices and lists name items by stable string ids, and selection callbacks receive that id. Text callbacks receive a string, and validation returns a string error or nil. Region pointer callbacks receive the discriminated `surface.PointerEvent` union; a region can also register a local focus receiver and request keyboard routing explicitly. Read-only contract properties allow required values to satisfy optional fields covariantly. Public method signatures and implementations name their contract type as the receiver rather than a provider-private type.

A pointer button captures its original control through release or cancellation. A captured move remains on that control after the pointer leaves its bounds. A release activates only the eligible original control or item; cancellation never activates it. Exclusive controls reject captures from another pointer while held. Hiding, disabling, destruction, size changes, and control-bound or item replacement cancel affected captures and clear hover state before callbacks run. `Panel:setPose` preserves captures during rigid panel motion and updates the projection and description revision. Beginning a grip-driven grab still cancels pointer gestures before motion. Hover does not take keyboard focus. Text fields acquire local focus targets, and native input reaches them only through the focus source routing described in [Focus](#focus).

Text fields store a valid single-line Unicode UTF-8 value and reject control characters and line separators. `setSelection(caret, anchor?)` and `selection()` use one-based byte offsets at extended grapheme boundaries, including the terminal offset `#value + 1`; omitting the anchor collapses the selection. Movement and deletion operate on complete grapheme clusters. Insertion recomputes the boundaries because a combining mark or emoji sequence can join adjacent clusters. `setValue` validates but does not issue a user-change callback. A user edit calls `onChange` after validation succeeds. Enter calls `onSubmit` only when validation returns no error, and Escape blurs and calls `onCancel` with the current value. `setError` presents an external error. The default renderer measures with the same font used for drawing and indicates clipping or overflow without splitting a grapheme.

Themes resolve provider, panel, and control overrides in that order. Colours replace as complete lists. A draw hook receives `(pass, visual, base)`, where `visual` is an immutable snapshot in logical panel coordinates. Provider, panel, and control hooks wrap earlier renderers in that order. Calling `base` preserves the wrapped renderer; omitting it replaces drawing. Bounds and clipping bounds passed to `base` must retain the declared geometry. Custom drawing must remain within `visual.clip`. Each invocation restores the pass state and transform, including on error; a hook must balance its own pushes, must not pop a stack entry it does not own, and must not retain the pass. Arbitrary pass misuse is outside this guarantee. Draw errors propagate to the caller's frame boundary. Widget notification and validation failures are reported with the control owner through the protected callback boundary. A valid key or text edit remains consumed when `onChange`, `onSubmit`, or `onCancel` raises; the committed draft or blur is not undone. A raw region receiver's key or text exception instead produces a failed focus-source result and never falls through to an application.

Panel and control lifetimes belong to their creation owners. Owner unload, provider unload or replacement, and source reload end their surface offers, captures, and control-held focus resources. The underlying local focus target is registered under the UI provider's context because the provider requires the focus service. The control's owner-held inverse releases that target, attempts the remaining cleanup, and rethrows failures. A failure during owner cleanup remains visible at the control owner's inverse boundary, and direct destruction raises to its caller. Receiver errors are annotated with the control owner's label and rethrown to the focus delivery boundary. The target's actual registration owner remains the UI provider; its lifetime is held by the control rather than registered directly under the control owner. Dead handles do not mutate a replacement resource.

`panel:describe()` returns detached read-only geometry, control metadata, visibility, a revision, and a `ui.Generation` token. One frozen generation token is shared by panels from one provider activation; every replacement activation creates a distinct token. `Control.owner` and `ControlDescription.owner` expose a read-only frozen `ui.OwnerIdentity` token with `kind = 'ui-owner'`. It is stable for one actual creation-owner activation within the provider and fresh after owner or provider replacement. It exposes no context or scripting authority. Names and control ids may recur after replacement, and different owners may use the same id concurrently. The generation token, owner token, and id together disambiguate a live control. Consumers compare token identity to reject descriptions and callbacks from an earlier activation; `kind` fields are discriminators, not activation identifiers. A revision orders changes only within its panel activation. Descriptions invoke no user callback and grant no input or ownership authority.

### Bindings

The `lunette/bindings` contract is a broker for desktop key chords. `bindings:register(owner, { chord = { key, modifiers }, run })` binds a chord for the owner and answers an effect; `key` is a LÖVR key name and `modifiers` a list of `control`, `alt`, `logo`, and `shift`, the set `bindings.MODIFIERS` names. A chord names one registration, whatever order its modifiers are written in, and binding a chord that is bound raises. `bindings:dispatch { key, modifiers, isRepeat }` runs the binding whose chord is that key with exactly those modifiers and answers whether one matched; a repeat of a matched chord is consumed and does not run it again, and a `run` that raises is reported and still consumes the press. `bindings:chords()` lists the bound chords.

The built-in provider requires `lunette/frame` and takes every key press itself in the frame provider's `binding` phase, with the modifiers LÖVR reports held, which `@lunette-contracts/keys`' `heldModifiers` reads, so a matched press never reaches the focused client. `desktop/input` delivers keys in the `delivery` phase and does not require bindings, so a bindings outage leaves typing working. `dispatch` remains for another source of presses, such as an on-screen keyboard. The shipped configuration registers reload as the `desktop/reload` menu action in `desktop/actions`; it does not bind reload to a key chord. A configuration can register its own key chords through this broker.

```lua
bindings:register(owner, {
  chord = { key = 'h', modifiers = { 'control', 'alt' } },
  run = function(press) end,
})
```

### Menu actions

`@lunette-contracts/menu` declares `lunette/menu` at schema 1. The built-in `@lunette-plugins/menu` provider takes no options and holds action registrations without rendering a menu. `register(owner, action)` returns an owner-scoped effect. An action contains `id`, `label`, `run`, and optional `group`, `order`, `enabled`, and `selected` values. Containers must be plain, fields must be declared, and order must be finite. The defaults are group `''`, order `0`, enabled `true`, and selected `false`. Duplicate ids raise rather than replace a registration.

`list()` returns detached frozen descriptors sorted by group, order, and id. Each descriptor contains the resolved display values and a frozen `Registration` token, with no callback or getter. `update(owner, effect, state)` changes optional enabled and selected values only for that owner's exact live registration effect. Omitted values remain unchanged. A stale effect cannot update a replacement with the same id.

`invoke(id, expectedRegistration?)` returns `invoked`, `unavailable`, or `failed` with a diagnostic message. Missing, disabled, or stale registrations are unavailable. Passing the descriptor's token rejects a replacement with the same id; callers that retain displayed rows pass that token. Invocation snapshots the registration and calls its callback once under the registering owner's protected diagnostic context. Callback errors do not invoke another action or escape as unhandled input. Registration disposal and provider shutdown invalidate retained callbacks. `inspect()` returns callback-free owner-labelled registration metadata through the inspection vocabulary. An inspection consumer can run as a suspendable child rather than making the broker a required dependency of its parent.

### Layouts

The `lunette/layouts` contract is a broker for named layouts, which the built-in `@lunette-plugins/layouts` provider implements. A layout is a function that poses a list of panels. It holds no panels and chooses none: the caller passes the panels, for example the members of a tag it resolved, and names the layout. A layout therefore depends on no tags or rules contract, and a consumer that arranges panels depends on no particular layout.

```lua
layouts:register(owner, { name = 'grid', apply = function(panels, options) end, continuous = false })
layouts:apply { name = 'grid', panels = tag:panels(), options = { columns = 3 } }
layouts:names()            -- { 'arc', 'grid' }, sorted
layouts:get 'grid'         -- { name = 'grid', continuous = false }, or nil
layouts:onChanged(owner, { run = function() end })
```

`register` is owner-scoped and answers an effect; the registration ends when the effect is disposed or the owner unloads. A name names one registration, and registering a name that is registered raises. A built-in layout is replaced by disabling the composition entry that registers it and registering another layout under its name, never by overriding a registration in place. `apply` calls the named layout with the live panels of the list, in the order given, and the options; it raises for a name that is not registered, naming the ones that are, and the layout's own error, such as one for an option it does not take, is raised to the caller. A panel is `surface.Movable`, a surface whose `setPose` is required, and a layout poses it with `panel:setPose(pose)`. `continuous` marks a layout meant to be applied on every frame, such as one that follows the head; the broker does not apply it, and the consumer that arranges with it applies it from a frame update. `onChanged` listeners hear each registration begin or end, after the change. Each runs under its own protected call, and its error is reported through `lunette.reportError`. An owner has no authority while one of its own effects is disposed, so its own listeners do not hear what that disposal ends. A registration, `apply`, or listener with a field the contract does not name raises at the call.

The arc layout, `@lunette-plugins/layout/arc`, is a plugin that registers a layout and provides nothing. Its module answers `definition`, `define`, and `requires`, and `arc.layout(tuning, label)`, the layout function itself. Its options are `layout`, the name it registers under, default `arc`, and `tuning`: `radius`, `step`, the minimum angle between adjacent panels, `span`, the widest the arc may be, `gap`, the room between adjacent panels' edges in metres, and `center`, a native vector. The options a caller passes to `apply` are a tuning, every field optional, merged over the configured one for that call and validated the same way. `@lunette-plugins/layout/arc/geometry` is the pure geometry. Panels face the centre from a circle of `radius`. Adjacent panels are at least `step` apart, and further apart when they are wide: a flat panel of width w touching the circle covers `atan(w / 2 / radius)` on each side of its angle as seen from the centre, so adjacent panels whose extents are disjoint do not intersect, and `gap` is added between them. When the arc would be wider than `span`, every separation shrinks by one factor to fit it, and wide panels may then overlap.

### Tags

The `lunette/tags` contract groups borrowed panels under names. A tag is made in one of two ways. `tags:new(owner, name, options)` makes a tag that belongs to its caller: the name is that owner's, a second `new` of it raises, and the tag ends with the owner or when the owner calls `tag:destroy(owner)`. `destroy` by any other owner raises, as `panel:destroy` does, and so does `destroy` of a held tag, which ends only when its last holder lets go. `tags:hold(owner, { name, index, selected, layout })` answers the tag of that name and an effect, making the tag when there is none, and holds it for the owner: a tag `hold` made lasts while any owner holds it, so the plugins that need one tag need not agree on which of them makes it or in which order they start. Holding a tag `new` made borrows it and does not extend its life. Options apply only when the call makes the tag, and an owner holds a tag once, so a second `hold` answers the same effect.

```lua
local tag = tags:hold(owner, { name = 'web' })
tag:add(owner, panel)                           -- the owner holds a membership
local kept = tag:exclude(owner, { panel = panel }) -- the owner keeps the panel out
tag:setSelected(owner, { selected = true })
tag:setLayout(owner, { layout = 'grid' })
tags:onChanged(owner, { tag = tag, run = function(change) end })
```

A panel is a member while any owner holds its membership and no owner holds an exclusion of it, so a plugin moves a window another plugin added, such as one rules placed in `main`, by excluding it there and adding it elsewhere. `exclude` answers an effect, one per owner and panel, and the panel returns when the effect is disposed or the owner unloads. `remove` drops the caller's own membership; the owner of a tag `new` made may drop every one, and any other caller that holds none raises. A tag's selection and its layout are owner-held overrides with the most recent live one deciding, the rule panel visibility follows, and a tag with none has the value it was made with. A layout is the name of a layout in the layouts broker, or nil: the tags service does not resolve it, and whatever arranges a tag looks it up, so tags depend on no layout. `desktop/arrange` arranges each tag with its own layout when it names one, and a window in several tags by the first selected tag that holds it.

`onChanged` hears every tag, or the one `tag` names, as `{ tag, kind }`, where `kind` is `created`, `destroyed`, `selection`, `layout`, or `membership`. A change is announced after it is made. A panel that dies leaves its tags without an announcement, since `panels:onRemoved` announces it. A listener is owner-scoped and runs under its own protected call, and its error is reported through `lunette.reportError`. `desktop/monitors` joins a tag made after a mirror when it hears it made, and `@lunette-plugins/desktop/workspaces` shows the selected workspace's panels as selection and membership change.

### Rules and placement

`lunette/rules` holds rule sources and resolves a window's properties from them; it makes no panel and joins no tag, so the rules provider requires no other contract. `lunette/placement` turns a window into a panel and is the one component that depends on rules, panels, and tags. `placement:place(owner, { window, properties, defaults })` resolves the window's properties through rules unless `properties` gives them, fills in what they do not name from `defaults`, makes the panel, applies `hidden`, joins the tags they name, holding a tag named by a string, and answers the panel, the properties, and the placement effect. Disposing the effect, the owner unloading, or the panel's removal ends the placement, its memberships, and its holds. `placement:placed()` answers every live placement, in order, as `{ panel, properties }`, and `placement:onPlaced(owner, { run = function(placement) end })` hears each one as it is made, whoever made it; a listener runs under its own protected call, and its error is reported without undoing the placement. `desktop/arrange` arranges from these.

The placement provider's option `panelOptions(properties, window, base)` is an around hook that answers the panel's options, and `base` maps `pose`, `width`, `height`, `title`, `priority`, `chrome`, and `curve`. A configuration that forwards a property of its own replaces nothing but this hook:

```lua
local placement = require '@lunette-plugins/placement'

return placement.define {
  name = 'bending-placement',
  panelOptions = function(properties, window, base)
    local options = base(properties, window)
    if type(properties.bend) == 'number' then
      options.curve = properties.bend
    end
    return options
  end,
}
```

A rule's `match` takes the named fields, each a value or a predicate of the field and the window, and `where`, a predicate of the whole window, for what no field describes, such as a process or a pattern over the title. The named properties are `pose`, `width`, `height`, `title`, `priority`, `chrome`, `curve`, `hidden`, `adopt`, and `tags`; any other key passes through to the resolved properties, where a replaced `panelOptions` or an `onPlaced` listener reads it. `@lunette-contracts/vocabulary`'s `PRECEDENCE` names the desktop's source precedences, `rules` at 100, `persisted` at 200, and `native` at 300, so a source of a configuration's own is registered at `PRECEDENCE.persisted + 50` rather than at a number whose meaning lives in another file. The rules provider's default precedence and the adoption provider's install precedence are these unless configured.

The adoption provider places every window through placement. `adoption:install(owner, { precedence })` registers the native pose source, which answers the pose a window carries in its `lunette.pose` property, as the rules source `lunette.adoption` on the caller's owner; the service exposes no other view of it. `adoption:start(owner, { defaults, filter, onPlaced })` adopts a window unless `filter` answers false for it or its resolved properties, over `defaults`, carry `adopt = false`, so a plugin that presents a window itself keeps it out. The start's own `onPlaced(panel, properties)` hears only that start's placements, after placement's listeners.

### Errors stream

The `lunette/errors` contract is the session's error reports, rate-limited, which the built-in `@lunette-plugins/errors` provider implements. It owns the `lunette.onError` subscription for its activation. `errors:subscribe(owner, { run, cleared })` hears every report it delivers and answers an effect; `errors:recent()` answers the bounded history, oldest first; and `errors:clear(owner)` forgets it and calls every subscriber's `cleared`. A report is a frozen `{ message, traceback, suppressed, text, sequence, time }`: `suppressed` counts the identical reports withheld since it was last delivered, `text` is the message, traceback, and that count ready to show, and `sequence` counts the reports delivered since the provider started or was last cleared. The provider's options are `window`, the seconds a repeat is withheld for, `maxKeys`, how many distinct reports it remembers, `history`, how many it keeps, and `clock`. A report that arrives while subscribers are being called, such as a subscriber's own error, joins the history and is not delivered, so a presenter that raises cannot feed itself. `@lunette-plugins/errors/format` and `@lunette-plugins/errors/limiter` are the pure halves.

A presenter is any plugin that subscribes. The shipped `desktop/errors` draws the latest report on a quad over the scene, and `examples/desktop/notify-errors.luau` sends each as a desktop notification through `lunette.spawn`; several presenters run side by side.

### Frame pacing and output scale

How often each window's client draws and what scale each output's clients render at are policy over `window:setFrameRate` and `output:setMode`. Each is a contract that hands out a pure chooser, and a desktop entry that reads the scene and applies what the choosers answer, so a different rule and a different reading of the scene are replaced separately.

```lua
local pacer = pacing:newPacer()
local rate, changed = pacer:observe { visible = false, contentType = window.contentType, drew = true }
pacer:current()             -- the latest rate, nil for unthrottled.
pacer:isExempt('video')     -- whether this hint, or the pacer's history, exempts the window.
pacer:reset()

local chooser = scale:newChooser()
local step, moved = chooser:choose(0.8)   -- the scale for a panel 0.8 metres away.
chooser:current()
chooser:reset()
```

`lunette/pacing` hands out a pacer per window. `observe` records one frame's `{ visible, contentType, drew }` and answers the rate in hertz, or nil for unthrottled, and whether it differs from the previous answer. `visible` is required. `drew` is whether the client committed a new buffer since the previous observation, and an observation without it adds no sample to the history, so a caller that cannot tell says nothing rather than reporting a quiet frame. A window is exempt when its content type is one the tuning exempts or when at least the `busy` fraction of the recent samples carried a commit; an exempt window out of view is paced at the `exempt` rate, any other window out of view at the `background` rate, and a window in view is unthrottled. A pacer with no samples is not busy, so a new window is judged on its hint alone.

The built-in `@lunette-plugins/pacing` provider's options are `tuning`, with `background`, default 1 Hz, the native floor; `exempt`, default 30 Hz; `history`, the samples kept, default 90; `busy`, default one half; and `exemptTypes`, a flag for each of `none`, `photo`, `video`, and `game`, by default `video` and `game`; and `choose(pacer, observation, base)`, an around hook whose `base` is the rule above. A rule answers nil or a finite rate above zero, and anything else raises from `observe`. `@lunette-plugins/pacing/pacer` is the pure rule, `pacer.new { tuning, choose }` and `pacer.rule(tuning)`.

`lunette/scale` hands out a chooser per output. `choose(distance)` answers the scale for the nearest panel the output's clients are shown on, `distance` metres away, and whether it differs from the previous answer. The scale is a rung of `lunette.scaleSteps()`. The first choice takes the largest rung no greater than the ideal scale; after it, the chooser climbs a rung only when the ideal passes that rung by the `raise` fraction and gives one back only when the ideal falls below the current rung by the `lower` fraction, as many rungs as the ideal has moved, so an ideal inside the band around a rung changes nothing. A distance that is not a number raises.

The built-in `@lunette-plugins/scale` provider's options are `tuning`, with `reference`, the distance at which the ideal scale is 1, default one metre; `raise`, default 0.06; `lower`, default 0.12; and `nearest`, the closest a panel is treated as being, default 0.05 metres; and `ideal(distance, base)`, an around hook whose `base` is `reference / max(distance, nearest)`. An ideal that is not a number above zero raises from `choose`. The ladder is not an option, because a second ladder would make a raised panel ask the layer pool for a rung it does not hold. `@lunette-plugins/scale/chooser` is the pure rule, `chooser.new { steps, tuning, ideal }` and `chooser.ideal(tuning)`.

Neither provider requires a contract or holds a resource, and a pacer or chooser is released with the last reference to it. The `desktop/pacing` and `desktop/scale` entries apply them each frame, and [Default configuration](stdlib.md#default-configuration) states what each reads, what a monitor panel does, and what unloading undoes.

## Text boundaries

`lunette.textBoundaries(text)` returns a fresh array of one-based UTF-8 byte offsets at Unicode extended grapheme boundaries. The array starts with 1 and includes the terminal offset `#text + 1` exactly once. The empty string returns `{ 1 }`. A range between adjacent offsets contains one complete extended grapheme cluster. The helper rejects invalid UTF-8 instead of repairing it or dropping bytes. `crates/lunette/src/lua/text.rs` owns the implementation, backed by the exact `unicode-segmentation` 1.13.3 dependency. The generated native declaration follows the registration in `crates/lunette/src/lua/mod.rs`.

The helper supplies segmentation only. Lua controls own editing, selection, and display policy. Segmentation does not provide font shaping, bidirectional layout, normalization, an IME, or preedit handling. The UI text field uses the offsets for movement, deletion, selection, and truncation, and retains UTF-8 byte offsets rather than treating byte positions as character counts.

## Events

The native layer pushes events through LÖVR's own event queue, so lunette events interleave with `lovr.keypressed` and other LÖVR callbacks in a defined order. A listener subscribes through the module and is answered with the function that cancels it:

```lua
local cancel = lunette.onWindowOpened(function(event)
  print(event.window.title)
end)
```

Several listeners may wait on one event. They are called in the order they subscribed, each under a protected call, and a listener that raises does not stop the ones after it — a library and a configuration listening for the same event are peers, neither displacing the other.

`crates/lunette/src/events/mod.rs` declares each event once — its name, the fields its payload carries, and the expression that fills each one — and both the subscription and its payload type are generated from that declaration. The handler's parameter is typed without an annotation: `event` above is a `WindowOpenedEvent`, and `lunprocessexited` hands over a `ProcessExitedEvent` whose `outcome` is the union of the three names it can hold.

A source reload clears every native subscription before it re-runs the configuration, so a listener registered by the previous configuration is not called again. A plugin subscribes through `Context:on`, which ends the subscription with the activation; [Plugin authoring](#confinement) states why. A subscription made outside a plugin lasts until it is cancelled or the next source reload clears it.

`boot.lua`'s poll loop unpacks four arguments, so a payload of more than four values would not arrive. Every event carries a table instead, including the events with one field, so the shape does not differ between callbacks and a field added later is not a change to a signature.

`event.outcome` on `lunprocessexited` says which of `event.code`, `event.signal`, and `event.message` is present, and `ProcessExitedEvent` carries the three names it can take. A program that never started is reported this way and no other, so a mistyped `argv` reaches the configuration here.

An event is delivered against the snapshot of the frame it was drained in. `onWindowClosed` therefore hands over a handle that is already dead; it still reports the title, size, and identifier the window had.

An error raised by one of these handlers is reported and does not stop the frame's remaining events from being delivered.

A pointer picks from surfaces rather than from panels alone. A surface answers where a ray meets it and how far away that is; a panel is one, backed by a window or a monitor, and a virtual keyboard is another, drawing itself. `@lunette-contracts/surface` and the interaction contract state it. Nothing in `lunette` knows about it: picking, hovering, and grabbing are policy, and the native layer supplies only the sink a panel routes to.

Finer-grained notifications are implemented in Lua. The native layer pushes flat events; a provider builds the notifications its contract needs on top of them, such as the panels contract's `onAdded` and `onRemoved`, and registers each listener on its caller's owner. Nothing native knows about them, so they stay replaceable with the provider.

## Handles

Window, monitor, process, seat, output, and claim handles are persistent objects with stable identity, refreshed at frame start. See [Architecture](architecture.md#handles) for the model and for why dead handles go inert rather than raising.

Reads are snapshot fields. Mutations are requests:

```lua
print(win.title)             -- last frame's value.
print(win.appId)             -- the client's application identifier.
print(win.width, win.height) -- the surface's size in pixels.
print(win.opaque)            -- true when the buffer's fourth component is padding, not alpha.
print(win.contentType)       -- 'none', 'photo', 'video', or 'game': what the client says it draws.
print(win.output)            -- the output the client is shown, or nil.
print(win.commit)            -- changes whenever the client commits a new buffer; 0 before the first.
win:resize(1920, 1080)       -- a configure request; the client may ignore it.
win:setFrameRate(10)         -- how often this client is let draw; nil for unthrottled.
win:close()                  -- a close request, not a kill; watch for lunette.onWindowClosed.
win:getTexture()             -- this frame's pixels; never cache it.
win:stabilize()              -- a persistent texture, at a copy per damaged frame.
win:setProperty('pose', p)   -- keeps a value for this window across a reload.
win:getProperty('pose')      -- what was kept, or nil.
win:properties()             -- every key this window is carrying, as a table.
```

`win:close()` sends the xdg-toplevel close request. The client decides what to do with it: an editor with unsaved work puts up a prompt, and a client is free to ignore it entirely. The window goes when the client unmaps it, which arrives as `lunette.onWindowClosed`.

`win:resize(width, height)` configures the toplevel. The client resizes at its own pace, and `win.width` and `win.height` change when it commits a buffer — which may be at a different size, because a client is free to honour its own minimum or to round to a character cell. Nothing waits for that. The dimensions are whole pixel counts of at least one, and a value that is not raises.

Both return `false` on a dead handle, without raising. Both are requests, so neither reports what the client did; that arrives as an event or as a changed snapshot field.

`win:setFrameRate(hz)` sets how often the compositor answers this window's frame callbacks, which is how often its client draws. `nil` returns it to unthrottled, which is where every window starts; throttling is asked for rather than imposed. The rate is a finite number of hertz above zero, and a value that is not raises.

The rate is a ceiling with a floor under it. A rate below approximately 1 Hz is paced at 1 Hz rather than honoured, because a client answered no frame callbacks stops pumping its event loop and stops answering input with it — the difference between a panel that is cheap and one that appears hung. [Rendering](rendering.md#frame-pacing) states the rest. Which window deserves which rate is policy, which the pacing provider and `desktop/pacing` hold ([Frame pacing and output scale](#frame-pacing-and-output-scale)); this is the mechanism it is built on.

`win:stabilize()` is described in [Rendering](rendering.md#windowstabilize).

`win.opaque` reports that the window's current buffer has no alpha channel, so its fourth component is padding a caller forces to one rather than sampling. It is a property of the buffer and changes when the client renegotiates its format, so it is read each frame alongside the texture. [Rendering](rendering.md#alpha) states what a consumer does with it, and why premultiplied blending is the other half of the same subject.

`win.contentType` is `wp_content_type_v1`, and is a hint rather than a fact. The protocol has no events and no way to ask, and adoption is thin and uneven: a client playing video commonly reports `'none'`, and one reporting `'video'` may be paused on a still frame. It is reported rather than acted on, and the pacing provider's pacer combines it with an observed commit rate, read from `win.commit`, to decide what is exempt from throttling. A configuration that wants a different rule has both halves.

`win.commit` names the buffer the window's pixels came from. It is a number that changes whenever the client commits a new buffer, taken from a counter every surface shares and that never restarts, so a value is never repeated for a different buffer; it is 0 before the client's first buffer and once the window is gone. A caller that reads it each frame learns whether the client drew in between, which is the observed commit rate pacing needs.

`win.output` is the output the window's client is shown, the one whose scale and refresh rate it lays out against: the output it was spawned with, or the one every session starts with. It is read from the frame's snapshot, so a client whose output was destroyed reports the starting output it was moved to. It is nil for a handle that has never seen its window in a snapshot.

`win.width` and `win.height` are pixels, and report the size the client last committed rather than the size last requested of it. They are part of the native surface rather than something the standard library derives, because converting a ray hit on a panel into a pixel coordinate for `sink:pointer` needs them, and the standard library reaches for nothing the public API does not expose.

## Per-window properties

A source reload retains the Lua state, but clears configuration modules and callbacks. Configuration locals are recreated when `main.luau` runs again. Globals and values retained by protected modules remain in the state. `win.userdata` holds a Lua value on the handle; the native property store remains outside Lua:

```lua
win:setProperty('pose', '0 1.6 -1.5')  -- a number, a string, a boolean, or nil to remove.
win:getProperty('pose')                -- what was kept, or nil.
win:properties()                       -- { pose = '0 1.6 -1.5' }, a fresh table each call.
```

The two are for different lifetimes and both are wanted. State a rule can derive comes back when the rules re-run, and `userdata` is the right place for it. A pose the user placed by hand, a size they dragged, or a tag they assigned by hand is derivable from nothing, and a reload that lost it would scramble a hand-arranged workspace.

A property is a number, a string, or a boolean. A table raises, with the key named: a table holds Lua values, which is the same problem one level down. A caller wanting structure encodes it into a string and knows that it did. A number that is not finite raises for the reason a layer priority that is not does — it is a defect in the caller's maths, and one that came back after a reload would be much harder to trace. `nil` removes the key.

`win:setProperty` returns `false` on a dead handle, like every other mutation; the entries of a window that has gone are dropped, so there would be nothing to store into. `win:getProperty` still answers on one, for the reason a dead handle still reports its title: `lunette.onWindowClosed` is dispatched against the frame the window has already left, and a handler tidying up after a panel is exactly who wants to read what that panel stored.

`win:properties()` exists so that what survived a reload can be discovered rather than guessed at. A configuration that stores under a key it computed — a tag name, a monitor identity — cannot enumerate its own keys once the state holding them has gone.

Entries live as long as the window and not as long as the Lua state. A reload leaves them untouched; a window closing drops them.

`win.id` is stable for the window's whole life, and a source reload does not change it. The compositor thread is not restarted by a source reload, so the identifiers it minted remain valid and a configuration can re-associate with a window by reading `win.id` again. A hard restart does not change this either. It destroys the graphics device and the XR session, but the compositor thread survives both, so the identifiers stay valid across it. See [LÖVR integration](lovr-integration.md#restart-semantics). A hard restart replaces the Lua state, so configuration values that must survive belong in the property store or in persistent data keyed by a durable identity such as `win.appId` or a monitor identity.

Writing properties to disk is outside the native store's contract. A configuration or Lua library decides which values to persist across a hard restart.

## Outputs

An output is a virtual monitor lunette shows to the clients assigned to it. It is not one of the user's own screens — those are monitors, below — and it is not a panel; it is what a client sees when it asks what display it is on.

```lua
local out = lunette.newOutput{ width = 1920, height = 1080, scale = 1.5, refresh = 90 }
local steps = lunette.scaleSteps()   -- the scale ladder, ascending.

for _, output in ipairs(lunette.outputs()) do
    print(output.id)                     -- the compositor's identifier.
    print(output.dead)                   -- whether the compositor has this output right now.
    print(output.width, output.height)   -- the mode, in pixels.
    print(output.scale)                  -- the scale factor, fractional.
    print(output.refresh)                -- hertz, not the millihertz the protocol carries.
    output:setMode{ scale = 2 }          -- change the mode; unnamed fields are kept.
    output:destroy()                     -- withdraw the output.
end
```

`lunette.newOutput` returns a handle before the compositor has made the output, so `output.dead` is true in the frame that created it — the same rule `lunette.newSeat` and `lunette.spawn` follow. Until then the handle reports the mode it was asked for.

`width` and `height` are required and are whole pixel counts; a monitor with no size is not one a client can lay out against. `scale` defaults to 1 and `refresh` defaults to 60. A scale or a refresh rate that is not finite and positive raises, because a client told its monitor has a scale of zero divides by it.

`refresh` is in hertz here and in millihertz on the wire. Nothing above the native boundary deals in millihertz.

Refresh is advertisement, not pacing. It is what a client reads off `wl_output.mode` and reasons about; how often the compositor actually answers a surface's frame callbacks is `window:setFrameRate`, which is separate.

`output:setMode` keeps the fields it was not given, so `setMode{ scale = 2 }` changes the scale alone. Clients reallocate their buffers and re-lay-out in response, and some — GTK in particular — do it aggressively, so a configuration that adjusts this continuously will see them struggle. The scale provider moves between discrete steps with hysteresis for that reason.

`lunette.scaleSteps()` answers with the scale ladder, ascending, as plain numbers. It is the same ladder a claimed layer's requested size is quantised against ([Rendering](rendering.md#the-layer-pool)), and it is one ladder rather than two so that raising a panel's scale asks the pool for a rung the free list already holds instead of forcing an allocation. Each call returns its own table, so writing into what one call handed back does not change what the next reads. The scale provider's choosers move along it with hysteresis; a configuration that wants different steps is choosing among these, not adding to them.

`lunette.spawn{ output = out }` is how a client is assigned one, and it takes an output handle rather than an identifier so that a number in range cannot be mistaken for one. The assignment is made at spawn and lasts the client's life; there is no way to move a running client to another output, because the filter is only consulted when a client reads the registry or binds, so a change would have to withdraw the global and create a new one — which the client experiences as a monitor unplugged and replugged. Changing the mode of the output a client is already on is the supported operation.

A session starts with one output, and it is what a client that was assigned none is shown. Every client adopted from outside lunette is one of those, since nothing spawned it and so nothing named an output for it, and a client with no `wl_output` at all cannot pick a scale or a refresh rate. That one refuses to be destroyed, as the seat every session starts with does: `output:destroy()` on it returns `false`. Destroying any other output moves its clients to that starting output rather than leaving them on one that no longer exists: their assignment is cleared, their windows are reconfigured against the starting output's bounds, and the starting output's global is withdrawn and advertised again so a client that has already read the registry is offered it. Those clients see one monitor unplugged and another plugged in, which is the same cost `lunette.spawn{ output = out }` records for the reassignment it does not offer. Transform and physical size are not settable: the physical size is derived from the mode so that a client's density guess agrees with the scale lunette advertises.

## Monitors

`lunette.monitors()` returns the user's own screens. Lunette prefers direct host `wlr-screencopy` capture when the pinned backend can use it, with the screencast portal and PipeWire as fallback. These screens are not hosted compositor windows or outputs; a window belongs to a client lunette runs, and a monitor belongs to the host desktop.

```lua
for _, monitor in ipairs(lunette.monitors()) do
    print(monitor.id)              -- the saved identity, stable across a restart.
    print(monitor.name)            -- as a user would recognise it: 'Acme X24 on DP-1'.
    print(monitor.width, monitor.height)               -- the host mode, in pixels.
    print(monitor.x, monitor.y)                        -- where it sits, in logical coordinates.
    print(monitor.logicalWidth, monitor.logicalHeight) -- its desktop-oriented logical size.
    print(monitor.mirrored)        -- whether a capture stream is installed.
    print(monitor.pending)         -- whether a mirror request is outstanding.
    print(monitor.frameTransform)  -- current frame's UV transform, or nil.
    monitor:getTexture()           -- latest captured pixels, or false; read each frame.
    monitor:mirror()               -- request capture; the portal fallback may prompt.
    monitor:setPaused(true)        -- pause PipeWire; pinned direct pause is a no-op.
    monitor:dismiss()              -- remove the active mirror and its texture.
end
```

The list is ordered by identity rather than by the order the host enumerated the screens, so an arrangement derived from it does not change when a cable is replugged and nothing else has.

`monitor.id` is the identity described in [Host desktop](host-desktop.md#identity-and-lifecycle): the make and model where the host reports one, a connector name where it does not, and the monitor's logical position where neither is available. It is what a table of per-monitor state is keyed by; connector and position fallbacks do not survive every rearrangement.

`monitor.width` and `monitor.height` report the host's mode in pixels, not the captured texture's dimensions. `monitor.logicalWidth` and `monitor.logicalHeight` describe the desktop-oriented logical rectangle, accounting for scale and output rotation. The built-in panels derive proportions from this logical size. Monitor sinks accept pixel-space coordinates over the reported mode dimensions and normalize them into that logical rectangle; they do not rotate an already desktop-oriented panel hit again.

`monitor.directCapture` reports whether the active stream uses `wlr-screencopy`. It is false before a stream starts and for portal capture. A source reload retains streams requested again by the replacement configuration and stops streams it no longer requests. A failed or cancelled portal request remains refused until an explicit `lunette.selectMonitors()` action.

`monitor:mirror()` requests capture, not a first frame. Direct setup can install a stream during the call and inherits the pinned client's synchronous initialization. A request made before graphics initialization waits for a later frame. Portal permission is asynchronous and may put a dialog on the user's screen. `monitor.pending` reports an outstanding request, while `monitor.mirrored` reports an installed stream, which may not yet have produced pixels. It returns `false` when the monitor is gone or capture setup is refused. The pinned direct backend has no asynchronous failure channel, so `mirrored` is not proof that frames are still arriving.

Capture starts lazily. `monitor:mirror()` first tries direct capture; only a monitor needing fallback requests a portal session. Explicit `lunette.selectMonitors()` requests a fresh portal grant even when direct capture is available.

`lunette.selectMonitors()` requests a fresh selection without a restore token. It returns `(true, nil)` when the request starts, or `(false, message)` when no host monitors are attached, another request is pending, or the portal refuses the request. `lunette.monitorSelection()` returns a detached `{ state, message? }` record. `state` is `idle`, `pending`, `ready`, or `failed`. Existing captures continue while selection is pending or refused. A successful grant replaces PipeWire streams and restore tokens but retains active direct streams; portal revocation likewise leaves direct streams running. A grant with no identifiable attached monitor reports failure and retains the previous captures. A monitor dismissed while selection is pending remains dismissed. Polling does not reopen a refused dialog.

Direct capture requests an embedded cursor. The portal client prefers a cursor embedded in the captured pixels, then cursor metadata, then hidden capture. Embedded cursor pixels appear through the normal monitor shader. Metadata-only cursor presentation is not implemented; such a backend can still produce a mirror without the host cursor.

`monitor:dismiss()` removes the active mirror and its texture. PipeWire drops and joins its worker, retaining the portal session so a covered monitor can be mirrored again without another prompt. The pinned direct backend has no cancellation or joined-drop contract, so its worker may remain detached and dismissal does not guarantee zero remaining capture cost. It returns `false` when no mirror was active; dismissing twice is not an error.

`monitor:getTexture()` returns the latest captured texture, valid for the current frame only. Direct and PipeWire capture cycle small buffer pools, so read it again each frame rather than caching it. It returns `false` when the monitor is gone, it is not mirrored, or it has produced no usable frame yet. Descriptor-backed shared-memory frames can refill a texture instead of replacing it.

`monitor.frameTransform` is nil without an installed frame. Otherwise it is one of `'undefined'`, `'normal'`, `'rot90'`, `'rot180'`, `'rot270'`, `'flipped'`, `'flipped90'`, `'flipped180'`, or `'flipped270'`, describing the UV transform for that texture. The built-in panels apply WayVR's rotation and flip permutations on flat and curved geometry. Undefined and normal sample unchanged: the pinned PipeWire backend reports undefined, while direct raw capture reports the output transform. The value refreshes when a texture is reused or refilled and is independent of the host mode dimensions.

`monitor:setPaused(paused)` deactivates or reactivates PipeWire while retaining its session. The pinned direct backend accepts the request but its pause and resume methods are no-ops. Use `dismiss` to remove a closed panel's active mirror, without assuming it cancels a direct worker.

`lunette.onMonitorAdded` fires for each monitor at startup and for each one attached afterwards. It carries `event.id`, and `event.monitor` when the screen is still attached by the time the handler runs.

## Sinks and input domains

A sink is somewhere pixel-space input can be delivered. `window.sink` names one for a window lunette hosts, and `monitor.sink` names one for a mirrored screen, and the two behave differently in a way that is exposed rather than hidden:

```lua
print(sink.domain)             -- 'window' or 'host'.
print(sink.window)             -- the window a window sink reaches, or nil.
print(sink.monitor)            -- the monitor a host sink reaches, or nil.
print(sink.id)                 -- the compositor's identifier, or nil for a host sink.
sink:pointer(x, y)             -- pixel coordinates on the target.
sink:button('left', true)      -- press; false releases.
sink:leave()                   -- the pointer stops hovering; focus is untouched.
sink:scroll(dx, dy)            -- a continuous distance, in surface-local pixels.
sink:scrollDiscrete(dx, dy)    -- whole wheel notches.
sink:key(keycode, true)        -- an evdev keycode; false releases.
sink:modifiers{ 'shift' }      -- the modifiers held from now on.
sink:typeText('café')          -- text, whether or not the layout can express it.
```

A window sink's events go to that client through its seat, so each window has independent focus and its own cursor. A host sink's go to the user's desktop through lunette's input provider, and every host sink shares one cursor and one keyboard focus, because the host has one of each. Two hands pointing at two mirrored monitors cannot produce two cursors. [Host desktop](host-desktop.md#the-input-domain-leak) states why that is surfaced rather than papered over.

`sink:pointer` and `sink:button` take pixel coordinates on their target — the window's committed size, or the monitor's resolution. A coordinate that is not finite raises, because it is a defect in the caller's maths rather than a race. Every method returns `false` on a dead handle without raising: a client can exit, and a monitor can be unplugged, between the raycast and the click.

`monitor.sink` exists whether or not the monitor is mirrored. Pointing at the host desktop does not require lunette to be showing it.

`sink:leave()` is hover, not focus. It withdraws the pointer from whatever it was over without changing which sink holds the keyboard, so a panel library can highlight what one hand is pointing at without that hand taking the keyboard from the other. It returns `false` on a host sink: the host cursor is always somewhere on the host desktop, and there is no position that means "nowhere".

The two scroll methods are separate because the protocol keeps the two sources apart. A notched wheel sends whole steps and a trackpad sends a continuous distance, and a client uses the difference to decide whether to scroll kinetically. An axis whose delta is zero sends nothing. A host sink takes both axes and converts to wheel detents, at ten surface-local pixels per detent.

`sink:key(keycode, pressed)` takes an evdev keycode, which is what `wl_keyboard` carries and what `seat:strokeFor` hands back. On a window sink it goes to the seat's keyboard and so reaches whichever client that seat is focused on; a seat with no focus delivers to nobody. On a host sink it reaches whatever the host compositor currently focuses, and lunette does not choose what that is. A keycode outside the set lunette's host provider declared is refused with `false` rather than sent, because the kernel would otherwise drop it without a word.

`lunette.keyCodes()` answers a fresh table from key name to evdev code, such as `codes.leftShift` for 42, so a configuration does not write keycodes as numbers. The names are camelCase and the set is the host sinks' `VirtualKey` in `crates/lunette-capture/src/hid/key.rs`, so every named key reaches a host sink as well as a window's seat; a key outside it still reaches a seat by number. The table's Luau type is keyed by `lunette.KeyName`, so indexing it with a misspelt name is a type error. `crates/lunette/src/lua/keys.rs` gives the names, and `crates/lunette-capture/tests/evdev_codes.rs` checks the codes against xkeyboard-config's evdev table.

`sink:modifiers(names)` replaces the modifiers held, rather than pressing modifier keys. `lunette.modifierNames()` answers with the names it takes, in the order a keymap numbers them, and an unrecognised one raises; `KeyModifier` in `crates/lunette-compositor/src/protocol/input.rs` is where the set is declared and everything else derives from it. `lunette.lockingModifierNames()` answers the subset a keymap reports as locked rather than held, `capsLock` and `numLock`: a press turns one on and the next press turns it off. A host sink refuses a set containing `mod3`, because neither the virtual-keyboard protocol nor uinput has a bit for it and applying the rest would leave the host holding something the caller did not ask for.

`sink:typeText(text)` is an escape hatch, and explicitly stateful. Text the active layout can type goes down the ordinary path and changes nothing; the rest makes lunette generate a temporary keymap, upload it, type against it, and put the client's own back. So it must not be interleaved with `sink:key` on the same seat, and a client may see its keymap change while it runs — which is legal, and is the price of entering text no layout binds. Text needing more distinct keysyms than one keymap holds is split into runs that fit rather than refused. It is refused on a host sink, because lunette does not own the host's keyboard well enough to promise the layout it took can be given back.

Every one of these methods takes an optional trailing seat. Leaving it off addresses the seat every session starts with, which is what a configuration that never calls `lunette.newSeat` wants. A host sink ignores the argument: the host has one cursor and one keyboard focus however many hands point at it.

## Seats

A `wl_seat` carries exactly one pointer and one keyboard, so two simultaneous cursors need two seats and the protocol offers nothing else. [Input](input.md#seats) states why.

```lua
local left = lunette.newSeat('left', { layout = 'de', repeatDelay = 200, repeatRate = 50 })

for _, seat in ipairs(lunette.seats()) do
    print(seat.id, seat.name)      -- the identifier, and what clients see on wl_seat.name.
    print(seat.dead)               -- whether the compositor has this seat right now.
    print(seat.modifiers)          -- an array of names; what clients were last told.
    print(seat.layouts)            -- an array of one: 'English (US)', not 'us'.
    print(seat.clipboardBridge)    -- whether this seat's selections are the host's.
    seat:setFocus(win.sink)        -- gives this seat's keyboard to a sink; nil withdraws it.
    seat:setModifiers{ 'shift' }   -- the same request sink:modifiers makes.
    seat:symbolFor(30)             -- the keysym a keycode produces, or nil.
    seat:characterFor(30, { 'shift' })  -- the text it types, or nil.
    seat:strokeFor('A')            -- { keycode = 30, modifiers = { 'shift' } }, or nil.
    seat:setClipboardBridge(true)  -- makes this seat's selections the host's.
    seat:destroy()                 -- withdraws the seat.
end
```

`lunette.defaultSeat()` returns the seat used when a native input call omits its trailing seat argument. It returns nil when that seat is absent from the current frame snapshot; it does not substitute the first seat in `lunette.seats()`. Each call returns a fresh handle, so identity comparisons use `seat.id`, not Lua wrapper equality. The generated declaration is `read defaultSeat: () -> Seat?`; `crates/lunette/src/lua/mod.rs` owns the registration and declaration metadata.

`lunette.newSeat(name, options)` returns a handle before the compositor creates the seat. `seat.dead` is true until a snapshot contains it. The name identifies the seat to clients, so an existing or pending seat with that name raises. The reservation survives command flushes and source reloads. Queuing `seat:destroy()` releases the name immediately, allowing a replacement to queue after the destruction in the same frame. `crates/lunette/src/lua/seat.rs` owns this bookkeeping; snapshot reads remain unchanged.

The options are the five names libxkbcommon compiles a layout from — `rules`, `model`, `layout`, `variant`, and `options` — plus `repeatDelay` in milliseconds and `repeatRate` in repeats per second. An absent layout name takes the desktop's own default, read from the `XKB_DEFAULT_*` variables, which is what a user who configured a layout for their session expects lunette to inherit. Key repeat defaults to a 200ms delay and 50Hz, and a rate of zero disables it; the timing is policy, so it lives here rather than in the native layer. A layout that does not compile is reported in the log and the seat never appears.

A seat carries exactly one layout, so `layout` naming several — `'us,de'` — is refused and the seat never appears. Every keymap query answers for the seat's one layout and nothing can read or set an active group, so a seat with two would answer for the first whichever one the user had switched to. A configuration wanting two layouts makes two seats. [Input](input.md#decisions) records the reasoning and what lifting it would take.

An inherited default naming several layouts is treated differently, because a desktop configured with `us,de` is ordinary and the user did not ask lunette for anything. The list is narrowed to its first entry, with the matching entry of the variant list, and the seat is created on that one layout. The narrowing is reported in the log, with the note that a second layout wants a second seat. So `layout = 'us,de'` leaves the seat uncreated, and `XKB_DEFAULT_LAYOUT=us,de` does not.

`seat:setFocus(sink)` is what gives a client the keyboard. Nothing infers focus from pointer motion — that heuristic is what makes a second hand steal focus by hovering — so a configuration that wants focus-follows-hover writes it. `nil` withdraws focus. A host sink returns `false`: which window on the host desktop holds the keyboard is the host compositor's decision.

`seat.layouts` is an array of one, for the reason above; it is an array because that is what `wl_keyboard`'s keymap carries and a second entry becomes possible if group switching ever lands. It, `seat:symbolFor`, `seat:characterFor`, and `seat:strokeFor` are the keymap queries [Input](input.md#keyboard) asks for. They are what lets a virtual keyboard draw correct legends and produce correct keycodes without reimplementing xkb in Lua. All of them answer from the seat's own layout, so two seats on different layouts answer differently.

`seat:strokeFor(value)` is the reverse lookup. A string is read as the character to type and a number as a keysym, and the answer prefers the fewest modifiers and then the lowest keycode, so a digit resolves to the number row rather than the keypad. It returns `nil` for anything the layout cannot express — that is what `sink:typeText` is for — and raises on a string of more than one character, because a stroke produces one keysym.

`seat.clipboardBridge` and `seat:setClipboardBridge(bridged)` are the host clipboard's one connection to a seat. The host desktop has one clipboard and one primary selection while every seat has its own, so exactly one seat is bridged: its selections are the host's in both directions, and every other seat's stay inside lunette. Bridging a seat takes the bridge off whichever seat had it, and passing `false` on a seat that is not the bridged one does nothing, so a configuration can call either without first asking which seat holds it. The seat every session starts with is bridged, so a configuration that never mentions the clipboard behaves as a single-seat compositor does. [Input](input.md#clipboard) states the mapping and [its decisions](input.md#decisions) state why it is one seat rather than all of them.

A selection the newly bridged seat already held is not pushed to the host retroactively; the next copy on that seat crosses. Both calls return `false` on a dead seat, like every other seat method.

`seat:destroy()` queues withdrawal of a published seat or cancellation of a pending creation. It returns `false` for the default seat, an already requested destruction, or a previously published seat that has disappeared. Cancellation is allowed while `seat.dead` is true before publication. A creation that fails asynchronously has no failure acknowledgement, so its name remains reserved until the retained handle is destroyed. Destroying the handle releases that name without requiring the seat to appear.

## Layer claims

A panel renders either as an in-scene quad or on an OpenXR composition layer. The second is sharper, because the runtime composites the source at its native resolution instead of resampling lunette's own resampling of it. Layers are scarce, so a panel asks for one:

```lua
local claim = lunette.claimLayer{
    window = win,               -- the source whose pixels the layer carries.
    width = win.width,          -- the requested size, in whole pixels.
    height = win.height,
    priority = 10,              -- where this ranks against every other claim.
}

print(claim.granted)         -- whether it holds a layer this frame.
print(claim.layer)           -- the LÖVR Layer, or false; never cache it.
print(claim.width, claim.height) -- the layer's size, not the requested size.
print(claim.window)          -- the source it was made for.
print(claim.priority)        -- the number last supplied.
claim:setPriority(20)        -- reranks it; takes effect at the next boundary.
claim:release()              -- withdraws it, returning the layer to the pool.
```

`claim.layer` is a real LÖVR `Layer`, not a wrapper, so `setPose`, `setDimensions`, `setCurve`, `setViewport`, `getTexture`, and the rest are the documented `Layer` methods. It is `false` whenever the claim holds none.

The priority is Lua's own number and lunette never invents it. Rust sorts by it, stably, and assigns the top N; focus, gaze, distance, a rule ranking video above a terminal, and hysteresis to stop grants flapping are all cases of computing a different number. A priority that is not orderable — nan — raises, because a claim silently keeping its old ranking would be diagnosed as the pool misbehaving.

`claim.width` and `claim.height` report the layer's size rather than the size that was asked for. Requested sizes are quantised to a ladder of discrete steps, described in [Rendering](rendering.md#the-layer-pool), so the layer is at least as large as the request and usually larger. A caller setting the layer's viewport wants the rung.

Grants and revocations land on frame boundaries and never mid-frame, so a panel's realisation cannot change between its `lovr.update` and its `lovr.draw`. A fresh claim therefore holds nothing in the call that made it, and may hold nothing indefinitely if higher-priority claims keep the pool full. Both paths are live from the start: the in-scene quad is the fallback, not a degraded mode.

Grants and revocations also arrive as callbacks, so a panel does not have to poll for them:

```lua
function lunette.onLayerGranted(event)  -- event.claim, event.layer.
function lunette.onLayerRevoked(event)  -- event.claim.
```

Both fire at the boundary the change lands on, before `lovr.update`, so a handler reading `event.claim.granted` agrees with the event it was handed. `lunlayerrevoked` carries no layer because there is none by then. An error raised in either handler is reported and changes nothing: both had already happened before the handler ran.

Revocation does not kill the claim. `claim.granted` goes false and `claim.layer` answers `false`, and the claim takes a layer again as soon as one frees and nothing outranks it — which is what makes the upgrade automatic. A claim is dead only after `claim:release()`, and a dead handle reads its last-known values and answers `false` from its methods.

Releasing is explicit. Nothing releases a claim when its handle is collected, because the grant and revoke events carry a second handle to the same claim and collecting that one would withdraw a live claim. A configuration that drops a panel releases the panel's claim.

## Scene rendering

Once every panel is on a composition layer there is nothing left for lunette to draw itself, and drawing an empty projection layer costs a swapchain acquire, a render pass, and a multisample resolve every frame for no picture.

```lua
lunette.setSceneEnabled(false)   -- skip lunette's own scene rendering.
print(lunette.sceneEnabled())    -- what was last asked for.
```

Skipping means `lovr.draw` is not called and the projection layer is left out of the frame. The XR frame is still submitted, and the composition layers still are, so panels on layers keep updating; what stops is lunette's own rendering. [Rendering](rendering.md#frame-pacing) records what an idle frame still costs.

A change takes effect at the next frame boundary rather than immediately, because the frame's layer list has already been submitted with the answer the frame started with. A configuration therefore sets this from `lovr.update` and reads the effect on the frame after.

Deciding is the configuration's, and lunette has no way to check. Everything drawn in `lovr.draw` is the configuration's own: a panel that holds no layer, a panel's chrome, a laser, an error panel, or anything else it draws. Turning the scene off while still drawing means the drawing does not happen, and the value defaults to on so that a configuration that never mentions it behaves as it always did. No built-in provider or consumer sets it, and the shipped configuration does not either: it draws chrome around every panel and a laser for every hand, so its scene is never empty.

## Reload

Source reload and hard restart preserve running applications. Plugin instance reload is a separate operation that replaces one activation within its runtime.

`lunette.reload()` performs a source reload in the current Lua state. It shuts down plugin runtimes, which advances the plugin contract epoch, clears native event subscriptions, clears the callbacks owned by `main.luau`, drops unprotected entries from `package.loaded`, and runs `main.luau` and `lovr.load` again. It retains the LÖVR modules, XR session, GPU objects, compositor, and clients. Globals and the Lua state remain. A failed reload leaves the session running with whatever the failed configuration installed before it raised.

Plugin effects are the only cleanup a source reload runs, and the native plugin runtime runs them. A Lua module that creates resources outside a plugin must release them through another lifecycle path or tolerate their continued existence.

The order is: plugin runtime shutdown and contract epoch reset, subscription clearing, callback clearing, `package.loaded` clearing, `main.luau`, then `lovr.load`. `lovr.load` runs because `main.luau` conventionally defines callbacks and does its setup there, so a reload that ran only the file would install the new callbacks and never run the new setup. It receives the same `arg` it is given at startup.

What survives is stated as roots rather than as a list of what goes, so that a module added later is cleared without the mechanism being updated. `lovr.*` and the libraries Luau registers, such as `string`, `table`, `math`, `os`, `coroutine`, `debug`, `bit32`, `utf8`, `buffer`, and `vector`, are kept; everything else goes. `crates/lunette/src/reload.rs` is the source of truth for both that set and the callbacks cleared, which deliberately exclude the ones `boot.lua` defines defaults for: `boot.lua` runs once per Lua state, and a soft reload does not make a new one, so clearing `lovr.log` would remove a default nothing would put back.

The Lua state itself is not closed. Globals and protected modules survive. `main.luau` locals are recreated when its module is run again. Values in modules whose `package.loaded` entries are cleared are recreated only if the new configuration requires them. A hard restart replaces the state and its globals.

Clearing the callbacks matters for the case the file no longer mentions them. Re-running `main.luau` redefines the callbacks it still defines, but a callback the user *deleted* would otherwise stay bound to the old function and keep being called, so a reload would silently keep executing code that is no longer in the file.

`lunette.reload()` answers `true`, or `false` and a message. It does not raise, and it does not fall into safe mode: safe mode is for a `main.luau` that fails to load at startup, and a reload that fails leaves the session running so the user can fix the file and reload again. A reload that reached `main.luau` and failed there has already torn the previous configuration down, so the session continues with whatever the failed run installed before it raised.

A reload asked for from inside a reload is refused with that message rather than performed. A configuration that reloads as it loads would otherwise recurse until the stack ran out, and taking the process down takes every connected client with it. In practice this means `lovr.load` is not a place to call it from; a key binding or a `lunctl` chunk is.

`lunette.restart()` performs a hard restart, using LÖVR's `lovr.event.restart`. This closes the entire Lua state and rebuilds it, tearing down graphics and the XR session with it. See [LÖVR integration](lovr-integration.md#restart-semantics). The result is a clean slate, with a visible hitch and brief blackness in the headset. It is used when a soft reload is not sufficient.

The host shuts down plugin runtimes clears native subscribers, flushes the final frame, quiesces or stops native users of the state, and closes the external LÖVR state. The next state creates a new plugin attachment and contract epoch. Lua modules that allocate native objects outside the plugin runtime get no cleanup callback before the state closes. External close still has allocator-bookkeeping concerns that this ordering does not resolve.

The host handles plugin cleanup when the event loop takes the restart, not when the restart is requested. `lunette.restart()`, a bare `lovr.event.restart()`, and LÖVR's own `lovr.filechanged` therefore use the same native shutdown order.

The call pushes the event and returns; the restart is taken once the frame's callbacks have returned and the event loop reads it. Nothing is performed inline, so there is no counterpart to the reload's refusal: a restart asked for from `lovr.load`, from inside a reload, or twice in one frame is one restart at the end of that frame. `lunette.restart()` raises only if `lovr.event.restart` cannot be reached, which is a broken build rather than a mistake in the configuration.

Wayland clients survive source reload and hard restart because the compositor owns the socket outside the Lua state. Process exit terminates them with the process.

## Errors

Three kinds of callback run under a protected call: the `lunette.on*` event listeners, plugin initializers and inverses, and the handlers a Lua dispatcher protects and reports through `lunette.reportError`, such as the frame provider's. An error raised in one of them is logged with its traceback and emitted to every `lunette.onError` listener, and execution continues: the frame's remaining events are delivered, the plugin drain goes on, and the dispatcher calls its next handler. The shipped configuration selects the built-in error stream provider, which rate-limits repeated reports, and its `desktop/errors` presenter, which draws the latest report on a floating quad.

LÖVR's own callbacks, `lovr.update`, `lovr.draw`, `lovr.keypressed`, and the others `boot.lua`'s `lovr.run` calls, are not protected by the host. An error raised in one unwinds the frame loop to `boot.lua`'s error handler, which calls `lovr.errhand` when one is defined and uses what it returns as the next frame loop. Without one, `boot.lua` prints the error and returns a loop that ends the process with status 1, which disconnects every client. Neither the host nor the shipped configuration defines `lovr.errhand`. The shipped configuration binds its frame callbacks to the frame provider, which protects each handler, so only an error in the provider's own dispatch reaches `boot.lua`. A configuration that defines `lovr.update` or `lovr.draw` itself protects its own body or accepts that an error there ends the session. [Known gaps](#known-gaps) records this.

The native side of the callback boundary is `crates/lunette/src/callback_error.rs`. It splits the message from the traceback, logs it, and notifies every `lunette.onError` listener. It does not look up a Lua handler or rate-limit errors. Each listener handles the event independently, so a configuration can omit the error stream provider. A session without a listener still gets native logging, but repeated errors are not rate-limited.

`lunette.reportError { context = ..., message = ..., traceback = ... }` reports an error through the same boundary: it is logged and every `lunette.onError` listener receives it, with `context` leading the message and the traceback optional. A missing `context` or `message`, or a field outside the three, raises. A listener that raises does not make it raise. A Lua dispatcher that calls several handlers from one callback protects each handler and reports a handler's error with it, so one handler's defect does not stop the handlers after it. The frame provider does this for `lovr.update`, `lovr.draw`, `lovr.quit`, `lovr.keypressed`, and `lovr.textinput`, and the surfaces provider for each offer, so a raising draw handler does not hide the error display that draws after it. The panels provider reports a raising panel listener the same way.

A plugin failure that happens while lifecycle work drains takes the same path. Its context names the phase and the definition, for example `plugin load: <definition> (instance 3)`, and the traceback of a raising callback is kept apart from the message. A plugin instance that is waiting for a provider is logged at information level and is not reported.

The built-in error stream provider subscribes to `lunette.onError`, rate-limits and formats reports, and delivers them to presenters, which [Errors stream](#errors-stream) states. The shipped presenter, `desktop/errors`, draws a floating quad. It does not use the panels provider because an error report has no textured source.

The native layer owns exactly one failure path: if `main.luau` fails to load, safe mode starts. This is a minimal built-in configuration with a laser, one panel, a way to spawn a terminal, and a reload key. Without this fallback, a configuration error would produce a black headset with no way to recover, requiring the user to remove the headset and edit Lua at a desk every time.

The trigger is a wrapper around `lovr.boot`, installed after `boot.lua`'s chunk has run and before its coroutine is first resumed. `lovr.boot` is the function whose failure means the configuration did not start: a source that will not mount, a missing `main.luau`, a `conf.luau` that raised, a syntax error, and an error at the top level of `main.luau` all raise inside it. So does a `lovr.load` that raises, because `lovr.boot` ends with `return lovr.run()` and `lovr.run` calls `lovr.load` before it returns the frame loop. That is intended: `lovr.load` is where a configuration builds the state its later callbacks assume, and a session whose `lovr.load` raised halfway is not one those callbacks can run in. Everything after `lovr.load` happens once the frame loop has been returned, and goes to the boundaries above instead. `lovr.errhand` would be the wrong hook, because it is reached by every error that escaped a callback boundary and because it belongs to the configuration. Safe mode replaces the callbacks a half-run `main.luau` installed, so a configuration that raised partway through does not keep running alongside it, and the load error is shown on the panel rather than only logged.

Safe mode is compiled into the binary rather than installed, and `crates/lunette/src/safe_mode.luau` is what it runs. It requires `lunette` and nothing else — never a mounted module root, since a broken installation is one of the reasons `main.luau` may have failed — so it resembles the shipped configuration without sharing code with it. [Decisions](#decisions) below records why the duplication is deliberate.

Safe mode tries `foot`, `weston-terminal`, `alacritty`, `kitty`, `konsole`, and `xterm`, in that order. `crates/lunette/src/safe_mode.luau` owns the candidate list and arguments. A `spawnFailed` outcome delivered through `lunette.onProcessExited` advances to the next candidate only when its process identifier matches the current attempt. An exit or signal from a process that started stops the search; closing a terminal does not open another. Exhausting the list reports that no terminal emulator could be spawned and leaves safe mode available for reload. Konsole receives `--separate` so an existing host instance cannot take the request over its existing display connection.

## lunctl

`lunctl` sends a Lua chunk to the running instance over a Unix socket at `$XDG_RUNTIME_DIR/lunette/lunette-0.sock`, mode 0600 inside a directory lunette creates at 0700. The chunk is evaluated on the Lua thread between frames within a wall-clock budget, and the result is serialised back.

The directory is what makes the 0600 requirement enforceable, and reproducing the path without it would reintroduce a race. `UnixListener::bind` creates the inode with `0777 & ~umask` and offers no pre-creation hook; `fchmod` on the listener's descriptor does nothing on Linux, because for a socket the descriptor refers to the socket object rather than to the inode; binding and then widening the permissions leaves a window in which a connection can be accepted and stays valid afterwards; and `umask` is process-global and not thread-safe. A directory only the owner can traverse closes all of that, whatever the socket's own mode says. `$XDG_RUNTIME_DIR` is checked for the same property at startup rather than trusted, because the specification that mandates it is not an enforcement.

```console
$ lunctl 'return #lunette.windows()'
3
$ lunctl 'for _, w in ipairs(lunette.windows()) do print(w.appId, w.title) end'
$ lunctl "return require('@lunette-contracts/vocabulary').encodePose(lovr.math.newMat4())"
```

A chunk resolves a module by its own name, so `lunette` is reachable without a `require` even though a configuration binds it to a local. The lookup is globals first and modules second, and a module name is tried as written and then under the `@` root the session registers it at, so `lunette` finds `@lunette`. Only a module already loaded or holding a registered loader resolves this way: an unknown name is `nil`, as Lua specifies, rather than a module that could not be found. A name a chunk assigns is written to the globals, so the next chunk sees it.

This is the most significant inheritance from awesome, more significant than any layout algorithm. awesome's design allows the whole window manager to be inspected and mutated from a shell prompt while it runs, which is a substantial part of its usability. `lunctl` also serves as the end-to-end test harness: it spawns a client, evaluates assertions, and tears down.

The plugin authoring API provides typed service contracts and runtime lifecycle management. It does not replace `lunctl` or make the control socket a typed protocol.

`lunctl` has three modes, which is awesome-client's shape: a chunk as an argument, a chunk on standard input, and an interactive prompt when standard input is a terminal. It has no line editing of its own; `rlwrap lunctl` supplies it. `--socket PATH` names a socket other than the resolved one, which is what the end-to-end tests drive.

The exit status says what happened, so a script can branch on it: `0` the chunk ran, `1` it raised, `2` it did not compile, `3` it ran past its time budget and was abandoned, `4` it returned something the protocol cannot carry, or more of it than one message holds, `5` the session did not evaluate it, `6` the session could not be reached, and `64` `lunctl` was invoked wrongly, which includes a chunk larger than one message carries. An answer too large is reported as the answer it is, not as a session that could not be reached: the session closing the connection would reach the client as an end of file, and a chunk that succeeded would be reported as a session that is not running. A load error and a runtime error stay apart because a caller acts differently on each; awesome collapses both into one string.

A top-level string prints without quotes and a string inside a table prints with them. The top level is what a shell captures, so `$(lunctl 'return win.title')` is the title rather than the title in quotes. A handle prints as `<window 3>`: its kind and the identity the session keys it on, and nothing a client could dereference.

Three things learned from awesome's version (awesome upstream: `lib/awful/remote.lua`):

- awesome's remote control is exposed on the session D-Bus, reachable by every process in the session, including Flatpak applications granted `--socket=session-bus`. This makes it possible for a sandboxed application to ask the window manager to run arbitrary Lua. A 0600 socket in `$XDG_RUNTIME_DIR` provides the same capability with a smaller attack surface.
- awesome enables remote control unintentionally. The manpage implies it is opt-in, but `lib/awful/init.lua:28` requires `awful.remote` unconditionally, so every configuration that calls `require("awful")` has arbitrary code execution enabled. lunctl is enabled deliberately, documented as equivalent to root access on the user's session, with a switch to disable it.
- awesome's serialisation is limited to booleans, numbers, and strings; every other value is converted with `tostring`. This is adequate for a REPL but insufficient for tooling. lunctl serialises nested tables, and represents handles as opaque ids.

No network transport is provided. The type is a Unix listener and nothing accepts a host or a port, so there is no configuration that makes this listen on a network address.

`LUNETTE_CONTROL=off` is the switch that disables it. Unset and empty leave it on, because in-headset iteration is what it exists for; any other value that is not `on` turns it off and warns. Since unset already means on, the only reason to set the variable is to turn the endpoint off, so an unrecognised value is a misspelt `off` rather than a misspelt `on`, and answering one by opening an endpoint equivalent to root access on the user's session is the failure worth protecting against.

## Bindings

The API is bound with `mlua`, which creates the session's Luau state and owns it for the session's lifetime. LÖVR steps that same state through the raw C entry points, and `mlua` reads and writes it through the Luau feature. The boot sequence keeps ownership with mlua and never closes a state it created a second time.

This choice is motivated by failure mode, not throughput. A Lua mistake should raise a catchable error rather than crash the window manager, because the premise of this project is that users write Lua that reshapes the system. mlua's per-call cost is negligible relative to the cost of a compositor and a GPU frame.

Luau has no FFI. A script that wants a C ABI directly has the standard library and the `lunette` API, and nothing else; calling native code from a configuration is not part of the contract. The `lunette check` command is available to catch a configuration that reaches for it.

The API is available only in the main Lua state. `lovr.thread` and `lovr.task` states do not receive it.

## Decisions

Choices made deliberately, recorded with their reasoning, so they are not relitigated by accident.

mlua, on Luau, not the raw C API or LuaJIT FFI. A Lua mistake must raise a catchable error, not crash the window manager. lunette runs Luau (via mlua and the LÖVR-linked fork) so that the standard library and configurations are statically checked, and because a typed dialect catches the two defect classes the interpreter alone does not (a local referenced before its declaration, and an accidental global). LuaJIT is not a build mode: the standard library carries annotations LuaJIT cannot parse, and a mode that builds and cannot run is worse than none.

Control socket over Lua eval, not a typed protocol. awesome's design has held for seventeen years. lunette changes the transport (a 0600 Unix socket, not the session D-Bus), makes it deliberate rather than incidental, and serialises properly. The plugin API is a separate in-process composition mechanism; it does not narrow the remote evaluation protocol.

The plugin types cover each service, configuration, and capability use locally. A mapped `Services<R>` and `Provisions<P>` design requires a recursive inferred type for the complete provider graph, and Luau exceeds its 20,000 subtype-normalization budget for it even with an empty initializer. Changing Luau's compiler flags or limits was rejected. Capabilities are read directly and published only from the initializer. Runtime declarations and lifecycle checks validate graph wiring; static analysis does not claim whole-graph guarantees.

`LUNETTE_CONTROL` fails closed: anything that is not `on` disables the socket. Unset and empty mean enabled, so the only reason to set the variable is to turn the endpoint off, and an unrecognised value is a misspelt `off`, such as `false`, `0`, `no`, or `disabled`. Failing open on one was rejected: it would open a socket that evaluates arbitrary Lua, with a warning on stderr that a user who set the variable in a systemd unit or a `.desktop` file does not read. The cost is a session whose `lunctl` stops working because of a typo, which is visible the moment it is used and is fixed by writing `on`.

Per-window state lives in a native store as well as in `win.userdata`, and the two have different lifetimes. `userdata` is a Lua value on a Lua handle. Source reload retains the Lua state but clears configuration modules and callbacks, so configuration locals are recreated while globals and protected modules remain. The native property store survives source reload because it is outside the Lua state. It holds values a configuration cannot derive from its rules, such as a pose or size placed by hand. The store holds a number, a string, or a boolean and refuses a table; a caller that needs structure encodes it as a string. Preserving `userdata` by serialising it during reload was rejected: it would fail on functions, coroutines, and handles or silently drop them. Entries are keyed by `WindowId` and last as long as the window. Source reload and hard restart leave the compositor thread running, so the identifier remains valid across both. Persistence to disk is outside the native store's contract.

Safe mode is a Lua chunk compiled into the binary, not a file installed beside the default configuration. It exists for the moment `main.luau` fails to load, and a broken standard library, a missing install, or a `LUNETTE_STDLIB_PATH` pointing at nothing is one of the reasons it might have, so a fallback that read anything off disk would be unavailable in many of the cases it exists for. It therefore requires `lunette` and nothing else, no mounted module root, and does its own ray-plane solve for one fixed axis-aligned panel rather than reaching for the panels provider. That duplicates a little of the shipped configuration, which is the price of always working, and both sites say so, so neither is later simplified by pointing at the other. `crates/lunette/src/safe_mode.luau` is the chunk and `safe_mode.rs` embeds it with `include_str!`, so it stays a Lua file that an editor highlights and a diff can be read against the shipped desktop's plugins in `lua/lunette-plugins/`. Installing it as a third file under `$SYSCONFDIR` was rejected: it reads better and fails in exactly the case the feature is for.

### The lunctl time budget is best-effort

A `lunctl` chunk runs under a native `lua_callbacks(L)->interrupt` callback that raises through `lua_error` once the wall clock passes its budget. The interrupt fires at safepoints (loop back edges, calls, returns, and GC), which is the bound Luau offers, so the chunk is abandoned at the first safepoint at or after the deadline. LÖVR builds Luau without native codegen, so the interpreter runs every chunk and a function the chunk calls is bounded by the same call and back-edge safepoints as the chunk itself, unless the callee is a native call.

The bound stays advisory, and the escapes are not fixable from inside Lua. An `error()` raised from the interrupt is catchable, so a `pcall` inside the user's own chunk swallows it. A loop inside a C function, a blocking allocator, or a native call does not reach a safepoint, so no VM callback interrupts it.

A hard bound would need a watchdog outside Lua. Since the chunk holds the Lua thread, the only thing such a watchdog could do is abort the process, turning a bad `lunctl` command into a crash that takes every connected client with it. That is worse than the hang it prevents, so it is not built. `lunette-v1.AC8.2`'s first clause is stated as best-effort in the design plan for the same reason, and the tests assert the escape as the behaviour it is rather than as an aspiration.

### lunctl refuses what it cannot represent

A serialiser meets values with no wire form: functions, coroutines, userdata that is not a lunette handle, and table or function keys. It errors on each, naming the path to the offending value, rather than falling back to `tostring`. Dropping content silently is a correctness bug per `CONTRIBUTING.md`, and the `tostring` fallback is exactly what [lunctl](#lunctl) criticises awesome's remote control for.

Four further cases each need an answer, and each is a source of silent corruption if left implicit.

A cycle is an error, not a back-reference. A back-reference would be more faithful, and it would make the value tree a graph that every consumer, including `lunctl`'s own renderer, has to be total over. A `lunctl` chunk that wants to inspect a cyclic structure can break the cycle itself; a renderer that has to guard against one cannot.

Shared subtables are duplicated, and identity is not preserved. That follows from the choice above: without back-references there is nothing to share with. The node cap is what keeps a wide directed acyclic graph from expanding without bound, and it produces a clean error rather than an allocation failure.

Metamethods are not honoured. Traversal is raw, so what is serialised is what the table actually holds. `__index` can fabricate fields that do not exist and `__pairs` can hide ones that do, and a wire format whose contents depend on which of those a caller happened to install is not an inspection tool.

An answer too large to send is an answer, not a closed connection. The frame cap is checked before anything is written, so a reply that does not fit leaves the session with nothing on the socket and something to say. Closing instead reaches the client as an end of file, which it can only report as a session it could not reach, a false report about a session that is running and a chunk that succeeded. `Reply::Oversized` therefore carries the size back, and `Reply::Malformed` does the same for a request the session could not read. The protocol version is 2 because of these two tags. The node cap does not make this unreachable: it bounds how many values a reply holds and not how many bytes, so an ordinary chunk returning one long string reaches it without being pathological.

A handle serialises as its kind and the identity the session keys it on, never as `tostring(handle)`. Addresses are reused after collection, so an id derived from one could come to refer to a different object, a defect that appears only under memory pressure. The identity is `win.id` and its siblings; the userdata itself is minted fresh on every read and is not identity-stable at all.

### The declarations are generated from the registration

`lua/lunette/init.luau` is what the type checker reads `require '@lunette'` as, because Luau resolves a require to a file on disk and a definitions file can only declare globals. It is generated rather than written: each property and method is declared once, beside the closure that answers it, and the same declaration registers it with mlua and states its type, its parameter names, and its prose.

The Luau type comes from the Rust one. `LuauType` maps a Rust type to its spelling, `f64` to `number`, `Option<T>` to `T?`, and a handle to its own name, so a signature is derived rather than restated, and the spelling of a type exists in one impl rather than in every signature that uses it. Where Rust says less than Luau does, a wrapper type carries the difference: a texture that may be `false`, a string that is one of four words, an option table that validates its own keys as it is read. An option table's accepted names are the declaration's field names, so a table the runtime refuses cannot be one the type offers.

A hand-written stub kept in step by hand was rejected. Nothing checks it against the Rust, so it drifts, and a member it omits makes a documented call fail the check.

### An event is subscribed to, not assigned

`lunette.onWindowOpened(handler)` answers the function that cancels the subscription, and several listeners may wait on one event. An event has two kinds of party that want to hear it, the configuration and whatever library it loaded, and an assigned callback gives each event exactly one handler for the whole session. A slot forces a library either to poll rather than handle the event, so as not to take the callback from the configuration, or to take the slot and call by hand whatever handler it displaced. `lovr.errhand` shows the same cost in LÖVR: a library that wraps it saves the previous handler and calls it.

A module function also types its handler. A Luau definitions file declares globals and cannot name a module's exported types, so a callback on `lovr` cannot say it takes a payload carrying a `Window`, while a handler passed to a module function has its parameter typed with no annotation.

The cost is a second convention in a file that already has LÖVR's: `function lovr.draw(pass)` sits a few lines from `lunette.onWindowOpened(function(event)`, and the Lua conventions in `CONTRIBUTING.md` treat a second convention in one file as friction. The two are different things, a frame hook with one owner and a notification with any number, and giving them one shape forces the workarounds above. Assigned `lovr.lun*` callbacks were rejected for that reason. Assignment on the module table, `lunette.onWindowOpened = handler`, was rejected too: it keeps LÖVR's feel and would be typed, but it keeps the single slot, which is the defect.

Only the way a listener is reached differs from LÖVR's callbacks. The events travel LÖVR's queue and are drained through `lovr.handlers`, so they interleave with `lovr.keypressed`, and the layering above stands: the native layer pushes flat events, and anything finer, such as the panels contract's `onAdded` and `onRemoved`, belongs to a Lua provider.

### Errors and safe mode

The native side of the callback boundary rate-limits nothing. `crates/lunette/src/callback_error.rs` logs the message and traceback and notifies every `lunette.onError` listener. The shipped configuration enables the built-in error stream provider, which owns its limiter, report formatting, and history, and the `desktop/errors` presenter, which owns its floating quad. A configuration can omit either. Without any listener, an error is still logged, but repeated errors are not rate-limited. [Errors](#errors) states this behavior.

The shipped presenter draws a quad rather than a panels-provider panel, because an error report has no textured source. The provider subscribes independently to `lunette.onError`, so a configuration can replace its presentation without displacing a native handler.

Safe mode is triggered by wrapping `lovr.boot`, not by installing a `lovr.errhand`. `lovr.boot` is the function whose failure means the configuration did not load. `lovr.errhand` handles errors that escape callback boundaries and remains part of LÖVR's callback handling. Replacing it with the error stream provider would use the wrong boundary and couple the configuration's error policy to LÖVR's loop recovery.

The wrapper includes `lovr.load` failures because `lovr.boot` ends with `return lovr.run()`, and `lovr.run` calls `lovr.load` before it returns the frame loop. Safe mode replaces a configuration whose setup failed before its callbacks can run. Errors from `lovr.update`, `lovr.draw`, and event listeners occur after the frame loop has been returned and are not a load failure. [Errors](#errors) states which of them the host protects.

### A Lua dispatcher reports through the native boundary

`lunette.reportError` exists so that a dispatcher written in Lua reports a handler's error exactly as a raising callback is reported. A dispatcher that runs every handler inside one call stops the handlers after a raising one, every frame, including the error display that would show the failure. Reporting from Lua through `lovr.log` alone was rejected because it reaches no `lunette.onError` listener, so the error display and any other listener would not hear it. Raising and relying on the host's boundary was rejected because it stops the later handlers.

### Plugin failures are reported, not raised from the request

An initializer or inverse that fails during a drain is reported through `lunette.onError` and recorded as the instance's diagnostic. It is not raised from `enable` or whichever request started the drain, because one drain loads and unloads many instances, and raising one instance's failure from another instance's request attributes it to the wrong caller. `instance:state()` and `instance:diagnostic()` let a caller that wants the outcome of its own request read it. An operation that a caller performs directly, such as `effect:dispose()`, raises its own failure, and that failure is not also reported, so it is not seen twice.

A definition defaults to the location of its initializer as its name. Requiring an explicit name would change every existing definition for a label that the source location already provides, and an anonymous definition would make an instance number the only thing a report could name.

### A published service is a view that its provider's activation revokes

A provision reaches consumers as a frozen view that raises once the provider's activation has ended and raises on every write. Handing consumers the provider's own table was rejected: a reference kept past the provider's unload would reach torn-down state, so every provider would repeat a hand-written liveness guard, and consumers would share one mutable table that any of them could change for all the others.

The view is checked against the provider's activation, not the consumer's. A consumer's inverses run while the consumer unloads and its own activation has already ended, and they routinely call the services they depend on to release what they acquired; a consumer-side check would refuse exactly those calls. Dependents always unload before their providers, so the provider is still active while every dependent's inverses run. A consumer that leaks a service reference past its own activation is a confinement fault, and it is caught as soon as the provider it reaches has gone.

The view checks a read rather than wrapping each method. Luau has no tail calls, so a wrapper adds a stack frame, and every provider error raised at level 2 to name the consumer's call site would name the adapter instead. The cost is that a function read while the provider was live remains callable. A method wrapper cache was rejected for the same reason. One view per provision, shared by all consumers of a generation, keeps the cost to one native liveness query per read.

### Subscriptions are context effects

`Context:on { event = subscribe, run = handler }` makes a native subscription an effect of the activation, which is how Cordis's `ctx.on` tracks a listener on its fiber. It takes the subscribing function rather than an event name, because `lunette` events are subscribed through typed functions such as `lunette.onWindowOpened`, and taking the function keeps the handler's payload type. Wrapping the subscription in `Context:effect` by hand was rejected: every provider and desktop consumer would repeat it, each with its own `context:active()` check in the handler, and an initializer that calls `lunette.on*` directly leaks the subscription across instance reload.

### The plugin runtime does not defend against a malicious plugin

Every plugin runs in the configuration's Lua state with the whole `lunette` API, so a plugin that means harm needs no forged capability or context: it can call `lunette.spawn`, close windows, or replace LÖVR's callbacks directly. The runtime's checks, declared access, owner checks, revoked service views, retired epochs, and stale contexts, catch honest mistakes and handles kept past their lifetime, and they are not a security boundary. Their tests cover those cases and one plain table passed where a capability belongs; constructing tables that imitate a capability or a context is not tested, because resisting it buys nothing a plugin cannot get by calling the API. Sandboxing a plugin would need a separate Lua state or environment per plugin and a narrowed API, which is not planned; [the overview](overview.md#non-goals) records that spawned applications are not sandboxed either.

### Contracts are declared only through capabilities

The facade does not export the native `contract` function. A token declared that way is unbound, so declaring `lunette/panels` at schema 1 through it reserves the identity without producing a capability anything can use, and blocks the real contract for the rest of the epoch. `plugin.capability` declares and binds in one step. The native function remains for the adapter and for tests of the native layer.

### A child is enabled when it is installed

`Context:child` enables the instance it installs, matching the `ctx:use` semantics of issue #32 and Cordis's `ctx.plugin`, where installing a child under a parent loads it. A disabled child would load only after a separate `enable`, which every caller would make at once. Enabling inside the parent's initializer is a request like any other: a conflicting reservation raises in the initializer and fails the parent's load, which retires the child with it.

### Definitions and capabilities take named fields

`plugin.define` and `plugin.capability` each take one table of named fields. Positional arguments, a configuration witness, the required and provided declarations, and the initializer, were rejected because a call site does not say which empty table is which. Named fields also give a definition a declared name in place of the source position of its initializer, and they let the facade reject a misspelt field.

There is no configuration witness, because the initializer's configuration annotation carries the type. Luau infers `C` from the `init` field of a generic table parameter. `Definition<C>` keeps the initializer under `init` with its context and publisher erased to `never`. An initializer typed with `Context` there makes `Definition` and `Context` mutually recursive, and `Context:child` then stops rejecting a wrongly-typed configuration; the erased form keeps `C` in the type without the cycle.

There is no capability witness at the call site, because Luau's explicit type instantiation, `plugin.capability<<Service>> { ... }`, names the service type directly. The vendored Luau parses, checks, and compiles it, and StyLua formats it. `Capability<T>` carries `T` through an identity witness, which the adapter creates. A witness function at the call site was rejected because it repeats the service type twice in an identity function the runtime never needs.

### Ambiguous plugin calls take named fields

A plugin-system call whose arguments do not say what they are at the call site takes a table of named fields. The rule is the one `plugin.define` and `plugin.capability` follow: two arguments of the same type, or a bare number or boolean whose meaning is not in the method's name, read as a guess. `rules:addSource(owner, 'name', 200, resolve)` does not say that 200 is a precedence, and `tag:setSelected(owner, false)` does not say what `false` sets. The calls that take named fields are `Context:on { event, run }`, `lunette.reportError { context, message, traceback }`, `focus:register(owner, target)`, `focus:newSource(owner, { mode, nativeTarget })`, `focus:onChanged(owner, { run })`, `picking.scrollDelta { x, y, dt, tuning }`, `Pointer:setButton { button, pressed, sink, surface }`, `Pointer:push { deflection, dt }`, `rules:addSource(owner, { name, precedence, resolve })`, `rules:setRules(owner, { name, precedence, rules })`, `rules:report { message, level }`, `adoption:install(owner, { precedence })`, `layouts:register(owner, { name, apply, continuous })`, `layouts:apply { name, panels, options }`, `layouts:onChanged(owner, { run })`, `tag:setSelected(owner, { selected })`, `tag:setLayout(owner, { layout })`, `tag:exclude(owner, { panel })`, `tags:hold(owner, { name, index, selected, layout })`, `tags:onChanged(owner, { tag, run })`, `placement:place(owner, { window, properties, defaults })`, `placement:onPlaced(owner, { run })`, `errors:subscribe(owner, { run, cleared })`, `drops:onDropped(owner, { run })`, `drops:emit(owner, { surface, pointer })`, `panel:setHidden(owner, { hidden })`, `bindings:register(owner, { chord, run })`, `bindings:dispatch { key, modifiers, isRepeat }`, `panels:onRemoved(owner, { panel, run })`, `arrangement:save { force }`, `keys.heldModifiers { isDown, shift }`, and the error format's `key { message, traceback }`. `setRules` takes a name and precedence so that a second rule list is a second source rather than a collision with the first under `DEFAULT_SOURCE`, and `placement:place` takes its window in a request because the defaults beside it would be a second table that reads as a guess.

An owner-first call with one further argument whose type says what it is stays positional: `keyboard:new(owner, options)`, `panels:onAdded(owner, callback)`, `tags:new(owner, name, options)`, and `runtime:use(definition, config)`. So do the surface protocol's callbacks, `raycast(origin, direction, backFace)`, `setSize(width, height)`, `onHover(x, y, pointer)`, and `onPress(x, y, pointer)`, and the helpers that share their convention, `picking.pick(surfaces, origin, direction, reach)`, `quad.hit(quad, origin, direction)`, and the keyboard layout's `keyAt(keys, x, y)`. A ray's origin before its direction, and x before y and width before height, is the convention LÖVR's own API uses, and every surface implements these callbacks, so changing them belongs with the surface vocabulary rather than with this rule. A setter named for its one value, such as `keyboard:setVisible(visible)`, also stays.

The rule applies to the native API only where the plugin system introduced the call. `lunette.reportError` exists for Lua dispatchers; the rest of the native API keeps its shapes.

### Configuration types and validation share one descriptor

A configuration descriptor states the fields, defaults, collection children, closed choices, and constraints once. It supplies runtime validation, editor metadata, and Luau input and output types. Default-table inference remains available for legacy modules but cannot describe absent fields, arbitrary map keys, or collection element types. A separate runtime schema beside handwritten configuration types was rejected because those declarations can diverge. Curried default construction and explicit singleton witnesses retain nested types in the pinned checker. [Configuration schemas](../guide/configuration-schema.md#decisions) records the compiler constraints and custom-value identity policy.

Configured definition construction and managed preflight reject invalid settings before acquiring resources. A configuration supplied directly to the native runtime instead fails at activation and is reported without stopping unrelated entries. Preflight cannot guarantee that an initializer succeeds, and replacement remains nontransactional.

### Composition is the facade's, and running it is the frame provider's

Composing a list of entries and starting it use nothing but the facade, so `plugin.compose` and `plugin.start` belong to it, and a configuration that composes a list of its own needs no desktop. Binding the composition to LÖVR's callbacks needs `frame.install`, and `@lunette-plugins` depends on `@lunette-plugin` and not the reverse, so the binding is `frame.run`, beside `install`. A `plugin.run` in the facade was rejected because it would make the facade require a provider. Keeping the engine in `@lunette-desktop` was rejected because the desktop is one list among the lists a configuration can compose, and the engine has nothing desktop-specific in it.

### A typed patch is made from the definition

`plugin.configure` takes the definition and answers a function of the configuration, rather than taking both at once. With both arguments in one call, Luau infers the configuration type from the definition and the literal together, widens a string option such as `hand = 'right'` to `string`, and reports a correct call as an error. With the definition alone, the type is fixed before the literal is checked against it. A table of one function per shipped entry, keyed by id, was rejected: it restated each entry's id and type beside the entry list and had to be kept in step with it, and it could not configure an entry it did not list. A `configure` export on each provider module was not needed, because the definition carries its configuration type. `configureEntry` uses the same two-step type inference while separating the actual entry id from the definition name. Calling a factory to discover an id was rejected for this helper because it would create runtime-lifetime state before a runtime starts.

### Frame dispatch and the surface list are contracts

Frame dispatch and the surface list are the `lunette/frame` and `lunette/surfaces` contracts, each with a built-in provider, so any plugin requires them and either can be replaced without the other. A configuration-local callback registry, passed to each consumer through its configuration, was rejected: a plugin in a user's configuration could reach it only by copying the file, and nothing but that module could draw, update, or offer a surface. One contract for both was rejected because a replacement of the surface list would then have to reimplement frame dispatch.

Phases order handlers rather than numbers. A numeric order has meaning only relative to numbers in other files, so a new handler would have to read every other consumer to choose one. A phase names the reason a handler runs where it does. `order` breaks ties within a phase. Draw and update share one phase order because the reasons coincide: what is drawn over the scene is also what reads it.

Key and text handlers can consume an event, so a hotkey does not also reach the current target. Consumption needs an order between interceptors and delivery, which the `binding` and `delivery` phases provide. Events are tables, as native event payloads are. Schema 2 adds batch identity and `onBatch` before both phases so physical sources record route eligibility before a binding can change it. Immediate notification of the current batch allows a newly activated consumer to join without waiting for another update. Suppressing one later text callback was rejected because LÖVR supplies no per-key text correlation; a route transition or consumed or failed local key invalidates remaining text until the next update.

The LÖVR callbacks are bound by a small installation step outside any plugin, `frame.install`, rather than by the frame provider assigning them in an effect and restoring the previous values when it unloads. The runtime is created from `lovr.load`, so `lovr.load` must be assigned before any plugin exists, and `lovr.quit` must close the runtime after the quit handlers run, which a plugin cannot do to the runtime it belongs to. Restoring previous values is correct only when assignments unload in the reverse order they were made, which another assigner, an instance reload, or a second runtime does not guarantee. Source reload shuts the runtimes down and then clears the configuration callbacks, so a provider-assigned callback would gain nothing there either. The installed callbacks find the loaded frame activation when they run, so an instance reload or an outage of the frame provider leaves them in place doing nothing rather than unassigned.

### The checker reports a capability with an unknown service type

`plugin.capability { ... }` without `<<Service>>` leaves the type parameter unsolved, and Luau reads it as `unknown`. Every service read through the resulting capability is then unchecked, and nothing reports it. `crates/lunette-lovr/src/analyze.cpp` therefore walks each checked module after Luau has checked it and reports any call whose first result is the facade's capability shape, `{ read witness: (T) -> T }`, at `T = unknown`. The check needs the module's expression types after checking, so the checker retains full type graphs, at the cost of memory a command-line check can afford.

Two ways to make the omission a type error in the facade's own signature were rejected. A user-defined type function on the return type, `Capability<ServiceType<T>>`, reports the omission, but every `Context:require` of a capability then pushes the checker past its complexity limit, which fails the standing check across the tree. The same type function on the parameter, `spec: Named<T, CapabilitySpec>`, reports the omission at the call within one module, but checking a call from another module crashes the vendored Luau's constraint solver. A crash in `lunette check` on a user's mistake is worse than the silence it would replace.

### A keyboard is laid out from keys, not a grid

A key carries `x`, room before it, and `height`, and a key with no code is a spacer, so a split keyboard's gap, a numpad's two-row key, and an arrow cluster placed under a gap can be written. A uniform grid of `{ code, label, width }`, every row one unit tall and every key flush against the last, was rejected because it expresses none of them. These are the terms keyboard-layout-editor's format uses, which is the common description of physical layouts. A row advances by its shortest key rather than by one unit so that a row of half-height spacers is a half-row gap. A row-level offset field was rejected: it would make a row a record rather than a list.

A key that does something other than send a code has an `action`, a closed union discriminated by `kind`, rather than a string such as `'layer:numpad'`, which would carry its argument in a format every reader parses. `custom` exists so that a hook can give a key a meaning the provider does not have, such as pasting, without the hook having to recognise keys by their position. Layers fall out of the `layer` action and a `layers` option: a layer is another set of rows, and the keyboard keeps the size of the largest so the plate does not jump.

Rows replace the default list wholesale. The keyboard descriptor validates the nested row arrays, key objects, and action unions. Its integration validator checks layout constraints at construction, binding, and activation. Schema-declared containers are copied and frozen; callback references and atomic custom values retain their identity. This rejects invalid rows before drawing or input uses them.

### Keyboard variation is two around hooks

`onKey` and `drawKey` cover what a slightly different keyboard needs: key sounds and haptics, keys that are not keycodes, a press animation, and other key shapes. Each receives the default as its last argument, so a hook adds to the default without copying it. Wrapping a built keyboard does not change what it draws, because the provider calls its own methods through closures; a hook is called by the provider at the point the variation happens. A whole-keyboard `draw` hook was not added: the plate is a colour and a margin, which `style` covers, and neither example keyboard needs to replace it. The base `drawKey` is split into `face` and `legend` in the drawing module, because a hook that replaces only the face would otherwise copy the legend.

A hook receives the provider's `Board` rather than the contract's `Keyboard`, because layers and laid-out keys are this provider's. A hook is an option of this provider, so it can name this provider's types; a contract that every replacement must implement cannot.

### The keyboard contract is what consumers call

The keyboard contract exposes the surface, size and visibility, activations and text, held modifiers, drawing, release, and callback-free registration inspection. Schema 2 adds the owner's visibility notification because a hide action can change visibility without an owner calling `setVisible`. State changes before notification so a callback reads the change it received. Exposing legend lookup, latched, locked, and hovered sets, rows, and style was rejected because these are provider implementation details. Each owner draws and offers what it made. A service-wide draw was rejected because it would draw another owner's keyboard that the drawing owner does not offer, visible and impossible to press. Pure layout lives in the provider's layout module.

Route changes clear latches and locks immediately rather than waiting for the next frame or key. Otherwise a modifier selected for one receiver could affect a newly focused receiver. Legends read the same live keymap selection as local translation. A cached construction-time seat was rejected because local targets can select a different keymap and seats can die while the keyboard remains live. Visibility notifications expose no menu policy; `desktop/actions` registers the `desktop/keyboard/toggle` menu action to show or hide the shared keyboard.

`Keyboard` states the surface fields it always has rather than intersecting `Surface`. `Surface` declares `setPose` and `setSize` optional, so `Surface & { read setPose: ... }` holds two function types for one field, and the checker reports `keyboard:setPose(pose)` as an ambiguous call. A keyboard is still assignable to `Surface`. The panel a layout poses and a tag holds is `surface.Movable` for the same reason, which restates the surface fields with `setPose` required. A generic alias of the fields, parameterised by `setPose`'s type, is refused by Luau, because the fields refer back to `Surface`.

### Haptics reach a pointer through its creator

`Pointer:vibrate { strength, duration }` pulses the device that drives a pointer, so a surface such as a key can respond to a press with a click. The pointer's creator supplies it through `PointerOptions.vibrate`, because only the creator knows the device: the laser knows its hand's controller, and a gaze or desktop pointer would know its own or have none. A separate `lunette/feedback` contract keyed by pointer was rejected; it would be one more contract that every pointer source and every surface that wants feedback must agree on, for one function the pointer can carry. Interaction does not interpret the pulse; it forwards it while the pointer is live. The pulse reaches `lovr.headset.vibrate`, and the native API has no part in it.

### Layouts are a broker, not a replaceable provider

Layouts are a broker in the form section 6.2 of the Cordis paper describes, the shape the rules sources and the surface offers have: several layouts coexist under names, and a consumer chooses one by a string that can be configuration or a tag's layout. A contract per layout, varied by replacing its provider, was rejected: it allows one layout at a time, so a configuration could not keep the arc for one workspace and use a grid for another, and it shapes the contract like the first implementation, so a grid would have to answer the arc's `angles`, `poses`, and `TUNING`. A layout takes a panel list rather than a tag, so a layout needs no tags service. Follow-me and animated layouts are marked `continuous` rather than given a frame of their own, so the broker stays a registry and the consumer that already decides when to arrange decides when to apply one every frame.

### Drops are a broker of their own

Drops are `lunette/drops`, a broker that neither side provides: interaction emits, and pose memory, persistence, and the arrangement listen. Announcing the drop through the panels contract was rejected: the drop originates in interaction, which would then require panels only to emit, and only a panel's drop could be heard. Moving the event to the interaction contract was rejected: every listener would require interaction, so an interaction outage would unload persistence, and only a pointer source that is the interaction provider could announce a drop. A listener that raises is reported rather than raised into the grab, because the listeners belong to other plugins and the grab is already over. The drop carries the surface, not a panel, because a title bar that moves a panel is not one; such a surface carries its panel's kind and source, and a listener resolves the panel. The contract states what a replacement must emit, because a replacement that does not emit loses the arrangement's autosave and pose memory without any error.

Pose memory is the `desktop/pose-memory` entry rather than a provider method. It is desktop policy: the native property is the desktop's way of keeping a window's place across a reload, which adoption's source reads back, and a configuration that keeps places some other way disables the entry. Writing the property inside interaction was rejected: a replacement interaction that did not know to write it would lose every window's place across a reload.

### Focus is a contract of its own

Keyboard routing is `lunette/focus`, separate from interaction, so a keyboard, physical input source, or local receiver does not require a pointer provider. Schema 2 uses owner-scoped target handles and sources instead of native-only grants. One current route identifies the receiver of new input; native seat authority remains independently owned so two seats keep their own focus. Disposing a target never restores an older route. Restoring one was rejected because the earlier interaction or local control can have ended. `focusOnPress` makes the pointer's focus policy optional.

Sources centralize target selection, route revision checks, protected receiver calls, and original-target inverses. Separate native forwarding after a local refusal was rejected because input would reach an application behind a local control. A native-only source callback retains the keyboard's `Options.target` customization while remaining subordinate to the current local receiver. `lunette.defaultSeat` makes omitted-seat authority agree with native omitted-seat delivery without guessing from enumeration order. Inspection reads metadata only, because evaluating receiver or target callbacks would change session state during an inspection.

### A pointer exposes what it hovers and carries

A pointer answers what it hovers and carries, its seat, and its tuning, read-only, and the rest of its state is the provider's. Exposing its grab offset, its partner in a two-handed scale, its pressed sink and surface, and its hand position as assignable fields was rejected: a replacement would have to reproduce that state, and a driver could corrupt it. `endGrab` answers whether something was carried.

### Pointer buttons replace the trigger

`Input.buttons` maps each held `lunette.PointerButton`, the native set, to true, and the pointer presses each one on its own, so a second button, a right click, or a remapped trigger needs no new provider. A single `trigger` boolean that interaction maps to one configured button was rejected for that reason. Which controller button holds which pointer button is device knowledge, so it is the laser's `buttons` option, and interaction has no second way to say the same thing. An analog pinch strength was not added: no consumer reads one, and a pinch reader can threshold it into a button in a `readInput` hook.

### Interaction and laser variation is four around hooks

`drive` covers what a different pointer mapping needs, a remapped button, a different grab gesture, a scroll curve, because it receives the default and the primitives are public. `constrain` covers what a different grab feel needs, a level panel, a grid, an arc, because every carry goes through it. A `pick` hook was not added: a `drive` hook picks with `@lunette-plugins/interaction/picking`. The laser's `draw` hook is called by the service's bulk draw, because wrapping a laser does not change what that draw calls, as with the keyboard. `readInput` is a provider hook, and `desktop/pointing` forwards laser options from its configuration.

### Bindings are a broker that takes its own presses

`lunette/bindings` registers chords by owner, and the provider takes each press in the frame provider's `binding` phase, before anything delivers it, so a bound press never reaches a client. The provider registers its own `binding` handler. Having `desktop/input` dispatch each press to the broker was rejected: a bindings outage would take `desktop/input` with it and stop all typing until a bindings provider returned. Both read the held modifiers through `@lunette-contracts/keys`' `heldModifiers`, so they agree on what is held. `desktop/input` does not need to know which keys a binding consumed, because the frame provider's consumption already keeps them from the `delivery` phase. Chords match exactly, so control and H is not bound by a binding for H, and a repeat is consumed without running again. The shipped configuration registers reload as the `desktop/reload` menu action through `desktop/actions`; custom plugins can register their own key chords.

### Panel visibility is an owner-held override

Minimising, workspaces, and hiding the desktop need a panel hidden without destroying it, because a panel belongs to its creator. `setHidden` is an owner's override with the most recent live one deciding, the rule a tag's selection follows, because several plugins may want a say and each one's say must end with it. Reverting to the value before an override was rejected for the reason it was rejected for tags: the result depends on the order owners unload in. A hidden panel gives up its layer at once rather than at the next update, because a layer the compositor draws would otherwise outlast the decision.

### A curve is LÖVR's layer curve

A panel's `curve` is the value `Layer:setCurve` takes, a cylinder of radius `1 / curve` centred in front of the panel, so the panel picks where the compositor draws it when it is on a layer. The in-scene drawing follows the same arc with a mesh of flat strips, so a panel that loses its layer does not change shape. The shape is three hooks, picking, drawing, and placing a layer, rather than a curve alone, so a dome or a sphere segment is a configuration's without a provider change.

### Decorations are a consumer

The panels provider's chrome is off by default, and `desktop/decorations` draws borders and title bars from the panels contract's arrival and removal listeners, offering each bar as a surface that carries its panel, so a title bar can be grabbed and its style is the consumer's configuration. A decorator broker in the panels provider was rejected; a consumer needs nothing the contract does not already give, and a configuration replaces it by disabling one entry. The provider keeps its own chrome behind the `chrome` option for a panel that wants it without a consumer, and decorations skip such a panel.

### Tags are held, excluded, and announced

`hold` makes a tag shared by its holders, so the entries that need a tag need not start in a particular order and the tag lasts while any of them holds it. With `new` alone, a tag belongs to whichever plugin asks first: a placement that makes `main` before `desktop/workspace` starts makes the workspace's `new` raise, and the tag ends when that placement does. Reference counting every tag was rejected; `new` keeps the exclusive form, because a plugin that owns a tag's name, such as one that would raise on a second workspace of the same name, still wants the duplicate to raise.

An exclusion is an owner-held override like a selection, and membership is the holds less the live exclusions, so a plugin moves a window that rules placed in `main` without taking another owner's hold, and the window returns when the plugin unloads. Letting any owner remove any membership was rejected because the membership would then not end with the owner that made the change.

`onChanged` announces a tag being made or ending and its selection, layout, and members changing, so a workspace consumer does not poll and a mirror placed before its tag exists joins the tag when it is made. The announcements are one stream filtered by tag, because a listener that cares about one tag cares about all of these and one registration is less to get wrong than four. A panel dying is not announced as a membership change, because the panels contract announces it and announcing it again would come from inside whatever query first noticed the death.

### A tag's layout is a name

A tag's layout is a name in the layouts broker, set as an owner override like a selection, and the consumer that arranges resolves it, so tags depend on no layout and a layout is chosen per tag by a string. A layout function on the tag was rejected: a function cannot be saved or chosen from a configuration, and it makes tags the owner of layout behaviour.

### Placement is a contract of its own

Placement is the integration component section 6.5 of the Cordis paper describes: it alone depends on rules, panels, and tags, and its `panelOptions` hook is where a property reaches a panel. Mapping resolved properties to panel options inside rules was rejected: rules would require panels and tags, and forwarding a further property, such as a curve, would mean replacing rules. Placement announces every placement, whoever made it, so a plugin that places windows itself is arranged like an adopted one. The adoption start's own `onPlaced` remains, because it is that caller's callback and its error is that caller's, where a listener's error is reported.

`hidden` and `adopt` are named properties so they can be evaluators, and `where` is a match key because the named fields cannot express a predicate over the whole window. Precedences are named in the vocabulary so a user source can say where it sits without knowing the numbers the shipped sources use.

### The error stream is a provider, and presenters are consumers

`lunette/errors` keeps what every presenter shares, the subscription, the limiter, and a bounded history, and a presenter is any plugin that subscribes, so several coexist and a configuration chooses them by entry. One error display whose contract carries a quad's position and size was rejected, because a toast or a notification would have to fake them. A broker of named presenters was rejected; subscription already composes several, and a name would add nothing a composition entry does not already give. Reports raised while subscribers run are kept and not delivered, because a presenter that raises on every report would otherwise report its own error to itself for as long as the limiter let it.

### Pacing and scale hand out choosers

The contracts answer a pacer per window and a chooser per output rather than a rate for a window or a scale for an output, because a rule with hysteresis or a history needs state per window or output, and a service holding that state would have to be told when each window and output ends. A pacer and a chooser are plain objects their caller keeps and drops, so they are not owner-scoped, and the provider holds nothing. A service that applied rates itself was rejected: reading the scene is a separate choice from the rule, and a configuration that paces by gaze replaces the consumer and keeps the rule.

### A window names its output and its latest commit

Scaling an output by its nearest panel needs to know which output a window's client is shown on, and pacing by an observed commit rate needs to know whether the client drew. Both are mechanism, so they are fields of the window handle, `window.output` and `window.commit`, rather than something a provider infers. Comparing textures from `getTexture` across frames was rejected for the commit: a texture is valid for one frame, and a client that alternates two buffers hands back a texture that was seen before. `commit` is the texture ledger's shared counter, which never repeats a value for a different buffer, and is 0 rather than nil before the first buffer so that a comparison needs no nil case.

### UI geometry and activation tokens are public data

The UI contract exposes declared geometry and detached descriptions so input, drawing, and automation use one coordinate model. Deriving hit bounds from rendering was rejected because a skin change would change input behavior. Read-only records and contract-named receivers keep replacements type-compatible without importing a built-in implementation. A frozen `ui.Generation` token distinguishes activations by identity. A numeric counter was rejected because a replacement provider or source reload can restart it and reuse a panel name and revision. A frozen `ui.OwnerIdentity` token distinguishes actual creation-owner activations without exposing their contexts. A panel-local id namespace was rejected because one owner can create controls across panels and different owners can contribute controls to the same panel. The generation token, owner token, and id identify a live control without granting authority or making a dead handle live.

### Grapheme segmentation is native mechanism

The native text helper uses `unicode-segmentation` 1.13.3 rather than a Lua implementation of Unicode segmentation. Combining marks, regional indicators, and emoji sequences require the complete extended grapheme rules; byte stepping or codepoint stepping would split user-visible characters. Editing policy remains in Lua. Full shaping, bidirectional layout, and IME composition require separate mechanisms and are not inferred from grapheme segmentation.

## Known gaps

Named, not solved.

The `lovr.lun*` prefix squats in LÖVR's callback namespace permanently. It is distinctive enough that a collision is unlikely, but this remains an assumption rather than a guarantee.

`lunctl` has root-equivalent access to the session. Anything that can write to the socket controls the machine. This follows from the single-user assumption, stated explicitly, and the socket is never network-reachable.

Source reload and hard restart run no cleanup for Lua modules outside the plugin runtime. A module that retains native resources outside plugin instances can therefore outlive its configuration callbacks.

An error raised in a LÖVR callback that no Lua dispatcher protects ends the session. `boot.lua` calls `lovr.update`, `lovr.draw`, and the other LÖVR callbacks directly, and with no `lovr.errhand` its error handler replaces the frame loop with one that exits with status 1, which takes every connected client with it. The shipped configuration avoids it by dispatching through the frame provider, and a raw callback in a user's configuration does not. Recovering in the host would need each LÖVR callback called under its own protected call, through a host-owned `lovr.run` or a wrapper on every callback a configuration assigns, and a frame that unwinds between `lovr.headset.getPass` and `lovr.headset.submit` would still have to end the XR frame it began. Defining a `lovr.errhand` that returns the previous frame loop resumes the session but skips the rest of the frame, including its submit, so it does not settle that question either.

A monitor panel cannot hold a composition layer, because `lunette.claimLayer` takes windows, so a monitor is always drawn in the scene, at the scene's resolution, and a curved monitor is the arc mesh. The arc mesh has not been seen on a GPU-backed session.

The focus source contract takes activations and committed UTF-8, not held-key state or IME preedit. Virtual local translation has no dead-key or compose state. Native window text can deliver a prefix before encountering an unrepresentable scalar. Physical text invalidation is batch-wide because LÖVR supplies no per-key text correlation. [Input](input.md#known-gaps) records those limitations and the outstanding hardware acceptance.

The menu action broker, shared keyboard display, wrist menu, shipped session actions, and runtime manager use the public UI contract. Manager search and configuration fields receive routed input through the shared keyboard. The checked `examples/ui` form uses neutral UI, menu, and frame contracts and the shared keyboard. Full text shaping, bidirectional editing, IME composition, and GPU-backed and in-headset acceptance remain outstanding. Draw hooks cannot make arbitrary pass stack misuse safe.

## Deliberately left open

Contract authorities are a naming convention and are not authenticated. Any module can declare a contract under any authority, including `lunette`, and the first declaration in an epoch holds the name and schema. Binding an authority to the package root that may declare under it is left to plugin packaging and distribution, #39.
