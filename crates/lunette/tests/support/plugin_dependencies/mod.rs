//! Test-only inventory, source ownership, and parser-backed boundary validation.

pub mod catalog;
pub mod documentation;
pub mod ownership;
pub mod policy;
#[cfg(test)]
mod policy_tests;
pub mod scan;
