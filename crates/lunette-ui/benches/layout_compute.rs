//! Linux-only: measures public layout computation with the thread CPU clock.

use std::{
    cell::RefCell, error::Error, hint::black_box, io, mem::MaybeUninit, rc::Rc, time::Instant,
};

use clap::{Parser, ValueEnum};
use lunette_ui::{
    layout::{
        Change, ContentSpec, Descriptor, NoScripts, Outcome, Placement, Style, Transform, Tree,
    },
    text::Fonts,
};
use serde_json::{Value, json};
use taffy::{
    geometry::Size,
    style::{Dimension, LengthPercentageAuto, Position},
};

#[derive(Debug, Parser)]
#[command(about = "Measure full public Tree::compute calls on deterministic layout trees")]
struct Arguments {
    /// Validate one frame per case without reading clocks or reporting timings.
    #[arg(long)]
    smoke: bool,
    #[arg(long, default_value_t = 1000, value_parser = clap::value_parser!(u64).range(1..))]
    iterations: u64,
    /// Warmup frames per tree, in addition to the initial geometry validation.
    #[arg(long, default_value_t = 20)]
    warmup: u64,
    #[arg(long, value_delimiter = ',', default_value = "1,8,48,192,768", value_parser = clap::value_parser!(u32).range(1..=768))]
    nodes: Vec<u32>,
    #[arg(
        long,
        value_enum,
        value_delimiter = ',',
        default_value = "chain,broad,balanced"
    )]
    shape: Vec<Shape>,
    #[arg(
        long,
        value_enum,
        value_delimiter = ',',
        default_value = "cached,position-dirty,size-dirty"
    )]
    case: Vec<Case>,
    #[arg(long, hide = true)]
    bench: bool,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum Shape {
    Chain,
    Broad,
    Balanced,
}

impl Shape {
    fn parent(self, index: usize) -> usize {
        match self {
            Self::Chain => index - 1,
            Self::Broad => 0,
            Self::Balanced => (index - 1) / 2,
        }
    }
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum Case {
    Cached,
    PositionDirty,
    SizeDirty,
}

fn main() -> Result<(), Box<dyn Error>> {
    let arguments = Arguments::parse();
    let mut records = Vec::new();
    for &shape in &arguments.shape {
        for &nodes in &arguments.nodes {
            for &case in &arguments.case {
                records.push(measure(shape, nodes, case, &arguments)?);
            }
        }
    }
    println!(
        "{}",
        serde_json::to_string(&json!({
            "schema": 1,
            "debug_assertions": cfg!(debug_assertions),
            "records": records,
        }))?
    );
    Ok(())
}

fn measure(
    shape: Shape,
    nodes: u32,
    case: Case,
    args: &Arguments,
) -> Result<Value, Box<dyn Error>> {
    let iterations = if args.smoke { 1 } else { args.iterations };
    let warmup = if args.smoke { 0 } else { args.warmup };
    // A small pool amortizes clock reads without timing public apply or allocating unbounded trees.
    let batch_size = iterations.min(16) as usize;
    let mut fixtures = (0..batch_size)
        .map(|_| Fixture::new(shape, nodes))
        .collect::<Result<Vec<_>, _>>()?;
    for fixture in &mut fixtures {
        fixture.verify_states(case)?;
        for _ in 0..warmup {
            fixture.prepare(case)?;
            let outcome = fixture.compute()?;
            fixture.validate(case, &outcome, false)?;
        }
    }

    let mut elapsed_ns = 0;
    let mut thread_cpu_ns = 0;
    let mut changed_placements = 0_u64;
    let mut failures = 0_u64;
    let mut consumed_checksum = 0_u64;
    let mut outcomes = Vec::with_capacity(batch_size);
    let mut remaining = iterations;
    while remaining > 0 {
        let count = remaining.min(batch_size as u64) as usize;
        let batch = &mut fixtures[..count];
        for fixture in batch.iter_mut() {
            fixture.prepare(case)?;
        }
        outcomes.clear();
        let start = if args.smoke {
            None
        } else {
            Some((thread_cpu_nanoseconds()?, Instant::now()))
        };
        for fixture in batch.iter_mut() {
            let outcome = black_box(fixture.compute()?);
            changed_placements += outcome.changed.len() as u64;
            failures += outcome.failures.len() as u64;
            consumed_checksum = consumed_checksum
                .wrapping_mul(31)
                .wrapping_add(outcome.changed.len() as u64)
                .wrapping_add(outcome.failures.len() as u64);
            outcomes.push(outcome);
        }
        if let Some((cpu_start, elapsed_start)) = start {
            elapsed_ns += elapsed_start.elapsed().as_nanos();
            thread_cpu_ns += thread_cpu_nanoseconds()?
                .checked_sub(cpu_start)
                .ok_or_else(|| invalid("thread CPU clock regressed"))?;
        }
        for (fixture, outcome) in batch.iter_mut().zip(&outcomes) {
            fixture.validate(case, outcome, false)?;
        }
        remaining -= count as u64;
    }
    black_box(consumed_checksum);
    let frame_checksum = checksum(&fixtures[0].placements);
    let mut record = json!({
        "shape": shape.to_possible_value().map(|value| value.get_name().to_owned()),
        "nodes": nodes,
        "case": case.to_possible_value().map(|value| value.get_name().to_owned()),
        "iterations": iterations,
        "warmup_per_tree": warmup,
        "batch_size": batch_size,
        "changed_placements": changed_placements,
        "failures": failures,
        "expected_placements": nodes,
        "frame_checksum": frame_checksum,
        "consumed_checksum": consumed_checksum,
        "smoke": args.smoke,
    });
    if !args.smoke {
        record["elapsed_ns"] = json!(elapsed_ns);
        record["thread_cpu_ns"] = json!(thread_cpu_ns);
        record["elapsed_ns_per_frame"] = json!(elapsed_ns as f64 / iterations as f64);
        record["thread_cpu_ns_per_frame"] = json!(thread_cpu_ns as f64 / iterations as f64);
    }
    Ok(record)
}

struct Fixture {
    tree: Tree,
    expected: Vec<Placement>,
    placements: Vec<Option<Placement>>,
    state: bool,
    root_leaf: bool,
}

impl Fixture {
    fn new(shape: Shape, nodes: u32) -> Result<Self, Box<dyn Error>> {
        let count = nodes as usize;
        let mut children = vec![Vec::new(); count];
        for index in 1..count {
            children[shape.parent(index)].push(index);
        }
        let mut changes = Vec::with_capacity(count * 2);
        let mut expected: Vec<Placement> = Vec::with_capacity(count);
        for index in 0..count {
            let leaf = children[index].is_empty();
            let mut style = root_style(leaf, Case::Cached, false);
            let (u, v) = if index == 0 {
                (0.0, 0.0)
            } else {
                let parent = shape.parent(index);
                let slot = children[parent]
                    .iter()
                    .position(|&child| child == index)
                    .ok_or_else(|| invalid("fixture has no child slot"))?;
                let x = (slot + 1) as f32 / 32.0;
                let y = 1.0 / 64.0;
                style.position = Position::Absolute;
                style.inset.left = LengthPercentageAuto::length(x);
                style.inset.top = LengthPercentageAuto::length(y);
                (expected[parent].u + x, expected[parent].v + y)
            };
            let id = index as u32 + 1;
            changes.push(Change::Create {
                id,
                content: if leaf {
                    ContentSpec::Leaf(Descriptor::Fixed {
                        width: 0.25,
                        height: 0.125,
                    })
                } else {
                    ContentSpec::Box
                },
                style: Box::new(style),
            });
            expected.push(Placement {
                id,
                u,
                v,
                width: if leaf { 0.25 } else { 2.0 },
                height: if leaf { 0.125 } else { 2.0 },
                transform: Transform::default(),
            });
        }
        for (index, children) in children.iter().enumerate() {
            if !children.is_empty() {
                changes.push(Change::SetChildren {
                    id: index as u32 + 1,
                    children: children.iter().map(|&child| child as u32 + 1).collect(),
                });
            }
        }
        // These fixtures contain no text; an empty bundled database reads no system fonts.
        let mut tree = Tree::new(Rc::new(RefCell::new(Fonts::bundled([]))));
        tree.apply(changes)?;
        if tree.len() != count {
            return Err(invalid("tree node count differs from fixture").into());
        }
        Ok(Self {
            tree,
            expected,
            placements: vec![None; count],
            state: false,
            root_leaf: count == 1,
        })
    }

    fn compute(&mut self) -> Result<Outcome, lunette_ui::layout::ComputeError> {
        self.tree.compute(1, None, None, &NoScripts)
    }

    fn prepare(&mut self, case: Case) -> Result<(), Box<dyn Error>> {
        if !matches!(case, Case::Cached) {
            self.state = !self.state;
            self.tree.apply(vec![Change::SetStyle {
                id: 1,
                style: Box::new(root_style(self.root_leaf, case, self.state)),
            }])?;
        }
        Ok(())
    }

    fn verify_states(&mut self, case: Case) -> Result<(), Box<dyn Error>> {
        let outcome = self.compute()?;
        self.validate(case, &outcome, true)?;
        for _ in 0..2 {
            self.prepare(case)?;
            let outcome = self.compute()?;
            self.validate(case, &outcome, false)?;
        }
        let cached = self.compute()?;
        if !cached.changed.is_empty() || !cached.failures.is_empty() {
            return Err(invalid("unchanged computation is not cached").into());
        }
        Ok(())
    }

    fn validate(
        &mut self,
        case: Case,
        outcome: &Outcome,
        initial: bool,
    ) -> Result<(), Box<dyn Error>> {
        let wanted = if initial || matches!(case, Case::PositionDirty) {
            self.expected.len()
        } else if matches!(case, Case::SizeDirty) {
            1
        } else {
            0
        };
        if !outcome.failures.is_empty() || outcome.changed.len() != wanted {
            return Err(invalid(format!(
                "expected {wanted} changes and no failures, got {} changes and {} failures",
                outcome.changed.len(),
                outcome.failures.len()
            ))
            .into());
        }
        let mut seen = vec![false; self.expected.len()];
        for placement in &outcome.changed {
            let index = placement
                .id
                .checked_sub(1)
                .ok_or_else(|| invalid("placement id is zero"))? as usize;
            if index >= seen.len() || seen[index] {
                return Err(invalid("unknown or duplicate placement id").into());
            }
            seen[index] = true;
            self.placements[index] = Some(*placement);
        }
        for (index, expected) in self.expected.iter().enumerate() {
            let mut expected = *expected;
            if self.state && matches!(case, Case::PositionDirty) {
                expected.u += 0.125;
            }
            if index == 0 && self.state && matches!(case, Case::SizeDirty) {
                expected.width += 0.25;
            }
            if self.placements[index] != Some(expected) {
                return Err(invalid(format!(
                    "node {}: expected {expected:?}, got {:?}",
                    expected.id, self.placements[index]
                ))
                .into());
            }
        }
        Ok(())
    }
}

fn root_style(leaf: bool, case: Case, state: bool) -> Style {
    let mut style = Style::default();
    if !leaf {
        style.size = Size {
            width: Dimension::length(2.0),
            height: Dimension::length(2.0),
        };
    }
    if state {
        match case {
            Case::Cached => {}
            Case::PositionDirty => style.margin.left = LengthPercentageAuto::length(0.125),
            Case::SizeDirty => {
                style.size.width = Dimension::length(if leaf { 0.5 } else { 2.25 });
            }
        }
    }
    style
}

fn checksum(placements: &[Option<Placement>]) -> u64 {
    let mut checksum = 0xcbf2_9ce4_8422_2325_u64;
    for placement in placements.iter().flatten() {
        for word in [
            placement.id,
            placement.u.to_bits(),
            placement.v.to_bits(),
            placement.width.to_bits(),
            placement.height.to_bits(),
            placement.transform.rotation.to_bits(),
            placement.transform.scale.to_bits(),
        ] {
            for byte in word.to_le_bytes() {
                checksum ^= u64::from(byte);
                checksum = checksum.wrapping_mul(0x0000_0100_0000_01b3);
            }
        }
    }
    checksum
}

fn invalid(message: impl std::fmt::Display) -> io::Error {
    io::Error::other(format!("layout compute benchmark: {message}"))
}

fn thread_cpu_nanoseconds() -> io::Result<u128> {
    let mut time = MaybeUninit::<libc::timespec>::uninit();
    // SAFETY: clock_gettime initializes the writable, aligned timespec on success.
    if unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, time.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the successful clock_gettime call initializes both fields.
    let time = unsafe { time.assume_init() };
    let seconds = u128::try_from(time.tv_sec).map_err(io::Error::other)?;
    let nanoseconds = u128::try_from(time.tv_nsec).map_err(io::Error::other)?;
    Ok(seconds * 1_000_000_000 + nanoseconds)
}
