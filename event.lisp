(defpackage :pretend-event-loop
  (:use :cl)
  (:export #:*max-work-threads*
           #:*max-passive-threads*
           
           #:next
           #:work
           #:delay
           #:enqueue
           #:size
           #:event-loop-stop
           #:event-loop-force-stop
           #:event-loop-start)
  (:nicknames :pel))
(in-package :pretend-event-loop)

(defparameter *max-work-threads* 3
  "The number of work threads to spawn. Work threads are used to send long 
   running CPU intensive work to without blocking the main thread. Set this
   value to (1- number-of-cores).")
(defparameter *max-passive-threads* 10
  "The maximum number of blocking operations to run in the background.")

(defvar *internal-active-queue* nil)
(defvar *internal-passive-queue* nil)
(defvar *internal-work-queue* nil)

(defvar *active-threads* nil)
(defvar *passive-threads* nil)
(defvar *work-threads* nil)

(define-condition poller-quit (error) ()
  (:report (lambda (c s) (declare (ignore c)) (format s "Quitting.")))
  (:documentation "Thrown to make a poller quit."))

(defun enqueue (fn &key (type :passive))
  "Queue a function for processing. If :type is :active, it sends it to be
   executed by the active thread, which would be the main thread in an event
   loop. It's the thread that does everything besides blocking operations.
   
   If :type is :passive, sends the function to the passive queue, to be
   executed by one of *max-passive-threads* passive workers. It is BEST PRACTICE
   (hint hint) to do as absolutely little as possible in a passive thread. You
   generally want to run your blocking operation then GTFO. If you need to
   process the result, send it to the :active thread =].

   :type can also be :work, which sends the function to a worker thread. These
   threads are specificically designated for CPU-intensive tasks, so you really
   should have no more *max-work-threads* than your number of cores.

   TL;DR: Send any blocking operations to :passive. Heavy lifting goes into
   :work. Everything else goes into :active. Don't do anything but blocking ops
   in :passive. Ever."
  (assert (find type '(:active :passive :work)))
  (jpl-queues:enqueue fn (case type
                           (:active *internal-active-queue*)
                           (:passive *internal-passive-queue*)
                           (:work *internal-work-queue*))))


(defun size (type)
  "Count how many elements are in a queue. Great for rate-limiting intake in an
   application."
  (assert (find type '(:active :passive :work)))
  (jpl-queues:size (case type
                     (:active *internal-active-queue*)
                     (:passive *internal-passive-queue*)
                     (:work *internal-work-queue*))))

(defmacro background-task (var-and-options operation &body body)
  "Wraps the following task:
    - Spawn a background task in presumably a work or passive thread,
    - Once finished, bind result to given variable, wrap in closure, and send to
      active thread for processing.

   Usage:
     (background-task (varname &key multiple-value-list sleep backround-type) &body body)
     
   This is mainly used by the next/work macros."
  (let ((varname (car var-and-options))
        (options (cdr var-and-options))
        (fake-varname (gensym)))
    ;; by default, sleep .02s after queueing blocking op
    (unless (find :sleep options)
      (setf (getf options :sleep) 0.02))
    `(progn
       ;; enqueue the blocking op in the passive queue
       (enqueue
         (lambda ()
           (let ((,(if varname varname fake-varname) ,(if (getf options :multiple-value-list)
                                                          `(multiple-value-list ,operation)
                                                          operation)))
             ;; once the op returns and is bound, we send it off the active queue,
             ;; which only the main thread will be executing
             (enqueue (lambda ()
                        ,(unless varname
                           `(declare (ignore ,fake-varname)))
                        ,@body) :type :active)))
         :type ,(if (getf options :background-type)
                    (getf options :background-type)
                    :passive))
       ;; sleep so the blocking operation has time to enter the block.
       ,(when (getf options :sleep)
          `(sleep ,(getf options :sleep))))))

(defmacro next (var-and-options blocking-op &body body)
  "Wraps around a blocking operation, grabs the result into the specified
   variable, and sends the continuing execution back into the active thread
   queue. This mimics the way an event queue works where there is one thread
   executing the program, and non-blocking operations queue callbacks once they
   return.

   After the blocking operation is queued, the active (current) thread sleeps
   for the specified amount of time (default .02s) to allow the blocking op to
   actually enter the block before it continues processing.
   
   Once the blocking operation is finished, the result is wrapped in a closure
   which is then sent off to the active queue (run by the main thread). This
   ensures that only one thread is ever doing any work, and the passive threads
   process *only* blocking operations (give or take).
   
   The best way to use this is to call your blocking for as *close* to its block
   as possible. The less computation involved in getting the thread to actually
   block, the less switching the CPU is going to be doing, and the better the
   app will perform.

   Usage:
     (next (varname &key multiple-value-list sleep) blocking-op &body body)

     (next (http-result :multiple-value-list t :sleep .01) (drakma:http-request myurl)
       (pprint http-result))"
  (let ((varname (car var-and-options))
        (options (cdr var-and-options)))
    `(background-task (,varname ,@(append (list :background-type :passive) options)) ,blocking-op ,@body)))

(defmacro work (var-and-options cpu-intensive-op &body body)
  "Wraps around creation of a work item (long-running, CPU intensive task) and
   sending the results back to the active thread. Works much like the (next ...)
   macro, except it doesn't sleep before returning to the active thread.

   Usage:
     (work (varname &key :multiple-value-list) cpu-intensive-op &body body)
     
     (work (result) (process-data)
       (print result))"
  (let ((varname (car var-and-options))
        (options (cdr var-and-options)))
    `(background-task (,varname ,@(append (list :background-type :work :sleep nil) options)) ,cpu-intensive-op ,@body)))

(defmacro delay (time &body body)
  "Delays execution by the specified number of seconds. Convenience macro that
   wraps around (next)."
  `(next () (sleep ,time)
     ,@body))

(defun active-dispatch (fn)
  "Wraps around the dispatching of active tasks. Allows adding logic around
   invoking active tasks without restarting the active thread."
  (funcall fn))

(defun passive-dispatch (fn)
  "Wraps around the dispatching of passive tasks. Allows adding logic around
   invoking passive tasks without restarting all the pollers."
  (funcall fn))

(defun work-dispatch (fn)
  "Wraps around the dispatching of work tasks. Allows adding logic around
   invoking work tasks without restarting the work threads."
  (funcall fn))

(defun active-poller (&key error-handler)
  "Start the active thread. Executes items off the active queue. Allows passing
   in of error handler which will catch any errors in the blocking op."
  (loop for active-op = (jpl-queues:dequeue *internal-active-queue*) do
    (handler-case
      (active-dispatch active-op)
      (poller-quit ()
        (return-from active-poller t))
      (error (e)
        (if (subtypep (type-of error-handler) 'function)
            (funcall error-handler e)
            (error e))))))

(defun passive-poller (&key error-handler)
  "Start a poller. Executes blocking operations off the passive queue. Allows
   passing in of error handler which will catch any errors in the blocking op.
   The error handler *is run in the active thread*."
  (loop for blocking-op = (jpl-queues:dequeue *internal-passive-queue*) do
    (handler-case 
      (passive-dispatch blocking-op)
      (poller-quit ()
        (return-from passive-poller t))
      (error (e)
        (if (subtypep (type-of error-handler) 'function)
            (enqueue (lambda () (funcall error-handler e)) :type :active)
            (error e))))))

(defun work-poller (&key error-handler)
  "Start a worker thread. Does long-running CPU intensive tasks that are not
   well suited for the active thread."
  (loop for work-op = (jpl-queues:dequeue *internal-active-queue*) do
    (handler-case
      (work-dispatch work-op)
      (poller-quit ()
        (return-from work-poller t))
      (error (e)
        (if (subtypep (type-of error-handler) 'function)
            (funcall error-handler e)
            (error e))))))

(defun event-loop-stop ()
  "Stop the event loop by signalling the active/passive workers to quit."
  (let ((quit-fn (lambda () (error 'poller-quit))))
  (dotimes (i *max-passive-threads*)
    (enqueue quit-fn))
  (dotimes (i *max-work-threads*)
    (enqueue quit-fn :type :work))
  (enqueue quit-fn :type :active)))

(defun event-loop-force-stop ()
  "Forcibly terminates the threads created."
  (dolist (thread (append *active-threads* *passive-threads* *work-threads*))
    (bt:destroy-thread thread))
  (setf *active-threads* nil
        *passive-threads* nil
        *work-threads* nil))

(defun event-loop-start (&key error-handler)
  "Start the pretend event loop. Spins up *max-passive-threads* threads, each of
   which pulls blocking operations off the passive queue and executes them and
   also spins up *max-work-threads* threads which pull operations off the work
   queue. It also starts the active thread, would would be likened to the main
   thread in an event loop (does everything, doesn't block).
   
   Allows passing in of a function that takes one argument (error object) that
   handles all unhandled errors in the active and passive threads. If an error
   happens in a passive thread, the error handler is sent *to the active thread*
   to run."
  (setf *internal-active-queue* (make-instance 'jpl-queues:synchronized-queue
                                               :queue (make-instance 'jpl-queues:unbounded-fifo-queue))
        *internal-passive-queue* (make-instance 'jpl-queues:synchronized-queue
                                                :queue (make-instance 'jpl-queues:unbounded-fifo-queue))
        *internal-work-queue* (make-instance 'jpl-queues:synchronized-queue
                                             :queue (make-instance 'jpl-queues:unbounded-fifo-queue)))
  ;; start THE active thread
  (push (bt:make-thread (lambda () (active-poller :error-handler error-handler)) :name "active-worker")
        *active-threads*)

  ;; start the passive threads
  (dotimes (i *max-passive-threads*)
    (push (bt:make-thread (lambda () (passive-poller :error-handler error-handler)) :name (format nil "passive-worker-~a" i))
          *passive-threads*)
    ;(when (zerop (mod (1+ i) 10)) (format t "Created thread ~a~%" (1+ i)))
    (sleep .01))

  ;; start the worker threads
  (dotimes (i *max-work-threads*)
    (push (bt:make-thread (lambda () (work-poller :error-handler error-handler)) :name (format nil "work-worker-~a" i))
          *work-threads*)
    (sleep .01)))

