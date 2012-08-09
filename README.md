pretend-event-loop
==================
This is a common lisp library that simulates an event loop. It uses threads and
queued execution (via [jpl-queues](http://www.thoughtcrime.us/software/jpl-queues/))
to make blocking operations execute in the background while letting the main
thread continue to execute.

This is (probably) not anywhere near as performant as a true event loop, but
it is a lot more performant than spawning num-cpu-cores threads and having them
sit and wait on blocking operations.

So why would you use this instead of a real event loop?
 - This library is a lot more portable. It runs on *any* implementation that
 supports threads (via [bordeaux-threads](http://common-lisp.net/project/bordeaux-threads/)).
 - This library allows you to add an event-loop-like interface to your app
 *without* reprogramming all of your libraries to be evented.

"OMG sounds great! But, how do I use it?!?!?!"
"Gee, I'm glad you asked."

Usage
-----
Any time your application does a blocking operation, queue it in the background
with the `(next)` macro. `next` executes the blocking operation in a background
thread, binds the result of the blocking operation, and continues execution in
the active (main) thread. Let's see an example with [beanstalkd](http://kr.github.com/beanstalkd/),
a distributed work queue:

	;; start the event loop with a custom error handler
    (pel:event-loop-start :error-handler #'app-error-handler)

	;; asynchronously grab a beanstalkd connection
    (pel:next (conn) (beanstalk:connect "127.0.0.1" 11300)
	  (format t "Got connection. Reserving job.~%")
	  ;; we have a connection, now asynchronously reserve the next job
	  (pel:next (job :multiple-value-list t) (beanstalk:reserve conn)
		;; we got a job! process it
		(dispatch-job job)))

So what's happening is you're creating a connection in a background thread. The
main thread continues to execute (and process more tasks, if needed). Once the
connection is created, it is bound to the variable `conn` and the execution is
continued in the main thread, with the connection still bound under `conn`.

The main thread prints the "Got connection" message and then does another
blocking operation with `beanstalk:reserve` (which blocks until a job is
available for processing). Once the job is grabbed, it is bound to `job` and the
main thread start executing `(dispatch-job job)`.

pretend-event-loop also works with long running, CPU-intensive jobs much in the
same way. If you need to process a large amount of data without blocking, you
use `(work ...)`:

    (pel:next (data) (grab-data-from-db)
	  (pel:work (result) (process-data data)
	    (format t "The result is: ~a~%" result)))

There you have it. Non-blocking IO (kind of) and a thread-pool to do heavy work.

Documentation
-------------
This is an outline of all the publicly available variables/methods in this
package.

    *max-work-threads*

`integer`. This defines how many threads are available for background
CPU-intensive tasks.  It's a *really* good idea to keep this number at
num-cores - 1 (the fourth core is used for the main thread).

    *max-passive-threads*

`integer`. How many threads are spawned specifically for running blocking ops.
If more than `*max-passive-threads*` blocking ops are queued, they are pulled
out by the passive threads FIFO. This is a value that will probably be very
dependent on your app and the machine you're running on. Obviously, the higher
you can get this number without breaking your load average, the better. Play
with it.

    (event-loop-start &key error-handler)

Start the "event loop." If specified, the error handler will be registered to
all of workers. Note that when an error happens in a passive thread, it is sent
to the active thread to be handled.

    (event-loop-stop)

Saturate each of the work queues with a function that signals them to quit. This
is more or less a graceful exit.

    (event-loop-force-stop)

Forcibly destroy all of the threads (active thread, passive threads, work
threads).

    (enqueue function &key (type :passive))

Send a function to be worked on in the background. `:type` can be one of
`(:active :passive :work)`, each one corresponding to which queue to send 
`function` to be executed on.

    (size type)

Count the items in a queue. `type` can be one of `(:active :passive :work)`.
This can be very useful for rate-limiting intake of work items in an app. For
instance, you may want to stop reading jobs off of a queue after you have a
certain number of blocking or cpu-intensive operations queued.

    (next (varname &key multiple-value-list sleep) blocking-op &body body)

Wraps `blocking-op` in a function and sends it off to the background threads for
processing. Once the passive thread finishes, it will bind the result of
`(funcall blocking-op)` to `varname` and wrap `body` in a lambda that it queues
for execution on the active thread. This way, *only* the blocking operation is
run in the background, and all other execution happens on the main thread (much
like an event loop).

If `:multiple-value-list t` is passed, the result of `(funcall blocking-op)` is
wrapped in `multiple-value-list`, so with something like `draka:http-request`,
you can get all the return values if you need them.

By default, the macro sleeps the active thread by .02s directly after queuing
the background task. This allows the background task to actually enter its
blocking operation before the active thread continues execution, the idea being
that we want to limit context switches to a minumum. If you want to change the
amount `next` sleeps, you can pass `:sleep .5` or disable it altogether with
`:sleep nil`.

    (work (varname &key multiple-value-list) cp-intensive-op &body body)

Exactly the same as the `next` macro, except it sends `cpu-intensive-op` off to
the work threads instead of the background/passive threads, and it doesn't allow
`:sleep` in the options (no point).

    (delay time &body body)

Wraps around `(next)` to create a delayed active task. Much like `setTimeout` in
Javascript. `time` is in seconds.

Performance
-----------
It's mentioned in the code over and over, but I think it's pertinent to mention
it again. _Never, ever do any real processing in your passive threads_. They are
meant for running blocking operations only, and simple error handling if you
need it. It's better to run a passive thread as close as possible to the place
it blocks. The less code between spawning a passive job and when it blocks, the
better. This system is designed to house a large number of passive threads and
the last thing you want is 100 threads doing context switches.

Also, this library makes no attempt to limit the number of blocking/work items
you queue. It is up to your application to rate limit itself in some fashion if
you are creating background work faster that it's processing.

If you find that you're doing a lot of context switching, turn down
`*max-passive-threads*` and adjust your app's rate limiting accordingly.

Notes
-----
That's it. This isn't as good as a real event loop as far as performance. As far
as converting your entire app to be evented, that takes a lot of work and might
be more of a pain in the ass than it's worth. This library meets somewhere in
the middle.
