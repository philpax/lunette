//! Linux-only: how an imported image is handed between Vulkan queues.
//!
//! Neither the layout to acquire from nor the queue family to acquire from is
//! settled, and both are what milestone 0 exists to measure. They are therefore
//! runtime settings on [`BarrierPolicy`] rather than constants, so a run can
//! answer the question without a rebuild.
//!
//! The choice of arguments is separate from recording the barrier, so that it
//! is a pure function of the policy and testable without a device.

use ash::vk;
use tracing::warn;

/// How the barrier around an imported texture is recorded.
///
/// Both fields are open questions rather than settled ones, which is why they
/// are runtime settings. `docs/2026-08-06-milestone-0-findings.md` is where the
/// answers go, and a run has to be able to try the other value without a
/// rebuild to produce them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BarrierPolicy {
    pub source_family: QueueFamilyMode,
    pub old_layout: ForeignLayout,
}

impl BarrierPolicy {
    /// Reads a policy from two optional settings, falling back to the default
    /// for anything unrecognised.
    ///
    /// Unrecognised rather than rejected: this is a diagnostic switch, and a
    /// typo in it should not stop a session starting. The fallback is reported
    /// so a run that thought it was measuring the other value finds out.
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
    /// The measurable half of the policy: an acquire may legally name
    /// `UNDEFINED` here, and doing so is what asks the driver whether it
    /// discards the client's content.
    #[must_use]
    fn acquire_layout(self) -> vk::ImageLayout {
        self.old_layout.layout()
    }

    /// The layout the release hands the image back in.
    ///
    /// `GENERAL` whatever the policy says, because this is a barrier's
    /// `newLayout` and VUID-VkImageMemoryBarrier2-newLayout-01198 forbids
    /// `UNDEFINED` there. It is also the layout the image is genuinely in: a
    /// producer outside Vulkan has no other, which is why it is what
    /// [`ForeignLayout::General`] names on the way in.
    const RELEASE_LAYOUT: vk::ImageLayout = vk::ImageLayout::GENERAL;
}

/// Which queue family an imported image is acquired from.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum QueueFamilyMode {
    /// `VK_QUEUE_FAMILY_FOREIGN_EXT`: a real ownership transfer from a producer
    /// outside Vulkan, which is what a client's dmabuf is. The default because
    /// it is what the specification describes.
    #[default]
    Foreign,
    /// `VK_QUEUE_FAMILY_IGNORED`: no ownership transfer at all. What WayVR does,
    /// and it works on Mesa; whether that is the driver being lenient is the
    /// question.
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
    /// `VK_IMAGE_LAYOUT_GENERAL`. The default: a DRM-modifier image written by
    /// a producer outside Vulkan has no other meaningful layout, and an
    /// ownership acquire from a non-`UNDEFINED` layout preserves its contents.
    #[default]
    General,
    /// `VK_IMAGE_LAYOUT_UNDEFINED`. Legal, and permits the driver to discard
    /// the client's rendered content — which is the whole reason
    /// `TextureInfo.foreign` exists. Available only so a run can confirm the
    /// discard happens rather than assuming it.
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
/// Named fields rather than a pair, because both are `u32` and the FFI call
/// takes them positionally: a transposition would compile and record a barrier
/// naming a queue family index as a layout.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct BarrierArguments {
    pub(super) layout: u32,
    pub(super) queue_family: u32,
}

/// The arguments the acquire barrier is recorded with.
///
/// Separate from [`LovrTexture::acquire`] so the choice is a pure function of
/// the policy: recording the barrier needs a device and this does not, which is
/// what makes the choice testable.
pub(super) fn acquire_arguments(policy: BarrierPolicy) -> BarrierArguments {
    BarrierArguments {
        layout: policy.acquire_layout().as_raw().unsigned_abs(),
        queue_family: policy.source_family.index(),
    }
}

/// The arguments the release barrier is recorded with.
///
/// The layout is [`BarrierPolicy::RELEASE_LAYOUT`] whatever the policy says.
/// This is a barrier's `newLayout`, where `UNDEFINED` is forbidden, so the
/// policy's own layout must not reach here. As [`acquire_arguments`], separate
/// so that is testable without a device.
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
    fn a_barrier_policy_defaults_to_what_the_specification_describes() {
        let policy = BarrierPolicy::default();
        assert_eq!(policy.source_family, QueueFamilyMode::Foreign);
        assert_eq!(policy.old_layout, ForeignLayout::General);
        assert_eq!(policy.source_family.index(), vk::QUEUE_FAMILY_FOREIGN_EXT);
        assert_eq!(policy.old_layout.layout(), vk::ImageLayout::GENERAL);
    }

    #[test]
    fn the_other_value_of_each_setting_is_reachable_without_a_rebuild() {
        let policy = BarrierPolicy::from_settings(Some("ignored"), Some("undefined"));

        assert_eq!(policy.source_family, QueueFamilyMode::Ignored);
        assert_eq!(policy.source_family.index(), vk::QUEUE_FAMILY_IGNORED);
        assert_eq!(policy.old_layout, ForeignLayout::Undefined);
        assert_eq!(policy.old_layout.layout(), vk::ImageLayout::UNDEFINED);
    }

    #[test]
    fn a_release_hands_the_image_back_in_a_layout_a_barrier_may_name() {
        // The regression: the release passed the policy's own layout as the
        // barrier's `newLayout`, so `LUNETTE_IMPORT_LAYOUT=undefined` recorded
        // `VK_IMAGE_LAYOUT_UNDEFINED` as a destination, which
        // VUID-VkImageMemoryBarrier2-newLayout-01198 forbids. Asserting on the
        // arguments the call is made with, rather than on the constant, is what
        // makes reintroducing the switch on the release side fail here.
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
        // The other half of the pair: `UNDEFINED` is legal as a barrier's
        // `oldLayout`, and naming it is the whole point of the setting, so the
        // acquire must pass the policy through where the release must not.
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

    #[test]
    fn an_unrecognised_setting_falls_back_rather_than_stopping_the_session() {
        assert_eq!(
            BarrierPolicy::from_settings(Some("FOREIGN"), Some("")),
            BarrierPolicy::default(),
            "a diagnostic switch is not worth failing a session over, and the parse is exact"
        );
        assert_eq!(QueueFamilyMode::parse("neither"), None);
        assert_eq!(ForeignLayout::parse("optimal"), None);
    }

    #[test]
    fn an_unset_setting_is_the_default() {
        assert_eq!(
            BarrierPolicy::from_settings(None, None),
            BarrierPolicy::default()
        );
    }
}
