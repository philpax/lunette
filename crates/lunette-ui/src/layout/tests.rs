#![expect(
    clippy::expect_used,
    reason = "Tests fail loudly on a malformed fixture; that is the assertion."
)]

use std::cell::RefCell;

use pretty_assertions::assert_eq;
use taffy::{
    geometry::Size as TaffySize,
    style::{Dimension, Display, FlexDirection, LengthPercentage},
    style_helpers::{length, zero},
};

use super::*;
use crate::test_fonts;

fn tree() -> Tree {
    Tree::new(std::rc::Rc::new(RefCell::new(test_fonts::mono())))
}

fn row(gap: f32) -> Box<Style> {
    Box::new(Style {
        display: Display::Flex,
        flex_direction: FlexDirection::Row,
        gap: TaffySize {
            width: LengthPercentage::length(gap),
            height: zero(),
        },
        ..Style::default()
    })
}

fn column() -> Box<Style> {
    Box::new(Style {
        display: Display::Flex,
        flex_direction: FlexDirection::Column,
        ..Style::default()
    })
}

fn fixed(id: NodeId, width: f32, height: f32) -> Change {
    Change::Create {
        id,
        content: ContentSpec::Leaf(Descriptor::Fixed { width, height }),
        style: Box::default(),
    }
}

fn placement(outcome: &Outcome, id: NodeId) -> Placement {
    *outcome
        .changed
        .iter()
        .find(|placement| placement.id == id)
        .expect("the node is reported")
}

fn close(a: f32, b: f32) -> bool {
    (a - b).abs() < 1e-6
}

#[test]
fn a_row_places_children_with_its_gap_in_metres() {
    let mut tree = tree();
    tree.apply(vec![
        Change::Create {
            id: 1,
            content: ContentSpec::Box,
            style: row(0.004),
        },
        fixed(2, 0.0125, 0.01),
        fixed(3, 0.02, 0.015),
        Change::SetChildren {
            id: 1,
            children: vec![2, 3],
        },
    ])
    .expect("a valid batch");
    let outcome = tree.compute(1, None, None, &NoScripts).expect("a root");
    let first = placement(&outcome, 2);
    let second = placement(&outcome, 3);
    // No rounding: sizes in millimetres survive in metres.
    assert!(close(first.width, 0.0125), "{first:?}");
    assert!(close(second.u, 0.0125 + 0.004), "{second:?}");
    let root = placement(&outcome, 1);
    assert!(close(root.width, 0.0125 + 0.004 + 0.02), "{root:?}");
    assert!(close(root.height, 0.015), "{root:?}");
}

#[test]
fn positions_compose_into_the_roots_coordinates() {
    let mut tree = tree();
    let padded = Box::new(Style {
        padding: taffy::geometry::Rect {
            left: length(0.01),
            right: zero(),
            top: length(0.02),
            bottom: zero(),
        },
        ..*column()
    });
    tree.apply(vec![
        Change::Create {
            id: 1,
            content: ContentSpec::Box,
            style: padded.clone(),
        },
        Change::Create {
            id: 2,
            content: ContentSpec::Box,
            style: padded,
        },
        fixed(3, 0.01, 0.01),
        Change::SetChildren {
            id: 2,
            children: vec![3],
        },
        Change::SetChildren {
            id: 1,
            children: vec![2],
        },
    ])
    .expect("a valid batch");
    let outcome = tree.compute(1, None, None, &NoScripts).expect("a root");
    let leaf = placement(&outcome, 3);
    assert!(close(leaf.u, 0.02) && close(leaf.v, 0.04), "{leaf:?}");
}

#[test]
fn a_second_computation_reports_only_what_changed() {
    let mut tree = tree();
    tree.apply(vec![
        Change::Create {
            id: 1,
            content: ContentSpec::Box,
            style: row(0.0),
        },
        fixed(2, 0.01, 0.01),
        fixed(3, 0.01, 0.01),
        fixed(4, 0.01, 0.01),
        Change::SetChildren {
            id: 1,
            children: vec![2, 3, 4],
        },
    ])
    .expect("a valid batch");
    tree.compute(1, None, None, &NoScripts).expect("a root");
    assert_eq!(
        tree.compute(1, None, None, &NoScripts)
            .expect("a root")
            .changed,
        vec![]
    );

    tree.apply(vec![Change::SetStyle {
        id: 3,
        style: Box::new(Style {
            size: TaffySize {
                width: Dimension::length(0.03),
                height: Dimension::auto(),
            },
            ..Style::default()
        }),
    }])
    .expect("a valid batch");
    let outcome = tree.compute(1, None, None, &NoScripts).expect("a root");
    let mut ids: Vec<NodeId> = outcome
        .changed
        .iter()
        .map(|placement| placement.id)
        .collect();
    ids.sort_unstable();
    // The widened node, the node it pushed along, and the root that grew.
    assert_eq!(ids, vec![1, 3, 4]);
}

#[test]
fn text_wraps_to_the_width_it_is_given() {
    let mut tree = tree();
    let text = |id| Change::Create {
        id,
        content: ContentSpec::Text {
            text: "alpha beta gamma delta epsilon".to_owned(),
            style: crate::text::TextStyle {
                family: Some("Iosevka".to_owned()),
                ..Default::default()
            },
        },
        style: Box::default(),
    };
    let narrow = Box::new(Style {
        size: TaffySize {
            width: Dimension::length(0.08),
            height: Dimension::auto(),
        },
        ..*column()
    });
    tree.apply(vec![
        Change::Create {
            id: 1,
            content: ContentSpec::Box,
            style: column(),
        },
        text(2),
        Change::Create {
            id: 3,
            content: ContentSpec::Box,
            style: narrow,
        },
        text(4),
        Change::SetChildren {
            id: 3,
            children: vec![4],
        },
        Change::SetChildren {
            id: 1,
            children: vec![2, 3],
        },
    ])
    .expect("a valid batch");
    let outcome = tree.compute(1, None, None, &NoScripts).expect("a root");
    let wide = placement(&outcome, 2);
    let wrapped = placement(&outcome, 4);
    assert!(wrapped.width <= 0.08 + 1e-6, "{wrapped:?}");
    assert!(
        wrapped.height > wide.height * 2.0,
        "wraps onto several lines: {wrapped:?} against {wide:?}"
    );
    let lines = tree.text_lines(4).expect("a text node");
    assert!(lines.len() > 2);
}

#[test]
fn a_rejected_batch_leaves_the_tree_unchanged() {
    let mut tree = tree();
    tree.apply(vec![fixed(1, 0.01, 0.01)])
        .expect("a valid batch");
    let error = tree
        .apply(vec![
            fixed(2, 0.01, 0.01),
            Change::SetChildren {
                id: 9,
                children: vec![2],
            },
        ])
        .expect_err("node 9 does not exist");
    assert_eq!(error, ApplyError::Unknown { index: 1, id: 9 });
    assert!(!tree.contains(2), "the earlier create was not applied");
}

#[test]
fn a_font_borrow_rejection_leaves_earlier_changes_unapplied() {
    for text_change in [
        Change::Create {
            id: 4,
            content: ContentSpec::Text {
                text: "new text".to_owned(),
                style: TextStyle::default(),
            },
            style: Box::default(),
        },
        Change::SetText {
            id: 2,
            text: "replacement text".to_owned(),
            style: TextStyle::default(),
        },
        Change::SetText {
            id: 2,
            text: "original text".to_owned(),
            style: TextStyle::default(),
        },
    ] {
        let mut tree = tree();
        tree.apply(vec![
            fixed(1, 0.01, 0.01),
            Change::Create {
                id: 2,
                content: ContentSpec::Text {
                    text: "original text".to_owned(),
                    style: TextStyle::default(),
                },
                style: Box::default(),
            },
        ])
        .expect("a valid batch");
        let fonts = tree.fonts.clone();
        let _borrow = fonts.borrow();
        let error = tree
            .apply(vec![fixed(3, 0.01, 0.01), text_change])
            .expect_err("the shared font borrow prevents shaping");
        assert_eq!(error, ApplyError::FontsBusy { index: 1 });
        assert!(!tree.contains(3), "the earlier create was not applied");
        assert!(!tree.contains(4), "the text create was not applied");
        let Content::Text(block) = &tree.nodes[&2].content else {
            panic!("node 2 remains text");
        };
        assert_eq!(block.text(), "original text");
    }
}

#[test]
fn invalid_text_styles_are_rejected_before_mutations_or_font_borrows() {
    for text_change in [
        Change::Create {
            id: 4,
            content: ContentSpec::Text {
                text: "new text".to_owned(),
                style: TextStyle {
                    size: -1.0,
                    ..TextStyle::default()
                },
            },
            style: Box::default(),
        },
        Change::SetText {
            id: 2,
            text: "replacement text".to_owned(),
            style: TextStyle {
                size: -1.0,
                ..TextStyle::default()
            },
        },
    ] {
        let mut tree = tree();
        tree.apply(vec![Change::Create {
            id: 2,
            content: ContentSpec::Text {
                text: "original text".to_owned(),
                style: TextStyle::default(),
            },
            style: Box::default(),
        }])
        .expect("a text node");
        let fonts = tree.fonts.clone();
        let _borrow = fonts.borrow();
        assert_eq!(
            tree.apply(vec![fixed(3, 0.01, 0.01), text_change]),
            Err(ApplyError::TextStyle {
                index: 1,
                error: TextStyleError::Size(-1.0)
            })
        );
        assert!(!tree.contains(3), "the earlier create was not applied");
        assert!(!tree.contains(4), "the invalid text create was not applied");
    }
}

#[test]
fn batches_without_text_do_not_borrow_fonts() {
    let mut tree = tree();
    let fonts = tree.fonts.clone();
    let _borrow = fonts.borrow_mut();
    tree.apply(vec![]).expect("an empty batch needs no fonts");
    tree.apply(vec![
        Change::Create {
            id: 1,
            content: ContentSpec::Box,
            style: column(),
        },
        fixed(2, 0.01, 0.01),
        Change::SetChildren {
            id: 1,
            children: vec![2],
        },
        Change::SetStyle {
            id: 1,
            style: row(0.0),
        },
        Change::Remove { id: 2 },
    ])
    .expect("box changes need no fonts");
    assert_eq!(tree.len(), 1);
    assert!(tree.nodes[&1].children.is_empty());
}

#[test]
fn prepared_text_changes_keep_batch_order_and_invalidate_measurements() {
    let mut tree = tree();
    let style = TextStyle::default();
    tree.apply(vec![Change::Create {
        id: 1,
        content: ContentSpec::Text {
            text: "x".to_owned(),
            style: style.clone(),
        },
        style: Box::default(),
    }])
    .expect("a text node");
    let before = tree.compute(1, None, None, &NoScripts).expect("a root");
    tree.apply(vec![
        Change::SetText {
            id: 1,
            text: "xx".to_owned(),
            style: style.clone(),
        },
        Change::SetText {
            id: 1,
            text: "xxxx".to_owned(),
            style: style.clone(),
        },
    ])
    .expect("text changes apply in order");
    let after = tree.compute(1, None, None, &NoScripts).expect("a root");
    assert!(placement(&after, 1).width > placement(&before, 1).width);
    tree.apply(vec![Change::SetText {
        id: 1,
        text: "xxxx".to_owned(),
        style,
    }])
    .expect("an unchanged text update remains valid");
    assert!(
        tree.compute(1, None, None, &NoScripts)
            .expect("a root")
            .changed
            .is_empty()
    );
}

#[test]
fn invalid_batches_are_named() {
    let mut tree = tree();
    tree.apply(vec![
        Change::Create {
            id: 1,
            content: ContentSpec::Box,
            style: column(),
        },
        Change::Create {
            id: 2,
            content: ContentSpec::Box,
            style: column(),
        },
        fixed(3, 0.01, 0.01),
        Change::SetChildren {
            id: 1,
            children: vec![2],
        },
        Change::SetChildren {
            id: 2,
            children: vec![3],
        },
    ])
    .expect("a valid batch");
    let cases = vec![
        (
            vec![fixed(1, 0.0, 0.0)],
            ApplyError::Duplicate { index: 0, id: 1 },
        ),
        (
            vec![Change::SetChildren {
                id: 2,
                children: vec![1],
            }],
            ApplyError::Cycle { index: 0, id: 1 },
        ),
        (
            vec![Change::SetChildren {
                id: 1,
                children: vec![3],
            }],
            ApplyError::Reparent { index: 0, id: 3 },
        ),
        (
            vec![Change::SetChildren {
                id: 2,
                children: vec![3, 3],
            }],
            ApplyError::Reparent { index: 0, id: 3 },
        ),
        (
            vec![Change::SetText {
                id: 3,
                text: "x".to_owned(),
                style: Default::default(),
            }],
            ApplyError::NotText { index: 0, id: 3 },
        ),
        (
            vec![fixed(4, f32::NAN, 0.0)],
            ApplyError::Descriptor { index: 0, id: 4 },
        ),
        (
            vec![Change::Remove { id: 5 }],
            ApplyError::Unknown { index: 0, id: 5 },
        ),
    ];
    for (batch, expected) in cases {
        assert_eq!(tree.apply(batch), Err(expected.clone()), "{expected}");
    }
}

#[test]
fn moving_a_child_between_parents_in_one_batch_is_allowed() {
    let mut tree = tree();
    tree.apply(vec![
        Change::Create {
            id: 1,
            content: ContentSpec::Box,
            style: column(),
        },
        Change::Create {
            id: 2,
            content: ContentSpec::Box,
            style: column(),
        },
        fixed(3, 0.01, 0.01),
        Change::SetChildren {
            id: 1,
            children: vec![3],
        },
    ])
    .expect("a valid batch");
    tree.apply(vec![
        Change::SetChildren {
            id: 1,
            children: vec![],
        },
        Change::SetChildren {
            id: 2,
            children: vec![3],
        },
    ])
    .expect("moving after releasing is allowed");
    assert_eq!(
        tree.compute(1, None, None, &NoScripts),
        Ok(Outcome {
            changed: vec![placement_of_empty_root()],
            failures: vec![]
        })
    );
}

fn placement_of_empty_root() -> Placement {
    Placement {
        id: 1,
        u: 0.0,
        v: 0.0,
        width: 0.0,
        height: 0.0,
        transform: Transform::default(),
    }
}

#[test]
fn compute_refuses_a_node_that_is_not_a_root() {
    let mut tree = tree();
    tree.apply(vec![
        Change::Create {
            id: 1,
            content: ContentSpec::Box,
            style: column(),
        },
        fixed(2, 0.01, 0.01),
        Change::SetChildren {
            id: 1,
            children: vec![2],
        },
    ])
    .expect("a valid batch");
    assert_eq!(
        tree.compute(2, None, None, &NoScripts),
        Err(ComputeError::NotRoot(2))
    );
    assert_eq!(
        tree.compute(7, None, None, &NoScripts),
        Err(ComputeError::Unknown(7))
    );
}

/// A radial layout: children in a ring, the container sized from its largest child.
struct Radial {
    radius: f32,
    calls: RefCell<Vec<bool>>,
}

impl Scripts for Radial {
    fn measure(&self, _node: NodeId, _input: &Input) -> Result<Size, ScriptError> {
        Ok(Size {
            width: 0.005,
            height: 0.005,
        })
    }

    fn layout(
        &self,
        _node: NodeId,
        input: &Input,
        context: &mut dyn ScriptContext,
    ) -> Result<Size, ScriptError> {
        self.calls.borrow_mut().push(input.perform);
        let children = context.children();
        let mut largest: f32 = 0.0;
        for child in &children {
            let size = context.measure(*child, (Available::MaxContent, Available::MaxContent))?;
            largest = largest.max(size.width).max(size.height);
        }
        let size = 2.0 * (self.radius + largest);
        if input.perform {
            for (index, child) in children.iter().enumerate() {
                #[expect(clippy::cast_precision_loss, reason = "A handful of children.")]
                let angle = index as f32 / children.len() as f32 * std::f32::consts::TAU;
                context.place(
                    *child,
                    size / 2.0 + self.radius * angle.cos(),
                    size / 2.0 + self.radius * angle.sin(),
                    None,
                    Transform {
                        rotation: angle,
                        scale: 1.0,
                    },
                )?;
            }
        }
        Ok(Size {
            width: size,
            height: size,
        })
    }
}

#[test]
fn a_scripted_container_sizes_itself_from_its_children() {
    let mut tree = tree();
    tree.apply(vec![
        Change::Create {
            id: 1,
            content: ContentSpec::Box,
            style: row(0.0),
        },
        Change::Create {
            id: 2,
            content: ContentSpec::Scripted,
            style: Box::default(),
        },
        fixed(3, 0.01, 0.01),
        fixed(4, 0.02, 0.01),
        Change::Create {
            id: 5,
            content: ContentSpec::Measured,
            style: Box::default(),
        },
        Change::SetChildren {
            id: 2,
            children: vec![3, 4, 5],
        },
        Change::SetChildren {
            id: 1,
            children: vec![2],
        },
    ])
    .expect("a valid batch");
    let scripts = Radial {
        radius: 0.05,
        calls: RefCell::new(Vec::new()),
    };
    let outcome = tree.compute(1, None, None, &scripts).expect("a root");
    assert_eq!(outcome.failures, vec![]);
    let ring = placement(&outcome, 2);
    assert!(
        close(ring.width, 2.0 * (0.05 + 0.02)),
        "sized from the largest child: {ring:?}"
    );
    let root = placement(&outcome, 1);
    assert!(
        close(root.width, ring.width),
        "the row sees the ring's intrinsic size: {root:?}"
    );
    let second = placement(&outcome, 4);
    assert!(
        close(second.transform.rotation, std::f32::consts::TAU / 3.0),
        "{second:?}"
    );
    let measured = placement(&outcome, 5);
    assert!(
        close(measured.width, 0.005),
        "a measured leaf: {measured:?}"
    );
    assert!(scripts.calls.borrow().contains(&true), "the final pass ran");
    assert!(scripts.calls.borrow().contains(&false), "sizing passes ran");
}

struct Failing;

impl Scripts for Failing {
    fn measure(&self, node: NodeId, _input: &Input) -> Result<Size, ScriptError> {
        if node == 3 {
            Ok(Size {
                width: f32::NAN,
                height: 0.0,
            })
        } else {
            Err(ScriptError("the measurement raised".to_owned()))
        }
    }

    fn layout(
        &self,
        _node: NodeId,
        input: &Input,
        context: &mut dyn ScriptContext,
    ) -> Result<Size, ScriptError> {
        if !input.perform {
            // Placing outside the final pass is refused.
            let refused = context.place(4, 0.0, 0.0, None, Transform::default());
            assert!(refused.is_err());
        }
        context.measure(99, (Available::MaxContent, Available::MaxContent))?;
        Ok(Size::default())
    }
}

#[test]
fn failing_callbacks_are_reported_and_layout_completes() {
    let mut tree = tree();
    tree.apply(vec![
        Change::Create {
            id: 1,
            content: ContentSpec::Box,
            style: row(0.0),
        },
        Change::Create {
            id: 2,
            content: ContentSpec::Measured,
            style: Box::default(),
        },
        Change::Create {
            id: 3,
            content: ContentSpec::Measured,
            style: Box::default(),
        },
        Change::Create {
            id: 5,
            content: ContentSpec::Scripted,
            style: Box::default(),
        },
        fixed(4, 0.01, 0.01),
        fixed(6, 0.01, 0.01),
        Change::SetChildren {
            id: 5,
            children: vec![4],
        },
        Change::SetChildren {
            id: 1,
            children: vec![2, 3, 5, 6],
        },
    ])
    .expect("a valid batch");
    let outcome = tree.compute(1, None, None, &Failing).expect("a root");
    let failing: std::collections::HashSet<NodeId> =
        outcome.failures.iter().map(|failure| failure.id).collect();
    assert_eq!(failing, [2, 3, 5].into_iter().collect());
    let healthy = placement(&outcome, 6);
    assert!(
        close(healthy.width, 0.01),
        "the rest of the tree is laid out: {healthy:?}"
    );
    let unplaced = placement(&outcome, 4);
    assert!(
        close(unplaced.width, 0.0),
        "a child the layout did not place takes no space: {unplaced:?}"
    );
}

#[test]
fn removing_a_child_releases_it_from_its_parent() {
    let mut tree = tree();
    tree.apply(vec![
        Change::Create {
            id: 1,
            content: ContentSpec::Box,
            style: row(0.0),
        },
        fixed(2, 0.01, 0.01),
        fixed(3, 0.01, 0.01),
        Change::SetChildren {
            id: 1,
            children: vec![2, 3],
        },
    ])
    .expect("a valid batch");
    tree.compute(1, None, None, &NoScripts).expect("a root");
    tree.apply(vec![Change::Remove { id: 2 }])
        .expect("a valid batch");
    let outcome = tree.compute(1, None, None, &NoScripts).expect("a root");
    let moved = placement(&outcome, 3);
    assert!(
        close(moved.u, 0.0),
        "the remaining child moves up: {moved:?}"
    );
    assert!(!tree.contains(2));
}
