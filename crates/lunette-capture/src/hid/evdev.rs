//! Linux-only: the parts of `linux/input.h` and `linux/uinput.h` lunette uses.
//!
//! `libc` carries the structures — `input_event`, `input_id`, `input_absinfo`,
//! `uinput_setup`, `uinput_abs_setup` — but not the event-type constants and
//! not the ioctl request numbers, so those are written out here against the
//! kernel headers.
//!
//! Handrolling this rather than taking `input-linux` is a deliberate choice.
//! `input-linux` 0.7.1 pulls `nix` 0.26 while its own `input-linux-sys` 0.8
//! pulls `nix` 0.29, so it lands two copies of `nix` in the tree; and the part
//! of it lunette would use is this file's worth of constants plus a wrapper over
//! `ioctl`. The rest of its surface — reading devices, decoding event streams —
//! is not wanted. The whole problem is visible here, which is the condition the
//! house rules put on handrolling something.
//!
//! Nothing in this file is `unsafe`; it is constants and one arithmetic helper.
//! The calls that use them are in [`crate::hid::uinput`].

use std::ffi::c_ulong;

// The ioctl request encoding below is Linux's asm-generic one, which covers
// x86, arm, arm64, riscv, and loongarch. Alpha, MIPS, PowerPC, and SPARC use a
// different bit layout for the direction field, so the numbers this produces
// would be wrong there rather than merely unsupported.
#[cfg(any(
    target_arch = "mips",
    target_arch = "mips32r6",
    target_arch = "mips64",
    target_arch = "mips64r6",
    target_arch = "powerpc",
    target_arch = "powerpc64",
    target_arch = "sparc",
    target_arch = "sparc64"
))]
compile_error!(
    "the uinput ioctl requests here use Linux's asm-generic encoding, which this architecture does not use"
);

/// Synchronisation events. A zero-code `EV_SYN` ends an event group.
pub const EV_SYN: u16 = 0x00;
/// Key and button events.
pub const EV_KEY: u16 = 0x01;
/// Relative axis events, which is how a wheel reports.
pub const EV_REL: u16 = 0x02;
/// Absolute axis events, which is how the pointer position is reported.
pub const EV_ABS: u16 = 0x03;

/// `SYN_REPORT`, the code that ends an event group.
pub const SYN_REPORT: u16 = 0x00;

pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;

/// `REL_WHEEL_HI_RES`, in 120ths of a detent.
///
/// The high-resolution axes rather than `REL_WHEEL`: a host that understands
/// them scrolls smoothly, and one that does not still receives the low-resolution
/// events the kernel synthesises from them.
pub const REL_WHEEL_HI_RES: u16 = 0x0b;
/// `REL_HWHEEL_HI_RES`, in 120ths of a detent.
pub const REL_HWHEEL_HI_RES: u16 = 0x0c;

/// How many units one wheel detent is, on the high-resolution axes.
pub const WHEEL_HI_RES_PER_DETENT: f64 = 120.0;

/// `UI_DEV_CREATE`: brings the configured device into existence.
pub const UI_DEV_CREATE: c_ulong = io(1);
/// `UI_DEV_DESTROY`: removes it again.
pub const UI_DEV_DESTROY: c_ulong = io(2);
/// `UI_DEV_SETUP`: names the device and gives it a bus identity.
pub const UI_DEV_SETUP: c_ulong = iow(3, size_of::<libc::uinput_setup>());
/// `UI_ABS_SETUP`: declares one absolute axis's range.
pub const UI_ABS_SETUP: c_ulong = iow(4, size_of::<libc::uinput_abs_setup>());
/// `UI_SET_EVBIT`: declares that the device emits an event type at all.
pub const UI_SET_EVBIT: c_ulong = iow(100, size_of::<libc::c_int>());
/// `UI_SET_KEYBIT`: declares one key or button the device can emit.
pub const UI_SET_KEYBIT: c_ulong = iow(101, size_of::<libc::c_int>());
/// `UI_SET_RELBIT`: declares one relative axis.
pub const UI_SET_RELBIT: c_ulong = iow(102, size_of::<libc::c_int>());
/// `UI_SET_ABSBIT`: declares one absolute axis.
pub const UI_SET_ABSBIT: c_ulong = iow(103, size_of::<libc::c_int>());

/// The `'U'` in `_IOW('U', …)`, which is what makes these requests uinput's.
const UINPUT_IOCTL_TYPE: u32 = b'U' as u32;

const IOC_NR_SHIFT: u32 = 0;
const IOC_TYPE_SHIFT: u32 = 8;
const IOC_SIZE_SHIFT: u32 = 16;
const IOC_DIR_SHIFT: u32 = 30;
/// `_IOC_WRITE`: the argument is read by the kernel from userspace.
const IOC_DIR_WRITE: u32 = 1;

/// `_IO('U', nr)`: a request that carries no argument.
const fn io(nr: u32) -> c_ulong {
    ioc(0, nr, 0)
}

/// `_IOW('U', nr, ty)`: a request whose argument the kernel reads.
const fn iow(nr: u32, size: usize) -> c_ulong {
    ioc(IOC_DIR_WRITE, nr, size)
}

const fn ioc(dir: u32, nr: u32, size: usize) -> c_ulong {
    ((dir << IOC_DIR_SHIFT)
        | (UINPUT_IOCTL_TYPE << IOC_TYPE_SHIFT)
        | (nr << IOC_NR_SHIFT)
        | ((size as u32) << IOC_SIZE_SHIFT)) as c_ulong
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn the_argumentless_requests_match_the_kernel_headers() {
        // `_IO('U', 1)` and `_IO('U', 2)`, which every uinput example in the
        // kernel documentation shows as these literals.
        assert_eq!(UI_DEV_CREATE, 0x5501);
        assert_eq!(UI_DEV_DESTROY, 0x5502);
    }

    #[test]
    fn the_integer_requests_match_the_kernel_headers() {
        // `_IOW('U', 100, int)`: direction 1 at bit 30, size 4 at bit 16,
        // 'U' at bit 8, and the number in the low byte.
        assert_eq!(UI_SET_EVBIT, 0x4004_5564);
        assert_eq!(UI_SET_KEYBIT, 0x4004_5565);
        assert_eq!(UI_SET_RELBIT, 0x4004_5566);
        assert_eq!(UI_SET_ABSBIT, 0x4004_5567);
    }

    #[test]
    fn the_structure_requests_carry_the_structure_size() {
        assert_eq!(
            UI_DEV_SETUP,
            iow(3, size_of::<libc::uinput_setup>()),
            "the encoding and the constant disagree",
        );
        assert_eq!(
            (UI_DEV_SETUP >> IOC_SIZE_SHIFT) & 0x3fff,
            size_of::<libc::uinput_setup>() as c_ulong,
        );
        assert_eq!(
            (UI_ABS_SETUP >> IOC_SIZE_SHIFT) & 0x3fff,
            size_of::<libc::uinput_abs_setup>() as c_ulong,
        );
    }

    #[test]
    fn every_request_names_uinput() {
        for request in [
            UI_DEV_CREATE,
            UI_DEV_DESTROY,
            UI_DEV_SETUP,
            UI_ABS_SETUP,
            UI_SET_EVBIT,
            UI_SET_KEYBIT,
            UI_SET_RELBIT,
            UI_SET_ABSBIT,
        ] {
            assert_eq!(
                (request >> IOC_TYPE_SHIFT) & 0xff,
                c_ulong::from(b'U'),
                "{request:#x} is not a uinput request",
            );
        }
    }
}
