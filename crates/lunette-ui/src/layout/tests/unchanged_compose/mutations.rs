//! Exercises committed mutations and callback effects against the always-compose oracle.

use pretty_assertions::assert_eq;

use super::*;

#[test]
fn successful_failed_and_empty_batches_preserve_reporting_and_text_side_effects() {
    let mut pair = Pair::new();
    pair.apply(|| {
        let mut changes = shape_changes(4, 1, Display::Flex);
        changes.push(Change::Create {
            id: 5,
            content: ContentSpec::Text {
                text: "alpha beta gamma delta".to_owned(),
                style: TextStyle::default(),
            },
            style: Box::default(),
        });
        changes
    });
    pair.compute(1, None, None);
    pair.apply(|| {
        vec![Change::SetChildren {
            id: 1,
            children: vec![2, 3, 4],
        }]
    });
    assert_eq!(ids(&pair.compute(1, None, None).changed), vec![2, 3, 4]);
    pair.apply(Vec::new);
    assert!(pair.compute(1, None, None).changed.is_empty());
    pair.apply(|| {
        vec![Change::SetStyle {
            id: 2,
            style: row(0.125),
        }]
    });
    pair.compute(1, None, None);
    pair.apply(|| {
        vec![Change::SetChildren {
            id: 1,
            children: vec![4, 3, 2, 5],
        }]
    });
    assert_eq!(
        ids(&pair.compute(1, None, None).changed),
        vec![1, 4, 3, 2, 5]
    );
    pair.apply(|| {
        vec![Change::SetText {
            id: 5,
            text: "epsilon zeta eta theta iota kappa lambda".to_owned(),
            style: TextStyle::default(),
        }]
    });
    pair.compute(1, Some(0.075), None);
    pair.text_lines();
    pair.compute(1, Some(0.075), None);
    pair.apply(|| {
        vec![
            Change::SetChildren {
                id: 1,
                children: vec![2, 3],
            },
            Change::SetChildren {
                id: 2,
                children: vec![4, 5],
            },
        ]
    });
    pair.compute(1, None, None);
    pair.apply(|| vec![Change::Remove { id: 2 }]);
    pair.compute(1, None, None);
    pair.compute(4, None, None);
    pair.apply(|| {
        vec![Change::Create {
            id: 2,
            content: ContentSpec::Box,
            style: Box::default(),
        }]
    });
    pair.compute(2, None, None);
    for invalid in 0..3 {
        pair.apply(|| {
            vec![
                Change::SetStyle {
                    id: 1,
                    style: row(0.875),
                },
                match invalid {
                    0 => Change::Remove { id: 99 },
                    1 => Change::SetText {
                        id: 5,
                        text: "rejected".to_owned(),
                        style: TextStyle {
                            size: 0.0,
                            ..Default::default()
                        },
                    },
                    _ => fixed(99, f32::INFINITY, 1.0),
                },
            ]
        });
        pair.compute(1, None, None);
    }
}

#[test]
fn root_switches_dimensions_and_root_errors_match() {
    let mut pair = Pair::new();
    pair.apply(|| {
        let mut changes = shape_changes(3, 0, Display::Flex);
        changes.push(fixed(4, 0.25, 0.5));
        changes
    });
    for root in [1, 4, 1, 2, 99, 4, 1] {
        for width in [None, Some(0.0), Some(-0.0), Some(1.0), Some(f32::NAN)] {
            for height in [None, Some(0.0), Some(2.0), Some(f32::NAN)] {
                pair.compute(root, width, height);
                pair.compute(root, width, height);
            }
        }
    }
    pair.apply(|| {
        vec![Change::SetChildren {
            id: 4,
            children: vec![1],
        }]
    });
    pair.compute(1, None, None);
    pair.compute(4, None, None);
    pair.apply(|| vec![Change::Remove { id: 4 }]);
    pair.compute(4, None, None);
    pair.compute(1, None, None);
}

#[test]
fn callbacks_failures_partial_placement_and_hidden_children_remain_per_compute() {
    for mode in [
        Mode::Good,
        Mode::Fail,
        Mode::Partial,
        Mode::Invalid,
        Mode::Omit,
    ] {
        let mut pair = Pair::new();
        pair.apply(script_changes);
        pair.compute(1, None, None);
        pair.mode(mode);
        let mut previous_failures = Vec::new();
        for iteration in 0..3 {
            let mut values = pair.actual_scripts.values.get();
            values[0] += 0.125;
            values[4] += 0.25;
            pair.values(values);
            pair.clear_caches(1);
            let calls_before = pair.actual_scripts.calls.borrow().len();
            let outcome = pair.compute(1, None, None);
            assert!(pair.actual_scripts.calls.borrow().len() > calls_before);
            if matches!(mode, Mode::Fail | Mode::Partial | Mode::Invalid) {
                assert!(
                    !outcome.failures.is_empty(),
                    "mode {mode:?}, iteration {iteration}"
                );
                if matches!(mode, Mode::Fail | Mode::Partial) {
                    assert_ne!(outcome.failures, previous_failures);
                }
                previous_failures = outcome.failures;
            }
            if matches!(mode, Mode::Partial | Mode::Invalid) {
                assert!(outcome.changed.iter().any(|p| p.id == 2));
            }
            let calls_before = pair.actual_scripts.calls.borrow().len();
            assert!(pair.compute(1, None, None).failures.is_empty());
            assert_eq!(pair.actual_scripts.calls.borrow().len(), calls_before);
        }
        pair.mode(Mode::Good);
        pair.clear_caches(1);
        pair.compute(1, None, None);
    }
    let mut pair = Pair::new();
    pair.apply(|| {
        vec![Change::Create {
            id: 1,
            content: ContentSpec::Measured,
            style: Box::default(),
        }]
    });
    pair.mode(Mode::Fail);
    for _ in 0..3 {
        pair.clear_caches(1);
        assert!(!pair.compute(1, None, None).failures.is_empty());
        assert!(pair.compute(1, None, None).failures.is_empty());
    }
}

#[test]
fn rejected_text_preparation_and_busy_fonts_leave_geometry_unchanged() {
    let mut pair = Pair::new();
    pair.apply(|| shape_changes(2, 0, Display::Flex));
    pair.compute(1, None, None);
    let fonts = Rc::clone(&pair.actual.fonts);
    let borrow = fonts.borrow_mut();
    pair.apply(|| {
        vec![
            Change::SetStyle {
                id: 1,
                style: row(0.5),
            },
            Change::Create {
                id: 3,
                content: ContentSpec::Text {
                    text: "not committed".to_owned(),
                    style: TextStyle::default(),
                },
                style: Box::default(),
            },
        ]
    });
    assert!(!pair.actual.contains(3));
    assert!(pair.compute(1, None, None).changed.is_empty());
    drop(borrow);
    pair.apply(|| {
        vec![Change::Create {
            id: 3,
            content: ContentSpec::Text {
                text: "alpha beta gamma".to_owned(),
                style: TextStyle::default(),
            },
            style: Box::default(),
        }]
    });
    pair.compute(3, Some(0.05), None);
    for _ in 0..2 {
        pair.clear_caches(3);
        let borrow = fonts.borrow_mut();
        assert!(!pair.compute(3, Some(0.05), None).failures.is_empty());
        drop(borrow);
        pair.clear_caches(3);
        pair.compute(3, Some(0.05), None);
    }
}
