;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Schema tests: the XML reader on hand-written inputs, and then the real
;;;; gate -- every vendored protocol compared against what wayland-scanner
;;;; derives from the same XML.  The scanner is the oracle because it is the
;;;; implementation every client and compositor on the machine agrees with.

(in-package #:cl-user)

(defpackage #:wayland.test.schema
  (:use #:cl #:wayland.test)
  (:local-nicknames (#:wp #:wayland.protocol))
  (:documentation "Tests for wayland.protocol: XML reader, schema, registry, oracle."))

(in-package #:wayland.test.schema)

;;; ---------------------------------------------------------------------------
;;; Hand-written XML
;;; ---------------------------------------------------------------------------

(defparameter *sample*
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!-- a comment before the root -->
<protocol name=\"sample\">
  <copyright>
    Copyright &#169; 2026 Nobody &amp; Friends
  </copyright>
  <interface name=\"sm_surface\" version=\"3\">
    <description summary=\"a test surface\">
      Words about the surface.
    </description>
    <request name=\"destroy\"/>
    <request name=\"attach\" since=\"2\">
      <arg name=\"buffer\" type=\"object\" interface=\"sm_buffer\" allow-null=\"true\"/>
      <arg name=\"x\" type=\"int\" summary=\"x coordinate\"/>
      <arg name=\"y\" type=\"int\"/>
    </request>
    <request name=\"move\">
      <!-- an argument in a comment must be ignored -->
      <arg name=\"dx\" type=\"fixed\"/>
      <arg name=\"dy\" type=\"fixed\"/>
    </request>
    <request name=\"write\">
      <arg name=\"name\" type=\"string\"/>
      <arg name=\"data\" type=\"array\"/>
      <arg name=\"fd\" type=\"fd\"/>
      <arg name=\"serial\" type=\"uint\"/>
    </request>
    <request name=\"make\">
      <arg name=\"id\" type=\"new_id\" interface=\"sm_buffer\"/>
    </request>
    <event name=\"done\" since=\"3\"/>
    <event name=\"error\">
      <arg name=\"code\" type=\"uint\" enum=\"error\"/>
      <arg name=\"object\" type=\"object\" allow-null=\"true\"/>
    </event>
    <enum name=\"error\" bitfield=\"true\">
      <entry name=\"none\" value=\"0\" summary=\"no error\"/>
      <entry name=\"bad\" value=\"0x2\"/>
      <entry name=\"worse\" value=\"4\" since=\"2\"/>
    </enum>
  </interface>
  <interface name=\"sm_buffer\" version=\"1\"/>
</protocol>")

(defun sample ()
  (wp:parse-protocol-string *sample* :origin "sample.xml"))

(deftest xml-reader-shape
  (let* ((root (wp:parse-xml *sample*))
         (interfaces (wp::xml-elements root "interface")))
    (is (string= "protocol" (wp:xml-element-name root)))
    (is (string= "sample" (wp::xml-attribute root "name")))
    (is (eql 2 (length interfaces)))
    (is (string= "sm_surface" (wp::xml-attribute (first interfaces) "name")))
    (is (null (wp:xml-element-children (second interfaces)))
        "a self-closing element has no children")))

(deftest xml-entities-and-comments
  (let* ((root (wp:parse-xml *sample*))
         (copyright (wp::trim-text (wp::xml-text (wp::xml-first-element root "copyright"))))
         (surface (first (wp::xml-elements root "interface"))))
    (is (search "© 2026 Nobody & Friends" copyright))
    ;; The commented-out argument must not become an argument.
    (let ((move (find "move" (wp::xml-elements surface "request")
                      :key (lambda (e) (wp::xml-attribute e "name"))
                      :test #'string=)))
      (is (eql 2 (length (wp::xml-elements move "arg")))))))

(deftest schema-interface
  (let* ((protocol (sample))
         (surface (first (wp:protocol-interfaces protocol)))
         (buffer (second (wp:protocol-interfaces protocol))))
    (is (string= "sample" (wp:protocol-name protocol)))
    (is (search "Nobody" (wp:protocol-copyright protocol)))
    (is (string= "sm_surface" (wp:interface-name surface)))
    (is (= 3 (wp:interface-version surface)))
    (is (string= "a test surface" (wp:interface-summary surface)))
    (is (search "Words about the surface" (wp:interface-description surface)))
    (is (string= "sm_buffer" (wp:interface-name buffer)))
    (is (eql 0 (length (wp:interface-requests buffer))))))

(deftest schema-opcodes-are-document-order
  (let* ((surface (first (wp:protocol-interfaces (sample))))
         (requests (wp:interface-requests surface))
         (events (wp:interface-events surface)))
    (is (equal '("destroy" "attach" "move" "write" "make")
               (mapcar #'wp:message-name requests)))
    (is (equal '(0 1 2 3 4) (mapcar #'wp:message-opcode requests)))
    (is (equal '("done" "error") (mapcar #'wp:message-name events)))
    (is (equal '(0 1) (mapcar #'wp:message-opcode events))
        "events are numbered separately from requests")))

(deftest schema-signatures
  (let ((requests (wp:interface-requests (first (wp:protocol-interfaces (sample))))))
    (flet ((signature (name)
             (wp:message-signature
              (find name requests :key #'wp:message-name :test #'string=))))
      (is (string= "" (signature "destroy")))
      (is (string= "2?oii" (signature "attach"))
          "a message with since above 1 carries the version prefix")
      (is (string= "ff" (signature "move")))
      (is (string= "sahu" (signature "write")))
      (is (string= "n" (signature "make"))))))

(deftest schema-interface-references
  (let ((requests (wp:interface-requests (first (wp:protocol-interfaces (sample))))))
    (flet ((references (name)
             (wp:message-interface-references
              (find name requests :key #'wp:message-name :test #'string=))))
      (is (equal '("sm_buffer") (references "attach")))
      (is (null (references "move")))
      (is (equal '("sm_buffer") (references "make"))))))

(deftest schema-args
  (let* ((surface (first (wp:protocol-interfaces (sample))))
         (attach (second (wp:interface-requests surface)))
         (args (wp:message-args attach)))
    (is (string= "attach" (wp:message-name attach)))
    (is (string= "buffer" (wp:arg-name (first args))))
    (is (eq :object (wp:arg-type (first args))))
    (is (wp:arg-allow-null (first args)))
    (is (string= "sm_buffer" (wp:arg-interface (first args))))
    (is (eq :int (wp:arg-type (second args))))
    (is (not (wp:arg-allow-null (second args))))
    (is (string= "x coordinate" (wp:arg-summary (second args))))))

(deftest schema-since
  (let* ((surface (first (wp:protocol-interfaces (sample))))
         (attach (second (wp:interface-requests surface)))
         (destroy (first (wp:interface-requests surface)))
         (done (first (wp:interface-events surface))))
    (is (= 2 (wp:message-since attach)))
    (is (= 1 (wp:message-since destroy)) "since defaults to 1, not the interface version")
    (is (= 3 (wp:message-since done)))))

(deftest schema-enums
  (let* ((surface (first (wp:protocol-interfaces (sample))))
         (enum (first (wp:interface-enums surface)))
         (entries (wp:enum-entries enum)))
    (is (string= "error" (wp:enum-name enum)))
    (is (wp:enum-bitfield-p enum))
    (is (equal '("none" "bad" "worse") (mapcar #'wp:entry-name entries)))
    (is (equal '(0 2 4) (mapcar #'wp:entry-value entries))
        "hexadecimal entry values are parsed")
    (is (= 2 (wp:entry-since (third entries))))))

;;; ---------------------------------------------------------------------------
;;; Reader failures
;;; ---------------------------------------------------------------------------

(deftest xml-rejects-malformed-input
  (signals wp:xml-error (wp:parse-xml "<a><b></a>"))
  (signals wp:xml-error (wp:parse-xml "<a"))
  (signals wp:xml-error (wp:parse-xml "<!-- unterminated"))
  (signals wp:xml-error (wp:parse-xml "<a>&bogus;</a>"))
  (signals wp:xml-error (wp:parse-xml "<a x=1/>"))
  (signals wp:xml-error (wp:parse-xml "text before the root")))

(deftest schema-rejects-invalid-protocols
  (signals wp:invalid-schema
    (wp:parse-protocol-string "<not-a-protocol/>"))
  (signals wp:invalid-schema
    (wp:parse-protocol-string
     "<protocol name=\"p\"><interface name=\"i\" version=\"1\">
        <request name=\"r\"><arg name=\"a\" type=\"nonsense\"/></request>
      </interface></protocol>"))
  (signals wp:invalid-schema
    (wp:parse-protocol-string
     "<protocol name=\"p\"><interface name=\"i\">
        <request name=\"r\"/></interface></protocol>")))

(deftest schema-error-reports-its-file
  (handler-case
      (wp:parse-protocol-file "/nonexistent/nothing.xml")
    (error (condition)
      (is (search "nothing.xml" (princ-to-string condition))))))

;;; ---------------------------------------------------------------------------
;;; Registry
;;; ---------------------------------------------------------------------------

(deftest registry-roundtrip
  (wp:clear-protocol-registry)
  (unwind-protect
       (let* ((protocol (wp:parse-protocol-string *sample* :origin "sample.xml"))
              (surface (first (wp:protocol-interfaces protocol))))
         (wp:register-protocol protocol)
         (is (eq surface (wp:find-interface "sm_surface")))
         (is (string= "sm_buffer"
                      (wp:interface-name (wp:find-interface "sm_buffer"))))
         (is (null (wp:find-interface "no_such_interface")))
         (is (eql 2 (length (wp:registered-interfaces))))
         (wp:unregister-protocol protocol)
         (is (null (wp:find-interface "sm_surface"))))
    (wp:clear-protocol-registry)))

;;; ---------------------------------------------------------------------------
;;; The oracle: wayland-scanner private-code
;;; ---------------------------------------------------------------------------

(defun tests-directory ()
  (uiop:pathname-directory-pathname
   (asdf:component-pathname (asdf:find-system "cl-wayland-tests"))))

(defun protocol-root ()
  (uiop:subpathname (uiop:pathname-parent-directory-pathname (tests-directory))
                    "protocols/"))

(defun collect-xml-files (directory)
  (append (remove-if-not (lambda (file)
                           (string-equal "xml" (or (pathname-type file) "")))
                         (uiop:directory-files directory))
          (loop for subdirectory in (uiop:subdirectories directory)
                append (collect-xml-files subdirectory))))

(defun scanner-source (xml-path)
  "Run wayland-scanner's private-code generator on XML-PATH and return its text.
private-code, not the header: the header has no message tables, and the tables
are where opcodes and signatures live."
  (uiop:with-temporary-file (:pathname output :type "c")
    (uiop:run-program (list "wayland-scanner" "private-code"
                            (uiop:native-namestring xml-path)
                            (uiop:native-namestring output))
                      :output :string
                      :error-output :string)
    (uiop:read-file-string output)))

(defun quoted-strings (text)
  (let ((result '())
        (index 0))
    (loop
      (let ((open (position #\" text :start index)))
        (unless open (return))
        (let ((close (position #\" text :start (1+ open))))
          (unless close (return))
          (push (subseq text (1+ open) close) result)
          (setf index (1+ close)))))
    (nreverse result)))

(defun unquoted (text)
  (with-output-to-string (out)
    (let ((index 0))
      (loop
        (let ((open (position #\" text :start index)))
          (if (null open)
              (progn (write-string text out :start index) (return))
              (progn
                (write-string text out :start index :end open)
                (let ((close (position #\" text :start (1+ open))))
                  (if (null close)
                      (return)
                      (setf index (1+ close)))))))))))

(defun integers-in (text)
  (let ((clean (unquoted text))
        (result '())
        (index 0))
    (loop
      (let ((start (position-if #'digit-char-p clean :start index)))
        (unless start (return))
        (let ((end (or (position-if-not #'digit-char-p clean :start start)
                       (length clean))))
          (push (parse-integer clean :start start :end end) result)
          (setf index end))))
    (nreverse result)))

(defun split-c-list (text)
  (let ((items '())
        (start 0))
    (loop
      (let ((comma (position #\, text :start start)))
        (let ((item (string-trim '(#\Space #\Tab #\Newline #\Return)
                                 (subseq text start (or comma (length text))))))
          (when (plusp (length item))
            (push item items)))
        (if comma
            (setf start (1+ comma))
            (return))))
    (nreverse items)))

(defun ends-with-p (string suffix)
  (let ((offset (- (length string) (length suffix))))
    (and (>= offset 0)
         (string= suffix string :start2 offset))))

(defun split-message-array-name (full-name)
  (cond ((ends-with-p full-name "_requests")
         (values (subseq full-name 0 (- (length full-name) (length "_requests")))
                 :requests))
        ((ends-with-p full-name "_events")
         (values (subseq full-name 0 (- (length full-name) (length "_events")))
                 :events))
        (t (error "unexpected wl_message array name ~S" full-name))))

(defun parse-types-reference (field)
  "Parse `proto_types + 4` into (NAME . 4), or NIL for NULL."
  (cond ((null field) nil)
        ((string= (string-upcase field) "NULL") nil)
        (t (let* ((plus (position #\+ field))
                  (name (string-trim '(#\Space #\Tab) (subseq field 0 plus)))
                  (offset (parse-integer (string-trim '(#\Space #\Tab)
                                                      (subseq field (1+ plus))))))
             (cons name offset)))))

(defun parse-message-entries (body)
  "Parse `{ \"name\", \"signature\", array + N },` groups."
  (let ((entries '())
        (index 0))
    (loop
      (let ((open (position #\{ body :start index)))
        (unless open (return))
        (let* ((close (position #\} body :start open))
               (inner (subseq body (1+ open) close))
               (strings (quoted-strings inner)))
          (push (list (first strings)
                      (second strings)
                      (parse-types-reference (third (split-c-list inner))))
                entries)
          (setf index (1+ close)))))
    (nreverse entries)))

(defun scrape-scanner-output (text)
  "Scrape a private-code file into (values interfaces types-table).

INTERFACES maps name -> plist with :name :version :requests :events; TYPES maps
the per-protocol types array name to a vector of C expressions."
  (let ((types (make-hash-table :test #'equal))
        (messages (make-hash-table :test #'equal))
        (interfaces (make-hash-table :test #'equal)))
    (loop with marker = "static const struct wl_interface *"
          for start = (search marker text)
            then (search marker text :start2 (1+ start))
          while start
          do (let* ((name-start (+ start (length marker)))
                    (name-end (search "[]" text :start2 name-start))
                    (name (string-trim '(#\Space #\Tab #\Newline)
                                       (subseq text name-start name-end)))
                    (open (position #\{ text :start name-end))
                    (close (search "};" text :start2 open))
                    (body (subseq text (1+ open) close)))
               (setf (gethash name types) (coerce (split-c-list body) 'vector))))
    (loop with marker = "static const struct wl_message "
          for start = (search marker text)
            then (search marker text :start2 (1+ start))
          while start
          do (let* ((name-start (+ start (length marker)))
                    (bracket (search "[]" text :start2 name-start))
                    (full-name (string-trim '(#\Space #\Tab #\Newline)
                                            (subseq text name-start bracket)))
                    (open (position #\{ text :start bracket))
                    (close (search "};" text :start2 open))
                    (body (subseq text (1+ open) close)))
               (multiple-value-bind (interface kind)
                   (split-message-array-name full-name)
                 (setf (gethash (cons interface kind) messages)
                       (parse-message-entries body)))))
    (loop with marker = "WL_PRIVATE const struct wl_interface "
          for start = (search marker text)
            then (search marker text :start2 (1+ start))
          while start
          do (let* ((name-start (+ start (length marker)))
                    (assign (search "= {" text :start2 name-start))
                    (full-name (string-trim '(#\Space #\Tab #\Newline)
                                            (subseq text name-start assign)))
                    (interface (subseq full-name 0
                                       (- (length full-name)
                                          (length "_interface"))))
                    (open (+ assign 2))
                    (close (search "};" text :start2 open))
                    (body (subseq text (1+ open) close))
                    (numbers (integers-in body)))
               (setf (gethash interface interfaces)
                     (list :name (first (quoted-strings body))
                           :version (nth 0 numbers)
                           :requests (gethash (cons interface :requests) messages)
                           :events (gethash (cons interface :events) messages)))))
    (values interfaces types)))

(defun oracle-message-types (entry types count)
  "The scanner's types slice for a message with COUNT object arguments."
  (let ((reference (third entry)))
    (cond ((null reference)
           (when (plusp count) (list "<scanner has no types array>")))
          (t (let ((array (gethash (car reference) types)))
               (unless array
                 (return-from oracle-message-types
                   (list (format nil "<missing types array ~A>" (car reference)))))
               (loop for index from (cdr reference) below (+ (cdr reference) count)
                     collect (if (< index (length array))
                                 (aref array index)
                                 "<types array too short>")))))))

(defun expected-message-types (message)
  "wayland-scanner's types slice for MESSAGE: one entry per argument, NULL
unless the argument is an object or new_id with a declared interface.  A
message with no object arguments gets no slice at all (the scanner points it at
types + 0)."
  (when (some (lambda (arg) (member (wp:arg-type arg) '(:object :new-id)))
              (wp:message-args message))
    (mapcar (lambda (arg)
              (if (and (wp:arg-interface arg)
                       (member (wp:arg-type arg) '(:object :new-id)))
                  (format nil "&~A_interface" (wp:arg-interface arg))
                  "NULL"))
            (wp:message-args message))))

(defun compare-interface (interface oracle types)
  (let ((problems '())
        (name (wp:interface-name interface)))
    (labels ((note (control &rest arguments)
               (push (apply #'format nil control arguments) problems)))
      (unless (string= name (getf oracle :name))
        (note "~A: scanner calls it ~S" name (getf oracle :name)))
      (unless (= (wp:interface-version interface) (getf oracle :version))
        (note "~A: version ~D, scanner says ~D"
              name (wp:interface-version interface) (getf oracle :version)))
      (dolist (pair (list (cons :requests (wp:interface-requests interface))
                          (cons :events (wp:interface-events interface))))
        (let* ((kind (car pair))
               (ours (cdr pair))
               (theirs (getf oracle kind)))
          (unless (= (length ours) (length theirs))
            (note "~A ~A: ~D messages, scanner says ~D"
                  name kind (length ours) (length theirs)))
          (loop for message in ours
                for entry in theirs
                for opcode from 0
                do (unless (string= (wp:message-name message) (first entry))
                     (note "~A ~A ~D: name ~S, scanner says ~S"
                           name kind opcode (wp:message-name message)
                           (first entry)))
                   (unless (string= (wp:message-signature message) (second entry))
                     (note "~A ~A ~D (~A): signature ~S, scanner says ~S"
                           name kind opcode (wp:message-name message)
                           (wp:message-signature message) (second entry)))
                   (let* ((expected (expected-message-types message))
                          (actual (when expected
                                   (oracle-message-types
                                    entry types (length (wp:message-args message))))))
                     (unless (equal expected actual)
                       (note "~A ~A ~D (~A): types ~S, scanner says ~S"
                             name kind opcode (wp:message-name message)
                             expected actual)))))))
    (nreverse problems)))

(defun oracle-problems (xml-path protocol)
  (multiple-value-bind (oracle types)
      (scrape-scanner-output (scanner-source xml-path))
    (let ((problems '()))
      (dolist (interface (wp:protocol-interfaces protocol))
        (let ((entry (gethash (wp:interface-name interface) oracle)))
          (if (null entry)
              (push (format nil "~A: missing from the scanner output"
                            (wp:interface-name interface))
                    problems)
              (setf problems
                    (append (nreverse (compare-interface interface entry types))
                            problems)))))
      (let ((ours (sort (mapcar #'wp:interface-name (wp:protocol-interfaces protocol))
                        #'string<))
            (theirs (sort (loop for name being the hash-keys of oracle collect name)
                          #'string<)))
        (unless (equal ours theirs)
          (push (format nil "interface set differs: ours ~S, scanner ~S"
                        ours theirs)
                problems)))
      (nreverse problems))))

(deftest wl-registry-bind-has-four-arguments
  "The one message whose XML is not the wire format."
  (let* ((path (merge-pathnames "wayland/wayland.xml" (protocol-root)))
         (protocol (wp:parse-protocol-string
                    (uiop:read-file-string path :external-format :utf-8)
                    :origin (namestring path)))
         (registry (find "wl_registry" (wp:protocol-interfaces protocol)
                         :key #'wp:interface-name :test #'string=))
         (bind (first (wp:interface-requests registry))))
    (is (string= "bind" (wp:message-name bind)))
    (is (string= "usun" (wp:message-signature bind)))
    (is (equal '("name" "interface" "version" "id")
               (mapcar #'wp:arg-name (wp:message-args bind))))
    (is (equal '(:uint :string :uint :new-id)
               (mapcar #'wp:arg-type (wp:message-args bind))))))

(deftest every-vendored-protocol-matches-wayland-scanner
  (let ((files (sort (collect-xml-files (protocol-root)) #'string< :key #'namestring)))
    (is (>= (length files) 60)
        (format nil "expected the vendored corpus, found ~D XML files"
                (length files)))
    (dolist (file files)
      (let* ((protocol (wp:parse-protocol-string
                        (uiop:read-file-string file :external-format :utf-8)
                        :origin (namestring file)))
             (problems (oracle-problems file protocol)))
        (dolist (problem problems)
          (format *error-output* "~&  oracle: ~A: ~A~%" (file-namestring file) problem))
        (is (null problems)
            (format nil "wayland-scanner agrees on ~A" (file-namestring file)))))))
