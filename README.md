# zen-mode.hx

a zen-mode toggle for the [steel-enabled helix fork](https://github.com/mattwparas/helix), inspired by [folke/zen-mode.nvim](https://github.com/folke/zen-mode.nvim). centers the active window with even padding on both sides and hides the gutters.

## install

install as a local steel package with forge, then require it from your steel init:

```sh
git clone https://github.com/notnmeyer/zen-mode.hx
forge install ./zen-mode.hx
```

this copies the package into `~/.local/share/steel/cogs/zen-mode/`. then add the require to `~/.config/helix/init.scm`:

```scheme
(require "zen-mode/zen-mode.scm")
```

restart helix to pick it up.

> for development: symlink the cog to your checkout so edits apply without reinstalling — `mise run link`. `mise tasks` lists the rest (install, uninstall, require, setup, status).

## usage

- `:zen-mode` — toggle zen mode on/off.
- `space z` — same toggle, bound by the plugin in normal mode.

`space z` is unbound in default helix normal mode. if you have your own binding there, the plugin's binding wins — remove the `keymap` line at the bottom of `zen-mode.scm` and bind `:zen-mode` yourself (in `config.toml` under `[keys.normal]`, or via your own `keymap` call).

## configuration

tunables at the top of `zen-mode.scm`:

| variable | default | meaning |
|---|---|---|
| `*zen-width*` | `0.65` | content width when zen is on. a fraction `< 1` is a proportion of the terminal width (scales at every size); a number `>= 1` is an absolute column count. |
| `*zen-max-width*` | `120` | hard cap on the content band, in columns. keeps a fractional `*zen-width*` from growing the band past this on wide screens, so text stays visually centered instead of hugging the left edge of a too-wide band. set to `#f` to disable the cap. |
| `*zen-hide-gutters*` | `#t` | hide the gutters while zen is on. set to `#f` for centering only. |
| `*zen-blank-statusline*` | `#f` | empty the statusline while zen is on. the row can't be removed (it's structural), so this leaves a bare bar in the statusline theme color, not a hidden row. |
| `*zen-poll-ms*` | `120` | how often (ms) to poll for terminal resizes while zen is on, so centering follows a resize live. `0` disables polling (resizes then only re-center on the next keypress). must be a whole number. |

padding is `(total_width - content_width) / 2` per side. with the default `0.65`, content is 65% of the terminal width, so centering is visible at every size (mirrors zen-mode.nvim's `width = 0.65`) — but `*zen-max-width*` caps the band at `120` cols, so past ~185 cols wide the band holds and the padding keeps growing evenly. that keeps the text centered on wide screens instead of hugging the left edge of an ever-widening band. set `*zen-max-width*` to `#f` for the pure fraction, or set `*zen-width*` to e.g. `120` to pin an absolute column width directly.

## notes

- **single window only.** zen mode always shows exactly one window. opening a split (`vsplit`/`hsplit`/`goto_file_vsplit`) while zen is on turns it off automatically, and you can't turn zen on while a split is open — close the other windows first. the engine exposes no view count, so window state is inferred from command names plus the focused view's width and height; the common split/close paths are covered.
- **statusline.** by default zen leaves the statusline functional — it's a structural row that can't be removed via the clip or config api. set `*zen-blank-statusline*` to empty its content, which leaves a bare bar in the statusline theme color (recoloring it to blend in isn't possible cleanly through the steel theme api).
- **resize.** there's no window-resize hook, so a timer polls every `*zen-poll-ms*` and re-centers without a keypress. it settles ~2 ticks after a resize (a debounce that avoids clipping to a half-drawn frame).
- **gutters restore.** only the gutter *layout* is saved/restored; custom `line-numbers` options revert to defaults after a toggle cycle.
