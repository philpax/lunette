# Contract schemas

These modules validate shared contract values without importing plugin implementations, looking up services, or acquiring resources. Providers and consumers use the same validation boundary. The contract modules retain their service types and capability versions.

[Theme](theme.luau), [frame style](frame-style.luau), and [titlebar style](titlebar-style.luau) describe stable appearance values. Editable author settings and font-resource creation remain outside this directory. [Rules](rules.luau) validates rule values and shares read-only field classifications; matching and evaluation remain with the rules provider.
