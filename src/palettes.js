// Six sand colours + a glitter colour, plus the liquid and air the sand sits in.
// liquidAlpha: how much the liquid tints what's behind the glass (0 = water-clear).
// Dark palettes use a dark, mostly opaque liquid, as some real frames do.
// They live in core/palettes.json, shared with the native apps.
export const palettes = await (await fetch(new URL('../core/palettes.json', import.meta.url))).json();
