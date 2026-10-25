---
name: ip-as-logo
description: Generate extremely simple, cute, personified square character images with rounded heavy forms, a subject-derived color system, and a dominant lower-corner composition. Use when creating an animal, creature, robot, ghost, plant, object, or other character image, including when the agent should infer three product-relevant directions and propose six independent candidates for approval.
---

# IP as Logo

Create the simplest possible cute IP character: a compact, lovable symbol that remains recognizable at `32 × 32`, not a detailed character illustration.

## Workflow

1. Parse the request for an explicit IP subject and available product context. Do not ask the user to choose a color mode unless they explicitly want to control it.
2. When the user has not specified an IP subject and the current workspace is a product repository, inspect relevant read-only context before asking questions. Prefer the README, product docs, package or app metadata, landing-page copy, manifests, and design tokens. Treat context as sufficient when the product purpose, primary audience, and intended personality can be inferred with reasonable confidence.
3. When product context is insufficient, ask one consolidated round of background questions covering what the product does, who it serves, and how it should feel. Do not start a second background questionnaire. Continue with the best supported interpretation after the answer.
4. Once context is sufficient, always present three concise directions before generation and explicitly propose generating six independent candidates in one batch. Do not generate until the user agrees, unless the current request already explicitly authorizes six outputs or asks the agent to proceed without another confirmation.
5. Choose the three proposed directions deliberately:
   - When the user explicitly specifies an IP subject, keep that subject and propose three distinct design treatments based on silhouette treatment, secondary color region, defining feature, or personality emphasis.
   - When the user does not specify an IP subject, propose three genuinely different IP subjects or metaphors. Tie each one to a different product attribute or brand promise; do not return three arbitrary animals with no rationale.
6. Interpret the user's response exactly:
   - If the user accepts all three directions and the six-image proposal, generate two independent variants per direction and label them `A1`, `A2`, `B1`, `B2`, `C1`, and `C2`. Assign `A1`, `B1`, and `C1` to the lower-left and `A2`, `B2`, and `C2` to the lower-right so every direction is tested once from each side.
   - If the user selects one direction but accepts six images, generate six controlled variants of that direction and label them `A1` through `A6`. Assign odd-numbered variants to the lower-left and even-numbered variants to the lower-right.
   - If the user rejects the proposed quantity, directions, or distribution, follow the user's replacement instructions without arguing for the default.
   - For any other even default batch size, split candidates equally between lower-left and lower-right. For an odd batch, assign the extra candidate to either side deliberately and record the imbalance. Do not use bottom-center unless the user explicitly requests it.
7. Before generation, lock each subject's recognizable color identity. For an animal, write its natural dominant family, defining broad markings, small natural accents, a **Bright Tonal** or **Soft Neutral Pastel** mapping, and a same-family background pair. For a non-animal character, apply the same hierarchy to its recognizable intrinsic material or cultural color identity rather than inventing a product-theme recolor. Follow an explicit user request for a fantasy recolor or another color count. Keep this color contract consistent across variants of the same subject.
8. Before generation, require a top-tier image model: prefer GPT Image 2; also support Seedance 5.0 Pro, Nano Banana Pro (Gemini Image Pro), or Nano Banana 2 (Gemini Image Flash). If none is available, ask the user to enable a suitable tool or provide its API key. Never fall back to SVG generation. Use another available image model only with the user's explicit consent, and warn that its quality may not match the recommended models. Do not fabricate generated results.
9. If the runtime supports subagents, parallelize the six independent candidates up to the available concurrency. Give every subagent the same product brief, shared constraints, and one assigned direction or variant; run remaining candidates in subsequent waves when capacity is limited. If subagents are unavailable, generate the candidates through separate image-generation calls or jobs.
10. A user-supplied palette is a constraint only when they state it is one. Otherwise, derive the background from the mapped dominant subject family; never independently choose a product-theme, complementary, or batch-rotation background. Treat historical palettes and examples as inspiration rather than an allowlist unless the user says otherwise.
11. Abstract each subject using the complexity budget below. Generate every candidate as a separate full-resolution square asset; never ask an image model to compose a contact sheet, grid, or multi-image sheet. Do not use previous candidates as image references when testing prompt-only reproducibility.
12. Treat each batch as a one-pass creative draw. Generate every requested candidate once, then preserve and deliver every returned result as-is. Do not inspect outputs to block delivery, classify them as recommended or non-recommended, retry them automatically, or repair them with post-processing.
13. Preserve and label every generated result. Report every label, IP direction and rationale, assigned corner, saved path, prompt/color mapping, and dimensions. Present all results together; generate refinements or replacements only when the user explicitly asks for another draw.

When proposing directions before generation, describe each in one compact line: `<IP subject> — <product connection> — <defining silhouette>`. End with a direct proposal to generate six images using the distribution above. Do not turn the discovery phase into a long branding workshop unless the user asks for one.

## Complexity budget

- Build one dominant continuous outer silhouette from roughly `4–7` large basic geometric shapes. Merge or delete any shape that does not carry identity, expression, or recognition.
- Use at most one species-defining feature: for example, one large pouch beak, one pair of curled horns, or one broad visor.
- Use at most two broad internal color regions, plus only the small natural accent or neutral region essential to subject recognition. Keep the face to two eyes and, only when needed for the expression, one tiny mouth. Omit eyebrows, highlights, nostrils, texture, outlines, and decorative marks unless essential for recognition.
- Remove repeated feathers, scales, fur tufts, armor plates, buttons, screws, numbers, labels, and other illustrative detail.
- Make simplification, cuteness, and an endearing baby-like personality the decisive qualities. Favor a large head, compact proportions, soft cheeks, widely spaced simple eyes, and a calm friendly expression when appropriate to the subject.
- Require a readable black silhouette and recognizability at `32 × 32`. If a feature disappears or becomes noise at that size, enlarge, merge, or remove it.

## Shape language and composition

- Use thick, rounded, weighty contours and broad color masses.
- Forbid sharp corners, pointed ears or beaks, needle-like tails, thin antennae, thin smiles, narrow gaps, and acute flame or feather tips. Replace every necessary tip with a visibly blunt rounded end.
- Show both members of paired identifying features, such as ears, horns, wings, gills, or bells.
- Show the character upright and emerging from the assigned lower-left or lower-right corner, filling about `85–95%` of the canvas so the IP remains visually dominant.
- Cropping at the bottom or assigned side is welcome when it strengthens the sense of emerging from that corner, but do not prescribe exact edge contact or a fixed crop.
- Never center or bottom-center the character unless the user explicitly requests it.
- Preserve both members of paired identifying features within the visible composition.
- Keep the artwork upright; never rotate the canvas or tilt the main mark without an explicit request.

## Simplicity and visual treatment

- Start from large, clean semantic shapes and the strongest possible simple silhouette. The character should be understood immediately, before any internal feature is noticed.
- Prefer fewer, larger, softer forms over extra definition. Do not add a feature merely to explain anatomy or material.
- Keep facial marks tiny, simple, and subordinate. Do not add glossy hotspots or detailed cavity rendering to eyes, mouths, noses, or other small features.
- Keep the background as one clean full-bleed tonal field, without scenery, texture, halo, vignette, or lighting variation. It may include one sparse, extremely faint, same-source tone-on-tone watermark family only when it does not compete with the silhouette.
- Ask for the subtle dimensional effect only with the single sentence used in the Prompt skeleton. Do not expand it into numerical strength or instructions for gradients, highlights, or shadows. Incidental gradients, shading, or mild dimensionality returned by the generator are acceptable and must not trigger filtering or retrying.
- Keep the requested visual direction graphic and simple rather than asking for clay, inflatable, plastic, plush, toy-like, or photorealistic rendering.

## Color and canvas

- Treat color as a locked subject hierarchy, never as a reward for the product theme, personality, or batch variety. Count hue families rather than lightness variations.
- For every animal, prepare a **Natural Color-Spectrum Lock** before concepting: (1) the species or approved variant's natural dominant family, (2) its few defining broad regions, (3) its only necessary small natural accents, (4) a Bright Tonal or Soft Neutral Pastel mapping of those same families, and (5) a background pair: a lighter, darker, or less saturated derivative of the mapped dominant plus a same-hue watermark tone at roughly `3–6%` value contrast. Use the broadly recognized appearance when a variant is unspecified.
- For a non-animal subject, make the equivalent five-part lock from its recognizable intrinsic palette. Never use the product theme to replace that identity without explicit approval.
- **Bright Tonal** is for a naturally compatible clear, energetic subject: clean and brighten the existing hue family (for example fox rust to clean coral-rust, frog green to clean leaf green, or whale blue-gray to clean blue-gray) without changing its hue identity. Retain broad defining natural support in its correct region and keep accents subordinate.
- **Soft Neutral Pastel** is only for subjects whose recognizable spectrum supports luminous beige, ivory, clean gray, taupe, or fresh muted olive. Keep neutrals luminous and clean—never khaki, moss-brown, muddy, dusty, vintage, or washed out. Do not force this mode onto an incompatible naturally red, blue, black-and-white, or otherwise distinct subject.
- Preserve the hue identity and placement of broad identity markings. Simplify local variation into calm color masses, but do not recolor eyes, muzzle, belly, paws, ears, tail, or the defining feature into separate novelty colors. Permit a second chromatic family or broad neutral only when subject recognition requires it.
- Derive the background only after mapping the subject: use a lighter or less saturated natural-dominant derivative behind a saturated or dark subject; use a moderately deeper tonal derivative behind a pale subject; use a high-key neutral with a faint borrowed natural tint behind a high-contrast neutral subject. Build separation through value and saturation, not opposing hues. Never use complementary, near-complementary, neon-clash, independently selected, or high-chroma competing backgrounds unless those families naturally define the subject or the user explicitly requests them.
- Add one to three large, sparse, soft same-source watermark marks only on a separated background, derived from the subject's defining silhouette or movement. Keep them `3–6%` apart in value from the base field, without a new hue, bevel, gloss, cast shadow, readable glyph, generic pattern, or focal contrast. Omit them when they would harm recognition.
- Freeze the color contract across all variants of the same subject. Never rotate palettes merely to make a batch diverse.
- Name the derived background color directly. Ask for it to fill every open area and unoccupied corners while the assigned emergence corner is occupied by the character. Do not use image-mode terms such as `opaque`, `alpha`, or `transparency` in the generation prompt.
- Generate a direct `1:1` square with square outer corners. Request approximately `1536 × 1536`; accept and preserve a native `1254 × 1254` result when that is the service output limit. Never resample merely to reach the requested number.

## Prompt skeleton

### Route constraints by generator capability

Determine the available image model and its actual tool schema from runtime metadata, configured provider documentation, or an explicit user statement. Do not guess a model or invent unsupported parameters.

Describe the requested visual as an image only. Never tell the image generator that the image is a `logo`, `brand mark`, `app icon`, `icon asset`, or intended for any of those uses. Do not prepend use-case or asset-type scaffolding that reveals such a use. This rule applies only to the generation prompt; the surrounding user conversation and Skill name may still describe the broader project.

- For modern instruction-following image models such as GPT Image 2, Nano Banana Pro, Nano Banana 2, and Seedance 5.0 Pro, keep the complete positive prompt and express the minimal exclusions as the natural-language `Constraints:` line inside the main prompt. Do not create a separate negative-prompt payload for these models.
- For an older model or runtime that explicitly exposes a dedicated parameter such as `negative_prompt`, keep every positive prompt line unchanged and deliver the minimal exclusions through that dedicated parameter in the syntax required by the available adapter. Omit the natural-language `Constraints:` line from the main prompt to avoid duplicating the same exclusions in both channels.
- For an older model without a dedicated negative-prompt parameter, follow its documented prompt format. When only one prompt string is available, retain the concise natural-language `Constraints:` line.
- Record the model or provider, the detected constraint-delivery mode (`main-prompt constraints` or `dedicated negative parameter`), and the exact constraint text or payload in the generation report.

When a dedicated legacy negative-prompt parameter is available, adapt this minimal payload to its required syntax:

```text
text, literal watermark, borders, frames, cards, presentation masks, extra subjects, scenery, thin fragile lines, sharp tips, photorealistic materials, strong three-dimensional rendering, external cast shadows
```

For modern instruction-following models and single-prompt interfaces, use the following complete prompt:

```text
Create one complete full-bleed 1:1 square image.
Background: fill the entire square with the derived solid <background>, a lighter, darker, or less saturated derivative of the mapped dominant subject family. Keep <background> visible in every open area and in the corners not occupied by the character; the assigned emergence corner must be occupied by the character. When it does not harm recognition, add one sparse family of one to three large, broad, soft-edged marks derived only from the subject's defining silhouette or movement, as an extremely faint same-hue tone-on-tone watermark at roughly 3–6% value contrast; it must never read as a logo, literal watermark, second symbol, pattern, or focal point.
Subject: place one extremely simplified, cute, endearing <subject> IP character on the background, reduced to one soft rounded continuous silhouette and one defining feature.
Complexity: use only 4–7 large basic shapes and at most two broad internal color regions, plus only the small natural accent or neutral region essential to recognition. Use two simple eyes and add one tiny mouth only when it helps the expression. Remove every nonessential line, outline, anatomical detail, texture, and decoration. Keep the character readable at 32 × 32.
Color behavior: lock the subject's recognizable natural or intrinsic color spectrum before using product context. For an animal, name its natural dominant family, defining broad markings, necessary small natural accent, and either a Bright Tonal or Soft Neutral Pastel mapping of those same families. Bright Tonal cleans and brightens compatible natural hues without changing their identity; Soft Neutral Pastel is permitted only when luminous beige, ivory, clean gray, taupe, or fresh muted olive is naturally compatible. Preserve required broad identity markings in their correct regions, consolidate minor variation into calm color masses, and do not introduce fantasy recoloring or novelty colors for individual features. Derive the background from the mapped natural dominant: lighter or less saturated behind a saturated or dark subject, moderately deeper behind a pale subject, or high-key neutral with a faint borrowed natural tint behind a high-contrast neutral subject. Create separation through value and saturation rather than opposing hues. Do not use independent product-theme colors, complementary or near-complementary clash, neon conflict, dirty khaki, moss-brown olive, dusty vintage cast, or washed-out contrast unless explicitly requested. Keep the color contract unchanged across variants of the same subject.
Composition: keep the character upright and emerging from the assigned <lower-left or lower-right>, filling about 85–95% of the square so it remains visually dominant. Cropping at the bottom or assigned side is welcome when it strengthens the corner emergence. Preserve both paired identifying features. Never center or bottom-center the character.
Style: make simplification, cuteness, and lovable baby-like appeal the strongest qualities. Use large soft forms, compact proportions, thick rounded contours, and an ultra-clean graphic treatment. Prefer one clear shape over several explanatory details. Add an extremely, extremely subtle, almost imperceptible sense of depth through a barely-there neo-skeuomorphic treatment.
Finish: show only the character on the full-canvas background, with clean surfaces and normal square outer corners.
Constraints: Use no text, readable logo, literal watermark, borders, frames, cards, or presentation masks. Include one character only, with no extra subjects or scenery. Use no fragile lines, sharp tips, unnecessary outlines, tiny details, or decorative marks. Add no photorealistic material, dramatic bevel, glossy hotspot, deep occlusion, extrusion, strong three-dimensional rendering, or external cast shadow. Keep the background free of texture, vignette, lighting variation, scenery, generic patterns, and decoration; allow only the specified extremely faint same-source tone-on-tone marks.
```

## Delivery behavior

- Treat generation as a stochastic draw, not a conformance test.
- Generate the requested number of independent candidates once and deliver every returned image.
- Do not inspect or report alpha, transparency, or background mode by default.
- Do not block delivery, rank candidates as compliant or non-compliant, mark them as recommended or non-recommended, or automatically retry any result because of its background, colors, detail, composition, gradient, shading, or dimensionality.
- Do not post-process a result to make it appear more compliant. If the user later requests another direction or replacement, generate a new independent candidate in response to that explicit request.
