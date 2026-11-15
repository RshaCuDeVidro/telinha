# telinha themes

<sub>[🇺🇸 English](THEMES.md) · [🇧🇷 Português](THEMES.pt.md)</sub>

Each theme is a `.kdl` file (the [KDL](https://kdl.dev) format: nodes, values and
blocks in braces). The ones that ship with telinha live in
[`src/assets/temas/`](../src/assets/temas); yours go in the `temas` folder of the
configuration:

| System | Folder |
|---|---|
| Windows | `%APPDATA%\telinha\temas` |
| Linux | `~/.config/telinha/temas` |

The easiest way: **Settings → Appearance → Make my own from this one**. telinha
writes the theme you're using, with every color, to a new file (`meu-pwnd.kdl`,
for example), switches to it and opens the folder. Change what you want and save:
**telinha applies it by itself** as soon as you switch back to its window (or
within 2 seconds while the Appearance page is open). A file with the same id as
a built-in theme replaces the built-in one.

If something is wrong, the Appearance page shows the file, the line and what
couldn't be understood.

## Annotated example

```kdl
// everything after // is a comment; /- turns off the next node
theme "my-theme" name="Meu tema" name-en="My theme" author="me" \
    description-en="Shows up when the mouse is over the theme card."

colors {
    // the seven base colors: the rest of the palette comes from them
    bg        "#0B1218"   // the darkest background (home screen, behind everything)
    panel     "#101B23"   // side panels
    accent    "#34D3B4"   // accent: buttons, selection, lit borders
    text      "#DDEBF0"
    success   "#34D399"   // green (on, live)
    danger    "#F87171"   // red (leave, stop, error)
    accent-2  "#8B7CFF"   // second color: gradients and the neon glow

    // any other part can be replaced (see the list below)
    hover     "alpha(@accent, 0.09)"   // @name = another color in this block
    selected  "mix(@panel, @accent-2, 0.3)"
    border    "alpha(@accent, 0.12)"
}

// home screen background (4 corners: ↖ ↗ ↘ ↙) and the still stage pattern
background gradient="#0B1218 #0F2A2A #0B1218 #17123A" pattern=dots \
    pattern-color="alpha(#34D3B4, 0.05)" pattern-size=24

// text, titles and numbers/code; size = base text size
fonts ui="Atkinson Hyperlegible" heading="Fira Code" mono="Fira Code" size=15

metrics radius=10 border=1   // corners (px) and border thickness
effects glow=0.6              // neon glow: 0 turns it off, 1 is strong
```

## Colors

Formats: `"#rgb"`, `"#rrggbb"`, `"#rrggbbaa"`, `"rgb(10, 20, 30)"`,
`"rgba(10, 20, 30, 0.5)"`, `"white"`, `"black"`, `"transparent"`, and the functions:

| Function | What it does |
|---|---|
| `alpha(color, a)` | the same color with opacity `a` (0 to 1, or `40%`) |
| `mix(a, b, t)` | blend: `t` = 0 gives `a`, 1 gives `b` |
| `lighten(color, t)` | lighter (blend with white) |
| `darken(color, t)` | darker (blend with black) |
| `@name` | another color in the same `colors` block |

Every key the `colors` block accepts:

| Key | Where it shows |
|---|---|
| `bg`, `panel`, `surface`, `elevated`, `float`, `input`, `chat-input` | backgrounds: home screen, panels, stage, cards and the control bar, tooltips and menus, fields |
| `text`, `heading`, `muted`, `faint` | text, titles, secondary text and the faintest |
| `accent`, `accent-hover`, `accent-active`, `accent-2` | accent and its variations; the second gradient color |
| `success`, `success-hover`, `success-active` | green |
| `danger`, `danger-hover`, `danger-active`, `live`, `leave` | red, "live" and the leave button background |
| `warning` | yellow (warnings) |
| `button`, `button-hover`, `button-active` | secondary buttons |
| `hover`, `selected`, `border`, `check`, `scroll`, `scroll-hover`, `shadow`, `overlay` | mouse over, selection, outlines, marks, scrollbar, shadows |

## Fonts

`ui` (text), `heading` (titles) and `mono` (numbers and code) accept:

- `"Inter"`: the default, clean.
- `"Atkinson Hyperlegible"`: made for low vision (look-alike letters such as I,
  l, 1, O and 0 don't get mixed up). The easiest to read.
- `"Fira Code"`: monospaced, terminal look.

Anyone who finds a theme's font hard to read can change it just for themselves in
**Settings → Appearance → Text font**, without touching the theme, and make the
text bigger in **Text size**.

## Background and effects

- `background gradient="..."`: 1, 2 or 4 colors (corners ↖ ↗ ↘ ↙).
- `pattern=`: `none`, `grid`, `dots` or `scanlines`, with `pattern-color` and
  `pattern-size` (8 to 128). It's a still drawing: no GPU cost.
- `metrics radius=` (corners in px, 0 = square) and `border=` (border thickness).
- `effects glow=`: strength of the neon glow around buttons, screens and notices.
- `effects gradient=0`: a flat theme. Gradients become the base color and the neon edge line goes away (Husky, the default, is like that).
- `effects terminal=0`: drops the terminal look: the `>` before headers and the viewfinder corners around screens.

Animations (buttons lighting up, tabs sliding) stop by themselves once they
arrive: an idle telinha doesn't redraw. Anyone who prefers no motion can turn on
**Reduce motion** in Appearance (economy mode turns it off too).
