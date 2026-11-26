;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Inbound dispatch: octets -> (resource, request, arguments) -> a method call.
;;;;
;;;; The inverse of the client's encoder, and the place where the server's share
;;;; of the robustness checklist lives (docs/protocol-layer.md §9):
;;;;
;;;;   * unknown object id            -> invalid_object
;;;;   * no request at that opcode    -> invalid_method
;;;;   * request above the resource's
;;;;     version                      -> invalid_method
;;;;   * new_id out of range or in use-> invalid_object
;;;;   * argument naming a missing object -> invalid_object
;;;;   * octets left over afterwards  -> invalid_method
;;;;   * no method specialised        -> implementation ("not built yet")
;;;;
;;;; Every one of those is a wl_display.error and a disconnect, never a Lisp
;;;; condition escaping into the loop (D9).

(in-package #:wayland.server)

(defun dispatch-message (client object-id opcode reader)
  "Dispatch one decoded message from CLIENT."
  (let ((resource (object-table-ref (client-objects client) object-id)))
    (unless resource
      (protocol-error client object-id +error-invalid-object+
                      "no object with id ~D" object-id))
    (let* ((interface (resource-interface resource))
           (request (request-at-opcode interface opcode)))
      (unless request
        (protocol-error client object-id +error-invalid-method+
                        "~A has no request with opcode ~D"
                        (interface-name interface) opcode))
      (when (> (message-since request) (resource-version resource))
        (protocol-error client object-id +error-invalid-method+
                        "~A.~A needs version ~D, but this object is version ~D"
                        (interface-name interface)
                        (message-name request)
                        (message-since request)
                        (resource-version resource)))
      ;; A decode failure is the *request's* fault, and saying which request is the
      ;; difference between a usable trace and a puzzle.
      (handler-case
          (call-request client resource request reader)
        (wayland.wire:wire-error (condition)
          (protocol-error client (resource-id resource) +error-invalid-method+
                          "malformed ~A.~A: ~A"
                          (interface-name interface)
                          (message-name request)
                          condition))))))

(defun call-request (client resource request reader)
  "Decode REQUEST's arguments and call the handler specialised on RESOURCE."
  (let ((arguments '())
        (new-ids '()))
    (dolist (argument (message-args request))
      (if (eq (arg-type argument) :new-id)
          (push (read-new-id client argument reader) new-ids)
          (push (decode-request-argument client argument reader) arguments)))
    (unless (reader-done-p reader)
      (protocol-error client (resource-id resource) +error-invalid-method+
                      "~A carries ~D octet~:P after its arguments"
                      (message-name request) (reader-remaining reader)))
    (let ((arguments (nreverse arguments))
          (function (handler-function request)))
      (unless (and function
                   (compute-applicable-methods function (cons resource arguments)))
        (protocol-error client (resource-id resource) +error-implementation+
                        "~A.~A is not implemented by this compositor"
                        (interface-name (resource-interface resource))
                        (message-name request)))
      ;; The handler claims these with ALLOCATE-RESOURCE, in wire order.
      (setf (client-pending-new-ids client) (nreverse new-ids))
      (unwind-protect
           (progn
             (apply function resource arguments)
             (when (client-pending-new-ids client)
               (error 'internal-error
                      :client client
                      :detail (format nil "~A.~A did not create its new id"
                                      (interface-name (resource-interface resource))
                                      (message-name request)))))
        (setf (client-pending-new-ids client) nil)))))

;;; ---------------------------------------------------------------------------
;;; Arguments
;;; ---------------------------------------------------------------------------

(defun read-new-id (client argument reader)
  "Read and validate the new_id the client chose for ARGUMENT."
  (let ((id (read-uint reader)))
    (unless (client-id-p id)
      (protocol-error client 1 +error-invalid-object+
                      "new id ~D for ~A is outside the client range (~D..~D)"
                      id (arg-name argument) +first-client-id+ +client-id-max+))
    (when (object-table-ref (client-objects client) id)
      (protocol-error client 1 +error-invalid-object+
                      "new id ~D for ~A is already in use"
                      id (arg-name argument)))
    id))

(defun decode-request-argument (client argument reader)
  "One request argument, with the schema's nullability honoured."
  (ecase (arg-type argument)
    (:int (read-int reader))
    (:uint (read-uint reader))
    (:fixed (read-fixed reader))
    (:string (read-string reader))
    (:array (read-array reader))
    (:fd (read-fd reader))
    (:new-id
     ;; Handled by CALL-REQUEST: it is not a parameter (D15).
     (error 'internal-error
            :client client
            :detail (format nil "new_id argument ~A reached the value decoder"
                            (arg-name argument))))
    (:object
     (let ((id (read-object reader)))
       (cond
         ((null id)
          (unless (arg-allow-null argument)
            (protocol-error client nil +error-invalid-object+
                            "argument ~A is null, and the protocol says non-null"
                            (arg-name argument)))
          nil)
         (t
          (or (object-table-ref (client-objects client) id)
              (protocol-error client id +error-invalid-object+
                              "argument ~A names object ~D, which does not exist"
                              (arg-name argument) id))))))))
