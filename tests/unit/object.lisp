;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Object tables and the two id namespaces (wayland.object).
;;;;
;;;; These are the rules that both ends depend on and that are easy to get subtly
;;;; wrong: which ids are whose, that the lowest free id comes back first, and
;;;; that a released id is never handed out twice.

(in-package #:cl-user)

(defpackage #:wayland.test.object
  (:use #:cl #:rove)
  (:local-nicknames (#:obj #:wayland.object))
  (:documentation "Tests for wayland.object: id allocation and object tables."))

(in-package #:wayland.test.object)

(deftest id-namespaces
  (ok (obj:client-id-p 2))
  (ok (obj:client-id-p obj:+client-id-max+))
  (ok (not (obj:client-id-p 1)) "id 1 is wl_display, which neither side allocates")
  (ok (not (obj:client-id-p 0)) "0 is the wire's null object")
  (ok (not (obj:client-id-p (1+ obj:+client-id-max+))))
  (ok (obj:server-id-p obj:+first-server-id+))
  (ok (obj:server-id-p obj:+max-id+))
  (ok (not (obj:server-id-p (1- obj:+first-server-id+))))
  (ok (not (obj:server-id-p (1+ obj:+max-id+)))))

(deftest allocation-starts-at-two-and-counts-up
  (let ((table (obj:make-object-table)))
    (ok (= 2 (obj:allocate-client-id table)))
    (ok (= 3 (obj:allocate-client-id table)))
    (ok (= 4 (obj:allocate-client-id table)))))

(deftest released-ids-come-back-lowest-first
  (let ((table (obj:make-object-table)))
    (dotimes (index 3) (obj:allocate-client-id table))   ; 2, 3, 4
    (obj:release-client-id table 4)
    (obj:release-client-id table 2)
    (ok (= 2 (obj:allocate-client-id table)) "lowest free id first, as libwayland does")
    (ok (= 4 (obj:allocate-client-id table)))
    (ok (= 5 (obj:allocate-client-id table)) "the counter carries on after the free list")))

(deftest releasing-twice-does-not-duplicate
  (let ((table (obj:make-object-table)))
    (obj:allocate-client-id table)                      ; 2
    (obj:release-client-id table 2)
    (obj:release-client-id table 2)
    (ok (= 2 (obj:allocate-client-id table)))
    (ok (= 3 (obj:allocate-client-id table)))))

(deftest out-of-range-releases-are-ignored
  (let ((table (obj:make-object-table)))
    (obj:release-client-id table 1)
    (obj:release-client-id table obj:+first-server-id+)
    (obj:release-client-id table 0)
    (ok (= 2 (obj:allocate-client-id table))
        "a released id outside the client range must not become allocatable")))

(deftest server-ids-are-their-own-range
  (let ((table (obj:make-object-table)))
    (ok (= obj:+first-server-id+ (obj:allocate-server-id table)))
    (ok (= (1+ obj:+first-server-id+) (obj:allocate-server-id table)))
    (ok (= 2 (obj:allocate-client-id table))
        "the two counters are independent: a server id does not consume a client id")
    (obj:release-server-id table obj:+first-server-id+)
    (ok (= obj:+first-server-id+ (obj:allocate-server-id table)))
    (obj:release-server-id table 3)
    (ok (= 3 (obj:allocate-client-id table))
        "releasing a client id does not touch the server free list")))

(deftest table-set-ref-remove
  (let ((table (obj:make-object-table)))
    (ok (null (obj:object-table-ref table 2)))
    (obj:object-table-set table 2 :two)
    (ok (eq :two (obj:object-table-ref table 2)))
    (ok (= 1 (obj:object-table-count table)))
    (ok (signals (obj:object-table-set table 2 :again) 'error)
        "reusing a live id is a bug in the caller, not an overwrite")
    (ok (eq :two (obj:object-table-remove table 2)))
    (ok (null (obj:object-table-remove table 2)) "removing twice is not an error")
    (ok (zerop (obj:object-table-count table)))))

(deftest table-ids-are-ascending
  (let ((table (obj:make-object-table)))
    (dolist (id '(9 3 7 1)) (obj:object-table-set table id id))
    (ok (equal '(1 3 7 9) (obj:object-table-ids table)))))
