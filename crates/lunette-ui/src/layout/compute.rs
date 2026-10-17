//! taffy's traits over the tree, for one computation.

use taffy::{
    CacheTree, LayoutBlockContainer, LayoutContainingBlock, LayoutFlexboxContainer,
    LayoutGridContainer, LayoutInput, LayoutOutput, LayoutPartialTree, NodeId as TaffyId,
    RequestedAxis, ResolveOrZero, RunMode, SizingMode, TraversePartialTree, compute_block_layout,
    compute_cached_layout, compute_flexbox_layout, compute_grid_layout, compute_hidden_layout,
    compute_leaf_layout, compute_oof_layout, compute_root_layout,
    geometry::{Line, Point, Size as TaffySize},
    style::{AvailableSpace, Display, Style},
};

use crate::layout::{
    Available, Content, Descriptor, Failure, Input, NodeId, ScriptContext, ScriptError, Scripts,
    Size, Transform, Tree,
};

#[derive(Clone, Copy)]
enum Kind {
    Box,
    Text,
    Leaf(Descriptor),
    Measured,
    Scripted,
}

pub(super) struct Computation<'a> {
    pub tree: &'a mut Tree,
    pub scripts: &'a dyn Scripts,
    pub failures: Vec<Failure>,
}

fn host_id(id: TaffyId) -> NodeId {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "Every taffy id here was made from a 32-bit host id, so it fits."
    )]
    let id = u64::from(id) as NodeId;
    id
}

fn taffy_id(id: NodeId) -> TaffyId {
    TaffyId::from(u64::from(id))
}

impl Computation<'_> {
    pub fn run(&mut self, root: NodeId, width: Option<f32>, height: Option<f32>) {
        let available = TaffySize {
            width: width.map_or(AvailableSpace::MaxContent, AvailableSpace::Definite),
            height: height.map_or(AvailableSpace::MaxContent, AvailableSpace::Definite),
        };
        compute_root_layout(self, taffy_id(root), available);
    }

    fn style(&self, id: TaffyId) -> &Style {
        // Every id taffy passes back was handed to it by this tree, from its own nodes.
        &self.tree.nodes[&host_id(id)].style
    }

    fn previous_size(&self, id: NodeId) -> taffy::Size<f32> {
        self.tree
            .nodes
            .get(&id)
            .map_or(TaffySize::ZERO, |node| node.layout.size)
    }

    fn compute_uncached(&mut self, id: TaffyId, inputs: LayoutInput) -> LayoutOutput {
        let host = host_id(id);
        if inputs.run_mode == RunMode::PerformHiddenLayout {
            return compute_hidden_layout(self, id);
        }
        let Some(node) = self.tree.nodes.get(&host) else {
            return LayoutOutput::HIDDEN;
        };
        if node.style.display == Display::None {
            return compute_hidden_layout(self, id);
        }
        let kind = match &node.content {
            Content::Box => Kind::Box,
            Content::Text(_) => Kind::Text,
            Content::Leaf(descriptor) => Kind::Leaf(*descriptor),
            Content::Measured => Kind::Measured,
            Content::Scripted => Kind::Scripted,
        };
        let display = node.style.display;
        match kind {
            Kind::Box => {
                let mut output = match display {
                    Display::Grid => compute_grid_layout(self, id, inputs),
                    Display::Block => compute_block_layout(self, id, inputs, None),
                    _ => compute_flexbox_layout(self, id, inputs),
                };
                if inputs.run_mode == RunMode::PerformLayout {
                    compute_oof_layout(self, id, &mut output);
                }
                output
            }
            Kind::Text => self.text_leaf(host, inputs),
            Kind::Leaf(descriptor) => {
                let style = self.tree.nodes[&host].style.clone();
                compute_leaf_layout(
                    inputs,
                    &style,
                    |_, _| 0.0,
                    |known, available| descriptor_size(descriptor, known, available),
                )
            }
            Kind::Measured => self.measured(host, inputs),
            Kind::Scripted => self.scripted(host, inputs),
        }
    }

    fn measured(&mut self, host: NodeId, inputs: LayoutInput) -> LayoutOutput {
        let style = self.tree.nodes[&host].style.clone();
        let scripts = self.scripts;
        let input = script_input(inputs);
        let fallback = self.previous_size(host);
        let mut failure = None;
        let output = compute_leaf_layout(
            inputs,
            &style,
            |_, _| 0.0,
            |known, available| {
                let input = Input {
                    known: (known.width, known.height),
                    available: (available.width, available.height),
                    ..input
                };
                match scripts.measure(host, &input) {
                    Ok(size) if size_is_valid(size) => TaffySize {
                        width: size.width,
                        height: size.height,
                    },
                    Ok(size) => {
                        failure = Some(ScriptError(format!(
                            "the measurement {} by {} is not a pair of finite lengths",
                            size.width, size.height
                        )));
                        fallback
                    }
                    Err(error) => {
                        failure = Some(error);
                        fallback
                    }
                }
            },
        );
        if let Some(error) = failure {
            self.fail(host, error);
        }
        output
    }

    fn text_leaf(&mut self, host: NodeId, inputs: LayoutInput) -> LayoutOutput {
        let style = self.tree.nodes[&host].style.clone();
        let fonts = std::rc::Rc::clone(&self.tree.fonts);
        let Ok(mut fonts) = fonts.try_borrow_mut() else {
            // Another tree's computation holds the fonts, which only a callback that computes a
            // second tree from inside the first can cause.
            self.fail(
                host,
                ScriptError("the fonts are in use by another computation in progress".to_owned()),
            );
            return LayoutOutput::HIDDEN;
        };
        let Some(node) = self.tree.nodes.get_mut(&host) else {
            return LayoutOutput::HIDDEN;
        };
        let Content::Text(block) = &mut node.content else {
            return LayoutOutput::HIDDEN;
        };
        let mut output = compute_leaf_layout(
            inputs,
            &style,
            |_, _| 0.0,
            |known, available| {
                let width = known.width.or(match available.width {
                    AvailableSpace::Definite(width) => Some(width),
                    AvailableSpace::MinContent => Some(0.0),
                    AvailableSpace::MaxContent => None,
                });
                let (measured_width, measured_height) = block.measure(&mut fonts, width);
                TaffySize {
                    width: known.width.unwrap_or(measured_width),
                    height: known.height.unwrap_or(measured_height),
                }
            },
        );
        // A row aligns its baseline items by their first baselines, measured from the top of the
        // border box; without one, Taffy uses the bottom edge.
        if let Some(baseline) = block.first_baseline() {
            let width = inputs.parent_size.width;
            let padding = style.padding.top.resolve_or_zero(width, |_, _| 0.0);
            let border = style.border.top.resolve_or_zero(width, |_, _| 0.0);
            output.baselines.first = Some(baseline + padding + border);
        }
        output
    }

    fn scripted(&mut self, host: NodeId, inputs: LayoutInput) -> LayoutOutput {
        let scripts = self.scripts;
        let perform = inputs.run_mode == RunMode::PerformLayout;
        let input = Input {
            perform,
            ..script_input(inputs)
        };
        let fallback = self.previous_size(host);
        let children = self.tree.nodes[&host].children.clone();
        let mut context = Context {
            computation: self,
            node: host,
            children: children.clone(),
            perform,
            placed: Vec::new(),
        };
        let result = scripts.layout(host, &input, &mut context);
        let placed = context.placed;
        let size = match result {
            Ok(size) if size_is_valid(size) => TaffySize {
                width: inputs.known_dimensions.width.unwrap_or(size.width),
                height: inputs.known_dimensions.height.unwrap_or(size.height),
            },
            Ok(size) => {
                self.fail(
                    host,
                    ScriptError(format!(
                        "the layout's size {} by {} is not a pair of finite lengths",
                        size.width, size.height
                    )),
                );
                fallback
            }
            Err(error) => {
                self.fail(host, error);
                fallback
            }
        };
        if perform {
            // A child the layout did not place takes no space and is not drawn.
            for child in children {
                if !placed.contains(&child) {
                    compute_hidden_layout(self, taffy_id(child));
                }
            }
        }
        LayoutOutput::from_outer_size(size)
    }

    fn fail(&mut self, id: NodeId, error: ScriptError) {
        self.failures.push(Failure { id, error });
    }
}

fn script_input(inputs: LayoutInput) -> Input {
    Input {
        known: (
            inputs.known_dimensions.width,
            inputs.known_dimensions.height,
        ),
        available: (inputs.available_space.width, inputs.available_space.height),
        perform: inputs.run_mode == RunMode::PerformLayout,
    }
}

fn size_is_valid(size: Size) -> bool {
    size.width.is_finite() && size.width >= 0.0 && size.height.is_finite() && size.height >= 0.0
}

fn descriptor_size(
    descriptor: Descriptor,
    known: TaffySize<Option<f32>>,
    available: TaffySize<AvailableSpace>,
) -> TaffySize<f32> {
    let definite = |space: AvailableSpace| match space {
        AvailableSpace::Definite(length) => length,
        _ => 0.0,
    };
    let (width, height) = match descriptor {
        Descriptor::Fixed { width, height } => (width, height),
        Descriptor::Aspect {
            ratio,
            preferred_width,
        } => {
            let width = known.width.unwrap_or(preferred_width);
            (width, known.height.unwrap_or(width / ratio))
        }
        Descriptor::Fill => (definite(available.width), definite(available.height)),
    };
    TaffySize {
        width: known.width.unwrap_or(width),
        height: known.height.unwrap_or(height),
    }
}

struct Context<'c, 'a> {
    computation: &'c mut Computation<'a>,
    node: NodeId,
    children: Vec<NodeId>,
    perform: bool,
    placed: Vec<NodeId>,
}

impl Context<'_, '_> {
    fn owns(&self, child: NodeId) -> Result<(), ScriptError> {
        if self.children.contains(&child) {
            Ok(())
        } else {
            Err(ScriptError(format!(
                "node {child} is not a child of node {}",
                self.node
            )))
        }
    }
}

impl ScriptContext for Context<'_, '_> {
    fn children(&self) -> Vec<NodeId> {
        self.children.clone()
    }

    fn measure(
        &mut self,
        child: NodeId,
        available: (Available, Available),
    ) -> Result<Size, ScriptError> {
        self.owns(child)?;
        let output = self.computation.compute_child_layout(
            taffy_id(child),
            LayoutInput {
                run_mode: RunMode::ComputeSize,
                sizing_mode: SizingMode::InherentSize,
                axis: RequestedAxis::Both,
                known_dimensions: TaffySize::NONE,
                known_dimensions_are_definite: TaffySize {
                    width: true,
                    height: true,
                },
                parent_size: TaffySize::NONE,
                available_space: TaffySize {
                    width: available.0,
                    height: available.1,
                },
                vertical_margins_are_collapsible: Line::FALSE,
            },
        );
        Ok(Size {
            width: output.size.width,
            height: output.size.height,
        })
    }

    fn place(
        &mut self,
        child: NodeId,
        u: f32,
        v: f32,
        size: Option<Size>,
        transform: Transform,
    ) -> Result<(), ScriptError> {
        self.owns(child)?;
        if !self.perform {
            return Err(ScriptError(
                "place is valid only in the final pass, when the input's perform is true"
                    .to_owned(),
            ));
        }
        if !(u.is_finite()
            && v.is_finite()
            && transform.rotation.is_finite()
            && transform.scale.is_finite())
        {
            return Err(ScriptError(format!(
                "node {child} was placed at a position that is not finite"
            )));
        }
        let known = size.map_or(TaffySize::NONE, |size| TaffySize {
            width: Some(size.width),
            height: Some(size.height),
        });
        let output = self.computation.compute_child_layout(
            taffy_id(child),
            LayoutInput {
                run_mode: RunMode::PerformLayout,
                sizing_mode: SizingMode::InherentSize,
                axis: RequestedAxis::Both,
                known_dimensions: known,
                known_dimensions_are_definite: TaffySize {
                    width: true,
                    height: true,
                },
                parent_size: TaffySize::NONE,
                available_space: TaffySize {
                    width: AvailableSpace::MaxContent,
                    height: AvailableSpace::MaxContent,
                },
                vertical_margins_are_collapsible: Line::FALSE,
            },
        );
        let mut layout = taffy::Layout::with_order(0);
        layout.location = Point { x: u, y: v };
        layout.size = output.size;
        self.computation
            .set_unrounded_layout(taffy_id(child), &layout);
        if let Some(node) = self.computation.tree.nodes.get_mut(&child) {
            node.transform = transform;
        }
        self.placed.push(child);
        Ok(())
    }
}

pub(super) struct ChildIter<'a>(std::slice::Iter<'a, NodeId>);

impl Iterator for ChildIter<'_> {
    type Item = TaffyId;

    fn next(&mut self) -> Option<Self::Item> {
        self.0.next().copied().map(taffy_id)
    }
}

impl TraversePartialTree for Computation<'_> {
    type ChildIter<'b>
        = ChildIter<'b>
    where
        Self: 'b;

    fn child_ids(&self, parent: TaffyId) -> Self::ChildIter<'_> {
        ChildIter(self.tree.nodes[&host_id(parent)].children.iter())
    }

    fn child_count(&self, parent: TaffyId) -> usize {
        self.tree.nodes[&host_id(parent)].children.len()
    }

    fn get_child_id(&self, parent: TaffyId, index: usize) -> TaffyId {
        taffy_id(self.tree.nodes[&host_id(parent)].children[index])
    }
}

impl LayoutPartialTree for Computation<'_> {
    type CoreContainerStyle<'b>
        = &'b Style
    where
        Self: 'b;
    type CustomIdent = String;

    fn get_core_container_style(&self, id: TaffyId) -> Self::CoreContainerStyle<'_> {
        self.style(id)
    }

    fn set_unrounded_layout(&mut self, id: TaffyId, layout: &taffy::Layout) {
        if let Some(node) = self.tree.nodes.get_mut(&host_id(id)) {
            node.layout = *layout;
        }
    }

    fn compute_child_layout(&mut self, id: TaffyId, inputs: LayoutInput) -> LayoutOutput {
        compute_cached_layout(self, id, inputs, |computation, id, inputs| {
            computation.compute_uncached(id, inputs)
        })
    }
}

impl CacheTree for Computation<'_> {
    fn cache_get(&mut self, id: TaffyId, input: &LayoutInput) -> Option<LayoutOutput> {
        self.tree.nodes.get_mut(&host_id(id))?.cache.get(input)
    }

    fn cache_store(&mut self, id: TaffyId, input: &LayoutInput, output: LayoutOutput) {
        if let Some(node) = self.tree.nodes.get_mut(&host_id(id)) {
            node.cache.store(input, output);
        }
    }

    fn cache_clear(&mut self, id: TaffyId) {
        if let Some(node) = self.tree.nodes.get_mut(&host_id(id)) {
            node.cache.clear();
        }
    }
}

impl LayoutContainingBlock for Computation<'_> {
    type OofItemStyle<'b>
        = &'b Style
    where
        Self: 'b;

    fn get_oof_item_style(&self, id: TaffyId) -> Self::OofItemStyle<'_> {
        self.style(id)
    }

    fn clear_hoisted_children(&mut self, id: TaffyId) {
        if let Some(node) = self.tree.nodes.get_mut(&host_id(id)) {
            node.hoisted.clear();
        }
    }

    fn add_hoisted_children(&mut self, id: TaffyId, hoisted: &[TaffyId]) {
        if let Some(node) = self.tree.nodes.get_mut(&host_id(id)) {
            node.hoisted.extend_from_slice(hoisted);
        }
    }
}

impl LayoutFlexboxContainer for Computation<'_> {
    type FlexboxContainerStyle<'b>
        = &'b Style
    where
        Self: 'b;
    type FlexboxItemStyle<'b>
        = &'b Style
    where
        Self: 'b;

    fn get_flexbox_container_style(&self, id: TaffyId) -> Self::FlexboxContainerStyle<'_> {
        self.style(id)
    }

    fn get_flexbox_child_style(&self, id: TaffyId) -> Self::FlexboxItemStyle<'_> {
        self.style(id)
    }
}

impl LayoutGridContainer for Computation<'_> {
    type GridContainerStyle<'b>
        = &'b Style
    where
        Self: 'b;
    type GridItemStyle<'b>
        = &'b Style
    where
        Self: 'b;

    fn get_grid_container_style(&self, id: TaffyId) -> Self::GridContainerStyle<'_> {
        self.style(id)
    }

    fn get_grid_child_style(&self, id: TaffyId) -> Self::GridItemStyle<'_> {
        self.style(id)
    }
}

impl LayoutBlockContainer for Computation<'_> {
    type BlockContainerStyle<'b>
        = &'b Style
    where
        Self: 'b;
    type BlockItemStyle<'b>
        = &'b Style
    where
        Self: 'b;

    fn get_block_container_style(&self, id: TaffyId) -> Self::BlockContainerStyle<'_> {
        self.style(id)
    }

    fn get_block_child_style(&self, id: TaffyId) -> Self::BlockItemStyle<'_> {
        self.style(id)
    }
}
