# Contract schemas

These modules validate shared contract values without importing plugin implementations, looking up services, or acquiring resources. Providers and consumers use the same validation boundary. The contract modules retain their service types and capability versions.

[Theme](theme.luau), and [frame style](frame-style.luau) describe stable appearance values. [Rules](rules.luau) validates rule values and shares read-only field classifications; matching and evaluation remain with the rules provider.

Editable author settings use public [theme configuration](../../lunette-plugins/theme/configuration.luau) to project settings into contract values. The public [base theme](../../lunette-plugins/theme/base.luau) is a complete value, not a validation schema. Font-resource creation remains with the theme provider; these schemas acquire no resources.
