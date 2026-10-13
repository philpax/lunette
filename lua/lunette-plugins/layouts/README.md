# Layouts broker

The layouts provider stores named layout callbacks. A consumer applies a registered layout to its panels and ordering; the broker does not arrange panels or schedule continuous application.

Plugins register layouts through [`lunette/layouts`](../../lunette-contracts/layouts.luau). A registration follows its owner's lifetime. The optional `continuous` flag lets a consumer apply a layout each frame.

[Shared broker guarantees](../../../lua/lunette-contracts/policy-services.md#brokers) · [Arc contributor](../layout/arc/README.md)
