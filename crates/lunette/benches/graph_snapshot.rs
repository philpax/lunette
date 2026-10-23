//! Measures detached graph snapshots across a small set of graph shapes.

use std::{error::Error, hint::black_box, io, mem::MaybeUninit, time::Instant};

use clap::Parser;
use lunette::plugin::graph::{
    Action, ActivationId, ContractKey, Graph, InstanceId, Intent, LifecycleState, LoadOutcome,
    LoadResolution, ProviderGeneration,
};
use serde_json::{Value, json};

#[derive(Debug, Parser)]
#[command(about = "Measure graph snapshot cost across deterministic graph shapes")]
struct Arguments {
    /// Use one snapshot iteration per case and skip warmup.
    #[arg(long)]
    smoke: bool,
    /// Override the iteration count for every case.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    iterations: Option<u64>,
    /// Override the fixed warmup count for every case.
    #[arg(long, default_value_t = 20)]
    warmup: u64,
    #[arg(long, hide = true)]
    bench: bool,
}

#[derive(Clone, Copy, Debug)]
enum Shape {
    NoEdges,
    Sparse,
    RepeatedBindings,
}

impl Shape {
    const ALL: [Self; 3] = [Self::NoEdges, Self::Sparse, Self::RepeatedBindings];

    const fn name(self) -> &'static str {
        match self {
            Self::NoEdges => "no-edges",
            Self::Sparse => "sparse",
            Self::RepeatedBindings => "repeated-bindings",
        }
    }
}

struct ExpectedNode {
    id: InstanceId,
    parent: Option<InstanceId>,
    state: LifecycleState,
    enabled: bool,
    activation: Option<ActivationId>,
    generation: Option<ProviderGeneration>,
    bindings: Vec<(ContractKey, InstanceId, ProviderGeneration)>,
    children: Vec<InstanceId>,
    dependents: Vec<InstanceId>,
}

struct Counts {
    bindings: usize,
    children: usize,
    dependents: usize,
}

fn main() -> Result<(), Box<dyn Error>> {
    let arguments = Arguments::parse();
    let mut records = Vec::new();
    let sizes = [1, 8, 48, 192, 768];

    for shape in Shape::ALL {
        if matches!(shape, Shape::NoEdges) {
            records.push(measure_case(shape, 0, &arguments)?);
        }
        for size in sizes {
            records.push(measure_case(shape, size, &arguments)?);
        }
    }

    let output = json!({
        "schema": 1,
        "debug_assertions": cfg!(debug_assertions),
        "records": records,
    });
    println!("{}", serde_json::to_string(&output)?);
    Ok(())
}

fn measure_case(shape: Shape, size: usize, arguments: &Arguments) -> Result<Value, Box<dyn Error>> {
    let iterations = if arguments.smoke {
        1
    } else {
        arguments
            .iterations
            .unwrap_or_else(|| default_iterations(size))
    };
    let warmup = if arguments.smoke { 0 } else { arguments.warmup };
    let (graph, expected) = build_graph(shape, size)?;
    validate_snapshot(shape, &graph, &expected)?;

    for _ in 0..warmup {
        drop(black_box(black_box(&graph).snapshot()));
    }

    let cpu_start = thread_cpu_nanoseconds()?;
    let elapsed_start = Instant::now();
    for _ in 0..iterations {
        drop(black_box(black_box(&graph).snapshot()));
    }
    let elapsed_ns = elapsed_start.elapsed().as_nanos();
    let thread_cpu_ns = thread_cpu_nanoseconds()?
        .checked_sub(cpu_start)
        .ok_or_else(|| io::Error::other("graph snapshot benchmark: thread CPU clock regressed"))?;

    let snapshot = graph.snapshot();
    let counts = validate_snapshot_data(shape, &snapshot, &expected)?;
    let checksum = semantic_checksum(&snapshot);

    Ok(json!({
        "schema": 1,
        "debug_assertions": cfg!(debug_assertions),
        "shape": shape.name(),
        "size": size,
        "iterations": iterations,
        "warmup": warmup,
        "elapsed_ns": elapsed_ns,
        "ns_per_snapshot": elapsed_ns as f64 / iterations as f64,
        "thread_cpu_ns": thread_cpu_ns,
        "thread_cpu_ns_per_snapshot": thread_cpu_ns as f64 / iterations as f64,
        "binding_outputs": counts.bindings,
        "child_outputs": counts.children,
        "dependent_outputs": counts.dependents,
        "semantic_checksum": checksum,
    }))
}

fn default_iterations(size: usize) -> u64 {
    match size {
        0 | 1 | 8 => 1_000_000,
        48 => 20_000,
        192 => 2_000,
        768 => 500,
        _ => 1,
    }
}

fn build_graph(shape: Shape, size: usize) -> Result<(Graph, Vec<ExpectedNode>), Box<dyn Error>> {
    let mut graph = Graph::new();
    let mut expected = Vec::with_capacity(size);

    match shape {
        Shape::NoEdges => {
            for _ in 0..size {
                let id = graph.install(Vec::new(), Vec::new(), None)?;
                expected.push(ExpectedNode {
                    id,
                    parent: None,
                    state: LifecycleState::Inactive,
                    enabled: false,
                    activation: None,
                    generation: None,
                    bindings: Vec::new(),
                    children: Vec::new(),
                    dependents: Vec::new(),
                });
            }
        }
        Shape::Sparse => {
            if size == 0 {
                return Ok((graph, expected));
            }
            for index in 0..size {
                let parent_index = (index > 0).then(|| (index - 1) / 2);
                let parent = parent_index.map(|parent_index| expected[parent_index].id);
                let required = parent_index
                    .map(|parent_index| vec![edge_contract(parent_index)])
                    .unwrap_or_default();
                let provided = if index * 2 + 1 < size {
                    vec![edge_contract(index)]
                } else {
                    Vec::new()
                };
                let bindings = match (parent, parent_index) {
                    (Some(parent), Some(parent_index)) => {
                        let Some(generation) = expected[parent_index].generation else {
                            return Err(io::Error::other(
                                "graph snapshot benchmark: sparse parent has no published generation",
                            )
                            .into());
                        };
                        required
                            .iter()
                            .cloned()
                            .map(|contract| (contract, parent, generation))
                            .collect()
                    }
                    (None, None) => Vec::new(),
                    _ => {
                        return Err(io::Error::other(
                            "graph snapshot benchmark: sparse parent index is inconsistent",
                        )
                        .into());
                    }
                };
                let id = graph.install(required, provided, parent)?;
                expected.push(ExpectedNode {
                    id,
                    parent,
                    state: LifecycleState::Active,
                    enabled: true,
                    activation: None,
                    generation: None,
                    bindings,
                    children: Vec::new(),
                    dependents: Vec::new(),
                });
                if let Some(parent_index) = parent_index {
                    expected[parent_index].children.push(id);
                    expected[parent_index].dependents.push(id);
                }
                graph.request(Intent::Enable(id))?;
                publish_pending_loads(&mut graph, &mut expected)?;
            }
        }
        Shape::RepeatedBindings => {
            if size == 0 {
                return Ok((graph, expected));
            }
            let first = ContractKey::new("repeated.first", 1);
            let second = ContractKey::new("repeated.second", 1);
            let root = graph.install(Vec::new(), vec![first.clone(), second.clone()], None)?;
            expected.push(ExpectedNode {
                id: root,
                parent: None,
                state: LifecycleState::Active,
                enabled: true,
                activation: None,
                generation: None,
                bindings: Vec::new(),
                children: Vec::new(),
                dependents: Vec::new(),
            });
            graph.request(Intent::Enable(root))?;
            publish_pending_loads(&mut graph, &mut expected)?;
            let Some(root_generation) = expected[0].generation else {
                return Err(io::Error::other(
                    "graph snapshot benchmark: repeated-bindings root has no published generation",
                )
                .into());
            };
            for _ in 1..size {
                let id =
                    graph.install(vec![first.clone(), second.clone()], Vec::new(), Some(root))?;
                expected.push(ExpectedNode {
                    id,
                    parent: Some(root),
                    state: LifecycleState::Active,
                    enabled: true,
                    activation: None,
                    generation: None,
                    bindings: vec![
                        (first.clone(), root, root_generation),
                        (second.clone(), root, root_generation),
                    ],
                    children: Vec::new(),
                    dependents: Vec::new(),
                });
                expected[0].children.push(id);
                expected[0].dependents.push(id);
                graph.request(Intent::Enable(id))?;
                publish_pending_loads(&mut graph, &mut expected)?;
            }
        }
    }

    Ok((graph, expected))
}

fn edge_contract(parent_index: usize) -> ContractKey {
    ContractKey::new(format!("sparse.edge.{parent_index}"), 1)
}

fn publish_pending_loads(
    graph: &mut Graph,
    expected: &mut [ExpectedNode],
) -> Result<(), Box<dyn Error>> {
    while let Some(action) = graph.next_action() {
        match action {
            Action::BeginLoad {
                instance,
                activation,
            } => {
                let LoadResolution::Published(generation) =
                    graph.complete_load(instance, activation, LoadOutcome::Success)?
                else {
                    return Err(io::Error::other(format!(
                        "graph snapshot benchmark: load for {instance} was not published"
                    ))
                    .into());
                };
                let Some(node) = expected.iter_mut().find(|node| node.id == instance) else {
                    return Err(io::Error::other(format!(
                        "graph snapshot benchmark: published unknown instance {instance}"
                    ))
                    .into());
                };
                node.activation = Some(activation);
                node.generation = Some(generation);
            }
            Action::BeginUnload { instance, .. } => {
                return Err(io::Error::other(format!(
                    "graph snapshot benchmark: unexpected unload for {instance} during setup"
                ))
                .into());
            }
        }
    }
    Ok(())
}

fn validate_snapshot(
    shape: Shape,
    graph: &Graph,
    expected: &[ExpectedNode],
) -> Result<(), Box<dyn Error>> {
    let snapshot = graph.snapshot();
    validate_snapshot_data(shape, &snapshot, expected)?;
    Ok(())
}

fn validate_snapshot_data(
    shape: Shape,
    snapshot: &lunette::plugin::graph::GraphSnapshot,
    expected: &[ExpectedNode],
) -> Result<Counts, Box<dyn Error>> {
    if snapshot.instances.len() != expected.len() {
        return Err(io::Error::other(format!(
            "graph snapshot benchmark: {} snapshot has {} nodes, expected {}",
            shape.name(),
            snapshot.instances.len(),
            expected.len()
        ))
        .into());
    }

    let mut counts = Counts {
        bindings: 0,
        children: 0,
        dependents: 0,
    };
    for (instance, expected) in snapshot.instances.iter().zip(expected) {
        if instance.id != expected.id
            || instance.parent != expected.parent
            || instance.state != expected.state
            || instance.activation != expected.activation
            || instance.generation != expected.generation
            || instance.intent.enabled != expected.enabled
            || instance.intent.retired
            || instance.replacement_requested
            || instance.cleanup_failed
            || !instance.failed_bindings.is_empty()
            || instance.children != expected.children
            || instance.dependents != expected.dependents
            || instance.bindings.len() != expected.bindings.len()
        {
            return Err(io::Error::other(format!(
                "graph snapshot benchmark: {} node {} does not match its expected shape",
                shape.name(),
                expected.id
            ))
            .into());
        }
        match expected.state {
            LifecycleState::Inactive
                if expected.activation.is_none() && expected.generation.is_none() => {}
            LifecycleState::Active
                if expected.activation.is_some() && expected.generation.is_some() => {}
            _ => {
                return Err(io::Error::other(format!(
                    "graph snapshot benchmark: expected allocation identity is inconsistent for {}",
                    expected.id
                ))
                .into());
            }
        }
        for (binding, (contract, provider, generation)) in
            instance.bindings.iter().zip(&expected.bindings)
        {
            if binding.contract != *contract
                || binding.provider != *provider
                || binding.generation != *generation
            {
                return Err(io::Error::other(format!(
                    "graph snapshot benchmark: node {} has an unexpected binding",
                    expected.id
                ))
                .into());
            }
        }
        counts.bindings += instance.bindings.len();
        counts.children += instance.children.len();
        counts.dependents += instance.dependents.len();
    }
    Ok(counts)
}

fn semantic_checksum(snapshot: &lunette::plugin::graph::GraphSnapshot) -> u64 {
    let mut checksum = 0xcbf2_9ce4_8422_2325_u64;
    for instance in &snapshot.instances {
        checksum_u64(&mut checksum, instance.id.raw());
        checksum_u64(&mut checksum, instance.parent.map_or(0, InstanceId::raw));
        checksum_byte(&mut checksum, u8::from(instance.intent.enabled));
        checksum_byte(&mut checksum, u8::from(instance.intent.retired));
        checksum_byte(
            &mut checksum,
            match instance.state {
                LifecycleState::Inactive => 0,
                LifecycleState::Loading => 1,
                LifecycleState::Active => 2,
                LifecycleState::Unloading => 3,
                LifecycleState::Failed => 4,
                LifecycleState::Quarantined => 5,
            },
        );
        checksum_u64(
            &mut checksum,
            instance.activation.map_or(0, |activation| activation.raw()),
        );
        checksum_u64(
            &mut checksum,
            instance.generation.map_or(0, |generation| generation.raw()),
        );
        checksum_bindings(&mut checksum, &instance.bindings);
        checksum_bindings(&mut checksum, &instance.failed_bindings);
        checksum_ids(&mut checksum, &instance.children);
        checksum_ids(&mut checksum, &instance.dependents);
        checksum_byte(&mut checksum, u8::from(instance.replacement_requested));
        checksum_byte(&mut checksum, u8::from(instance.cleanup_failed));
    }
    checksum
}

fn checksum_bindings(checksum: &mut u64, bindings: &[lunette::plugin::graph::Binding]) {
    checksum_u64(checksum, bindings.len() as u64);
    for binding in bindings {
        checksum_bytes(checksum, binding.contract.name().as_bytes());
        checksum_u64(checksum, u64::from(binding.contract.schema()));
        checksum_u64(checksum, binding.provider.raw());
        checksum_u64(checksum, binding.generation.raw());
    }
}

fn checksum_ids(checksum: &mut u64, ids: &[InstanceId]) {
    checksum_u64(checksum, ids.len() as u64);
    for id in ids {
        checksum_u64(checksum, id.raw());
    }
}

fn checksum_bytes(checksum: &mut u64, bytes: &[u8]) {
    checksum_u64(checksum, bytes.len() as u64);
    for byte in bytes {
        checksum_byte(checksum, *byte);
    }
}

fn checksum_u64(checksum: &mut u64, value: u64) {
    for byte in value.to_le_bytes() {
        checksum_byte(checksum, byte);
    }
}

fn checksum_byte(checksum: &mut u64, byte: u8) {
    *checksum ^= u64::from(byte);
    *checksum = checksum.wrapping_mul(0x0000_0100_0000_01b3);
}

fn thread_cpu_nanoseconds() -> io::Result<u128> {
    let mut time = MaybeUninit::<libc::timespec>::uninit();
    // SAFETY: clock_gettime initializes the timespec on success; the pointer is writable and aligned.
    if unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, time.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the successful clock_gettime call initialized both fields.
    let time = unsafe { time.assume_init() };
    let seconds = u128::try_from(time.tv_sec).map_err(io::Error::other)?;
    let nanoseconds = u128::try_from(time.tv_nsec).map_err(io::Error::other)?;
    Ok(seconds * 1_000_000_000 + nanoseconds)
}
