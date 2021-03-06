;;; Copyright (c) 2013, James M. Lawrence. All rights reserved.
;;;
;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:
;;;
;;;     * Redistributions of source code must retain the above copyright
;;;       notice, this list of conditions and the following disclaimer.
;;;
;;;     * Redistributions in binary form must reproduce the above
;;;       copyright notice, this list of conditions and the following
;;;       disclaimer in the documentation and/or other materials provided
;;;       with the distribution.
;;;
;;;     * Neither the name of the project nor the names of its
;;;       contributors may be used to endorse or promote products derived
;;;       from this software without specific prior written permission.
;;;
;;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;; "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;; LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;; A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;; HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;; SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
;;; LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
;;; DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
;;; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
;;; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
;;; OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

(defpackage #:lfarm-server
  (:documentation
   "A server accepts tasks, executes them, and returns the results.")
  (:use #:cl
        #:lfarm-common)
  (:export #:start-server))

(in-package #:lfarm-server)

;;;; util

(defwith ignore-errors/log ()
  (handler-case (call-body)
    (error (err)
      (info "ignoring error" err)
      (values nil err))))

(defun socket-close* (socket)
  (ignore-errors/log (socket-close socket)))

;;; CCL sometimes balks at connection attempts (issue #1050)
#+ccl
(defwith with-bug-handler ()
  (with-tag :retry
    (handler-bind (((or usocket:unknown-error usocket:invalid-argument-error)
                    (lambda (err)
                      (info "socket error bug, retrying" err)
                      (go :retry))))
      (call-body))))

#-ccl
(defwith with-bug-handler ()
  (call-body))

(defmacro dynamic-closure (vars &body body)
  "Capture the values of the dynamic variables in `vars' and return a
closure in which those variables are bound to the captured values."
  (let ((syms (loop repeat (length vars) collect (gensym))))
    `(let ,(mapcar #'list syms vars)
       (lambda ()
         (let ,(mapcar #'list vars syms)
           ,@body)))))

;;;; package generator

(defvar *package-creation-lock* (make-lock))

;;; Allegro and ABCL signal `reader-error' for a missing package
;;; during `read'. We must parse the report string in order to get the
;;; package name.
#+(and (or abcl allegro) lfarm.with-text-serializer)
(progn
  (defparameter *match-around* #+abcl '("The package \"" "\" can't be found.")
                               #+allegro '("Package \"" "\" not found"))

  (defun match-around (seq left right)
    ;; (match-around "hello !want this! world" "hello !" "! world")
    ;; => "want this"
    (when-let* ((left-pos (search left seq))
                (match-pos (+ left-pos (length left)))
                (right-pos (search right seq :start2 match-pos)))
      (subseq seq match-pos right-pos)))

  (defun extract-package-name (err)
    (apply #'match-around (princ-to-string err) *match-around*))

  (defwith with-missing-package-handler (action)
    (handler-bind ((reader-error
                    (lambda (err)
                      (when-let (name (extract-package-name err))
                        (funcall action name)))))
      (call-body))))

;;; Allegro signals `type-error' for a missing package during
;;; `cl-store:restore'. According to Franz, if package `foo' does not
;;; exist then `:foo' is not a package designator, which is why
;;; (intern "BAR" :foo) signals a `type-error'. `cl-store:restore'
;;; calls `intern' when restoring a symbol.
#+(and allegro (not lfarm.with-text-serializer))
(defwith with-missing-package-handler (action)
  (handler-bind ((type-error
                  (lambda (err)
                    (when (eq 'package (type-error-expected-type err))
                      (funcall action (type-error-datum err))))))
    (call-body)))

;;; In all other cases `package-error' is signaled for a missing package.
#-(or (and (or abcl allegro) lfarm.with-text-serializer)
      (and allegro (not lfarm.with-text-serializer)))
(defwith with-missing-package-handler (action)
  (handler-bind ((package-error
                  (lambda (err)
                    (funcall action (package-error-package err)))))
    (call-body)))

(defwith with-package-generator ()
  (with-tag :retry
    (flet ((make-package-and-retry (name)
             (with-lock-predicate/wait
                 *package-creation-lock* (not (find-package name))
               (info "creating package" name)
               (make-package name :use nil))
             (go :retry)))
      (with-missing-package-handler (#'make-package-and-retry)
        (call-body)))))

;;;; task category tracking

;;; Vector of task category ids currently running.
(defvar *tasks*)

;;; Lock for *tasks*.
(defvar *tasks-lock*)

;;; Each task loop thread has an index into the `*tasks*' vector.
(defvar *task-index*)

;;; Value when no job is running.
(defconstant +idle+ 'idle)

(defwith with-task-tracking ()
  (let ((*tasks* (make-array 0 :fill-pointer 0 :adjustable t))
        (*tasks-lock* (make-lock)))
    (call-body)))

(defwith with-tasks-lock ()
  (with-lock-held (*tasks-lock*)
    (call-body)))

(defwith environment-closure ()
  (dynamic-closure (*auth* *tasks* *tasks-lock*)
    (call-body)))

(defun acquire-task-index ()
  (with-tasks-lock
    (let ((index (position nil *tasks*)))
      (if index
          (prog1 index
            (setf (aref *tasks* index) +idle+))
          (prog1 (length *tasks*)
            (vector-push-extend +idle+ *tasks*))))))

(defun release-task-index ()
  (setf (aref *tasks* *task-index*) nil))

(defwith with-task-index ()
  (unwind-protect/safe-bind
   :bind (*task-index* (acquire-task-index))
   :main (call-body)
   :cleanup (release-task-index)))

(defwith with-task-category-id (task-category-id)
  (let ((previous (aref *tasks* *task-index*)))
    (assert previous)
    (unwind-protect/safe
     :prepare (setf (aref *tasks* *task-index*)
                    (cons task-category-id (current-thread)))
     :main    (call-body)
     :cleanup (setf (aref *tasks* *task-index*) previous))))

(defun kill-tasks (task-category-id)
  (dosequence (elem (with-tasks-lock (copy-seq *tasks*)))
    (etypecase elem
      (cons (destructuring-bind (id . thread) elem
              (when (eql id task-category-id)
                (info "killing task loop" id thread)
                (ignore-errors/log (destroy-thread thread)))))
      (null)
      (symbol (assert (eq elem +idle+))))))

;;;; task loop

(defun maybe-compile (fn-form)
  (etypecase fn-form
    (symbol fn-form)
    (cons (compile nil fn-form))))

(defun exec-task (task)
  (destructuring-bind (task-category-id fn-form &rest args) task
    (with-task-category-id (task-category-id)
      (apply (maybe-compile fn-form) args))))

(defun deserialize-task (buffer corrupt-handler)
  (with-package-generator
    (handler-bind ((end-of-file corrupt-handler))
      (deserialize-buffer buffer))))

(defun process-task (stream buffer task-handler corrupt-handler)
  (let* ((task (deserialize-task buffer corrupt-handler))
         (result (handler-bind ((error task-handler))
                   (exec-task task))))
    (info "task result" result stream)
    (handler-bind ((error task-handler))
      (send-object result stream))))

(defun read-task-buffer (stream clean-return corrupt-handler)
  (handler-bind ((end-of-file clean-return)
                 (corrupted-stream-error corrupt-handler))
    (receive-serialized-buffer stream)))

(defun read-and-process-task (stream clean-return corrupt-handler next-task)
  (let ((buffer (read-task-buffer stream clean-return corrupt-handler)))
    (info "new task" buffer stream)
    (flet ((task-handler (err)
             (info "error during task execution" err stream)
             (send-object (make-task-error-data err) stream)
             (funcall next-task)))
      (process-task stream buffer #'task-handler corrupt-handler))))

(defun task-loop (stream)
  (info "start task loop" stream (current-thread))
  (with-tag :next-task
    (info "reading next task")
    (flet ((clean-return (err)
             (declare (ignore err))
             (info "end task loop" stream)
             (return-from task-loop))
           (corrupt-handler (err)
             (info "corrupted stream" err stream)
             (ignore-errors/log (send-object +corrupt-stream-flag+ stream))
             (go :next-task))
           (next-task ()
             (go :next-task)))
      (read-and-process-task
       stream #'clean-return #'corrupt-handler #'next-task))
    (go :next-task)))

;;;; responses

(defun respond (message stream)
  (ecase message
    (:ping (send-object :pong stream))
    (:task-loop (send-object :in-task-loop stream)
                (with-task-index
                  (task-loop stream)))
    (:kill-tasks (kill-tasks (receive-object stream)))))

;;;; dispatch

(defun call-respond (message socket)
  (with-errors-logged
    (unwind-protect/safe
     :main (respond message (socket-stream socket))
     :cleanup (socket-close* socket))))

(defun spawn-response (message socket)
  (make-thread (environment-closure
                 (call-respond message socket))
               :name (format nil "lfarm-server response ~a" message)))

(defun dispatch (socket)
  (let ((message (receive-object (socket-stream socket))))
    (info "message" message socket)
    (case message
      (:end-server (socket-close* socket))
      (otherwise (spawn-response message socket)))
    message))

;;;; start-server

(defwith with-auth-error-handler ()
  (handler-case (call-body)
    (lfarm-common.data-transport:auth-error (err)
      (info "auth error:" (princ-to-string err))
      nil)))

(defwith with-server ((:vars server) host port)
  (with-errors-logged
    (with-bug-handler
      (with-connected-socket (server (socket-listen host port))
        (with-task-tracking
          (call-body server))))))

(defun server-loop (server)
  (loop (with-auth-error-handler
          (unwind-protect/safe-bind
           :bind (socket (socket-accept server))
           :main (case (dispatch socket)
                   (:end-server (return)))
           :abort (socket-close* socket)))))

(defun %start-server (host port)
  (info "server starting" host port *auth*)
  (with-server (server host port)
    (server-loop server))
  (info "server ending" host port))

(defun spawn-server (host port name)
  (make-thread (dynamic-closure (*auth*) (%start-server host port))
               :name name))

(defun start-server (host port
                     &key
                     background
                     (name (format nil "lfarm-server ~a:~a" host port))
                     ((:auth *auth*) *auth*))
  "Start a server instance listening at host:port.

If `background' is true then spawn the server in a separate thread
named `name'."
  (if background
      (spawn-server host port name)
      (%start-server host port)))
