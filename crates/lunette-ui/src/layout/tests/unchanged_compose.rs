//! Compares public computations with an independently composed tree after each operation.

mod mutations;

use std::cell::Cell;

use pretty_assertions::assert_eq;
use taffy::{LayoutPartialTree, NodeId as TaffyId};

use super::*;

#[test]
fn cached_computations_match_for_empty_single_deep_wide_and_branching_trees() {
    for shape in 0..3 {
        // Native layout recurses on a debug test thread; composition has a deeper separate test.
        let counts: &[NodeId] = if shape == 0 {
            &[0, 1, 2, 9, 17]
        } else {
            &[0, 1, 2, 9, 65, 129]
        };
        for &count in counts {
            for display in [Display::Flex, Display::Grid, Display::Block, Display::None] {
                let mut pair = Pair::new();
                pair.apply(|| shape_changes(count, shape, display));
                for _ in 0..3 {
                    pair.compute(1, None, None);
                }
                if count > 0 {
                    for dimensions in [(Some(0.0), None), (Some(2.0), Some(3.0)), (None, None)] {
                        pair.compute(1, dimensions.0, dimensions.1);
                        pair.compute(1, dimensions.0, dimensions.1);
                    }
                }
            }
        }
    }
}

#[test]
fn all_six_scripted_placement_fields_and_same_value_writes_match() {
    for field in 0..6 {
        let mut pair = Pair::new();
        pair.apply(script_changes);
        pair.compute(1, None, None);
        assert!(pair.compute(1, None, None).changed.is_empty());
        let mut values = pair.actual_scripts.values.get();
        values[field] += 0.375;
        pair.values(values);
        pair.clear_caches(1);
        let changed = pair.compute(1, None, None).changed;
        assert!(changed.iter().any(|p| p.id == 2), "field {field}");
        if field < 2 {
            assert!(
                changed.iter().any(|p| p.id == 3),
                "descendant of field {field}"
            );
        }
        for _ in 0..3 {
            pair.clear_caches(1);
            assert!(pair.compute(1, None, None).changed.is_empty());
        }
    }
}

#[test]
fn native_layout_setter_compares_each_geometry_field_and_preserves_reported_zero_bits() {
    for field in 0..4 {
        let mut pair = Pair::new();
        pair.apply(|| shape_changes(3, 0, Display::Flex));
        pair.compute(1, None, None);
        pair.layout(2, |layout| match field {
            0 => layout.location.x += 0.25,
            1 => layout.location.y -= 0.5,
            2 => layout.size.width += 0.75,
            3 => layout.size.height += 1.0,
            _ => unreachable!(),
        });
        assert!(
            pair.compute(1, None, None)
                .changed
                .iter()
                .any(|p| p.id == 2)
        );
        pair.layout(2, |_| {});
        assert!(pair.compute(1, None, None).changed.is_empty());
    }
    let mut pair = Pair::new();
    pair.apply(script_changes);
    pair.values([0.0, 0.0, 0.0, 0.0, -0.0, -0.0]);
    pair.compute(1, None, None);
    let before = pair.actual.nodes[&2].reported.map(bits);
    pair.values([-0.0, -0.0, -0.0, -0.0, 0.0, 0.0]);
    pair.clear_caches(1);
    assert!(pair.compute(1, None, None).changed.is_empty());
    assert_eq!(pair.actual.nodes[&2].reported.map(bits), before);
}

#[test]
fn cached_nan_fields_keep_reporting_without_another_child_write() {
    for field in 0..6 {
        let mut pair = Pair::new();
        pair.apply(|| shape_changes(3, 0, Display::Flex));
        let nan = f32::from_bits(0x7fc0_1234);
        if field >= 4 {
            for tree in [&mut pair.actual, &mut pair.oracle] {
                let transform = &mut tree.nodes.get_mut(&2).expect("child exists").transform;
                if field == 4 {
                    transform.rotation = nan;
                } else {
                    transform.scale = nan;
                }
            }
        }
        pair.compute(1, None, None);
        if field < 4 {
            pair.layout(2, |layout| match field {
                0 => layout.location.x = nan,
                1 => layout.location.y = nan,
                2 => layout.size.width = nan,
                3 => layout.size.height = nan,
                _ => unreachable!(),
            });
        }
        for _ in 0..4 {
            let layout = pair.actual.nodes[&2].layout;
            assert!(
                pair.compute(1, None, None)
                    .changed
                    .iter()
                    .any(|p| p.id == 2),
                "NaN field {field}"
            );
            let after = pair.actual.nodes[&2].layout;
            assert_eq!(layout_bits(layout), layout_bits(after), "no child write");
        }
    }
}

#[test]
fn nan_created_only_by_composing_infinite_ancestors_keeps_reporting() {
    let mut pair = Pair::new();
    pair.apply(|| shape_changes(3, 0, Display::Flex));
    pair.compute(1, None, None);
    pair.layout(2, |layout| layout.location.x = f32::INFINITY);
    pair.layout(3, |layout| layout.location.x = f32::NEG_INFINITY);
    for _ in 0..4 {
        let outcome = pair.compute(1, None, None);
        assert!(placement(&outcome, 3).u.is_nan());
    }
}

struct Pair {
    actual: Tree,
    oracle: Tree,
    actual_scripts: Callbacks,
    oracle_scripts: Callbacks,
}

impl Pair {
    fn new() -> Self {
        let actual = tree();
        let oracle = Tree::new(Rc::clone(&actual.fonts));
        Self {
            actual,
            oracle,
            actual_scripts: Callbacks::default(),
            oracle_scripts: Callbacks::default(),
        }
    }

    fn apply(&mut self, changes: impl Fn() -> Vec<Change>) {
        assert_eq!(self.actual.apply(changes()), self.oracle.apply(changes()));
        assert_reports(&self.actual, &self.oracle);
    }

    fn compute(&mut self, root: NodeId, width: Option<f32>, height: Option<f32>) -> Outcome {
        let actual = self
            .actual
            .compute(root, width, height, &self.actual_scripts);
        let expected = always_compose(&mut self.oracle, root, width, height, &self.oracle_scripts);
        let outcome = match (actual, expected) {
            (Ok(actual), Ok(expected)) => {
                assert_placements(&actual.changed, &expected.changed);
                assert_eq!(actual.failures, expected.failures);
                actual
            }
            (Err(actual), Err(expected)) => {
                assert_eq!(actual, expected);
                Outcome::default()
            }
            (actual, expected) => panic!("compute results differ: {actual:?} != {expected:?}"),
        };
        assert_eq!(
            *self.actual_scripts.calls.borrow(),
            *self.oracle_scripts.calls.borrow()
        );
        assert_reports(&self.actual, &self.oracle);
        self.text_lines();
        outcome
    }

    fn text_lines(&mut self) {
        let ids: Vec<_> = self.actual.nodes.keys().copied().collect();
        for id in ids {
            assert_eq!(
                self.actual.text_lines(id),
                self.oracle.text_lines(id),
                "text node {id}"
            );
        }
    }

    fn clear_caches(&mut self, id: NodeId) {
        self.actual.mark_dirty(id);
        self.oracle.mark_dirty(id);
    }

    fn values(&self, values: [f32; 6]) {
        self.actual_scripts.values.set(values);
        self.oracle_scripts.values.set(values);
    }

    fn mode(&self, mode: Mode) {
        self.actual_scripts.mode.set(mode);
        self.oracle_scripts.mode.set(mode);
    }

    fn layout(&mut self, id: NodeId, edit: impl Fn(&mut taffy::Layout)) {
        for tree in [&mut self.actual, &mut self.oracle] {
            let mut layout = tree.nodes[&id].layout;
            edit(&mut layout);
            compute::Computation {
                tree,
                scripts: &NoScripts,
                failures: Vec::new(),
            }
            .set_unrounded_layout(TaffyId::from(u64::from(id)), &layout);
        }
    }
}

// Native computation and recursive composition stay independent of Tree::compute's guard.
fn always_compose(
    tree: &mut Tree,
    root: NodeId,
    width: Option<f32>,
    height: Option<f32>,
    scripts: &dyn Scripts,
) -> Result<Outcome, ComputeError> {
    let node = tree.nodes.get(&root).ok_or(ComputeError::Unknown(root))?;
    if node.parent.is_some() {
        return Err(ComputeError::NotRoot(root));
    }
    let mut computation = compute::Computation {
        tree,
        scripts,
        failures: Vec::new(),
    };
    computation.run(root, width, height);
    let failures = computation.failures;
    let mut changed = Vec::new();
    recursive_compose(tree, root, 0.0, 0.0, &mut changed);
    Ok(Outcome { changed, failures })
}

fn recursive_compose(tree: &mut Tree, id: NodeId, u: f32, v: f32, changed: &mut Vec<Placement>) {
    let node = tree
        .nodes
        .get_mut(&id)
        .expect("public batches preserve children");
    let placement = Placement {
        id,
        u: u + node.layout.location.x,
        v: v + node.layout.location.y,
        width: node.layout.size.width,
        height: node.layout.size.height,
        transform: node.transform,
    };
    if node.reported != Some(placement) {
        node.reported = Some(placement);
        changed.push(placement);
    }
    let children = node.children.clone();
    for child in children {
        recursive_compose(tree, child, placement.u, placement.v, changed);
    }
}

fn assert_placements(actual: &[Placement], expected: &[Placement]) {
    assert_eq!(ids(actual), ids(expected));
    for (&actual, &expected) in actual.iter().zip(expected) {
        assert_eq!(bits(actual), bits(expected), "node {}", actual.id);
    }
}

fn assert_reports(actual: &Tree, expected: &Tree) {
    assert_eq!(actual.nodes.len(), expected.nodes.len());
    for (&id, node) in &actual.nodes {
        assert_eq!(
            node.reported.map(|p| (p.id, bits(p))),
            expected.nodes[&id].reported.map(|p| (p.id, bits(p))),
            "report {id}"
        );
    }
}

fn ids(placements: &[Placement]) -> Vec<NodeId> {
    placements.iter().map(|p| p.id).collect()
}
fn bits(p: Placement) -> [u32; 6] {
    [
        p.u.to_bits(),
        p.v.to_bits(),
        p.width.to_bits(),
        p.height.to_bits(),
        p.transform.rotation.to_bits(),
        p.transform.scale.to_bits(),
    ]
}
fn layout_bits(layout: taffy::Layout) -> [u32; 4] {
    [
        layout.location.x.to_bits(),
        layout.location.y.to_bits(),
        layout.size.width.to_bits(),
        layout.size.height.to_bits(),
    ]
}

fn shape_changes(count: NodeId, shape: NodeId, display: Display) -> Vec<Change> {
    let mut changes = Vec::new();
    for id in 1..=count {
        changes.push(Change::Create {
            id,
            content: ContentSpec::Box,
            style: Box::new(Style {
                display,
                ..*row(0.03125)
            }),
        });
    }
    for id in 1..=count {
        let children = (2..=count)
            .filter(|child| match shape {
                0 => child - 1 == id,
                1 => id == 1,
                _ => child / 2 == id,
            })
            .collect();
        changes.push(Change::SetChildren { id, children });
    }
    changes
}

fn script_changes() -> Vec<Change> {
    vec![
        Change::Create {
            id: 1,
            content: ContentSpec::Scripted,
            style: Box::default(),
        },
        Change::Create {
            id: 2,
            content: ContentSpec::Box,
            style: Box::default(),
        },
        fixed(3, 0.125, 0.25),
        Change::SetChildren {
            id: 1,
            children: vec![2],
        },
        Change::SetChildren {
            id: 2,
            children: vec![3],
        },
    ]
}

#[derive(Clone, Copy, Debug, Default)]
enum Mode {
    #[default]
    Good,
    Fail,
    Partial,
    Invalid,
    Omit,
}

struct Callbacks {
    values: Cell<[f32; 6]>,
    mode: Cell<Mode>,
    calls: RefCell<Vec<(NodeId, bool, bool)>>,
}

impl Default for Callbacks {
    fn default() -> Self {
        Self {
            values: Cell::new([0.25, -0.5, 1.0, 2.0, 0.125, 1.0]),
            mode: Cell::new(Mode::Good),
            calls: RefCell::default(),
        }
    }
}

impl Callbacks {
    fn record(&self, id: NodeId, perform: bool, layout: bool) -> ScriptError {
        self.calls.borrow_mut().push((id, perform, layout));
        ScriptError(format!("callback {}", self.calls.borrow().len()))
    }
}

impl Scripts for Callbacks {
    fn measure(&self, id: NodeId, input: &Input) -> Result<Size, ScriptError> {
        let error = self.record(id, input.perform, false);
        if matches!(self.mode.get(), Mode::Fail) {
            return Err(error);
        }
        Ok(Size {
            width: 1.0,
            height: 2.0,
        })
    }

    fn layout(
        &self,
        id: NodeId,
        input: &Input,
        context: &mut dyn ScriptContext,
    ) -> Result<Size, ScriptError> {
        let error = self.record(id, input.perform, true);
        let mode = self.mode.get();
        if matches!(mode, Mode::Fail) {
            return Err(error);
        }
        if input.perform && !matches!(mode, Mode::Omit) {
            let [u, v, width, height, rotation, scale] = self.values.get();
            for child in context.children() {
                context.place(
                    child,
                    u,
                    v,
                    Some(Size { width, height }),
                    Transform { rotation, scale },
                )?;
                if matches!(mode, Mode::Partial) {
                    return Err(error);
                }
                if matches!(mode, Mode::Invalid) {
                    context.place(child, f32::NAN, v, None, Transform::default())?;
                }
            }
        }
        Ok(Size {
            width: 4.0,
            height: 5.0,
        })
    }
}
