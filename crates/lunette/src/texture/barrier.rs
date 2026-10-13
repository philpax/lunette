//! Linux-only: how an imported image is handed between Vulkan queues.
//!
//! Neither the layout to acquire from nor the queue family to acquire from is
//! settled, so both are runtime settings on [`BarrierPolicy`]. A run can then
//! try either value without a rebuild.
//!
//! The choice of arguments is separate from recording the barrier, so the
//! choice is a pure function of the policy and testable without a device.

use ash::vk;
use tracing::warn;

/// How the barrier around an imported texture is recorded.
///
/// Both fields are runtime settings, so a run can try either value without a
/// rebuild. `docs/development/native/rendering.md` records the measurements behind the
/// defaults and the half that remains unmeasured.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BarrierPolicy {
    pub source_family: QueueFamilyMode,
    pub old_layout: ForeignLayout,
}

impl BarrierPolicy {
    /// Reads a policy from two optional settings.
    ///
    /// An unrecognised value falls back to the default, so a typo in a
    /// diagnostic switch cannot stop a session starting. The fallback logs a
    /// warning, so the operator can see the default is in use.
    #[must_use]
    pub fn from_settings(family: Option<&str>, layout: Option<&str>) -> Self {
        let source_family = family.map_or_else(QueueFamilyMode::default, |value| {
            QueueFamilyMode::parse(value).unwrap_or_else(|| {
                warn!(value, "unrecognised queue family mode; using the default");
                QueueFamilyMode::default()
            })
        });
        let old_layout = layout.map_or_else(ForeignLayout::default, |value| {
            ForeignLayout::parse(value).unwrap_or_else(|| {
                warn!(value, "unrecognised foreign layout; using the default");
                ForeignLayout::default()
            })
        });

        Self {
            source_family,
            old_layout,
        }
    }

    /// The layout the acquire takes the image to be in.
    ///
    /// This is the measurable half of the policy. The acquire layout may be
    /// `UNDEFINED`, and a run can then observe whether the driver discards
    /// the client's content.
    #[must_use]
    fn acquire_layout(self) -> vk::ImageLayout {
        self.old_layout.layout()
    }

    /// The layout the release hands the image back in.
    ///
    /// Always `GENERAL`. It is a barrier's `newLayout`, and
    /// VUID-VkImageMemoryBarrier2-newLayout-01198 forbids `UNDEFINED` there.
    /// It is also the layout the image is in: a producer outside Vulkan has
    /// no other layout, and [`ForeignLayout::General`] names it for the
    /// acquire.
    const RELEASE_LAYOUT: vk::ImageLayout = vk::ImageLayout::GENERAL;
}

/// Which queue family an imported image is acquired from.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum QueueFamilyMode {
    /// `VK_QUEUE_FAMILY_FOREIGN_EXT`: a real ownership transfer from a
    /// producer outside Vulkan. A client's dmabuf is owned by such a producer.
    /// It is the default because the specification describes this transfer.
    #[default]
    Foreign,
    /// `VK_QUEUE_FAMILY_IGNORED`: no ownership transfer. This is what WayVR
    /// does, and it works on Mesa; whether the driver accepts the missing
    /// ownership transfer is the question.
    Ignored,
}

impl QueueFamilyMode {
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "foreign" => Some(Self::Foreign),
            "ignored" => Some(Self::Ignored),
            _ => None,
        }
    }

    #[must_use]
    fn index(self) -> u32 {
        match self {
            Self::Foreign => vk::QUEUE_FAMILY_FOREIGN_EXT,
            Self::Ignored => vk::QUEUE_FAMILY_IGNORED,
        }
    }
}

/// The layout an imported image is taken to be in before the acquire.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ForeignLayout {
    /// `VK_IMAGE_LAYOUT_GENERAL`. It is the default. A DRM-modifier image
    /// written by a producer outside Vulkan is in this layout, and an
    /// ownership acquire from a non-`UNDEFINED` layout preserves the image's
    /// contents.
    #[default]
    General,
    /// `VK_IMAGE_LAYOUT_UNDEFINED`. It is legal as an acquire layout and
    /// permits the driver to discard the client's rendered content. The
    /// discard is the reason `TextureInfo.foreign` exists. A run can select
    /// this layout to confirm the discard.
    Undefined,
}

impl ForeignLayout {
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "general" => Some(Self::General),
            "undefined" => Some(Self::Undefined),
            _ => None,
        }
    }

    #[must_use]
    fn layout(self) -> vk::ImageLayout {
        match self {
            Self::General => vk::ImageLayout::GENERAL,
            Self::Undefined => vk::ImageLayout::UNDEFINED,
        }
    }
}

/// The two integers an import barrier is recorded with.
///
/// Both values are `u32`, and the FFI call takes them positionally. The
/// named fields fix which value is which, so a transposition cannot record
/// a barrier that names a queue family index as a layout.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct BarrierArguments {
    pub(super) layout: u32,
    pub(super) queue_family: u32,
}

/// The arguments the acquire barrier is recorded with.
///
/// A pure function of the policy, so the choice is testable without a device.
/// The arguments are chosen separately from recording the barrier, which does
/// need a device. [`LovrTexture::acquire`] records the result.
pub(super) fn acquire_arguments(policy: BarrierPolicy) -> BarrierArguments {
    BarrierArguments {
        layout: policy.acquire_layout().as_raw().unsigned_abs(),
        queue_family: policy.source_family.index(),
    }
}

/// The arguments the release barrier is recorded with.
///
/// The layout is [`BarrierPolicy::RELEASE_LAYOUT`] for every policy. It is a
/// barrier's `newLayout`, where `UNDEFINED` is forbidden, so the policy's own
/// layout cannot be used for the release. As with [`acquire_arguments`], the
/// choice of the release arguments is a pure function of the policy.
pub(super) fn release_arguments(policy: BarrierPolicy) -> BarrierArguments {
    BarrierArguments {
        layout: BarrierPolicy::RELEASE_LAYOUT.as_raw().unsigned_abs(),
        queue_family: policy.source_family.index(),
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn the_settings_choose_a_policy_and_fall_back_to_the_documented_default() {
        // A diagnostic switch is not worth failing a session over, so an
        // unset or unrecognised value is the default, and the parse is exact.
        let default = BarrierPolicy {
            source_family: QueueFamilyMode::Foreign,
            old_layout: ForeignLayout::General,
        };
        assert_eq!(BarrierPolicy::default(), default);
        assert_eq!(BarrierPolicy::from_settings(None, None), default);
        assert_eq!(
            BarrierPolicy::from_settings(Some("FOREIGN"), Some("")),
            default
        );
        assert_eq!(
            BarrierPolicy::from_settings(Some("ignored"), Some("undefined")),
            BarrierPolicy {
                source_family: QueueFamilyMode::Ignored,
                old_layout: ForeignLayout::Undefined,
            },
            "the other value of each setting is reachable without a rebuild"
        );
    }

    #[test]
    fn a_release_hands_the_image_back_in_a_layout_a_barrier_may_name() {
        // Regression: the release passed the policy's own layout as the
        // barrier's `newLayout`, so `LUNETTE_IMPORT_LAYOUT=undefined` recorded
        // `VK_IMAGE_LAYOUT_UNDEFINED` as a destination, which
        // VUID-VkImageMemoryBarrier2-newLayout-01198 forbids. Asserting
        // against the arguments the call is made with makes a reintroduced
        // switch on the release side fail the test.
        for old_layout in [ForeignLayout::General, ForeignLayout::Undefined] {
            let policy = BarrierPolicy {
                source_family: QueueFamilyMode::Foreign,
                old_layout,
            };
            assert_eq!(
                release_arguments(policy),
                BarrierArguments {
                    layout: vk::ImageLayout::GENERAL.as_raw().unsigned_abs(),
                    queue_family: vk::QUEUE_FAMILY_FOREIGN_EXT,
                },
                "the release names `GENERAL` whatever the policy asked for, for {old_layout:?}"
            );
        }
    }

    #[test]
    fn an_acquire_names_the_layout_the_policy_asked_for() {
        // `UNDEFINED` is legal as a barrier's `oldLayout`, and naming it is
        // the purpose of the setting. The acquire must pass the policy
        // through; the release must not.
        for (old_layout, expected) in [
            (ForeignLayout::General, vk::ImageLayout::GENERAL),
            (ForeignLayout::Undefined, vk::ImageLayout::UNDEFINED),
        ] {
            let policy = BarrierPolicy {
                source_family: QueueFamilyMode::Foreign,
                old_layout,
            };
            assert_eq!(
                acquire_arguments(policy),
                BarrierArguments {
                    layout: expected.as_raw().unsigned_abs(),
                    queue_family: vk::QUEUE_FAMILY_FOREIGN_EXT,
                },
                "the acquire is where the switch is measurable, for {old_layout:?}"
            );
        }
    }

    #[test]
    fn both_barriers_name_the_queue_family_the_policy_asked_for() {
        for (source_family, expected) in [
            (QueueFamilyMode::Foreign, vk::QUEUE_FAMILY_FOREIGN_EXT),
            (QueueFamilyMode::Ignored, vk::QUEUE_FAMILY_IGNORED),
        ] {
            let policy = BarrierPolicy {
                source_family,
                old_layout: ForeignLayout::General,
            };
            assert_eq!(acquire_arguments(policy).queue_family, expected);
            assert_eq!(
                release_arguments(policy).queue_family,
                expected,
                "the release side is the half of the ownership transfer the policy still governs"
            );
        }
    }
}
