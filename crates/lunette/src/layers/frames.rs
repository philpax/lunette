use tracing::warn;

use crate::{
    layers::{BlitLedger, LovrBlits, LovrLayers},
    lua::{PoolRegistry, Session},
    texture::LovrTexture,
};

/// Copies each claim's window into its layer and hands the frame's layer list to the runtime.
/// A claim without fresh pixels continues to composite its last image.
pub(crate) fn submit_window_layers(
    session: &Session<LovrTexture>,
    layers: &PoolRegistry<LovrLayers>,
    blits: &mut LovrBlits,
    blitted: &mut BlitLedger,
) {
    let scene = session.scene();
    layers.with_pool(|pool| {
        session.with_textures(|textures| {
            let report = blitted.run(pool, blits, textures, |claim| {
                session
                    .claims()
                    .source(claim)
                    .and_then(|window| session.window(window))
                    .map(|window| window.surface)
            });

            if report.iter().any(|(_, outcome)| outcome.copied()) {
                // Matters only on a frame that draws no scene. `crate::scene` has the reasoning.
                session.note_copies_recorded();
            }

            for (claim, outcome) in report {
                // `Blitted` decides which outcomes are permanent, and the blit ledger has already reported each once per claim.
                if outcome.worth_reporting_every_frame() {
                    warn!(%claim, ?outcome, "a layer was not updated this frame");
                }
            }
        });

        // The frame's whole layer list, which decides whether lunette's projection layer belongs in this `xrEndFrame`.
        if !pool.submit(scene) {
            warn!("the runtime refused this frame's composition layers");
        }
    });
}
