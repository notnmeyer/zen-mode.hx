;; zen-mode.scm — a zen-mode toggle for the Steel-enabled Helix fork.
;;
;; Toggling zen mode on centers the active pane on screen with even padding on
;; both sides (like folke/zen-mode.nvim) and hides the gutters + statusline.
;; Toggling off restores everything.
;;
;; The centering uses the editor clipping primitive (set-editor-clip-left!/right!)
;; which clips the editor render rect before the view tree lays out, so the pane
;; genuinely reflows into the narrower area and the outer columns paint as theme
;; background.

(require "helix/editor.scm")
(require "helix/configuration.scm")
(require "helix/keymaps.scm")
(require "helix/misc.scm")
(require "helix/components.scm") ;; area-width

(provide zen-mode zen-on zen-off)

;; --- tunables ---------------------------------------------------------------

;; content width when zen is on (like zen-mode.nvim's `width`):
;;   * a fraction < 1  -> that proportion of the terminal width (scales at every
;;                        size, so padding is always visible)
;;   * a number >= 1   -> an absolute column count
(define *zen-width* 0.65)
;; whether to hide the gutters while zen is on
(define *zen-hide-gutters* #t)
;; how often (ms) to poll for terminal resizes while zen is on, so centering
;; follows a window resize without waiting for a keypress. 0 disables polling
;; (resizes then only re-center on the next command).
(define *zen-poll-ms* 120)

;; --- session state ----------------------------------------------------------

(define *zen-on?* #f)
;; best-effort "more than one window is open" flag. the engine exposes no view
;; count, so we infer it (see the post-command hook): a split command sets it,
;; and it clears when the focused view returns to the full single-window size.
;; used to refuse turning zen on while split.
(define *zen-multi-window?* #f)
;; the focused view width/height observed while single-window and unclipped; the
;; reference used to notice when we're back to one window after a split closes.
;; we track BOTH dims: a vsplit shrinks width, an hsplit shrinks height, so width
;; alone can't tell an hsplit from a single window (each hsplit child keeps the
;; full width). only when both are back at the reference are we truly single.
(define *zen-full-width* #f)
(define *zen-full-height* #f)
;; per-side padding currently applied
(define *zen-cur-pad* 0)
;; the true total editor width, captured while unclipped. this is the source of
;; truth for the pad calculation. reconstructing it from a clipped view races
;; with the render loop (the view area only reflects a new clip on the *next*
;; frame), so we measure it once when the clip is 0 and cache it.
(define *zen-total* #f)
;; debounce for resize detection (see zen-reapply!)
(define *zen-pending-total* #f)
;; original gutter layout, captured on toggle-on so we can restore it
(define *zen-saved-gutters* #f)

;; --- helpers ----------------------------------------------------------------

;; read the focused view's inner width, or #f if there's no focused buffer
(define (zen-inner-width)
  (let ([area (editor-focused-buffer-area)])
    (and area (area-width area))))

;; focused view's height, or #f if there's no focused buffer
(define (zen-inner-height)
  (let ([area (editor-focused-buffer-area)])
    (and area (area-height area))))

;; keep our best-effort window-state view current from the focused view size:
;;   * single-window & unclipped -> record the reference full width + height
;;   * multi-window & both dims back at the reference -> we're single again
;; safe to call anytime; only reads size and updates the two flags. requiring
;; both dims is what catches hsplit recovery: an hsplit keeps full width, so a
;; width-only check would falsely clear the flag while the hsplit is still open.
(define (zen-refresh-window-state!)
  (let ([w (zen-inner-width)]
        [h (zen-inner-height)])
    (when (and w h)
      (cond
        [(and (not *zen-multi-window?*) (= *zen-cur-pad* 0))
         (set! *zen-full-width* w)
         (set! *zen-full-height* h)]
        [(and *zen-multi-window?* *zen-full-width* *zen-full-height*
              (>= w *zen-full-width*) (>= h *zen-full-height*))
         (set! *zen-multi-window?* #f)]))))

;; the true total width, only trustworthy when no clip is applied (cur-pad = 0),
;; because then the view area is the full width. returns #f if unreadable.
(define (zen-measure-total)
  (and (= *zen-cur-pad* 0) (zen-inner-width)))

;; desired content width in columns for a given total width, resolving
;; *zen-width* as a fraction (< 1) or an absolute column count (>= 1). always
;; clamped to the available width.
(define (zen-content-width total)
  (let ([w (if (< *zen-width* 1)
               (inexact->exact (floor (* total *zen-width*)))
               (inexact->exact (floor *zen-width*)))])
    (min total (max 1 w))))

;; per-side padding for a given total width. never returns negative.
(define (zen-pad-for total)
  (max 0 (quotient (- total (zen-content-width total)) 2)))

(define (zen-apply-pad! pad)
  (set-editor-clip-left! pad)
  (set-editor-clip-right! pad)
  (set! *zen-cur-pad* pad))

;; --- gutter hide / restore --------------------------------------------------
;;
;; We hide the gutters while zen is on. Setting gutters uses the generic
;; serde-based `set-option!` (the typed `gutters` config setter takes an opaque
;; Rust struct that can't be constructed from Steel). get-config-option-value
;; returns JSON-shaped values that set-option! accepts back.
;;
;; We save only the gutter `layout` list (an array of names): the full struct
;; round-trips badly because line-numbers.min-width comes back as a float (3.0)
;; that won't deserialize into a usize. The layout array restores the visible
;; gutters, which is what matters here. Side effect: because only the layout is
;; restored, a toggle cycle resets any custom line-numbers.min-width back to the
;; default (3) — restoring it would need an int through the same setter the float
;; round-trip rules out.
;;
;; The statusline is intentionally left alone. It's a structural row that can't
;; be removed via the clip or config API — blanking its content just leaves an
;; empty bar, and recoloring it to blend in isn't possible cleanly (the Steel
;; theme API can't restore the original theme and corrupts other scopes). So we
;; keep it fully functional in zen mode.

(define (zen-hide-gutters!)
  (let ([g (get-config-option-value "gutters")])
    (set! *zen-saved-gutters* (and (hash? g) (hash-try-get g 'layout))))
  ;; empty gutter layout -> no gutters
  (set-option! "gutters" '())
  (update-configuration!))

(define (zen-restore-gutters!)
  ;; restore gutters from the saved layout list (falls back to nothing if unset)
  (when (list? *zen-saved-gutters*)
    (set-option! "gutters" *zen-saved-gutters*))
  (update-configuration!))

;; --- public entry points ----------------------------------------------------

;;@doc
;; Turn zen mode on
(define (zen-on)
  (cond
    [*zen-on?*
     (set-status! "zen already on")]
    [else
     ;; re-check window state first: :wonly / :wclose typed at the prompt don't
     ;; fire post-command, so the flag may be stale until we look at the width now.
     (zen-refresh-window-state!)
     (cond
       ;; zen only ever shows one window
       [*zen-multi-window?*
        (set-status! "zen-mode: close other windows first")]
       [else
        ;; measured while unclipped (cur-pad is 0 here), so this is the true width
        (let ([total (zen-measure-total)])
          (cond
            [(not total)
             (set-status! "zen-mode: no focused buffer")]
            [else
             (set! *zen-total* total)
             (zen-apply-pad! (zen-pad-for total))
             (when *zen-hide-gutters* (zen-hide-gutters!))
             (set! *zen-on?* #t)
             (zen-start-polling!)
             (set-status! "zen on")]))])]))

;;@doc
;; Turn zen mode off
(define (zen-off)
  (zen-apply-pad! 0)
  (set! *zen-total* #f)
  (set! *zen-pending-total* #f)
  (when *zen-hide-gutters* (zen-restore-gutters!))
  (set! *zen-on?* #f)
  (set-status! "zen off"))

;;@doc
;; Toggle zen mode
(define (zen-mode)
  (if *zen-on?* (zen-off) (zen-on)))

;; --- keep centering correct across terminal resize --------------------------

;; there is no window-resize hook, but post-command fires after every command
;; and a resize triggers a redraw cycle.
;;
;; padding is always derived from the cached *zen-total* (never from the live
;; clipped view area, which lags the clip by one render and would compound —
;; that lag was the "very narrow column" bug).
;;
;; to pick up a genuine terminal resize we reconstruct the total from the
;; rendered view as inner + 2*cur-pad. but right after we change the clip, the
;; view is one frame stale, so the reconstruction is briefly wrong. we tell the
;; two apart with a one-frame debounce: a stale frame is transient and won't
;; repeat, whereas a real resize produces the same new reconstruction on the
;; next call too. so we only adopt a changed total after seeing it twice in a
;; row.
(define (zen-reapply!)
  (let ([inner (zen-inner-width)])
    (when (and inner *zen-total*)
      (let ([reconstructed (+ inner (* 2 *zen-cur-pad*))])
        (cond
          ;; matches cache: everything is in sync, clear any pending guess and
          ;; make sure the pad matches (covers the first settled frame).
          [(= reconstructed *zen-total*)
           (set! *zen-pending-total* #f)
           (let ([pad (zen-pad-for *zen-total*)])
             (unless (= pad *zen-cur-pad*)
               (zen-apply-pad! pad)))]
          ;; a changed reconstruction seen twice in a row -> real resize.
          [(equal? reconstructed *zen-pending-total*)
           (set! *zen-total* reconstructed)
           (set! *zen-pending-total* #f)
           (let ([pad (zen-pad-for *zen-total*)])
             (unless (= pad *zen-cur-pad*)
               (zen-apply-pad! pad)))]
          ;; first sighting of a changed value: remember it, act next frame.
          [else
           (set! *zen-pending-total* reconstructed)])))))

;; --- resize polling ---------------------------------------------------------

;; the post-command hook only re-centers on a keypress, so a terminal resize
;; sits at the old padding until you type. to follow resizes live we run a
;; self-rescheduling timer callback while zen is on. it drives the same
;; zen-reapply! (debounce included) every *zen-poll-ms* and stops itself when
;; zen turns off. the delayed callback runs as a local job, which triggers a
;; redraw, so the re-center is applied without any input.
;;
;; a generation counter guards against stacking multiple tickers if zen is
;; toggled on/off/on quickly: each start bumps the generation and only the
;; newest ticker keeps looping.
(define *zen-poll-gen* 0)

;; the delay must reach enqueue-thread-local-callback-with-delay as an exact
;; integer: its rust side does `delay.int_or_else(|| panic!(..))` and a float
;; panics the whole editor. floor whatever the tunable is set to (a fraction is
;; a config mistake, not a sub-ms poll) so a stray 0.5 can't crash helix.
(define (zen-poll-delay)
  (inexact->exact (floor *zen-poll-ms*)))

(define (zen-poll-tick my-gen)
  (when (and *zen-on?* (= my-gen *zen-poll-gen*))
    (zen-reapply!)
    (enqueue-thread-local-callback-with-delay
     (zen-poll-delay)
     (lambda () (zen-poll-tick my-gen)))))

(define (zen-start-polling!)
  (when (> (zen-poll-delay) 0)
    (set! *zen-poll-gen* (+ *zen-poll-gen* 1))
    (let ([my-gen *zen-poll-gen*])
      (enqueue-thread-local-callback-with-delay
       (zen-poll-delay)
       (lambda () (zen-poll-tick my-gen))))))

;; --- single-window enforcement ----------------------------------------------

;; zen mode only ever shows one window. the engine exposes no view count, so we
;; infer window state in the post-command hook:
;;
;;   * a split command means we now have >1 window -> disable zen and set the
;;     multi-window flag.
;;   * while single-window and unclipped we record the focused view's width as
;;     the reference full width.
;;   * while multi-window, once the focused view's width grows back to that full
;;     reference (the other split(s) closed, however they were closed) we clear
;;     the flag.
;;
;; the width-based clear is needed because `:wonly`/`:wclose` typed at the prompt
;; don't fire the post-command hook (only their keybound static forms do), so we
;; can't rely on catching the close command by name.
;; both spellings on purpose: keybound static commands report underscore names
;; (vsplit_new), but the same command typed at the prompt reports the typable
;; name, which is hyphenated for the -new variants (:vsplit-new / :vnew).
;;
;; goto_file_*split fire their name even when no file opens (the path under the
;; cursor didn't resolve), so those can turn zen off with no split having opened.
;; harmless — just re-toggle — and unavoidable without a real view-count api.
(define *zen-split-commands*
  (list "vsplit" "vsplit_new" "vsplit-new"
        "hsplit" "hsplit_new" "hsplit-new"
        "goto_file_vsplit" "goto_file_hsplit"))

(define (zen-split-command? name)
  (and (member name *zen-split-commands*) #t))

(register-hook 'post-command
               (lambda (command-name)
                 (cond
                   ;; a split just opened -> more than one window now
                   [(zen-split-command? command-name)
                    (set! *zen-multi-window?* #t)
                    (when *zen-on?*
                      (zen-off)
                      (set-status! "zen off: split opened"))]
                   ;; not a split command: refresh our view of window state
                   [else (zen-refresh-window-state!)])
                 ;; keep centering in sync when zen is on
                 (when *zen-on?* (zen-reapply!))))

;; --- window baseline seed ---------------------------------------------------

;; seed the single-window reference size once at load. a fresh helix always
;; starts with one view, so this captures a valid full-size baseline before any
;; command runs. without it, if a split is the very first command, the reference
;; is still #f when the split sets *zen-multi-window?* — and since the recording
;; branch is gated on (not multi) and the recovery branch needs a non-#f
;; reference, both would be stuck and zen could never turn on again that session.
;; deferred (like the keybinding) so the editor is fully laid out when we read.
(define (zen-seed-window-baseline!)
  (when (and (not *zen-full-width*) (= *zen-cur-pad* 0))
    (zen-refresh-window-state!)))

(enqueue-thread-local-callback zen-seed-window-baseline!)

;; --- keybinding -------------------------------------------------------------

;; space z toggles zen mode. override in your own config if space z is taken.
;;
;; the binding is deferred with enqueue-thread-local-callback so it runs after
;; the module has finished loading. the keymap machinery attaches each command's
;; description (its ;;@doc) at bind time by looking the name up in the docstring
;; table; binding at top-level load time races that table and the space menu
;; would show "Undocumented plugin command". running it as a post-load job means
;; zen-mode's doc is registered first, so the menu shows the real description.
(enqueue-thread-local-callback
 (lambda ()
   (keymap (global) (normal (space (z ":zen-mode"))))))
