//! Linux-only: checks [`VirtualKey`]'s codes against xkeyboard-config.
//!
//! The codes in `src/hid/key.rs` are written out by hand from
//! `linux/input-event-codes.h`. No crate in the dependency tree carries that
//! header's constants, so this test checks them against an independent table
//! derived from it: xkeyboard-config's `evdev` keycodes, which libxkbcommon
//! reads. Each key there has a physical name, such as `<LFSH>` for left shift,
//! at its evdev code plus eight.
//!
//! Most media and launcher keys have no physical name; xkeyboard-config names
//! them `<I…>` after their own code, which would check nothing. Those keys are
//! checked by the keysym the `us` layout gives them, such as `XF86Mail`, which
//! is defined independently of the code.
//!
//! The keymap is compiled from a pinned xkeyboard-config release and checked
//! in, because distributions ship different releases and older ones leave some
//! codes unnamed.

use lunette_capture::hid::VirtualKey;
use xkbcommon::xkb;

use crate::Expected::{Keysym, Name};

#[test]
fn every_key_is_named_by_the_evdev_keycodes_or_its_keysym() {
    let context = xkb::Context::new(xkb::CONTEXT_NO_DEFAULT_INCLUDES);
    let Some(keymap) = xkb::Keymap::new_from_string(
        &context,
        KEYMAP.to_owned(),
        xkb::KEYMAP_FORMAT_TEXT_V1,
        xkb::KEYMAP_COMPILE_NO_FLAGS,
    ) else {
        panic!("the pinned us keymap compiles");
    };

    let mut checked = Vec::new();
    let mut wrong = Vec::new();
    for (key, expected) in EXPECTED {
        checked.push(*key);
        let code = u32::from(key.evdev_code()) + XKB_OFFSET;
        let matches = match expected {
            Name(name) => keymap
                .key_by_name(*name)
                .is_some_and(|found| found.raw() == code),
            Keysym(symbol) => keymap
                .key_get_syms_by_level(xkb::Keycode::new(code), 0, 0)
                .iter()
                .any(|found| xkb::keysym_get_name(*found) == *symbol),
        };
        if !matches {
            wrong.push(format!("{key:?} is not {expected:?}"));
        }
    }

    assert!(wrong.is_empty(), "{wrong:#?}");
    assert_eq!(
        checked,
        VirtualKey::ALL,
        "every key is checked, in declaration order"
    );
}

/// The us layout compiled from xkeyboard-config 2.48's evdev rules.
const KEYMAP: &str = include_str!("fixtures/evdev-us.xkb");

/// XKB numbers keys eight higher than evdev.
const XKB_OFFSET: u32 = 8;

/// What xkeyboard-config calls a key.
#[derive(Debug)]
enum Expected {
    /// The physical name in the `evdev` keycodes.
    Name(&'static str),
    /// The first-level keysym the `us` layout assigns.
    Keysym(&'static str),
}

const EXPECTED: &[(VirtualKey, Expected)] = &[
    (VirtualKey::Escape, Name("ESC")),
    (VirtualKey::Digit1, Name("AE01")),
    (VirtualKey::Digit2, Name("AE02")),
    (VirtualKey::Digit3, Name("AE03")),
    (VirtualKey::Digit4, Name("AE04")),
    (VirtualKey::Digit5, Name("AE05")),
    (VirtualKey::Digit6, Name("AE06")),
    (VirtualKey::Digit7, Name("AE07")),
    (VirtualKey::Digit8, Name("AE08")),
    (VirtualKey::Digit9, Name("AE09")),
    (VirtualKey::Digit0, Name("AE10")),
    (VirtualKey::Minus, Name("AE11")),
    (VirtualKey::Equal, Name("AE12")),
    (VirtualKey::Backspace, Name("BKSP")),
    (VirtualKey::Tab, Name("TAB")),
    (VirtualKey::Q, Name("AD01")),
    (VirtualKey::W, Name("AD02")),
    (VirtualKey::E, Name("AD03")),
    (VirtualKey::R, Name("AD04")),
    (VirtualKey::T, Name("AD05")),
    (VirtualKey::Y, Name("AD06")),
    (VirtualKey::U, Name("AD07")),
    (VirtualKey::I, Name("AD08")),
    (VirtualKey::O, Name("AD09")),
    (VirtualKey::P, Name("AD10")),
    (VirtualKey::LeftBrace, Name("AD11")),
    (VirtualKey::RightBrace, Name("AD12")),
    (VirtualKey::Enter, Name("RTRN")),
    (VirtualKey::LeftCtrl, Name("LCTL")),
    (VirtualKey::A, Name("AC01")),
    (VirtualKey::S, Name("AC02")),
    (VirtualKey::D, Name("AC03")),
    (VirtualKey::F, Name("AC04")),
    (VirtualKey::G, Name("AC05")),
    (VirtualKey::H, Name("AC06")),
    (VirtualKey::J, Name("AC07")),
    (VirtualKey::K, Name("AC08")),
    (VirtualKey::L, Name("AC09")),
    (VirtualKey::Semicolon, Name("AC10")),
    (VirtualKey::Apostrophe, Name("AC11")),
    (VirtualKey::Grave, Name("TLDE")),
    (VirtualKey::LeftShift, Name("LFSH")),
    (VirtualKey::Backslash, Name("BKSL")),
    (VirtualKey::Z, Name("AB01")),
    (VirtualKey::X, Name("AB02")),
    (VirtualKey::C, Name("AB03")),
    (VirtualKey::V, Name("AB04")),
    (VirtualKey::B, Name("AB05")),
    (VirtualKey::N, Name("AB06")),
    (VirtualKey::M, Name("AB07")),
    (VirtualKey::Comma, Name("AB08")),
    (VirtualKey::Dot, Name("AB09")),
    (VirtualKey::Slash, Name("AB10")),
    (VirtualKey::RightShift, Name("RTSH")),
    (VirtualKey::KeypadAsterisk, Name("KPMU")),
    (VirtualKey::LeftAlt, Name("LALT")),
    (VirtualKey::Space, Name("SPCE")),
    (VirtualKey::CapsLock, Name("CAPS")),
    (VirtualKey::F1, Name("FK01")),
    (VirtualKey::F2, Name("FK02")),
    (VirtualKey::F3, Name("FK03")),
    (VirtualKey::F4, Name("FK04")),
    (VirtualKey::F5, Name("FK05")),
    (VirtualKey::F6, Name("FK06")),
    (VirtualKey::F7, Name("FK07")),
    (VirtualKey::F8, Name("FK08")),
    (VirtualKey::F9, Name("FK09")),
    (VirtualKey::F10, Name("FK10")),
    (VirtualKey::NumLock, Name("NMLK")),
    (VirtualKey::ScrollLock, Name("SCLK")),
    (VirtualKey::Keypad7, Name("KP7")),
    (VirtualKey::Keypad8, Name("KP8")),
    (VirtualKey::Keypad9, Name("KP9")),
    (VirtualKey::KeypadMinus, Name("KPSU")),
    (VirtualKey::Keypad4, Name("KP4")),
    (VirtualKey::Keypad5, Name("KP5")),
    (VirtualKey::Keypad6, Name("KP6")),
    (VirtualKey::KeypadPlus, Name("KPAD")),
    (VirtualKey::Keypad1, Name("KP1")),
    (VirtualKey::Keypad2, Name("KP2")),
    (VirtualKey::Keypad3, Name("KP3")),
    (VirtualKey::Keypad0, Name("KP0")),
    (VirtualKey::KeypadDot, Name("KPDL")),
    (VirtualKey::ZenkakuHankaku, Name("ZEHA")),
    (VirtualKey::IntlBackslash, Name("LSGT")),
    (VirtualKey::F11, Name("FK11")),
    (VirtualKey::F12, Name("FK12")),
    (VirtualKey::IntlRo, Name("AB11")),
    (VirtualKey::Katakana, Name("KATA")),
    (VirtualKey::Hiragana, Name("HIRA")),
    (VirtualKey::Henkan, Name("HENK")),
    (VirtualKey::KatakanaHiragana, Name("HKTG")),
    (VirtualKey::Muhenkan, Name("MUHE")),
    (VirtualKey::KeypadJpComma, Name("JPCM")),
    (VirtualKey::KeypadEnter, Name("KPEN")),
    (VirtualKey::RightCtrl, Name("RCTL")),
    (VirtualKey::KeypadSlash, Name("KPDV")),
    (VirtualKey::SysRq, Name("PRSC")),
    (VirtualKey::RightAlt, Name("RALT")),
    (VirtualKey::Home, Name("HOME")),
    (VirtualKey::Up, Name("UP")),
    (VirtualKey::PageUp, Name("PGUP")),
    (VirtualKey::Left, Name("LEFT")),
    (VirtualKey::Right, Name("RGHT")),
    (VirtualKey::End, Name("END")),
    (VirtualKey::Down, Name("DOWN")),
    (VirtualKey::PageDown, Name("PGDN")),
    (VirtualKey::Insert, Name("INS")),
    (VirtualKey::Delete, Name("DELE")),
    (VirtualKey::Mute, Name("MUTE")),
    (VirtualKey::VolumeDown, Name("VOL-")),
    (VirtualKey::VolumeUp, Name("VOL+")),
    (VirtualKey::Power, Name("POWR")),
    (VirtualKey::KeypadEqual, Name("KPEQ")),
    (VirtualKey::Pause, Name("PAUS")),
    (VirtualKey::KeypadComma, Keysym("KP_Decimal")),
    (VirtualKey::Hangeul, Name("HNGL")),
    (VirtualKey::Hanja, Name("HJCV")),
    (VirtualKey::IntlYen, Name("AE13")),
    (VirtualKey::LeftMeta, Name("LWIN")),
    (VirtualKey::RightMeta, Name("RWIN")),
    (VirtualKey::Compose, Name("COMP")),
    (VirtualKey::Stop, Name("STOP")),
    (VirtualKey::Again, Name("AGAI")),
    (VirtualKey::Undo, Name("UNDO")),
    (VirtualKey::Copy, Name("COPY")),
    (VirtualKey::Paste, Name("PAST")),
    (VirtualKey::Find, Name("FIND")),
    (VirtualKey::Cut, Name("CUT")),
    (VirtualKey::Help, Name("HELP")),
    (VirtualKey::Menu, Keysym("XF86MenuKB")),
    (VirtualKey::Calculator, Keysym("XF86Calculator")),
    (VirtualKey::Sleep, Keysym("XF86Sleep")),
    (VirtualKey::Mail, Keysym("XF86Mail")),
    (VirtualKey::Bookmarks, Keysym("XF86Favorites")),
    (VirtualKey::Computer, Keysym("XF86MyComputer")),
    (VirtualKey::Back, Keysym("XF86Back")),
    (VirtualKey::Forward, Keysym("XF86Forward")),
    (VirtualKey::NextSong, Keysym("XF86AudioNext")),
    (VirtualKey::PlayPause, Keysym("XF86AudioPlay")),
    (VirtualKey::PreviousSong, Keysym("XF86AudioPrev")),
    (VirtualKey::StopCd, Keysym("XF86AudioStop")),
    (VirtualKey::Record, Keysym("XF86AudioRecord")),
    (VirtualKey::Rewind, Keysym("XF86AudioRewind")),
    (VirtualKey::HomePage, Keysym("XF86HomePage")),
    (VirtualKey::Refresh, Keysym("XF86Reload")),
    (VirtualKey::ScrollUp, Keysym("XF86ScrollUp")),
    (VirtualKey::ScrollDown, Keysym("XF86ScrollDown")),
    (VirtualKey::F13, Name("FK13")),
    (VirtualKey::F14, Name("FK14")),
    (VirtualKey::F15, Name("FK15")),
    (VirtualKey::F16, Name("FK16")),
    (VirtualKey::F17, Name("FK17")),
    (VirtualKey::F18, Name("FK18")),
    (VirtualKey::F19, Name("FK19")),
    (VirtualKey::F20, Name("FK20")),
    (VirtualKey::F21, Name("FK21")),
    (VirtualKey::F22, Name("FK22")),
    (VirtualKey::F23, Name("FK23")),
    (VirtualKey::F24, Name("FK24")),
    (VirtualKey::Search, Keysym("XF86Search")),
    (VirtualKey::BrightnessDown, Keysym("XF86MonBrightnessDown")),
    (VirtualKey::BrightnessUp, Keysym("XF86MonBrightnessUp")),
    (VirtualKey::Media, Keysym("XF86AudioMedia")),
    (VirtualKey::SwitchVideoMode, Keysym("XF86Display")),
];
