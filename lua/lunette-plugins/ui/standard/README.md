# Standard kinds

Registers the standard kinds and their visuals in the default lunette theme, registers the bundled IBM Plex Sans and Iosevka faces, and publishes the constructors through `lunette/ui-components`. [Theming](../../../../docs/development/ui/theming.md#the-default-theme) describes the theme, and the [widget gallery](../../../../dev/plugins/ui-gallery/README.md) shows every kind.

Lengths that take a spacing token, such as `gap = 'md'`, also take metres. Text takes a type role (`body`, `label`, `caption`, `section`, `heading`, `title`, `value`, `mono`) and a colour role. Choice and collection kinds take options or items with string ids, which they key with `uiHost.keyOf`, so ids may contain any characters. A control with `disabledReason` takes no input and shows the reason.

The fonts are under the SIL Open Font License; [CREDITS.md](../../../../CREDITS.md) records their sources.

[Contract](../../../lunette-contracts/ui-components.luau)
