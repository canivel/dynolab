# Workspace scene

## Silicon board

`silicon-board.jpg` was generated with the built-in OpenAI imagegen tool at 1536 × 1024 and encoded as JPEG at quality 88. It is conceptual hardware artwork, not an accurate teardown of a specific Apple chip or motherboard. Animated neural connections are anchored to its central die; component-level signal traces continue outward onto the board.

Generation prompt:

Use case: product-mockup. Asset type: cinematic scroll-through website scene, 1536x1024 landscape. Generate a hyperreal premium macro photograph of a laptop silicon circuit board viewed directly straight down, perfectly parallel to image plane, absolutely no perspective angle or rotation. One central large square silicon processor package on a black/dark green motherboard. The processor package centered exactly at image center, outer square package occupies x30% to70% and y20% to80%. Inside its package, a clean dark near-black square exposed silicon die occupies exactly x40% to60%, y35% to65% (so 307 by307 pixels). This die surface is very dark flat obsidian with delicate barely visible microcircuit grid; no lettering or logo. Surround it with intricate tiny gold contacts, graphite memory chips, capacitors, solder and green-gold traces radiating across the motherboard, realistic layer depth, sharp architectural grid of components. Board extends past all four edges, no empty background. Photoreal microelectronics materials, precise engineering detail, cinematic grazing warm gold light from left and restrained green light right, deep charcoal palette, no neon sci-fi fantasy, no text, no labels, no brands, no watermark. Usage: an animated neural network will be composited on central dark square die; scrolling zooms out from inside that die to reveal its processor package and then full motherboard. Keep the die centered and unobstructed, geometry axis-aligned. It represents conceptual Apple Silicon local inference hardware, not a specific manufacturer's exact board layout.

## Mac workspace

`mac-workspace.jpg` is an AI-generated illustrative workspace, created with OpenAI imagegen for this site. It is not an app screenshot or a photograph of a particular Mac. The actual Dyno captures live in `../screenshots/`.

Generated at 1536 × 1024, then encoded as JPEG at quality 86 for delivery. The canvas is composited inside the display; the display and photograph share a single scroll transform. No external image service is contacted by the page.

## Generation prompt

Generate a photorealistic cinematic editorial photograph for a premium Mac local-AI website, landscape 1536x1024, one single continuous scene. Straight-on eye-level view of an open space-black MacBook Pro sitting solidly on a wide dark walnut desk in a beautiful quiet minimalist creative workspace at dusk. Laptop screen faces camera absolutely straight on, no yaw, almost rectangular, screen glass perfectly flat uniform pure black with no reflections, no text, no UI, no art; we will composite animated content inside it. Important composition: entire laptop centered horizontally, laptop display glass occupies approximately x=30% to70% and y=24% to62% of the image, keyboard and trackpad below naturally foreshortened on desk. Lid thin black bezel, realistic camera notch, photoreal machined aluminum keyboard detail. Hardware is a large substantial focal subject. Background depth: dark softly out-of-focus olive charcoal plaster wall, architectural window light spilling in from the left; a warm small lamp in deep background right and soft green rim light, refined cinematic soft shadows. Foreground depth: dark blurred plant leaves just at far left edge, corner of a closed textured black notebook lower right, desk wood grain in foreground. Keep objects away from the screen and laptop, no person, no floating objects, no extra computer or screen. The environment fills all edges, coherent grounded contact shadows. Rich real materials, natural lens, restrained muted lighting, luxurious photography rather than neon sci-fi or 3D cartoon. No typography, logos, labels, or watermark. Exact use: viewer starts inside black display and scrolls backwards to reveal entire room around laptop, so screen framing and crisp black rectangle critical.

## Fixed 3D office scene

`office-overhead.jpg` and `office-background.jpg` are AI-generated conceptual workspace images. The overhead image supplies keyboard and desk textures; the background supplies the upright wall. They are not photographs of a specific Mac or office. The real app capture is applied to the 3D display.

The plant and notebook are modeled in `../office-props.js`, with procedural surface grain, curved leaves, ceramic pot, soil, rounded covers and layered page edges. All scene geometry stays fixed; scrolling moves only the camera. `mac-workspace.jpg` remains the static fallback.

## Research walkthrough (0.2.0)

`research-{inspect,compare,probe,sae}.png`, `research-walkthrough.gif`, and
`research-walkthrough.mp4` show native Dyno views of completed local
`mlx-community/Qwen1.5-0.5B-Chat-4bit` experiments. No numbers are simulated.
The sequence is a saved-results walkthrough, not a real-time screen recording.
The probe/SAE examples are the small sentiment demonstration in
`tests/lab_acceptance.py`, not safety benchmarks.

Render exported job JSON using `DYNO_LAB_RESULT_FIXTURE=<file> Dyno --snapshot
<folder> --lab-only`, with folders named inspect, compare, probe, sae. Then run
`scripts/build-research-media.py <folder-root>` (Pillow and imageio-ffmpeg).
The packaging step crops to the result panel to exclude machine identities,
private history, and filesystem paths. Site video is user-controlled and has a
static poster; the GIF is used in the GitHub README.
