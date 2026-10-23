use pretty_assertions::assert_eq;

use super::*;

#[test]
fn compose_matches_recursive_preorder_for_a_nested_tree() {
    let mut actual = nested_tree();
    let mut oracle = nested_tree();
    let changed = compare_compose(&mut actual, &mut oracle, 1, (0.1234, -0.9876));
    assert_eq!(ids(&changed), vec![1, 2, 4, 7, 5, 3, 6, 8]);
}

#[test]
fn compose_matches_recursive_preorder_for_a_wide_tree() {
    let mut parents = vec![None];
    for _ in 0..128 {
        let branch = NodeId::try_from(parents.len() + 1).expect("the fixture fits in NodeId");
        parents.extend([Some(1), Some(branch), Some(branch)]);
    }
    let mut actual = compose_tree(&parents);
    let mut oracle = compose_tree(&parents);
    let changed = compare_compose(&mut actual, &mut oracle, 1, (-0.002, 0.005));
    assert_eq!(ids(&changed), (1..=385).collect::<Vec<_>>());
}

#[test]
fn compose_matches_recursive_preorder_for_a_deep_tree() {
    let parents: Vec<_> = std::iter::once(None).chain((1..512).map(Some)).collect();
    let mut actual = compose_tree(&parents);
    let mut oracle = compose_tree(&parents);
    let changed = compare_compose(&mut actual, &mut oracle, 1, (0.01, -0.02));
    assert_eq!(ids(&changed), (1..=512).collect::<Vec<_>>());
    assert!(compare_compose(&mut actual, &mut oracle, 1, (0.01, -0.02)).is_empty());
}

#[test]
fn compose_reports_a_single_node_once_and_appends_to_existing_changes() {
    let mut actual = compose_tree(&[None]);
    let mut oracle = compose_tree(&[None]);
    let changed = compare_compose(&mut actual, &mut oracle, 1, (0.25, -0.5));
    assert_eq!(ids(&changed), vec![1]);
    assert!(compare_compose(&mut actual, &mut oracle, 1, (0.25, -0.5)).is_empty());

    actual.nodes.get_mut(&1).expect("the node exists").reported = None;
    oracle.nodes.get_mut(&1).expect("the node exists").reported = None;
    let mut actual_changed = changed.clone();
    let mut oracle_changed = changed.clone();
    actual.compose(1, 0.25, -0.5, &mut actual_changed);
    recursive_compose(&mut oracle, 1, 0.25, -0.5, &mut oracle_changed);
    assert_eq!(ids(&actual_changed), vec![1, 1]);
    assert_placements_exact(&actual_changed, &oracle_changed);
    assert_reports_exact(&actual, &oracle);
}

#[test]
fn compose_matches_recursive_reports_after_every_placement_field_changes() {
    for field in 0..6 {
        let mut actual = nested_tree();
        let mut oracle = nested_tree();
        compare_compose(&mut actual, &mut oracle, 1, (0.125, -0.25));
        assert!(compare_compose(&mut actual, &mut oracle, 1, (0.125, -0.25)).is_empty());

        for tree in [&mut actual, &mut oracle] {
            let node = tree.nodes.get_mut(&2).expect("the edited node exists");
            match field {
                0 => node.layout.location.x += 0.137,
                1 => node.layout.location.y -= 0.271,
                2 => node.layout.size.width += 0.019,
                3 => node.layout.size.height += 0.023,
                4 => node.transform.rotation += 0.75,
                5 => node.transform.scale *= 1.25,
                _ => unreachable!("all placement fields are covered"),
            }
        }
        let changed = compare_compose(&mut actual, &mut oracle, 1, (0.125, -0.25));
        let expected = if field < 2 { vec![2, 4, 7, 5] } else { vec![2] };
        assert_eq!(ids(&changed), expected, "placement field {field}");
        assert!(compare_compose(&mut actual, &mut oracle, 1, (0.125, -0.25)).is_empty());
    }
}

#[test]
fn compose_preserves_exact_float_comparisons_and_stored_reports() {
    let mut actual = compose_tree(&[None]);
    let mut oracle = compose_tree(&[None]);
    for tree in [&mut actual, &mut oracle] {
        let node = tree.nodes.get_mut(&1).expect("the node exists");
        node.layout.location.x = -0.0;
        node.layout.location.y = -0.0;
        node.layout.size.width = -0.0;
        node.layout.size.height = -0.0;
        node.transform = Transform {
            rotation: -0.0,
            scale: -0.0,
        };
    }
    let first = compare_compose(&mut actual, &mut oracle, 1, (-0.0, -0.0));
    assert_eq!(placement_bits(first[0]), [(-0.0_f32).to_bits(); 6]);
    for tree in [&mut actual, &mut oracle] {
        let node = tree.nodes.get_mut(&1).expect("the node exists");
        node.layout.location.x = 0.0;
        node.layout.location.y = 0.0;
        node.layout.size.width = 0.0;
        node.layout.size.height = 0.0;
        node.transform = Transform {
            rotation: 0.0,
            scale: 0.0,
        };
    }
    assert!(compare_compose(&mut actual, &mut oracle, 1, (0.0, 0.0)).is_empty());
    let reported = actual.nodes[&1].reported.expect("the first report remains");
    assert_eq!(placement_bits(reported), placement_bits(first[0]));

    for tree in [&mut actual, &mut oracle] {
        let node = tree.nodes.get_mut(&1).expect("the node exists");
        node.layout.size.width = f32::INFINITY;
        node.layout.size.height = f32::NEG_INFINITY;
    }
    assert_eq!(
        compare_compose(&mut actual, &mut oracle, 1, (0.0, 0.0)).len(),
        1
    );
    assert!(compare_compose(&mut actual, &mut oracle, 1, (0.0, 0.0)).is_empty());

    for tree in [&mut actual, &mut oracle] {
        tree.nodes
            .get_mut(&1)
            .expect("the node exists")
            .transform
            .rotation = f32::from_bits(0x7fc0_1234);
    }
    for _ in 0..2 {
        let changed = compare_compose(&mut actual, &mut oracle, 1, (0.0, 0.0));
        assert_eq!(changed.len(), 1);
        assert_eq!(changed[0].transform.rotation.to_bits(), 0x7fc0_1234);
    }
}

#[test]
fn compose_skips_missing_nodes_without_skipping_later_siblings() {
    let mut actual = tree();
    let mut oracle = tree();
    assert!(compare_compose(&mut actual, &mut oracle, 99, (0.5, -0.5)).is_empty());

    let parents = [None, Some(1), Some(1), Some(2), Some(2), None];
    actual = compose_tree(&parents);
    oracle = compose_tree(&parents);
    for tree in [&mut actual, &mut oracle] {
        tree.nodes.remove(&4);
    }
    let changed = compare_compose(&mut actual, &mut oracle, 1, (0.5, -0.5));
    assert_eq!(ids(&changed), vec![1, 2, 5, 3]);
    assert_eq!(actual.nodes[&6].reported, None);
    assert!(compare_compose(&mut actual, &mut oracle, 99, (0.5, -0.5)).is_empty());
    assert!(compare_compose(&mut actual, &mut oracle, 1, (0.5, -0.5)).is_empty());
}

fn nested_tree() -> Tree {
    compose_tree(&[
        None,
        Some(1),
        Some(1),
        Some(2),
        Some(2),
        Some(3),
        Some(4),
        Some(3),
    ])
}

fn compose_tree(parents: &[Option<NodeId>]) -> Tree {
    let mut tree = tree();
    for (index, &parent) in parents.iter().enumerate() {
        let id = NodeId::try_from(index + 1).expect("the fixture fits in NodeId");
        let mut node = Node::new(Content::Box, Style::default());
        node.parent = parent;
        node.layout.location.x = (id % 7) as f32 * 0.1 - 0.3;
        node.layout.location.y = (id % 5) as f32 * -0.03 + 0.01;
        node.layout.size.width = id as f32 * 0.001 + 0.002;
        node.layout.size.height = id as f32 * 0.003 + 0.004;
        node.transform = Transform {
            rotation: id as f32 * -0.125,
            scale: id as f32 * 0.0625 + 0.5,
        };
        tree.nodes.insert(id, node);
        if let Some(parent) = parent {
            tree.nodes
                .get_mut(&parent)
                .expect("the parent precedes its child")
                .children
                .push(id);
        }
    }
    tree
}

fn compare_compose(
    actual: &mut Tree,
    oracle: &mut Tree,
    root: NodeId,
    origin: (f32, f32),
) -> Vec<Placement> {
    let mut actual_changed = Vec::new();
    let mut oracle_changed = Vec::new();
    actual.compose(root, origin.0, origin.1, &mut actual_changed);
    recursive_compose(oracle, root, origin.0, origin.1, &mut oracle_changed);
    assert_placements_exact(&actual_changed, &oracle_changed);
    assert_reports_exact(actual, oracle);
    actual_changed
}

fn ids(placements: &[Placement]) -> Vec<NodeId> {
    placements.iter().map(|placement| placement.id).collect()
}

fn assert_placements_exact(actual: &[Placement], expected: &[Placement]) {
    assert_eq!(ids(actual), ids(expected));
    for (&actual, &expected) in actual.iter().zip(expected) {
        assert_eq!(
            placement_bits(actual),
            placement_bits(expected),
            "node {}",
            actual.id
        );
    }
}

fn assert_reports_exact(actual: &Tree, oracle: &Tree) {
    assert_eq!(actual.nodes.len(), oracle.nodes.len());
    for (&id, node) in &actual.nodes {
        let expected = oracle.nodes[&id].reported;
        assert_eq!(
            node.reported.map(|p| p.id),
            expected.map(|p| p.id),
            "node {id}"
        );
        assert_eq!(
            node.reported.map(placement_bits),
            expected.map(placement_bits),
            "node {id}"
        );
    }
}

fn placement_bits(placement: Placement) -> [u32; 6] {
    [
        placement.u.to_bits(),
        placement.v.to_bits(),
        placement.width.to_bits(),
        placement.height.to_bits(),
        placement.transform.rotation.to_bits(),
        placement.transform.scale.to_bits(),
    ]
}

// The recursive implementation is an independent oracle for traversal and reporting.
fn recursive_compose(tree: &mut Tree, id: NodeId, u: f32, v: f32, changed: &mut Vec<Placement>) {
    let Some(node) = tree.nodes.get_mut(&id) else {
        return;
    };
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
