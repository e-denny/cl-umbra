;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; cf.font v0: a 5x7 bitmap font, rasterised into premultiplied ARGB8888
;;;; (docs/framework.md §4, D51).
;;;;
;;;; Why a table and not a font engine: the first text a compositor needs is the
;;;; window titles in an Alt+Tab switcher, and a switcher that cannot say which
;;;; window is which is not worth a font library.  Ninety-five glyphs, each seven
;;;; rows of five, draw every printable ASCII character, need no library, no
;;;; lookup, no configuration and no files, and are provably complete -- the
;;;; loader checks the table's shape and refuses to load a malformed one, and the
;;;; unit suite checks that every letter and digit draws something.
;;;;
;;;; What it is not: a text renderer.  No shaping, no kerning, no combining marks,
;;;; no BiDi, one size, no hinting; a title in a script outside ASCII draws as the
;;;; fallback glyph.  Phase 5/6 replace it when something needs more.  What stays
;;;; is the contract: one font cell is one *layout* pixel, a raster is requested
;;;; at the output's scale, and the result is premultiplied ARGB8888 -- so a
;;;; glyph is scale x scale device pixels per cell and text is crisp at scale 2
;;;; for the same reason the cursor is, by drawing bigger rather than by
;;;; upscaling a small picture (D49).

(in-package #:cf.font)

;;; ---------------------------------------------------------------------------
;;; Metrics
;;; ---------------------------------------------------------------------------

(defconstant +glyph-width+ 5 "Cells across one glyph.")
(defconstant +glyph-height+ 7 "Cells down one glyph.")
(defconstant +glyph-advance+ 6
  "Cells from one glyph's left edge to the next: five plus a blank column.

The blank column is the only spacing there is -- no kerning, no per-glyph widths --
which is what makes TEXT-WIDTH a multiplication instead of a loop.")
(defconstant +first-char-code+ 32 "The table starts at space.")
(defconstant +last-char-code+ 126 "and ends at tilde: printable ASCII, inclusive.")
(defconstant +fallback-character+ #\?
  "What a character outside the table is drawn as.  Dropping it would silently
shorten a title; a question mark says the text was not understood.")

(defun glyph-count ()
  "How many glyphs the table must hold: printable ASCII is 95 characters."
  (1+ (- +last-char-code+ +first-char-code+)))

;;; ---------------------------------------------------------------------------
;;; The table
;;; ---------------------------------------------------------------------------
;;
;; Seven rows of five cells each, '#' lit and '.' clear, rows separated by '/'.
;; One string per glyph, in character-code order from 32 (space) to 126 (tilde).
;;
;; Written by hand, read by hand: a glyph is recognisable at a glance, a diff to
;; one is a diff to one, and PARSE-GLYPH-ROWS refuses anything whose shape is not
;; exactly 7 x 5 -- so a typo in the table is a load-time error and not a strange
;; picture a week later.

(defparameter +glyph-rows+
  '(
    ;; 32 space .. 47 slash
    "...../...../...../...../...../...../....."      ; 32
    "..#../..#../..#../..#../..#../...../..#.."      ; 33 !
    ".#.#./.#.#./...../...../...../...../....."      ; 34 "
    ".#.#./.#.#./#####/.#.#./#####/.#.#./.#.#."      ; 35 #
    "..#../.####/#.#../.###./..#.#/####./..#.."      ; 36 $
    "##..#/##.#./...#./..#../.#.../#.##./#.##."      ; 37 %
    ".##../#..#./#.#../.#.../#.#.#/#..#./.##.#"      ; 38 &
    "..#../..#../...../...../...../...../....."      ; 39 '
    "...#./..#../.#.../.#.../.#.../..#../...#."      ; 40 (
    ".#.../..#../...#./...#./...#./..#../.#..."      ; 41 )
    "...../..#../#.#.#/.###./#.#.#/..#../....."      ; 42 *
    "...../..#../..#../#####/..#../..#../....."      ; 43 +
    "...../...../...../...../...../..#../.#..."      ; 44 ,
    "...../...../...../#####/...../...../....."      ; 45 -
    "...../...../...../...../...../...../..#.."      ; 46 .
    "....#/...#./...#./..#../.#.../.#.../#...."      ; 47 /
    ;; 48 zero .. 57 nine
    ".###./#...#/#..##/#.#.#/##..#/#...#/.###."      ; 48 0
    "..#../.##../..#../..#../..#../..#../.###."      ; 49 1
    ".###./#...#/....#/...#./..#../.#.../#####"      ; 50 2
    "####./....#/....#/.###./....#/....#/####."      ; 51 3
    "...#./..##./.#.#./#..#./#####/...#./...#."      ; 52 4
    "#####/#..../####./....#/....#/#...#/.###."      ; 53 5
    "..##./.#.../#..../####./#...#/#...#/.###."      ; 54 6
    "#####/....#/...#./..#../.#.../.#.../.#..."      ; 55 7
    ".###./#...#/#...#/.###./#...#/#...#/.###."      ; 56 8
    ".###./#...#/#...#/.####/....#/...#./.##.."      ; 57 9
    ;; 58 colon .. 64 at
    "...../...../..#../...../..#../...../....."      ; 58 :
    "...../...../..#../...../..#../.#.../....."      ; 59 ;
    "...../...#./..#../.#.../..#../...#./....."      ; 60 <
    "...../...../#####/...../#####/...../....."      ; 61 =
    "...../.#.../..#../...#./..#../.#.../....."      ; 62 >
    ".###./#...#/....#/...#./..#../...../..#.."      ; 63 ?
    ".###./#...#/#.###/#.#.#/#.###/#..../.###."      ; 64 @
    ;; 65 A .. 90 Z
    "..#../.#.#./#...#/#...#/#####/#...#/#...#"      ; 65 A
    "####./#...#/#...#/####./#...#/#...#/####."      ; 66 B
    ".###./#...#/#..../#..../#..../#...#/.###."      ; 67 C
    "###../#..#./#...#/#...#/#...#/#..#./###.."      ; 68 D
    "#####/#..../#..../####./#..../#..../#####"      ; 69 E
    "#####/#..../#..../####./#..../#..../#...."      ; 70 F
    ".###./#...#/#..../#.###/#...#/#...#/.###."      ; 71 G
    "#...#/#...#/#...#/#####/#...#/#...#/#...#"      ; 72 H
    ".###./..#../..#../..#../..#../..#../.###."      ; 73 I
    "..###/...#./...#./...#./...#./#..#./.##.."      ; 74 J
    "#...#/#..#./#.#../##.../#.#../#..#./#...#"      ; 75 K
    "#..../#..../#..../#..../#..../#..../#####"      ; 76 L
    "#...#/##.##/#.#.#/#.#.#/#...#/#...#/#...#"      ; 77 M
    "#...#/##..#/#.#.#/#..##/#...#/#...#/#...#"      ; 78 N
    ".###./#...#/#...#/#...#/#...#/#...#/.###."      ; 79 O
    "####./#...#/#...#/####./#..../#..../#...."      ; 80 P
    ".###./#...#/#...#/#...#/#.#.#/#..#./.##.#"      ; 81 Q
    "####./#...#/#...#/####./#.#../#..#./#...#"      ; 82 R
    ".####/#..../#..../.###./....#/....#/####."      ; 83 S
    "#####/..#../..#../..#../..#../..#../..#.."      ; 84 T
    "#...#/#...#/#...#/#...#/#...#/#...#/.###."      ; 85 U
    "#...#/#...#/#...#/#...#/#...#/.#.#./..#.."      ; 86 V
    "#...#/#...#/#...#/#.#.#/#.#.#/##.##/#...#"      ; 87 W
    "#...#/#...#/.#.#./..#../.#.#./#...#/#...#"      ; 88 X
    "#...#/#...#/.#.#./..#../..#../..#../..#.."      ; 89 Y
    "#####/....#/...#./..#../.#.../#..../#####"      ; 90 Z
    ;; 91 bracket .. 96 backtick
    ".###./.#.../.#.../.#.../.#.../.#.../.###."      ; 91 [
    "#..../.#.../.#.../..#../...#./...#./....#"      ; 92 backslash
    ".###./...#./...#./...#./...#./...#./.###."      ; 93 ]
    "..#../.#.#./#...#/...../...../...../....."      ; 94 ^
    "...../...../...../...../...../...../#####"      ; 95 _
    ".#.../..#../...../...../...../...../....."      ; 96 `
    ;; 97 a .. 122 z
    "...../...../.###./....#/.####/#...#/.####"      ; 97 a
    "#..../#..../####./#...#/#...#/#...#/####."      ; 98 b
    "...../...../.###./#..../#..../#...#/.###."      ; 99 c
    "....#/....#/.####/#...#/#...#/#...#/.####"      ; 100 d
    "...../...../.###./#...#/#####/#..../.###."      ; 101 e
    "..##./.#..#/.#.../####./.#.../.#.../.#..."      ; 102 f
    "...../.####/#...#/#...#/.####/....#/.###."      ; 103 g
    "#..../#..../####./#...#/#...#/#...#/#...#"      ; 104 h
    "..#../...../.##../..#../..#../..#../.###."      ; 105 i
    "...#./...../..##./...#./...#./#..#./.##.."      ; 106 j
    "#..../#..../#..#./#.#../##.../#.#../#..#."      ; 107 k
    ".##../..#../..#../..#../..#../..#../.###."      ; 108 l
    "...../...../##.#./#.#.#/#.#.#/#.#.#/#...#"      ; 109 m
    "...../...../####./#...#/#...#/#...#/#...#"      ; 110 n
    "...../...../.###./#...#/#...#/#...#/.###."      ; 111 o
    "...../...../####./#...#/####./#..../#...."      ; 112 p
    "...../...../.####/#...#/.####/....#/....#"      ; 113 q
    "...../...../#.##./##..#/#..../#..../#...."      ; 114 r
    "...../...../.####/#..../.###./....#/####."      ; 115 s
    ".#.../.#.../####./.#.../.#.../.#..#/..##."      ; 116 t
    "...../...../#...#/#...#/#...#/#..##/.##.#"      ; 117 u
    "...../...../#...#/#...#/#...#/.#.#./..#.."      ; 118 v
    "...../...../#...#/#.#.#/#.#.#/#.#.#/.#.#."      ; 119 w
    "...../...../#...#/.#.#./..#../.#.#./#...#"      ; 120 x
    "...../...../#...#/#...#/.####/....#/.###."      ; 121 y
    "...../...../#####/...#./..#../.#.../#####"      ; 122 z
    ;; 123 brace .. 126 tilde
    "...##/..#../..#../.#.../..#../..#../...##"      ; 123 {
    "..#../..#../..#../..#../..#../..#../..#.."      ; 124 |
    "##.../..#../..#../...#./..#../..#../##..."      ; 125 }
    "...../...../.#..#/#.#.#/#..#./...../.....")    ; 126 ~
  "Printable ASCII, 32 (space) to 126 (tilde), in character-code order.")

;;; ---------------------------------------------------------------------------
;;; Loading the table
;;; ---------------------------------------------------------------------------

(defun parse-glyph-rows (string)
  "STRING's seven row masks, five bits each, most significant bit leftmost.

Signals an error unless STRING is exactly seven rows of five, '#' or '.', joined
by slashes -- which is what turns a typo in the table into a load-time failure
instead of a strange picture."
  (let ((expected (1- (* +glyph-height+ (1+ +glyph-width+)))))
    (unless (= (length string) expected)
      (error "~S is ~D characters long; a glyph is ~D (seven rows of five, six slashes)"
             string (length string) expected)))
  (let ((rows (make-array +glyph-height+ :element-type '(unsigned-byte 8))))
    (loop for row from 0 below +glyph-height+
          for start = (* row (1+ +glyph-width+))
          do (let ((mask 0))
               (loop for column from 0 below +glyph-width+
                     for index = (+ start column)
                     do (case (char string index)
                          (#\# (setf (ldb (byte 1 (- +glyph-width+ 1 column)) mask) 1))
                          (#\. nil)
                          (t (error "glyph ~S: ~S at ~D is neither '#' nor '.'"
                                    string (char string index) index))))
               (setf (aref rows row) mask))
             (when (< row (1- +glyph-height+))
               (unless (char= #\/ (char string (+ start +glyph-width+)))
                 (error "glyph ~S: row ~D is not terminated by '/'" string row))))
    rows))

(defun build-font (glyphs)
  "GLYPHS as one flat row-major octet array: glyph g, row r at (+ (* g 7) r).

Checked, not assumed: a table of the wrong length is an error, because a font
that is quietly missing its last six glyphs draws a title with the wrong letters
in it and looks like a rendering bug."
  (unless (= (length glyphs) (glyph-count))
    (error "the font has ~D glyphs; printable ASCII is ~D"
           (length glyphs) (glyph-count)))
  (let ((font (make-array (* (glyph-count) +glyph-height+)
                          :element-type '(unsigned-byte 8))))
    (loop for string in glyphs
          for glyph from 0
          do (replace font (parse-glyph-rows string)
                      :start1 (* glyph +glyph-height+)))
    font))

(defparameter +font+ (build-font +glyph-rows+)
  "Ninety-five glyphs, seven five-bit rows each, in character-code order.")

(defun glyph-index (character)
  "CHARACTER's row in the font: its own if the table has one, '?' otherwise."
  (let ((code (char-code character)))
    (if (<= +first-char-code+ code +last-char-code+)
        (- code +first-char-code+)
        (- (char-code +fallback-character+) +first-char-code+))))

(defun glyph-row-mask (character row)
  "The five-bit mask of CHARACTER's ROW: bit 4 is the leftmost cell."
  (aref +font+ (+ (* (glyph-index character) +glyph-height+) row)))

(defun glyph-cell-p (character column row)
  "Is CHARACTER's cell at COLUMN, ROW lit?"
  (logbitp (- +glyph-width+ 1 column) (glyph-row-mask character row)))

;;; ---------------------------------------------------------------------------
;;; Measuring
;;; ---------------------------------------------------------------------------

(defun text-width (text)
  "TEXT's width in layout pixels, before any scaling: 0 when it is empty.

Five cells per glyph plus a one-cell gap between them, so n glyphs are 6n-1 and
the last glyph ends where its pixels end rather than one cell early."
  (if (plusp (length text))
      (1- (* (length text) +glyph-advance+))
      0))

(defun text-height ()
  "TEXT's height in layout pixels, before any scaling."
  +glyph-height+)

(defun truncate-text (text maximum-width)
  "TEXT cut to fit MAXIMUM-WIDTH layout pixels, ending in an ellipsis if cut.

Cutting is what keeps a stranger's 300-character title from widening the switcher
past the output.  A title that fits is returned as it is, unchanged and not
copied.  The ellipsis is three dots, and a MAXIMUM-WIDTH too small to hold even
those returns the empty string rather than a broken mess."
  (if (<= (text-width text) maximum-width)
      text
      ;; The longest prefix of n glyphs whose width plus the ellipsis still fits:
      ;; six per glyph less the last gap, so 6(n+3)-1 <= MAXIMUM-WIDTH.
      (let ((characters (max 0 (min (length text) (floor (- maximum-width 17) 6)))))
        (if (plusp characters)
            (concatenate 'string (subseq text 0 characters) "...")
            ""))))

;;; ---------------------------------------------------------------------------
;;; Rasterising
;;; ---------------------------------------------------------------------------
;;
;; Premultiplied ARGB8888, one font cell is SCALE x SCALE device pixels, and the
;; colour is written as given -- so it must already be premultiplied, exactly like
;; a rectangle's (D48).  An opaque colour is the same number either way, which is
;; what a text colour should be: text that is not opaque is text that has to be
;; blended, and nothing here needs it.

(defun write-pixel (octets offset argb)
  "Write ARGB at OFFSET as four little-endian bytes: blue, green, red, alpha."
  (setf (aref octets offset) (ldb (byte 8 0) argb)
        (aref octets (+ offset 1)) (ldb (byte 8 8) argb)
        (aref octets (+ offset 2)) (ldb (byte 8 16) argb)
        (aref octets (+ offset 3)) (ldb (byte 8 24) argb)))

(defun rasterize-text (text colour scale)
  "TEXT as premultiplied ARGB8888 octets at SCALE device pixels per cell.

Returns (values OCTETS WIDTH HEIGHT) in *device* pixels; WIDTH is zero when TEXT
is empty, and a zero-width raster draws nothing (the caller checks).  Every lit
cell becomes a SCALE x SCALE block, so a glyph at scale 2 is 10x14 device pixels
drawn 1:1 -- bigger, not upscaled."
  (let* ((scale (max 1 (round scale)))
         (width (* (text-width text) scale))
         (height (* (text-height) scale))
         (octets (make-array (* 4 width height)
                             :element-type '(unsigned-byte 8) :initial-element 0)))
    (when (and (plusp width) (plusp height))
      (loop for character across text
            for glyph from 0
            do (loop for row from 0 below +glyph-height+
                     do (loop for column from 0 below +glyph-width+
                              when (glyph-cell-p character column row)
                                do (loop for dy from 0 below scale
                                         for y = (+ (* row scale) dy)
                                         do (loop for dx from 0 below scale
                                                  for x = (+ (* (+ (* glyph
                                                                     +glyph-advance+)
                                                                   column)
                                                                scale)
                                                             dx)
                                                  do (write-pixel octets
                                                                  (* 4 (+ x (* width y)))
                                                                  colour)))))))
    (values octets width height)))
