(asdf:defsystem pretend-event-loop
  :author "Andrew Lyon <andrew@musio.com>"
  :licence "MIT"
  :version "0.1.1"
  :depends-on (#:bordeaux-threads #:jpl-queues)
  :components ((:file "event")))

