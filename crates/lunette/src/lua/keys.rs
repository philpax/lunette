//! Defines Lua key names for the evdev keycodes accepted by sinks.
//!
//! Named keys use [`VirtualKey`] for host sinks and window seats. Seats also accept raw keycodes.

use lunette_capture::hid::VirtualKey;
use lunette_compositor::protocol::KeyModifier;
use lunette_luau::Type;
use mlua::{IntoLua, Lua, Value};

use crate::lua::declarations::{AliasSpec, Aliased, Typed};

/// Every key name and its evdev code, as `lunette.keyCodes()` answers it.
#[derive(Clone, Copy, Debug)]
pub struct KeyCodes;

impl IntoLua for KeyCodes {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        let codes = lua.create_table_with_capacity(0, VirtualKey::ALL.len())?;
        for key in VirtualKey::ALL {
            codes.set(key_name(*key), key.evdev_code())?;
        }
        Ok(Value::Table(codes))
    }
}

impl Typed for KeyCodes {
    fn luau() -> Type {
        Type::map(KeyName::luau(), Type::NUMBER)
    }
}

/// The name of one key, as a key of the table `lunette.keyCodes()` answers.
#[derive(Clone, Copy, Debug)]
pub struct KeyName;

impl Typed for KeyName {
    fn luau() -> Type {
        Type::Named("KeyName")
    }
}

impl Aliased for KeyName {
    const ALIAS: AliasSpec = AliasSpec {
        doc: "The name of a key `lunette.keyCodes()` answers with an evdev code for. Indexing the table with any other name is a type error.",
        name: Self::luau,
        definition: |_| Type::literals(&KEY_NAMES),
    };
}

/// `lunette.modifierNames()`: every modifier a seat accepts, from
/// [`KeyModifier`] in the keymap's own modifier order.
pub fn modifier_names() -> Vec<String> {
    KeyModifier::NAMES
        .iter()
        .map(|name| (*name).to_owned())
        .collect()
}

/// A keymap reports locked modifiers separately from depressed modifiers. Each locked modifier
/// toggles on a press.
pub fn locking_modifier_names() -> Vec<String> {
    KeyModifier::ALL
        .iter()
        .filter(|modifier| modifier.is_lock())
        .map(|modifier| modifier.as_str().to_owned())
        .collect()
}

/// Every key name, in [`VirtualKey::ALL`]'s order.
static KEY_NAMES: [&str; VirtualKey::ALL.len()] = {
    let mut names = [""; VirtualKey::ALL.len()];
    let mut index = 0;
    while index < names.len() {
        names[index] = key_name(VirtualKey::ALL[index]);
        index += 1;
    }
    names
};

/// Lua key names use explicit camelCase strings. Renaming a Rust variant does not change the Lua
/// API.
const fn key_name(key: VirtualKey) -> &'static str {
    match key {
        VirtualKey::Escape => "escape",
        VirtualKey::Digit1 => "digit1",
        VirtualKey::Digit2 => "digit2",
        VirtualKey::Digit3 => "digit3",
        VirtualKey::Digit4 => "digit4",
        VirtualKey::Digit5 => "digit5",
        VirtualKey::Digit6 => "digit6",
        VirtualKey::Digit7 => "digit7",
        VirtualKey::Digit8 => "digit8",
        VirtualKey::Digit9 => "digit9",
        VirtualKey::Digit0 => "digit0",
        VirtualKey::Minus => "minus",
        VirtualKey::Equal => "equal",
        VirtualKey::Backspace => "backspace",
        VirtualKey::Tab => "tab",
        VirtualKey::Q => "q",
        VirtualKey::W => "w",
        VirtualKey::E => "e",
        VirtualKey::R => "r",
        VirtualKey::T => "t",
        VirtualKey::Y => "y",
        VirtualKey::U => "u",
        VirtualKey::I => "i",
        VirtualKey::O => "o",
        VirtualKey::P => "p",
        VirtualKey::LeftBrace => "leftBrace",
        VirtualKey::RightBrace => "rightBrace",
        VirtualKey::Enter => "enter",
        VirtualKey::LeftCtrl => "leftCtrl",
        VirtualKey::A => "a",
        VirtualKey::S => "s",
        VirtualKey::D => "d",
        VirtualKey::F => "f",
        VirtualKey::G => "g",
        VirtualKey::H => "h",
        VirtualKey::J => "j",
        VirtualKey::K => "k",
        VirtualKey::L => "l",
        VirtualKey::Semicolon => "semicolon",
        VirtualKey::Apostrophe => "apostrophe",
        VirtualKey::Grave => "grave",
        VirtualKey::LeftShift => "leftShift",
        VirtualKey::Backslash => "backslash",
        VirtualKey::Z => "z",
        VirtualKey::X => "x",
        VirtualKey::C => "c",
        VirtualKey::V => "v",
        VirtualKey::B => "b",
        VirtualKey::N => "n",
        VirtualKey::M => "m",
        VirtualKey::Comma => "comma",
        VirtualKey::Dot => "dot",
        VirtualKey::Slash => "slash",
        VirtualKey::RightShift => "rightShift",
        VirtualKey::KeypadAsterisk => "keypadAsterisk",
        VirtualKey::LeftAlt => "leftAlt",
        VirtualKey::Space => "space",
        VirtualKey::CapsLock => "capsLock",
        VirtualKey::F1 => "f1",
        VirtualKey::F2 => "f2",
        VirtualKey::F3 => "f3",
        VirtualKey::F4 => "f4",
        VirtualKey::F5 => "f5",
        VirtualKey::F6 => "f6",
        VirtualKey::F7 => "f7",
        VirtualKey::F8 => "f8",
        VirtualKey::F9 => "f9",
        VirtualKey::F10 => "f10",
        VirtualKey::NumLock => "numLock",
        VirtualKey::ScrollLock => "scrollLock",
        VirtualKey::Keypad7 => "keypad7",
        VirtualKey::Keypad8 => "keypad8",
        VirtualKey::Keypad9 => "keypad9",
        VirtualKey::KeypadMinus => "keypadMinus",
        VirtualKey::Keypad4 => "keypad4",
        VirtualKey::Keypad5 => "keypad5",
        VirtualKey::Keypad6 => "keypad6",
        VirtualKey::KeypadPlus => "keypadPlus",
        VirtualKey::Keypad1 => "keypad1",
        VirtualKey::Keypad2 => "keypad2",
        VirtualKey::Keypad3 => "keypad3",
        VirtualKey::Keypad0 => "keypad0",
        VirtualKey::KeypadDot => "keypadDot",
        VirtualKey::ZenkakuHankaku => "zenkakuHankaku",
        VirtualKey::IntlBackslash => "intlBackslash",
        VirtualKey::F11 => "f11",
        VirtualKey::F12 => "f12",
        VirtualKey::IntlRo => "intlRo",
        VirtualKey::Katakana => "katakana",
        VirtualKey::Hiragana => "hiragana",
        VirtualKey::Henkan => "henkan",
        VirtualKey::KatakanaHiragana => "katakanaHiragana",
        VirtualKey::Muhenkan => "muhenkan",
        VirtualKey::KeypadJpComma => "keypadJpComma",
        VirtualKey::KeypadEnter => "keypadEnter",
        VirtualKey::RightCtrl => "rightCtrl",
        VirtualKey::KeypadSlash => "keypadSlash",
        VirtualKey::SysRq => "sysRq",
        VirtualKey::RightAlt => "rightAlt",
        VirtualKey::Home => "home",
        VirtualKey::Up => "up",
        VirtualKey::PageUp => "pageUp",
        VirtualKey::Left => "left",
        VirtualKey::Right => "right",
        VirtualKey::End => "end",
        VirtualKey::Down => "down",
        VirtualKey::PageDown => "pageDown",
        VirtualKey::Insert => "insert",
        VirtualKey::Delete => "delete",
        VirtualKey::Mute => "mute",
        VirtualKey::VolumeDown => "volumeDown",
        VirtualKey::VolumeUp => "volumeUp",
        VirtualKey::Power => "power",
        VirtualKey::KeypadEqual => "keypadEqual",
        VirtualKey::Pause => "pause",
        VirtualKey::KeypadComma => "keypadComma",
        VirtualKey::Hangeul => "hangeul",
        VirtualKey::Hanja => "hanja",
        VirtualKey::IntlYen => "intlYen",
        VirtualKey::LeftMeta => "leftMeta",
        VirtualKey::RightMeta => "rightMeta",
        VirtualKey::Compose => "compose",
        VirtualKey::Stop => "stop",
        VirtualKey::Again => "again",
        VirtualKey::Undo => "undo",
        VirtualKey::Copy => "copy",
        VirtualKey::Paste => "paste",
        VirtualKey::Find => "find",
        VirtualKey::Cut => "cut",
        VirtualKey::Help => "help",
        VirtualKey::Menu => "menu",
        VirtualKey::Calculator => "calculator",
        VirtualKey::Sleep => "sleep",
        VirtualKey::Mail => "mail",
        VirtualKey::Bookmarks => "bookmarks",
        VirtualKey::Computer => "computer",
        VirtualKey::Back => "back",
        VirtualKey::Forward => "forward",
        VirtualKey::NextSong => "nextSong",
        VirtualKey::PlayPause => "playPause",
        VirtualKey::PreviousSong => "previousSong",
        VirtualKey::StopCd => "stopCd",
        VirtualKey::Record => "record",
        VirtualKey::Rewind => "rewind",
        VirtualKey::HomePage => "homePage",
        VirtualKey::Refresh => "refresh",
        VirtualKey::ScrollUp => "scrollUp",
        VirtualKey::ScrollDown => "scrollDown",
        VirtualKey::F13 => "f13",
        VirtualKey::F14 => "f14",
        VirtualKey::F15 => "f15",
        VirtualKey::F16 => "f16",
        VirtualKey::F17 => "f17",
        VirtualKey::F18 => "f18",
        VirtualKey::F19 => "f19",
        VirtualKey::F20 => "f20",
        VirtualKey::F21 => "f21",
        VirtualKey::F22 => "f22",
        VirtualKey::F23 => "f23",
        VirtualKey::F24 => "f24",
        VirtualKey::Search => "search",
        VirtualKey::BrightnessDown => "brightnessDown",
        VirtualKey::BrightnessUp => "brightnessUp",
        VirtualKey::Media => "media",
        VirtualKey::SwitchVideoMode => "switchVideoMode",
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn no_two_keys_share_a_name() {
        let unique: HashSet<&str> = KEY_NAMES.iter().copied().collect();
        assert_eq!(unique.len(), KEY_NAMES.len());
    }

    #[test]
    fn every_name_is_camel_case() {
        for name in KEY_NAMES {
            let mut characters = name.chars();
            let first = characters.next();
            assert!(
                first.is_some_and(|first| first.is_ascii_lowercase()),
                "{name} starts with a lowercase letter"
            );
            assert!(
                characters.all(|character| character.is_ascii_alphanumeric()),
                "{name} is letters and digits"
            );
        }
    }

    #[test]
    fn a_name_answers_its_key_s_evdev_code() {
        let lua = Lua::new();
        let value = KeyCodes.into_lua(&lua).expect("the table builds");
        let codes = value.as_table().expect("the codes are a table");
        for (name, key) in [
            ("escape", VirtualKey::Escape),
            ("leftShift", VirtualKey::LeftShift),
            ("capsLock", VirtualKey::CapsLock),
            ("keypadEnter", VirtualKey::KeypadEnter),
            ("f12", VirtualKey::F12),
        ] {
            let code: u16 = codes.get(name).expect("the name is a key");
            assert_eq!(code, key.evdev_code(), "{name}");
        }
        assert_eq!(codes.pairs::<String, u16>().count(), VirtualKey::ALL.len());
    }

    #[test]
    fn the_locking_modifiers_are_the_keymap_locks() {
        assert_eq!(locking_modifier_names(), ["capsLock", "numLock"]);
    }
}
