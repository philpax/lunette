//! A layout tree over taffy's low-level API.
//!
//! The host owns one tree per panel and identifies nodes by integer ids it assigns. A commit's
//! changes arrive as one batch through [`Tree::apply`], and [`Tree::compute`] lays out the dirty
//! part of the tree and returns the nodes whose position or size changed, in the coordinates of
//! the root: metres, origin at the root's top-left corner, `u` to the right and `v` downwards.
//!
//! Boxes use taffy's flexbox, grid, and block algorithms, chosen by their style's `display`.
//! Text nodes are measured natively by [`crate::text`]. Leaves with a [`Descriptor`] are sized
//! without a callback. Measured leaves and scripted containers call the host's [`Scripts`],
//! and a scripted container lays out its children through a [`ScriptContext`], which re-enters
//! the computation in progress.

mod compute;

use std::{collections::HashMap, fmt};

pub use taffy::style::{AvailableSpace, Style};

use crate::text::{Fonts, TextBlock, TextStyle, TextStyleError};

/// A node id that the host assigns.
pub type NodeId = u32;

/// What a node lays out as.
#[derive(Debug)]
pub enum Content {
    /// A container laid out by its style's `display`.
    Box,
    /// Text, measured natively.
    Text(TextBlock),
    /// A leaf sized by a declaration, with no callback.
    Leaf(Descriptor),
    /// A leaf the host measures through [`Scripts::measure`].
    Measured,
    /// A container the host lays out through [`Scripts::layout`].
    Scripted,
}

/// How a leaf sizes itself without a callback.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Descriptor {
    /// A fixed width and height, in metres.
    Fixed { width: f32, height: f32 },
    /// An aspect ratio, width over height, with a preferred width.
    Aspect { ratio: f32, preferred_width: f32 },
    /// Whatever space is available, and nothing when none is.
    Fill,
}

/// What a new node is.
#[derive(Debug)]
pub enum ContentSpec {
    Box,
    Text { text: String, style: TextStyle },
    Leaf(Descriptor),
    Measured,
    Scripted,
}

/// One change in a commit.
#[derive(Debug)]
pub enum Change {
    Create {
        id: NodeId,
        content: ContentSpec,
        style: Box<Style>,
    },
    SetStyle {
        id: NodeId,
        style: Box<Style>,
    },
    SetChildren {
        id: NodeId,
        children: Vec<NodeId>,
    },
    SetText {
        id: NodeId,
        text: String,
        style: TextStyle,
    },
    Remove {
        id: NodeId,
    },
}

/// A change that cannot be applied.
#[derive(Debug, Clone, PartialEq)]
pub enum ApplyError {
    /// A change names a node that does not exist.
    Unknown { index: usize, id: NodeId },
    /// A create names a node that already exists.
    Duplicate { index: usize, id: NodeId },
    /// A node is given as a child twice, or of two parents.
    Reparent { index: usize, id: NodeId },
    /// A node is made its own ancestor.
    Cycle { index: usize, id: NodeId },
    /// Text is set on a node that is not a text node.
    NotText { index: usize, id: NodeId },
    /// A text style cannot be shaped.
    TextStyle { index: usize, error: TextStyleError },
    /// A descriptor has a size that is negative or not finite.
    Descriptor { index: usize, id: NodeId },
}

impl fmt::Display for ApplyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unknown { index, id } => {
                write!(f, "layout: change {index}: node {id} does not exist")
            }
            Self::Duplicate { index, id } => {
                write!(f, "layout: change {index}: node {id} already exists")
            }
            Self::Reparent { index, id } => {
                write!(f, "layout: change {index}: node {id} already has a parent")
            }
            Self::Cycle { index, id } => {
                write!(f, "layout: change {index}: node {id} would contain itself")
            }
            Self::NotText { index, id } => {
                write!(f, "layout: change {index}: node {id} is not a text node")
            }
            Self::TextStyle { index, error } => write!(f, "layout: change {index}: {error}"),
            Self::Descriptor { index, id } => {
                write!(
                    f,
                    "layout: change {index}: node {id} has a size that is not a finite length"
                )
            }
        }
    }
}

impl std::error::Error for ApplyError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::TextStyle { error, .. } => Some(error),
            _ => None,
        }
    }
}

/// The space offered to a node along one axis.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Available {
    Definite(f32),
    MinContent,
    MaxContent,
}

impl From<AvailableSpace> for Available {
    fn from(space: AvailableSpace) -> Self {
        match space {
            AvailableSpace::Definite(length) => Self::Definite(length),
            AvailableSpace::MinContent => Self::MinContent,
            AvailableSpace::MaxContent => Self::MaxContent,
        }
    }
}

impl From<Available> for AvailableSpace {
    fn from(space: Available) -> Self {
        match space {
            Available::Definite(length) => Self::Definite(length),
            Available::MinContent => Self::MinContent,
            Available::MaxContent => Self::MaxContent,
        }
    }
}

/// What taffy asks a measured leaf or a scripted container.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Input {
    /// Dimensions the parent has already decided.
    pub known: (Option<f32>, Option<f32>),
    pub available: (Available, Available),
    /// Whether this is the final pass, in which a scripted container places its children.
    pub perform: bool,
}

/// A size, in metres.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Size {
    pub width: f32,
    pub height: f32,
}

/// A rotation and a uniform scale that a scripted container gives a child it places, about the
/// centre of the child's box.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Transform {
    /// Radians, clockwise in the `u`, `v` plane.
    pub rotation: f32,
    pub scale: f32,
}

impl Default for Transform {
    fn default() -> Self {
        Self {
            rotation: 0.0,
            scale: 1.0,
        }
    }
}

/// A failure that a host callback reports.
#[derive(Clone, Debug, PartialEq)]
pub struct ScriptError(pub String);

impl fmt::Display for ScriptError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ScriptError {}

/// The host's measurements and layouts.
///
/// Methods take `&self` so that a scripted layout can measure a child that is itself
/// scripted: the callback for the child runs while the callback for its parent is running.
pub trait Scripts {
    /// The size of a measured leaf.
    ///
    /// # Errors
    ///
    /// Returns the host's error; the node keeps its previous size.
    fn measure(&self, node: NodeId, input: &Input) -> Result<Size, ScriptError>;

    /// The size of a scripted container, placing its children in the final pass.
    ///
    /// # Errors
    ///
    /// Returns the host's error; the node keeps its previous size.
    fn layout(
        &self,
        node: NodeId,
        input: &Input,
        context: &mut dyn ScriptContext,
    ) -> Result<Size, ScriptError>;
}

/// Hosts that use no measured leaves or scripted containers.
#[derive(Debug, Default)]
pub struct NoScripts;

impl Scripts for NoScripts {
    fn measure(&self, node: NodeId, _input: &Input) -> Result<Size, ScriptError> {
        Err(ScriptError(format!(
            "node {node} is measured, and no measurements are registered"
        )))
    }

    fn layout(
        &self,
        node: NodeId,
        _input: &Input,
        _context: &mut dyn ScriptContext,
    ) -> Result<Size, ScriptError> {
        Err(ScriptError(format!(
            "node {node} is scripted, and no layouts are registered"
        )))
    }
}

/// What a scripted container can do with its children during its layout.
pub trait ScriptContext {
    /// The container's children, in order.
    fn children(&self) -> Vec<NodeId>;

    /// Lays out `child`'s subtree to find its size, without placing it.
    ///
    /// # Errors
    ///
    /// Returns an error if `child` is not one of the container's children.
    fn measure(
        &mut self,
        child: NodeId,
        available: (Available, Available),
    ) -> Result<Size, ScriptError>;

    /// Lays out `child`'s subtree at `size`, or at its measured size, and places it at `u`, `v`
    /// in the container's coordinates. Valid only in the final pass.
    ///
    /// # Errors
    ///
    /// Returns an error outside the final pass, or if `child` is not one of the container's
    /// children.
    fn place(
        &mut self,
        child: NodeId,
        u: f32,
        v: f32,
        size: Option<Size>,
        transform: Transform,
    ) -> Result<(), ScriptError>;
}

/// A node's position and size, in the root's coordinates, with its layout transform.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Placement {
    pub id: NodeId,
    pub u: f32,
    pub v: f32,
    pub width: f32,
    pub height: f32,
    pub transform: Transform,
}

/// A callback that failed during a computation.
#[derive(Clone, Debug, PartialEq)]
pub struct Failure {
    pub id: NodeId,
    pub error: ScriptError,
}

/// What a computation changed.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Outcome {
    /// Every node whose position, size, or layout transform changed since the last computation,
    /// in no particular order.
    pub changed: Vec<Placement>,
    /// Every callback that failed. Each failing node keeps its previous size.
    pub failures: Vec<Failure>,
}

/// An error that stops a computation before it starts.
#[derive(Clone, Debug, PartialEq)]
pub enum ComputeError {
    /// The root does not exist.
    Unknown(NodeId),
    /// The root has a parent.
    NotRoot(NodeId),
}

impl fmt::Display for ComputeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unknown(id) => write!(f, "layout: compute: node {id} does not exist"),
            Self::NotRoot(id) => write!(
                f,
                "layout: compute: node {id} has a parent, so it is not a root"
            ),
        }
    }
}

impl std::error::Error for ComputeError {}

#[derive(Debug)]
struct Node {
    style: Style,
    content: Content,
    children: Vec<NodeId>,
    parent: Option<NodeId>,
    cache: taffy::Cache,
    /// The layout taffy last set, relative to the parent.
    layout: taffy::Layout,
    hoisted: Vec<taffy::NodeId>,
    /// The transform a scripted parent gave the node.
    transform: Transform,
    /// The placement last reported, in the root's coordinates.
    reported: Option<Placement>,
}

impl Node {
    fn new(content: Content, style: Style) -> Self {
        Self {
            style,
            content,
            children: Vec::new(),
            parent: None,
            cache: taffy::Cache::new(),
            layout: taffy::Layout::with_order(0),
            hoisted: Vec::new(),
            transform: Transform::default(),
            reported: None,
        }
    }
}

/// A tree of nodes laid out together.
pub struct Tree {
    nodes: HashMap<NodeId, Node>,
    fonts: Fonts,
}

impl fmt::Debug for Tree {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Tree")
            .field("nodes", &self.nodes.len())
            .finish()
    }
}

impl Tree {
    /// An empty tree that shapes text with `fonts`.
    pub fn new(fonts: Fonts) -> Self {
        Self {
            nodes: HashMap::new(),
            fonts,
        }
    }

    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }

    pub fn contains(&self, id: NodeId) -> bool {
        self.nodes.contains_key(&id)
    }

    /// Applies one commit's changes in order. The batch is checked before anything changes, so a
    /// rejected batch leaves the tree as it was.
    ///
    /// # Errors
    ///
    /// Returns the first change that cannot be applied.
    pub fn apply(&mut self, changes: Vec<Change>) -> Result<(), ApplyError> {
        self.check(&changes)?;
        for (index, change) in changes.into_iter().enumerate() {
            self.apply_one(index, change)?;
        }
        Ok(())
    }

    /// Lays out the tree under `root` in the space offered, which is unbounded along an axis
    /// given as `None`.
    ///
    /// # Errors
    ///
    /// Returns an error if `root` is missing or has a parent.
    pub fn compute(
        &mut self,
        root: NodeId,
        width: Option<f32>,
        height: Option<f32>,
        scripts: &dyn Scripts,
    ) -> Result<Outcome, ComputeError> {
        let node = self.nodes.get(&root).ok_or(ComputeError::Unknown(root))?;
        if node.parent.is_some() {
            return Err(ComputeError::NotRoot(root));
        }
        let mut computation = compute::Computation {
            tree: self,
            scripts,
            failures: Vec::new(),
        };
        computation.run(root, width, height);
        let failures = computation.failures;
        let mut changed = Vec::new();
        self.compose(root, 0.0, 0.0, &mut changed);
        Ok(Outcome { changed, failures })
    }

    /// The shaped lines of a text node, at its laid-out width.
    pub fn text_lines(&mut self, id: NodeId) -> Option<Vec<crate::text::Line>> {
        let width = self.nodes.get(&id)?.layout.size.width;
        let Self { nodes, fonts } = self;
        match &mut nodes.get_mut(&id)?.content {
            Content::Text(block) => Some(block.lines(fonts, Some(width))),
            _ => None,
        }
    }

    /// Walks the tree from `id`, composing positions into the root's coordinates, and reports
    /// every node whose placement differs from the one last reported.
    fn compose(&mut self, id: NodeId, u: f32, v: f32, changed: &mut Vec<Placement>) {
        let Some(node) = self.nodes.get_mut(&id) else {
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
            self.compose(child, placement.u, placement.v, changed);
        }
    }

    fn check(&self, changes: &[Change]) -> Result<(), ApplyError> {
        // The batch is simulated over the ids and parents it touches, so a node created
        // earlier in the batch can be used later in it.
        let mut present: HashMap<NodeId, bool> = HashMap::new();
        let mut parents: HashMap<NodeId, Option<NodeId>> = HashMap::new();
        let mut is_text: HashMap<NodeId, bool> = HashMap::new();
        let exists = |present: &HashMap<NodeId, bool>, id: NodeId| {
            present
                .get(&id)
                .copied()
                .unwrap_or_else(|| self.nodes.contains_key(&id))
        };
        let parent_of = |parents: &HashMap<NodeId, Option<NodeId>>, id: NodeId| {
            parents
                .get(&id)
                .copied()
                .unwrap_or_else(|| self.nodes.get(&id).and_then(|node| node.parent))
        };
        for (index, change) in changes.iter().enumerate() {
            match change {
                Change::Create { id, content, .. } => {
                    if exists(&present, *id) {
                        return Err(ApplyError::Duplicate { index, id: *id });
                    }
                    match content {
                        ContentSpec::Text { style, .. } => {
                            style
                                .validate()
                                .map_err(|error| ApplyError::TextStyle { index, error })?;
                        }
                        ContentSpec::Leaf(descriptor) if !descriptor_is_valid(*descriptor) => {
                            return Err(ApplyError::Descriptor { index, id: *id });
                        }
                        _ => {}
                    }
                    present.insert(*id, true);
                    parents.insert(*id, None);
                    is_text.insert(*id, matches!(content, ContentSpec::Text { .. }));
                }
                Change::SetStyle { id, .. } => {
                    if !exists(&present, *id) {
                        return Err(ApplyError::Unknown { index, id: *id });
                    }
                }
                Change::SetText { id, style, .. } => {
                    if !exists(&present, *id) {
                        return Err(ApplyError::Unknown { index, id: *id });
                    }
                    let text = is_text.get(id).copied().unwrap_or_else(|| {
                        matches!(
                            self.nodes.get(id).map(|node| &node.content),
                            Some(Content::Text(_))
                        )
                    });
                    if !text {
                        return Err(ApplyError::NotText { index, id: *id });
                    }
                    style
                        .validate()
                        .map_err(|error| ApplyError::TextStyle { index, error })?;
                }
                Change::SetChildren { id, children } => {
                    if !exists(&present, *id) {
                        return Err(ApplyError::Unknown { index, id: *id });
                    }
                    let mut seen = std::collections::HashSet::new();
                    for child in children {
                        if !exists(&present, *child) {
                            return Err(ApplyError::Unknown { index, id: *child });
                        }
                        if !seen.insert(*child) {
                            return Err(ApplyError::Reparent { index, id: *child });
                        }
                        if let Some(parent) = parent_of(&parents, *child)
                            && parent != *id
                        {
                            return Err(ApplyError::Reparent { index, id: *child });
                        }
                        // The new parent must not lie inside the child's subtree.
                        let mut ancestor = Some(*id);
                        while let Some(current) = ancestor {
                            if current == *child {
                                return Err(ApplyError::Cycle { index, id: *child });
                            }
                            ancestor = parent_of(&parents, current);
                        }
                    }
                    // The previous children of `id` become parentless.
                    let previous: Vec<NodeId> = self
                        .nodes
                        .get(id)
                        .map(|node| node.children.clone())
                        .unwrap_or_default();
                    for old in previous {
                        if parent_of(&parents, old) == Some(*id) {
                            parents.insert(old, None);
                        }
                    }
                    for (simulated, parent) in parents.clone() {
                        if parent == Some(*id) {
                            parents.insert(simulated, None);
                        }
                    }
                    for child in children {
                        parents.insert(*child, Some(*id));
                    }
                }
                Change::Remove { id } => {
                    if !exists(&present, *id) {
                        return Err(ApplyError::Unknown { index, id: *id });
                    }
                    present.insert(*id, false);
                    for (simulated, parent) in parents.clone() {
                        if parent == Some(*id) {
                            parents.insert(simulated, None);
                        }
                    }
                    if let Some(node) = self.nodes.get(id) {
                        for child in &node.children {
                            if parent_of(&parents, *child) == Some(*id) {
                                parents.insert(*child, None);
                            }
                        }
                    }
                    parents.insert(*id, None);
                }
            }
        }
        Ok(())
    }

    fn apply_one(&mut self, index: usize, change: Change) -> Result<(), ApplyError> {
        match change {
            Change::Create { id, content, style } => {
                let content = match content {
                    ContentSpec::Box => Content::Box,
                    ContentSpec::Text { text, style } => Content::Text(
                        TextBlock::new(&mut self.fonts, &text, style)
                            .map_err(|error| ApplyError::TextStyle { index, error })?,
                    ),
                    ContentSpec::Leaf(descriptor) => Content::Leaf(descriptor),
                    ContentSpec::Measured => Content::Measured,
                    ContentSpec::Scripted => Content::Scripted,
                };
                self.nodes.insert(id, Node::new(content, *style));
            }
            Change::SetStyle { id, style } => {
                if let Some(node) = self.nodes.get_mut(&id) {
                    node.style = *style;
                }
                self.mark_dirty(id);
            }
            Change::SetText { id, text, style } => {
                let Self { nodes, fonts } = self;
                if let Some(Node {
                    content: Content::Text(block),
                    ..
                }) = nodes.get_mut(&id)
                {
                    block
                        .set(fonts, &text, style)
                        .map_err(|error| ApplyError::TextStyle { index, error })?;
                }
                self.mark_dirty(id);
            }
            Change::SetChildren { id, children } => {
                let previous = self
                    .nodes
                    .get_mut(&id)
                    .map(|node| std::mem::take(&mut node.children))
                    .unwrap_or_default();
                for old in previous {
                    if let Some(node) = self.nodes.get_mut(&old)
                        && node.parent == Some(id)
                    {
                        node.parent = None;
                    }
                }
                for child in &children {
                    if let Some(node) = self.nodes.get_mut(child) {
                        node.parent = Some(id);
                        node.reported = None;
                    }
                }
                if let Some(node) = self.nodes.get_mut(&id) {
                    node.children = children;
                }
                self.mark_dirty(id);
            }
            Change::Remove { id } => {
                let parent = self.nodes.get(&id).and_then(|node| node.parent);
                if let Some(parent) = parent {
                    if let Some(node) = self.nodes.get_mut(&parent) {
                        node.children.retain(|child| *child != id);
                    }
                    self.mark_dirty(parent);
                }
                if let Some(node) = self.nodes.remove(&id) {
                    for child in node.children {
                        if let Some(child) = self.nodes.get_mut(&child) {
                            child.parent = None;
                        }
                    }
                }
            }
        }
        Ok(())
    }

    /// Clears the caches of `id` and every ancestor, because each ancestor's layout may depend
    /// on it.
    fn mark_dirty(&mut self, id: NodeId) {
        let mut current = Some(id);
        while let Some(node_id) = current {
            let Some(node) = self.nodes.get_mut(&node_id) else {
                break;
            };
            node.cache.clear();
            current = node.parent;
        }
    }
}

fn descriptor_is_valid(descriptor: Descriptor) -> bool {
    let length = |value: f32| value.is_finite() && value >= 0.0;
    match descriptor {
        Descriptor::Fixed { width, height } => length(width) && length(height),
        Descriptor::Aspect {
            ratio,
            preferred_width,
        } => ratio.is_finite() && ratio > 0.0 && length(preferred_width),
        Descriptor::Fill => true,
    }
}

#[cfg(test)]
mod tests;
