# Error stream

The errors provider subscribes to `lunette.onError` for each activation. The shared API contract and native error boundaries remain specified in [the Lua API](../../../../docs/dev/lua-api.md#errors).

## Report policy

`lunette/errors` subscribes to `lunette.onError` for its activation, withholds identical reports during the configured window, and keeps the latest report. `onReport` listeners receive each delivered report. A report raised while listeners run, such as a listener's own error, becomes the latest report without being delivered, so a raising presenter cannot feed itself.

The provider combines the message and traceback into a suppression key, retains the latest delivered report, and notifies owner-scoped listeners through `lunette/errors`. The contract in [errors.luau](../../../lunette-contracts/errors.luau) defines report fields and listener methods.

The limiter reports the first occurrence of a key immediately. A repeated key within the configured `window` is withheld and counted. Once the interval has elapsed, the next occurrence is delivered with the accumulated suppression count, and the count resets. The limiter keeps at most `maxKeys` keys. When the limit is exceeded, it forgets the least recently recorded key.

The schema in [config.luau](../config.luau) owns the defaults: a 5-second window and 64 keys. The window may be zero or greater; `maxKeys` must be a positive integer. A key is the exact message and traceback joined by a newline.

Each delivered report has an increasing sequence number, the message, traceback, suppression count, and display text. The display text includes a line describing suppressed identical errors when the count is non-zero. `latest()` returns the most recently delivered report for consumers that start late. Suppressed errors do not replace it.

## Listener delivery

The provider commits a report as latest before notifying listeners. Each listener runs under the plugin callback protection specified by the shared contract. If a listener raises an error, the native error subscription can receive that report while listener delivery is in progress. The provider records the new report as latest but does not recursively deliver it. This prevents a failing presenter from repeatedly reporting its own failure.

The provider clears its latest report and listeners when its activation ends. `desktop/errors` is an independent consumer and can be disabled or replaced without disabling the error stream.

## Decisions

The separation between error reporting and presentation remains specified in [the Lua API](../../../../docs/dev/lua-api.md#presenters-are-consumers-of-one-error-stream).

Repeated reports are suppressed by the full message and traceback, not by message alone, because both identify a repeated report. The bounded least-recently-recorded key set limits retained suppression state.

A report received during listener delivery becomes the latest report but is not delivered recursively. Recursive delivery could make a presenter that raises feed itself.

## Known gaps

An error in a LÖVR callback that no Lua dispatcher protects ends the session with status 1. [The Lua API](../../../../docs/dev/lua-api.md#known-gaps) records the shared boundary and recovery limits.