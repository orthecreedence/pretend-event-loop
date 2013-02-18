(defpackage :pretend-event-loop
  (:use :cl)
  (:export #:*default-event-loop*
           #:enqueue
           #:size
           #:fullp
           #:next
           #:work
           #:delay
           #:active-poller
           #:event-loop-stop
           #:event-loop-force-stop
           #:make-event-loop
           #:event-loop-start)
  (:nicknames :pel))
(in-package :pretend-event-loop)

(defclass event-loop ()
  ((num-work-threads :accessor event-loop-num-work-threads :initarg :num-work-threads :initform 1
     :documentation "The number of work threads to spawn. Work threads are used
      to send long running CPU intensive work to without blocking the main
      thread. Set this value to (1- number-of-cores).")
   (num-passive-threads :accessor event-loop-num-passive-threads :initarg :num-passive-threads :initform 1
     :documentation "The maximum number of blocking operations to run in the
      background.")
   (active-queue :accessor event-loop-active-queue :initarg :active-queue :initform nil)
   (passive-queue :accessor event-loop-passive-queue :initarg :passive-queue :initform nil)
   (work-queue :accessor event-loop-work-queue :initarg :work-queue :initform nil)
   (passive-threads :accessor event-loop-passive-threads :initarg :passive-threads :initform nil)
   (work-threads :accessor event-loop-work-threads :initarg :work-threads :initform nil)))

(defmethod print-object ((event-loop event-loop) s)
  (format s "#<event-loop (~s passive threads) (~s work-threads)>"
          (length (remove-if-not #'bt:thread-alive-p (event-loop-passive-threads event-loop)))
          (length (remove-if-not #'bt:thread-alive-p (event-loop-work-threads event-loop)))))
                  
(defvar *default-event-loop* nil)

(define-condition poller-quit (error) ()
  (:report (lambda (c s) (declare (ignore c)) (format s "Quitting.")))
  (:documentation "Thrown to make a poller quit."))

(defun enqueue (fn &key (type :passive) (event-loop *default-event-loop*))
  "Queue a function for processing. If :type is :active, it sends it to be
   executed by the active thread, which would be the main thread in an event
   loop. It's the thread that does everything besides blocking operations.
   
   If :type is :passive, sends the function to the passive queue, to be
   executed by one of (event-loop-num-passive-threads event-loop) passive workers. It is BEST PRACTICE
   (hint hint) to do as absolutely little as possible in a passive thread. You
   generally want to run your blocking operation then GTFO. If you need to
   process the result, send it to the :active thread =].

   :type can also be :work, which sends the function to a worker thread. These
   threads are specificically designated for CPU-intensive tasks, so you really
   should have no more (event-loop-num-work-threads event-loop) than your number of cores.

   TL;DR: Send any blocking operations to :passive. Heavy lifting goes into
   :work. Everything else goes into :active. Don't do anything but blocking ops
   in :passive. Ever."
  (assert (find type '(:active :passive :work)))
  (jpl-queues:enqueue fn (case type
                           (:active (event-loop-active-queue event-loop))
                           (:passive (event-loop-passive-queue event-loop))
                           (:work (event-loop-work-queue event-loop)))))

(defun size (type &key (event-loop *default-event-loop*))
  "Count how many elements are in a queue. Great for rate-limiting intake in an
   application."
  (assert (find type '(:active :passive :work)))
  (jpl-queues:size (case type
                     (:active (event-loop-active-queue event-loop))
                     (:passive (event-loop-passive-queue event-loop))
                     (:work (event-loop-work-queue event-loop)))))

(defun fullp (type &key (event-loop *default-event-loop*))
  "Test if a specific queue is full."
  (assert (find type '(:active :passive :work)))
  (case type
    (:passive (< (event-loop-num-passive-threads event-loop) (size :passive)))
    (:work (< (event-loop-num-work-threads event-loop) (size :work)))
    (:active nil)))

(defmacro background-task ((varname &key sleep (background-type :passive) multiple-value-list (event-loop '*default-event-loop*)) operation &body body)
  "Wraps the following task:
    - Spawn a background task in presumably a work or passive thread,
    - Once finished, bind result to given variable, wrap in closure, and send to
      active thread for processing.

   Usage:
     (background-task (varname &key multiple-value-list sleep backround-type) &body body)
     
   This is mainly used by the next/work macros."
  (let ((fake-varname (gensym)))
    ;; by default, sleep .02s after queueing blocking op
    `(progn
       ;; enqueue the blocking op in the passive queue
       (enqueue
         (lambda ()
           (let ((,(if varname varname fake-varname) ,(if multiple-value-list
                                                          `(multiple-value-list ,operation)
                                                          operation)))
             ;; once the op returns and is bound, we send it off the active queue,
             ;; which only the main thread will be executing
             (enqueue (lambda ()
                        ,(unless varname
                           `(declare (ignore ,fake-varname)))
                        ,@body)
                      :type :active
                      :event-loop ,event-loop)))
         :type ,background-type)
       ;; sleep so the blocking operation has time to enter the block.
       ,(when sleep
          `(sleep ,sleep)))))

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

(defmacro wrap-poller-error-handling ((error-bind error-handler) op quit trigger-error)
  "Removes ugliness from poller error handling (or lack thereof)."
  `(if (functionp ,error-handler)
       (handler-case
         ,op
         (poller-quit ()
           ,quit)
         (error (,error-bind)
           ,trigger-error))
       (handler-case
         ,op
         (poller-quit ()
           ,quit))))

(defun active-poller (&key (event-loop *default-event-loop*) error-handler)
  "Start the active thread. Executes items off the active queue. Allows passing
   in of error handler which will catch any errors in the blocking op."
  (loop until (jpl-queues:empty? (event-loop-active-queue event-loop))
        for active-op = (jpl-queues:dequeue (event-loop-active-queue event-loop)) do
    (wrap-poller-error-handling (e error-handler)
      (active-dispatch active-op)
      (return-from active-poller t)
      (funcall error-handler e))))

(defun passive-poller (&key (event-loop *default-event-loop*) error-handler)
  "Start a poller. Executes blocking operations off the passive queue. Allows
   passing in of error handler which will catch any errors in the blocking op.
   The error handler *is run in the active thread*."
  (loop for blocking-op = (jpl-queues:dequeue (event-loop-passive-queue event-loop)) do
    (wrap-poller-error-handling (e error-handler)
      (passive-dispatch blocking-op)
      (return-from passive-poller t)
      (enqueue (lambda () (funcall error-handler e)) :type :active))))

(defun work-poller (&key (event-loop *default-event-loop*) error-handler)
  "Start a worker thread. Does long-running CPU intensive tasks that are not
   well suited for the active thread."
  (loop for work-op = (jpl-queues:dequeue (event-loop-work-queue event-loop)) do
    (wrap-poller-error-handling (e error-handler)
      (work-dispatch work-op)
      (return-from work-poller t)
      (enqueue (lambda () (funcall error-handler e)) :type :active))))

(defun event-loop-stop (&key (event-loop *default-event-loop*))
  "Stop the event loop by signalling the active/passive workers to quit."
  (let ((quit-fn (lambda () (error 'poller-quit))))
  (dotimes (i (event-loop-num-passive-threads event-loop))
    (sleep .01)
    (enqueue quit-fn))
  (dotimes (i (event-loop-num-work-threads event-loop))
    (enqueue quit-fn :type :work))
  (enqueue quit-fn :type :active)))

(defun event-loop-force-stop (&key (event-loop *default-event-loop*))
  "Forcibly terminates the threads created."
  (dolist (thread (append (event-loop-passive-threads event-loop)
                          (event-loop-work-threads event-loop)))
    (bt:destroy-thread thread))
  (setf (event-loop-passive-threads event-loop) nil
        (event-loop-work-threads event-loop) nil))

(defun make-event-loop (&key (num-passive 0) (num-workers 0))
  "Initialize an event loop (queues, mainly)."
  (let ((event-loop (make-instance 'event-loop
                                   :num-work-threads num-workers
                                   :num-passive-threads num-passive
                                   :active-queue (make-instance 'jpl-queues:synchronized-queue
                                                                :queue (make-instance 'jpl-queues:unbounded-fifo-queue))
                                   :passive-queue (make-instance 'jpl-queues:synchronized-queue
                                                                 :queue (make-instance 'jpl-queues:unbounded-fifo-queue))
                                   :work-queue (make-instance 'jpl-queues:synchronized-queue
                                                              :queue (make-instance 'jpl-queues:unbounded-fifo-queue)))))
    (unless *default-event-loop*
      (setf *default-event-loop* event-loop))
    event-loop))

(defun event-loop-start (&key (event-loop *default-event-loop*) error-handler)
  "Start the pretend event loop. Spins up (event-loop-num-passive-threads event-loop) threads, each of
   which pulls blocking operations off the passive queue and executes them and
   also spins up (event-loop-num-work-threads event-loop) threads which pull operations off the work
   queue. It also starts the active thread, would would be likened to the main
   thread in an event loop (does everything, doesn't block).
   
   If no work items are left in the active thread, it will return (but all the
   queues will remain active). This allows tighter integration with a real event
   loop. Once enqueue/next/work/etc is called again, the active poller will
   start.
   
   Allows passing in of a function that takes one argument (error object) that
   handles all unhandled errors in the active and passive threads. If an error
   happens in a passive thread, the error handler is sent *to the active thread*
   to run."
  ;; start the passive threads
  (dotimes (i (event-loop-num-passive-threads event-loop))
    (push (bt:make-thread (lambda () (passive-poller :error-handler error-handler)) :name (format nil "passive-worker-~a" i))
          (event-loop-passive-threads event-loop))
    (sleep .01))

  ;; start the worker threads
  (dotimes (i (event-loop-num-work-threads event-loop))
    (push (bt:make-thread (lambda () (work-poller :error-handler error-handler)) :name (format nil "work-worker-~a" i))
          (event-loop-work-threads event-loop))
    (sleep .01)))

