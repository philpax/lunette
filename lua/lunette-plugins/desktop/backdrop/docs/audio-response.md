# Audio response

The optional response child reads the public audio-analysis contract. It follows sample time and consumes completed FFT hops rather than estimating features from render frames. The analysis provider owns the transform and feature definitions in [its analysis specification](../../../audio-analysis/docs/analysis.md). The response child maps those features to the backdrop model and geometry.

## Feature mapping

The child maps each coarse band power through the square root, a fixed gain, and a 0-to-1 clamp. Bass, mid, and treble use gain 4. The eight spectrum bands use gains 8, 6, 5, 5.5, 6.5, 7, 13, and 13 in order. It does not normalise each frame to its own peak. Silence therefore stays dark, and absolute level remains meaningful. The spectrum gains bring a typical mastered mix near half scale in each band. They were measured on system-output captures of commercial music, which falls off steeply above 2 kHz. Treble-heavy mixes still reach full scale in the top bands. [`response-child.luau`](../response-child.luau) owns the calibration.

Each curtain carries the spectrum by altitude. Bass lights the hem in the bass colour, mid lights the body, and treble lights the ray tops. At rest, the body and tops use the configured `low` and `high` colours. A band's colour takes over its zone as that band grows loud. The band level is the mean of its spectrum sub-bands, squared, so a quiet band leaves its zone near rest. Rays rise further as overall energy grows. Normalised bass raises curtain elevation, mid deepens folds and radius, and treble adds fine ripples and strand shimmer. Each contribution is weighted toward one curtain. A faint airglow in the mid colour lights the low sky and swells with the mid band.

## Source transitions

A source change crossfades response features, not PCM. The default crossfade duration is 1.2 seconds. Incoming and outgoing readers coexist during the transition, with at most two readers. The outgoing response is read only when it was available before the transition. Starting, idle, unavailable, and ended incoming sources settle the response toward zero. They do not select another source. Provider loss also settles response toward zero while autonomous rendering continues.

A hop's age is its sample distance from the snapshot's exclusive end frame divided by 48,000. The response weights the onset by this age and the crossfade duration. A publication is processed once. An empty publication never replays an onset. Generation changes or an analysis gap clear the prior onset history and waves. A transient often completes two or three adjacent analysis hops, so onsets in the same band within 1200 samples of the previous onset are one event. The child keeps the stronger hop. If an onset has no band, it is treated as a mid flare.

Bass, mid, and treble onsets produce separate local effects. A bass onset heaves the curtains up and outward and flashes the hem in the bass colour. The flash climbs into the body. It punches at the origin and decays with a time constant of about 0.12 seconds. It then ripples in both directions at 0.3 turns per second as narrow concentric rings that fade over the wave's 0.9-second life. Narrow rings prevent steady kicks from holding an entire curtain in the bass colour.

A mid onset ripples a slightly whitened mid-colour flare outward along the body at 0.16 turns per second and lifts the curtains briefly as it spreads. A treble onset swells over about 0.08 seconds rather than popping. It shoots nearby rays upward, flickers individual rays in the treble colour, and adds treble-coloured stars nearby. An onset restores a ribbon's full height and extent where it passes. An onset in a gap therefore raises a curtain rather than drawing a thin line. Waves are pooled per band, with at most four bass, eight mid, and eight treble waves. Frequent treble onsets cannot evict a bass heave. Bass waves last 0.9 seconds, mid waves 1.2 seconds, and treble waves 0.9 seconds.

## Spatial placement

Onsets land near the direction the viewer faces, quantised so they do not chase the head. The base consumer reads the head direction each frame. The response snaps it to the nearest twelfth of a turn and keeps that anchor until the view passes the sector edge by a further 15 percent of the sector width. Before a valid head direction arrives, the anchor faces -z, LÖVR's forward direction.

Each onset scatters about the anchor within a full width of 0.05 turns for bass, 0.08 for mid, and 0.16 for treble. The hop's sample end and its band seed the offset. A replayed publication therefore lands in the same place, and different bands struck by one transient start apart.

## Decisions

A screen-wide audio brightness response is rejected because it obscures the spatial effect and can create abrupt changes. Band features instead alter separate geometric parameters, and bounded onset waves carry local events. Every onset acts at a longitude rather than as a screen-wide brightness pulse.

Each band has its own hue, altitude, and onset action. A single colour ramp driven by loudness is rejected because it merges registers when several are active. Mapping the eight-band spectrum across the height of every curtain was rejected after offscreen renders of recorded music: adjacent bands formed horizontal rows that crossed the strands into a plaid, and the extreme band hues fell where the curtain feathers out, so only the mid hue showed. Giving each band a whole curtain was also rejected. Three stacked solid-colour curtains read as a flag and lost the glow of the original translucent gradient. The current design uses three coarse altitude zones with smooth falloffs and places the bass zone at the sharp, bright lower hem rather than in the feathered region.

A bass flash on the sky's horizon was rejected because it sat below the curtains as a detached stripe. Steady kicks held every bass-coloured effect on continuously when the whole swell took the bass colour. A fast decay of the whole flash fixed that behavior but removed the outward ripple. The colour therefore travels only in narrow rings, while the punch at the origin decays within a beat.

The steady band levels attack over 0.12 seconds rather than 0.06 seconds, because frame-to-frame level changes flickered the ray tops. Onsets carry transients instead.

Onsets previously anchored at the panel that played the selected process's audio, or at -z for system audio. That gave the environment a fixed front. Scattering events around the whole ring put most of them out of view. The current quantised head-facing anchor keeps events in view without following every head movement.

## Known gaps

Analysis and response tests use synthetic or recorded feature inputs. They do not establish live PipeWire behavior. Headset comfort, brightness under sustained loud input, stereo seams, and prolonged motion remain pending manual headset checks. See [rendering gaps](rendering.md#known-gaps) and [audio acceptance](../../../../../docs/dev/audio.md#acceptance).