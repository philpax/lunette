# Error overlay

Shows shared error reports on a UI host panel at a fixed place in the world. The panel appears when a report arrives and lists the reports since the last dismissal, newest first. A repeated report, identified by its message and traceback as the error stream identifies it, keeps one entry with a count that includes the repeats the stream suppressed.

Dismiss clears the new reports and hides the panel. History switches to every report the overlay keeps, and the Error history menu action opens it after dismissal. Newer and Older page through a list longer than one page. Every control works with a controller ray and with focus traversal.

The panel is drawn by the UI toolkit, so it does not appear while the toolkit is not running; the [recovery plugin](../recovery/README.md) covers that case.

[Options](config.luau) · [Error stream](../error-stream/README.md)
