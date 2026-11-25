;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The listening socket: lock file, bind, accept, teardown.
;;;;
;;;; The convention is libwayland's, because clients and session managers assume
;;;; it (docs/protocol-layer.md §5):
;;;;
;;;;   $XDG_RUNTIME_DIR/wayland-0          the socket, mode 0700
;;;;   $XDG_RUNTIME_DIR/wayland-0.lock     a lock file holding the server's pid,
;;;;                                       mode 0600, locked for the server's life
;;;;
;;;; The lock is what makes "is a compositor already here?" answerable without a
;;;; race: a second server fails to take it and says so instead of unlinking a
;;;; live socket.  A *stale* socket (lock free, file left behind by a crash) is
;;;; removed before binding, which is exactly what libwayland does.

(in-package #:wayland.server)

(defconstant +socket-mode+ #o700
  "The socket file is private to its owner: only this user may connect.")

(defconstant +lock-mode+ #o600)

(defconstant +listen-backlog+ 32
  "Enough for a session's worth of clients queueing at once; a client that is
not accepted yet is not a failure.")

;;; ---------------------------------------------------------------------------
;;; Setup and teardown
;;; ---------------------------------------------------------------------------

(defun lock-path-for (socket-path)
  (concatenate 'string socket-path ".lock"))

(defun take-socket-lock (socket-path)
  "Lock the socket name; return the descriptor that holds the lock.

A lock already held by another process is SOCKET-IN-USE, not a generic error:
that is the case the user needs to be told about, because \"is a compositor
running?\" is the question they were asking."
  (let ((lock-path (lock-path-for socket-path)))
    (handler-case
        (wayland.ffi:open-lock-file lock-path :mode +lock-mode+)
      (wayland.ffi:io-error (condition)
        (if (= (wayland.ffi:io-error-errno condition) wayland.ffi:+eagain+)
            (error 'socket-in-use :path socket-path)
            (error 'socket-condition
                   :path socket-path
                   :cause condition
                   :detail "cannot create the lock file"))))))

(defun open-display-socket (socket-path)
  "Lock SOCKET-PATH and bind a listening socket there.

Returns (values socket-fd lock-fd).  The order matters and is libwayland's:
take the lock first, so that only the process allowed to own the name is the one
that removes and rebinds it."
  (let ((lock-fd (take-socket-lock socket-path)))
    (handler-case
        (progn
          ;; Stale socket from a crashed server: safe to remove, because we hold
          ;; the lock.  UIOP's delete-file-if-exists is unlink(2) with the
          ;; missing-file case already handled.
          (uiop:delete-file-if-exists socket-path)
          (values (wayland.ffi:listen-unix-socket socket-path
                                                  :backlog +listen-backlog+
                                                  :mode +socket-mode+)
                  lock-fd))
      (error (condition)
        (close-fd lock-fd)
        (uiop:delete-file-if-exists (lock-path-for socket-path))
        (error 'socket-condition
               :path socket-path
               :cause condition
               :detail "cannot bind the socket")))))

(defun close-display-socket (socket-path socket-fd lock-fd)
  "Remove the socket file, release the lock, remove the lock file.  Idempotent.

The order is the reverse of setup: while the lock is still held nobody else can
claim the name, so the socket file we unlink is certainly ours."
  (when socket-fd
    (close-fd socket-fd))
  (uiop:delete-file-if-exists socket-path)
  (when lock-fd
    (close-fd lock-fd))
  (uiop:delete-file-if-exists (lock-path-for socket-path))
  nil)

;;; ---------------------------------------------------------------------------
;;; Accepting
;;; ---------------------------------------------------------------------------

(defun accept-peer (display)
  "Accept one connection from DISPLAY's listening socket.

Returns (values fd pid uid gid), or NIL when nobody is waiting.  A peer whose uid
is not ours is refused and closed here: a client from another user has no
business talking to this compositor, and accepting it only to disconnect it
later would let it queue messages first."
  (multiple-value-bind (fd pid uid gid)
      (wayland.ffi:accept-unix-socket (display-socket-fd display))
    (when fd
      (if (/= uid (wayland.ffi:effective-uid))
          (progn
            (log-message :warn
                         "refusing connection from uid ~D (pid ~D): not our user"
                         uid pid)
            (close-fd fd)
            nil)
          (values fd pid uid gid)))))
