;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Protocol XML -> CLOS metadata.
;;;;
;;;; Two parts.  A small, strict XML reader (the protocol corpus uses elements,
;;;; attributes, text, comments and five entities -- nothing else, and a real
;;;; XML library would be a dependency we cannot justify for that), and the
;;;; schema built on top of it: interfaces, requests, events, arguments, enums.
;;;;
;;;; The schema keeps what the wire needs and nothing more:
;;;;
;;;;   - requests and events in document order, because the opcode IS the index;
;;;;   - `since` on every message, for version gating;
;;;;   - the libwayland signature of every message (docs/protocol-layer.md §4.1),
;;;;     used as an oracle against `wayland-scanner` and for debug dumps, never
;;;;     for runtime dispatch;
;;;;   - descriptions, so the REPL can document an interface it just met.
;;;;
;;;; docs/protocol-layer.md §4, tests/unit/schema.lisp.

(in-package #:wayland.protocol)

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition schema-error (error)
  ((origin :initarg :origin :initform nil :reader schema-error-origin)
   (detail :initarg :detail :reader schema-error-detail))
  (:report (lambda (condition stream)
             (format stream "protocol schema error~@[ in ~A~]: ~A"
                     (schema-error-origin condition)
                     (schema-error-detail condition)))))

(define-condition xml-error (schema-error) ())
(define-condition invalid-schema (schema-error) ())

(define-condition conflicting-interface (schema-error)
  ((name :initarg :name :reader conflicting-interface-name)
   (old-version :initarg :old-version :reader conflicting-interface-old-version)
   (new-version :initarg :new-version :reader conflicting-interface-new-version))
  (:report (lambda (condition stream)
             (format stream
                     "interface ~A is already loaded at version ~D, and this source says version ~D; a system must not load two versions of one protocol"
                     (conflicting-interface-name condition)
                     (conflicting-interface-old-version condition)
                     (conflicting-interface-new-version condition)))))

(defun xml-fail (origin control &rest arguments)
  (error 'xml-error :origin origin :detail (apply #'format nil control arguments)))

(defun schema-fail (origin control &rest arguments)
  (error 'invalid-schema :origin origin :detail (apply #'format nil control arguments)))

;;; ---------------------------------------------------------------------------
;;; A small XML reader
;;; ---------------------------------------------------------------------------

(defstruct (xml-element (:constructor make-xml-element (name attributes children)))
  (name "" :type string)
  ;; (name . value) pairs, in document order, values entity-decoded
  (attributes nil :type list)
  ;; strings (text) and xml-element instances, in document order
  (children nil :type list))

(defun xml-attribute (element name)
  (cdr (assoc name (xml-element-attributes element) :test #'string=)))

(defun parse-xml (string &key origin)
  "Parse XML text into XML-ELEMENT trees.  Strict about structure, because a
silently mis-parsed protocol is worse than a loud failure."
  (let ((position 0)
        (size (length string)))
    (labels
        ((fail (control &rest arguments)
           (apply #'xml-fail origin control arguments))
         (peek ()
           (when (< position size) (char string position)))
         (advance (&optional (count 1))
           (incf position count))
         (looking-at (prefix)
           (and (<= (+ position (length prefix)) size)
                (string= prefix string
                         :start2 position :end2 (+ position (length prefix)))))
         (skip-whitespace ()
           (loop while (and (< position size)
                            (member (char string position)
                                    '(#\Space #\Tab #\Newline #\Return)))
                 do (advance)))
         (skip-comment ()
           (advance 4)                  ; "<!--"
           (let ((end (search "-->" string :start2 position)))
             (unless end (fail "unterminated comment at offset ~D" position))
             (setf position (+ end 3))))
         (skip-processing-instruction ()
           (advance 2)                  ; "<?"
           (let ((end (search "?>" string :start2 position)))
             (unless end (fail "unterminated processing instruction"))
             (setf position (+ end 2))))
         (skip-markup-declaration ()
           ;; <!DOCTYPE ...>; nothing in the corpus uses one, but refusing to
           ;; parse it would be a strange place to draw the line.
           (let ((end (position #\> string :start position)))
             (unless end (fail "unterminated markup declaration"))
             (setf position (1+ end))))
         (entity-value (name)
           (cond ((string= name "amp") "&")
                 ((string= name "lt") "<")
                 ((string= name "gt") ">")
                 ((string= name "quot") "\"")
                 ((string= name "apos") "'")
                 ((and (plusp (length name)) (char= (char name 0) #\#))
                  (let* ((hexadecimal (and (> (length name) 1)
                                           (member (char name 1) '(#\x #\X))))
                         (digits (subseq name (if hexadecimal 2 1)))
                         (code (handler-case
                                   (parse-integer digits
                                                  :radix (if hexadecimal 16 10))
                                 (error () (fail "bad character reference &~A;" name)))))
                    (string (or (code-char code)
                                (fail "no character with code ~D" code)))))
                 (t (fail "unknown entity &~A;" name))))
         (decode-entities (text)
           (if (null (position #\& text))
               text
               (with-output-to-string (out)
                 (loop with index = 0
                       while (< index (length text))
                       for character = (char text index)
                       do (if (char= character #\&)
                              (let ((end (position #\; text :start index)))
                                (unless end (fail "unterminated entity in ~S" text))
                                (write-string
                                 (entity-value (subseq text (1+ index) end))
                                 out)
                                (setf index (1+ end)))
                              (progn
                                (write-char character out)
                                (incf index)))))))
         (read-name ()
           (let ((start position))
             (loop while (and (< position size)
                              (let ((character (char string position)))
                                (or (alphanumericp character)
                                    (member character '(#\- #\_ #\. #\:)))))
                   do (advance))
             (when (= start position)
               (fail "expected a name at offset ~D" position))
             (subseq string start position)))
         (read-attribute-value ()
           (let ((quote-character (peek)))
             (unless (member quote-character '(#\" #\'))
               (fail "expected a quoted attribute value at offset ~D" position))
             (advance)
             (let ((start position))
               (loop while (and (< position size)
                                (char/= (char string position) quote-character))
                     do (advance))
               (when (>= position size)
                 (fail "unterminated attribute value"))
               (let ((raw (subseq string start position)))
                 (advance)
                 (decode-entities raw)))))
         (read-attributes ()
           "Attributes up to and including the closing '>'.
Returns (values attributes self-closing-p)."
           (let ((attributes '()))
             (loop
               (skip-whitespace)
               (let ((character (peek)))
                 (cond
                   ((null character)
                    (fail "unexpected end of input inside a tag"))
                   ((char= character #\>)
                    (advance)
                    (return (values (nreverse attributes) nil)))
                   ((char= character #\/)
                    (advance)
                    (unless (eql (peek) #\>)
                      (fail "expected '>' after '/' at offset ~D" position))
                    (advance)
                    (return (values (nreverse attributes) t)))
                   (t
                    (let ((name (read-name)))
                      (skip-whitespace)
                      (unless (eql (peek) #\=)
                        (fail "expected '=' after attribute ~A" name))
                      (advance)
                      (skip-whitespace)
                      (push (cons name (read-attribute-value)) attributes))))))))
         (read-content (name)
           (let ((children '()))
             (loop
               (let ((character (peek)))
                 (cond
                   ((null character)
                    (fail "unexpected end of input; <~A> is not closed" name))
                   ((looking-at "</")
                    (return (nreverse children)))
                   ((looking-at "<!--")
                    (skip-comment))
                   ((looking-at "<?")
                    (skip-processing-instruction))
                   ((eql character #\<)
                    (push (read-element) children))
                   (t
                    (let ((start position))
                      (loop while (and (< position size)
                                       (char/= (char string position) #\<))
                            do (advance))
                      (let ((text (decode-entities
                                   (subseq string start position))))
                        (when (plusp (length text))
                          (push text children))))))))))
         (read-element ()
           (unless (eql (peek) #\<)
             (fail "expected '<' at offset ~D" position))
           (advance)
           (let ((name (read-name)))
             (multiple-value-bind (attributes self-closing)
                 (read-attributes)
               (if self-closing
                   (make-xml-element name attributes nil)
                   (let ((children (read-content name)))
                     (unless (looking-at "</")
                       (fail "expected </~A>" name))
                     (advance 2)
                     (let ((closing (read-name)))
                       (unless (string= closing name)
                         (fail "closing tag </~A> does not match <~A>"
                               closing name)))
                     (skip-whitespace)
                     (unless (eql (peek) #\>)
                       (fail "expected '>' at offset ~D" position))
                     (advance)
                     (make-xml-element name attributes children)))))))
      ;; Preamble: declarations and comments, then the root element.
      (loop
        (skip-whitespace)
        (cond ((looking-at "<?") (skip-processing-instruction))
              ((looking-at "<!--") (skip-comment))
              ((looking-at "<!") (skip-markup-declaration))
              ((null (peek)) (fail "no root element"))
              ((eql (peek) #\<) (return))
              (t (fail "unexpected content before the root element"))))
      (let ((root (read-element)))
        (loop
          (skip-whitespace)
          (cond ((looking-at "<!--") (skip-comment))
                ((null (peek)) (return))
                (t (fail "trailing content after the root element"))))
        root))))

(defun xml-elements (element name)
  "The XML-ELEMENT children of ELEMENT named NAME, in document order."
  (remove-if-not (lambda (child)
                   (and (xml-element-p child)
                        (string= (xml-element-name child) name)))
                 (xml-element-children element)))

(defun xml-first-element (element name)
  (find-if (lambda (child)
             (and (xml-element-p child)
                  (string= (xml-element-name child) name)))
           (xml-element-children element)))

(defun xml-text (element)
  "All text below ELEMENT, concatenated.  Descriptions never nest elements."
  (with-output-to-string (out)
    (labels ((walk (node)
               (if (xml-element-p node)
                   (dolist (child (xml-element-children node)) (walk child))
                   (write-string node out))))
      (dolist (child (xml-element-children element)) (walk child)))))

(defun trim-text (string)
  (string-trim '(#\Space #\Tab #\Newline #\Return #\Page) string))

;;; ---------------------------------------------------------------------------
;;; Schema objects
;;; ---------------------------------------------------------------------------

(defclass wl-protocol ()
  ((name :initarg :name :reader protocol-name)
   (copyright :initarg :copyright :initform nil :reader protocol-copyright)
   (interfaces :initarg :interfaces :initform '() :reader protocol-interfaces)
   (source :initarg :source :initform nil :reader protocol-source))
  (:documentation "One <protocol> element: a name, a copyright notice, interfaces."))

(defclass wl-interface ()
  ((name :initarg :name :reader interface-name)
   (version :initarg :version :initform 1 :accessor interface-version)
   ;; Document order; the position in each list is the opcode.
   (requests :initarg :requests :initform '() :accessor interface-requests)
   (events :initarg :events :initform '() :accessor interface-events)
   (enums :initarg :enums :initform '() :accessor interface-enums)
   (summary :initarg :summary :initform nil :accessor interface-summary)
   (description :initarg :description :initform nil :accessor interface-description)
   (protocol :initarg :protocol :initform nil :accessor interface-protocol))
  (:documentation "One <interface>: a version and two ordered message lists."))

(defclass wl-message ()
  ((name :initarg :name :reader message-name)
   (opcode :initarg :opcode :initform 0 :reader message-opcode)
   (kind :initarg :kind :reader message-kind)   ; :request or :event
   (args :initarg :args :initform '() :reader message-args)
   (since :initarg :since :initform 1 :reader message-since)
   (summary :initarg :summary :initform nil :reader message-summary)
   (description :initarg :description :initform nil :reader message-description)
   (interface :initarg :interface :initform nil :accessor message-interface)
   ;; The generic function, when the message came from a DEFINE-REQUEST or
   ;; DEFINE-EVENT form.  Messages parsed straight from XML have no Lisp names
   ;; yet, so this is NIL for them.
   (symbol :initarg :symbol :initform nil :reader message-symbol))
  (:documentation "A <request> or an <event>; identical on the wire apart from direction."))

(defclass wl-arg ()
  ((name :initarg :name :reader arg-name)
   (type :initarg :type :reader arg-type)       ; :int :uint :fixed :string
                                                ; :object :new-id :array :fd
   (interface :initarg :interface :initform nil :reader arg-interface)
   (allow-null :initarg :allow-null :initform nil :reader arg-allow-null)
   (enum :initarg :enum :initform nil :reader arg-enum)
   (summary :initarg :summary :initform nil :reader arg-summary)))

(defclass wl-enum ()
  ((name :initarg :name :reader enum-name)
   (bitfield-p :initarg :bitfield-p :initform nil :reader enum-bitfield-p)
   (entries :initarg :entries :initform '() :reader enum-entries)
   (summary :initarg :summary :initform nil :reader enum-summary)
   (description :initarg :description :initform nil :reader enum-description)
   (interface :initarg :interface :initform nil :accessor enum-interface)))

(defclass wl-entry ()
  ((name :initarg :name :reader entry-name)
   (value :initarg :value :reader entry-value)
   (since :initarg :since :initform 1 :reader entry-since)
   (summary :initarg :summary :initform nil :reader entry-summary)
   (description :initarg :description :initform nil :reader entry-description)))

;;; ---------------------------------------------------------------------------
;;; Signatures
;;; ---------------------------------------------------------------------------

(defun arg-type-character (arg)
  "The libwayland signature character for ARG's type."
  (ecase (arg-type arg)
    (:int #\i)
    (:uint #\u)
    (:fixed #\f)
    (:string #\s)
    (:object #\o)
    (:new-id #\n)
    (:array #\a)
    (:fd #\h)))

(defun message-signature (message)
  "The libwayland signature string, e.g. \"?oii\" or \"3?oii\".

A message with `since` above 1 is prefixed with that version, exactly as
wayland-scanner writes it: the signature then carries the version gate as well
as the argument types.  Used as an oracle against wayland-scanner and for debug
output; the runtime dispatches on generated readers, never on this string."
  (let ((body (with-output-to-string (out)
                (dolist (arg (message-args message))
                  (when (arg-allow-null arg)
                    (write-char #\? out))
                  (write-char (arg-type-character arg) out)))))
    (if (> (message-since message) 1)
        (format nil "~D~A" (message-since message) body)
        body)))

(defun message-interface-references (message)
  "The interfaces a message's object arguments point at, in argument order.

One entry per :object or :new-id argument: the interface name, or NIL for a
new_id whose interface the client chooses (wl_registry.bind is the only one)."
  (loop for arg in (message-args message)
        when (member (arg-type arg) '(:object :new-id))
          collect (arg-interface arg)))

;;; ---------------------------------------------------------------------------
;;; Building the schema
;;; ---------------------------------------------------------------------------

(defun required-attribute (element name origin)
  (or (xml-attribute element name)
      (schema-fail origin "<~A> without a ~S attribute"
                   (xml-element-name element) name)))

(defun integer-attribute (element name origin &key default)
  (let ((text (xml-attribute element name)))
    (cond ((null text) default)
          (t (handler-case (parse-integer text)
               (error ()
                 (schema-fail origin "<~A ~A=~S> is not an integer"
                              (xml-element-name element) name text)))))))

(defun parse-integer-text (text origin context)
  "Enum values may be decimal or hexadecimal."
  (handler-case
      (cond ((and (> (length text) 2) (string-equal "0x" text :end2 2))
             (parse-integer text :start 2 :radix 16))
            (t (parse-integer text)))
    (error ()
      (schema-fail origin "~A value ~S is not an integer" context text))))

(defun boolean-attribute (element name)
  (let ((text (xml-attribute element name)))
    (and text (string= text "true"))))

(defun element-documentation (element origin)
  "Values (summary description) from ELEMENT's <description> child."
  (declare (ignore origin))
  (let ((description (xml-first-element element "description")))
    (if (null description)
        (values nil nil)
        (values (xml-attribute description "summary")
                (trim-text (xml-text description))))))

(defun arg-type-keyword (name origin)
  (cond ((null name) (schema-fail origin "<arg> without a type"))
        ((string= name "int") :int)
        ((string= name "uint") :uint)
        ((string= name "fixed") :fixed)
        ((string= name "string") :string)
        ((string= name "object") :object)
        ((string= name "new_id") :new-id)
        ((string= name "array") :array)
        ((string= name "fd") :fd)
        (t (schema-fail origin "unknown argument type ~S" name))))

(defun build-arg (element origin)
  (let* ((name (required-attribute element "name" origin))
         (type (arg-type-keyword (xml-attribute element "type") origin))
         (interface (xml-attribute element "interface"))
         (allow-null (boolean-attribute element "allow-null")))
    ;; An object or new_id argument may omit INTERFACE (wl_display.error's
    ;; object_id does): the wire then says only "some object".  wayland-scanner
    ;; emits NULL in the types array for it, and so do we.
    (make-instance 'wl-arg
                   :name name
                   :type type
                   :interface interface
                   :allow-null allow-null
                   :enum (xml-attribute element "enum")
                   :summary (xml-attribute element "summary"))))

(defun synthesize-registry-bind-arguments (args)
  "wl_registry.bind is the one message whose XML does not match the wire.

The XML declares (name, id), but the client really sends the interface name and
its version as well, because the server has to know what to instantiate:
signature \"usun\".  wayland-scanner special-cases it, so we must too -- a
generated client that sent \"un\" would be speaking a different protocol from
every other client on the machine.  See wayland.xml's wl_registry.bind and
libwayland's wayland-scanner.c."
  (if (and (= (length args) 2)
           (eq :uint (arg-type (first args)))
           (eq :new-id (arg-type (second args))))
      (list (first args)
            (make-instance 'wl-arg
                           :name "interface"
                           :type :string
                           :summary "name of the interface to bind to")
            (make-instance 'wl-arg
                           :name "version"
                           :type :uint
                           :summary "version of the interface to bind to")
            (second args))
      args))

(defun build-message (element interface opcode kind origin)
  (multiple-value-bind (summary description) (element-documentation element origin)
    (let* ((name (required-attribute element "name" origin))
           (arguments (mapcar (lambda (child) (build-arg child origin))
                              (xml-elements element "arg"))))
      (when (and (string= name "bind")
                 (string= (interface-name interface) "wl_registry"))
        (setf arguments (synthesize-registry-bind-arguments arguments)))
      (make-instance 'wl-message
                   :name name
                   :opcode opcode
                   :kind kind
                   :interface interface
                   :args arguments
                   :since (or (integer-attribute element "since" origin) 1)
                   :summary (or summary
                                (xml-attribute element "summary"))
                   :description description))))

(defun build-enum (element interface origin)
  (multiple-value-bind (summary description) (element-documentation element origin)
    (make-instance 'wl-enum
                   :name (required-attribute element "name" origin)
                   :bitfield-p (boolean-attribute element "bitfield")
                   :interface interface
                   :summary summary
                   :description description
                   :entries
                   (loop for child in (xml-elements element "entry")
                         collect
                         (multiple-value-bind (entry-summary entry-description)
                             (element-documentation child origin)
                           (make-instance 'wl-entry
                                          :name (required-attribute child "name" origin)
                                          :value (parse-integer-text
                                                  (required-attribute child "value" origin)
                                                  origin
                                                  "entry")
                                          :since (or (integer-attribute child "since" origin) 1)
                                          :summary (or entry-summary
                                                       (xml-attribute child "summary"))
                                          :description entry-description))))))

(defun required-attribute-integer (element name origin)
  (let ((value (integer-attribute element name origin)))
    (unless value
      (schema-fail origin "<~A> without a ~S attribute"
                   (xml-element-name element) name))
    value))

(defun build-interface (element protocol origin)
  (multiple-value-bind (summary description) (element-documentation element origin)
    (let ((interface (make-instance 'wl-interface
                                    :name (required-attribute element "name" origin)
                                    :version (required-attribute-integer
                                              element "version" origin)
                                    :summary summary
                                    :description description
                                    :protocol protocol)))
      (setf (interface-requests interface)
            (loop for child in (xml-elements element "request")
                  for opcode from 0
                  collect (build-message child interface opcode :request origin)))
      (setf (interface-events interface)
            (loop for child in (xml-elements element "event")
                  for opcode from 0
                  collect (build-message child interface opcode :event origin)))
      (setf (interface-enums interface)
            (mapcar (lambda (child) (build-enum child interface origin))
                    (xml-elements element "enum")))
      interface)))

(defun protocol-from-xml (root &key source)
  (unless (string= (xml-element-name root) "protocol")
    (schema-fail source "root element is <~A>, not <protocol>"
                 (xml-element-name root)))
  (let* ((origin (or source "<string>"))
         (name (required-attribute root "name" origin))
         (protocol (make-instance 'wl-protocol :name name :source source)))
    (let ((copyright (xml-first-element root "copyright")))
      (when copyright
        (setf (slot-value protocol 'copyright) (trim-text (xml-text copyright)))))
    (setf (slot-value protocol 'interfaces)
          (loop for child in (xml-elements root "interface")
                collect (build-interface child protocol origin)))
    (dolist (interface (protocol-interfaces protocol))
      (unless (plusp (interface-version interface))
        (schema-fail origin "interface ~A has version ~D"
                     (interface-name interface)
                     (interface-version interface))))
    protocol))

(defun parse-protocol-string (string &key origin)
  (protocol-from-xml (parse-xml string :origin origin) :source origin))

(defun parse-protocol-file (path &key (register t))
  "Parse one XML file into a WL-PROTOCOL, registering its interfaces by default."
  (let ((text (with-open-file (in path :direction :input
                                       :external-format :utf-8)
                (let ((buffer (make-string (file-length in))))
                  (subseq buffer 0 (read-sequence buffer in))))))
    (let ((protocol (parse-protocol-string text :origin (namestring path))))
      (when register (register-protocol protocol))
      protocol)))

;;; ---------------------------------------------------------------------------
;;; Registry
;;; ---------------------------------------------------------------------------

(defvar *interfaces* (make-hash-table :test #'equal)
  "Interface name -> WL-INTERFACE, across every loaded protocol.")

(defvar *interface-symbols* (make-hash-table :test #'equal)
  "Interface symbol name (\"WL-SURFACE\") -> WL-INTERFACE, for the define-* forms.")

(defvar *protocols* '()
  "Loaded WL-PROTOCOL objects, most recent first.")

(defun register-protocol (protocol)
  "Install PROTOCOL's interfaces.  Re-registering replaces, which is what hot
reload of the protocol corpus wants."
  (pushnew protocol *protocols* :test #'eq)
  (dolist (interface (protocol-interfaces protocol))
    (setf (gethash (interface-name interface) *interfaces*) interface))
  protocol)

(defun unregister-protocol (protocol)
  (setf *protocols* (delete protocol *protocols* :test #'eq))
  (dolist (interface (protocol-interfaces protocol))
    (when (eq (gethash (interface-name interface) *interfaces*) interface)
      (remhash (interface-name interface) *interfaces*)))
  protocol)

(defun find-interface (name)
  "The interface called NAME (a string or symbol designator), or NIL."
  (gethash (string name) *interfaces*))

(defun resolve-interface (name)
  (or (find-interface name)
      (schema-fail nil "no loaded protocol defines interface ~A" name)))

(defun registered-interfaces ()
  "Every registered interface, sorted by name."
  (sort (loop for interface being the hash-values of *interfaces*
               collect interface)
        #'string< :key #'interface-name))

(defun clear-protocol-registry ()
  (clrhash *interfaces*)
  (clrhash *interface-symbols*)
  (setf *protocols* nil)
  nil)

;;; ---------------------------------------------------------------------------
;;; define-* forms
;;; ---------------------------------------------------------------------------
;;;
;;; These are what the code generator emits (WAYLAND.CODEGEN) and what a human
;;; writes when a protocol is small enough to spell out.  Each registers schema
;;; metadata and defines the names a compositor or client wants to mention: a
;;; version constant, an opcode constant, an enum constant, and a generic
;;; function per message to specialise.
;;;
;;; Lookup goes through the interface's *symbol name*, so a generated file can
;;; define wl-surface in package WAYLAND while another protocol refers to the
;;; same interface by the string "wl_surface" in an :interface option.

(defun interface-symbol-for (symbol)
  (or (gethash (symbol-name symbol) *interface-symbols*)
      (schema-fail nil
                   "no interface is defined for ~S; define the interface before its messages"
                   symbol)))

(defun wire-name-of (symbol)
  "wl-surface -> \"wl_surface\"."
  (string-downcase (substitute #\_ #\- (symbol-name symbol))))

(defun lisp-name-of (wire-name)
  "wl_surface -> wl-surface."
  (string-downcase (substitute #\- #\_ wire-name)))

(defun wire-name-string (lisp-name)
  "wl-surface -> \"wl_surface\".  The inverse of LISP-NAME-OF, for symbols whose
names are written in Lisp style and need to go back on the wire."
  (string-downcase (substitute #\_ #\- lisp-name)))

(defun option-value (options key &optional default)
  (let ((option (find key options :key #'first :test #'eq)))
    (if option (second option) default)))

(defun split-dotted-symbol (symbol)
  "wl-surface.error -> (values \"WL-SURFACE\" \"ERROR\")."
  (let* ((name (symbol-name symbol))
         (dot (position #\. name)))
    (unless dot
      (schema-fail nil "~S must be written as interface.name" symbol))
    (values (subseq name 0 dot) (subseq name (1+ dot)))))

(defun message-wire-name (symbol)
  "wl-surface.attach -> \"attach\"."
  (nth-value 1 (split-dotted-symbol symbol)))

;; Constant names are built as strings so the code generator can print the same
;; tokens without interning anything in its own package.

(defun version-constant-name (interface-name)
  (format nil "+~A-VERSION+" (string-upcase interface-name)))

(defun opcode-constant-name (interface-name message-name)
  (format nil "+~A-~A+" (string-upcase interface-name) (string-upcase message-name)))

(defun enum-constant-name (interface-name enum-name entry-name)
  (format nil "+~A-~A-~A+"
          (string-upcase interface-name)
          (string-upcase enum-name)
          (string-upcase entry-name)))

(defun %define-interface (symbol version wire-name documentation)
  (let ((previous (find-interface wire-name)))
    (when (and previous (/= version (interface-version previous)))
      (error 'conflicting-interface :name wire-name
                                     :old-version (interface-version previous)
                                     :new-version version))
    (let ((interface (make-instance 'wl-interface
                                    :name wire-name
                                    :version version
                                    :description documentation)))
      (setf (gethash wire-name *interfaces*) interface)
      (setf (gethash (symbol-name symbol) *interface-symbols*) interface)
      interface)))

(defmacro define-interface (symbol &body options)
  "Register an interface and define +INTERFACE-VERSION+.

OPTIONS: (:version N), (:wire-name \"wl_surface\"), (:documentation \"...\").
The wire name defaults to the symbol with its dash replaced by an underscore."
  (let ((version (option-value options :version 1))
        (wire-name (option-value options :wire-name (wire-name-of symbol)))
        (documentation (option-value options :documentation "")))
    `(progn
       (eval-when (:load-toplevel :execute)
         (%define-interface ',symbol ,version ,wire-name ,documentation))
       (defconstant ,(intern (version-constant-name (lisp-name-of (wire-name-of symbol)))
                             *package*)
         ,version))))

(defun %define-enum (interface-symbol enum-name bitfield-p entries)
  (let* ((interface (interface-symbol-for interface-symbol))
         (enum (make-instance 'wl-enum
                              :name enum-name
                              :bitfield-p bitfield-p
                              :interface interface
                              :entries
                              (loop for (name value since summary) in entries
                                    collect (make-instance 'wl-entry
                                                           :name name
                                                           :value value
                                                           :since since
                                                           :summary summary)))))
    (setf (interface-enums interface)
          (append (remove enum-name (interface-enums interface)
                          :key #'enum-name :test #'string=)
                  (list enum)))
    enum))

(defmacro define-enum (symbol options &body entries)
  "Register an enum (wl-surface.error) and define one constant per entry:
+wl-surface-error-invalid-scale+."
  (multiple-value-bind (interface-name enum-name) (split-dotted-symbol symbol)
    (let ((interface-symbol (intern interface-name *package*))
          (wire-enum (wire-name-string enum-name))
          (specs '()))
      (dolist (entry entries)
        (destructuring-bind (name value &rest rest) entry
          (push (list (wire-name-string (symbol-name name)) value
                      (or (getf rest :since) 1) (getf rest :summary))
                specs)))
      `(progn
         (eval-when (:load-toplevel :execute)
           (%define-enum ',interface-symbol ,wire-enum
                         ,(and (getf options :bitfield) t)
                         ',(nreverse specs)))
         ,@(loop for (name value) in (mapcar (lambda (entry)
                                               (list (first entry) (second entry)))
                                             entries)
                 collect `(defconstant
                              ,(intern (enum-constant-name
                                        (lisp-name-of (wire-name-of interface-symbol))
                                        ;; Both names are on the wire, so both
                                        ;; need converting: an enum called
                                        ;; keymap_format that is defined as
                                        ;; +WL-KEYBOARD-KEYMAP_FORMAT-...+ is not
                                        ;; the symbol the generated package
                                        ;; exports, and every user of the
                                        ;; constant gets an unbound variable.
                                        (lisp-name-of wire-enum)
                                        (lisp-name-of (string-downcase (symbol-name name))))
                                       *package*)
                            ,value))))))

(defun parameter-names (arguments kind)
  "The generic function lambda list: (object arg1 arg2 ...).

NEW_ID arguments are left out of a request's lambda list.  The wire carries an
id, but neither side takes one as an argument: the sender allocates it (a client
from its own id range, a server from its range) and the dispatch layer hands
back the created object.  A client calls

  (wl-registry.bind registry name interface version)

and gets the bound proxy; a compositor specialises the same function and creates
the resource.  Events keep every argument, because there the *sender* chose the
id and the receiver must learn it (wl_data_device.data_offer).

Duplicate or reserved names are replaced: OBJECT is the first parameter, and T
and NIL cannot be parameters at all."
  (let ((object (intern "OBJECT" *package*))
        (used (list "OBJECT"))
        (names '()))
    (loop for argument in arguments
          for index from 0
          for (name type) = argument
          for string = (symbol-name name)
          for dropped = (and (eq kind :request) (eq type :new-id))
          for usable = (and (not dropped)
                            (not (member string '("T" "NIL") :test #'string=))
                            (not (member string used :test #'string=)))
          do (push string used)
             (unless dropped
               (push (if usable
                         name
                         (intern (format nil "ARG~D" index) *package*))
                     names)))
    (cons object (nreverse names))))

(defun %define-message (message-symbol interface-symbol opcode kind since arguments documentation)
  (let* ((interface (interface-symbol-for interface-symbol))
         (message (make-instance 'wl-message
                                 :name (wire-name-string (message-wire-name message-symbol))
                                 :opcode opcode
                                 :kind kind
                                 :interface interface
                                 :since since
                                 :symbol message-symbol
                                 :description documentation
                                 :args (loop for (name type . options) in arguments
                                             collect (make-instance
                                                      'wl-arg
                                                      :name (wire-name-string (symbol-name name))
                                                      :type type
                                                      :interface (getf options :interface)
                                                      :allow-null (and (getf options :allow-null) t)
                                                      :enum (getf options :enum)
                                                      :summary (getf options :summary))))))
    (let ((messages (if (eq kind :request)
                        (interface-requests interface)
                        (interface-events interface))))
      (loop while (<= (length messages) opcode)
            do (setf messages (append messages (list nil))))
      (setf (nth opcode messages) message)
      (if (eq kind :request)
          (setf (interface-requests interface) messages)
          (setf (interface-events interface) messages)))
    message))

(defmacro define-message (kind message-symbol interface-symbol opcode arguments &body options)
  `(progn
     (defgeneric ,message-symbol ,(parameter-names arguments kind)
       ,@(let ((documentation (option-value options :documentation)))
           (when documentation `((:documentation ,documentation)))))
     (defconstant ,(intern (opcode-constant-name
                            (lisp-name-of (wire-name-of interface-symbol))
                            (string-downcase (message-wire-name message-symbol)))
                           *package*)
       ,opcode)
     (eval-when (:load-toplevel :execute)
       (%define-message ',message-symbol ',interface-symbol ,opcode ,kind
                        ,(or (option-value options :since) 1)
                        ',arguments
                        ,(option-value options :documentation)))))

(defmacro define-request ((message-symbol interface-symbol opcode) arguments &body options)
  "Register a request and define wl-surface.attach as a generic function.

The generic function is the handler a compositor specialises (server side) and
the callable a client uses (client side): one schema, two directions."
  `(define-message :request ,message-symbol ,interface-symbol ,opcode ,arguments
                   ,@options))

(defmacro define-event ((message-symbol interface-symbol opcode) arguments &body options)
  `(define-message :event ,message-symbol ,interface-symbol ,opcode ,arguments
                   ,@options))
