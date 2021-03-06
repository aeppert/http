;;;; Simple HTTP Package for LispWorks
;;;;
;;;; Copyright (c) 2013 by Jeffrey Massung
;;;;
;;;; This file is provided to you under the Apache License,
;;;; Version 2.0 (the "License"); you may not use this file
;;;; except in compliance with the License.  You may obtain
;;;; a copy of the License at
;;;;
;;;;    http://www.apache.org/licenses/LICENSE-2.0
;;;;
;;;; Unless required by applicable law or agreed to in writing,
;;;; software distributed under the License is distributed on an
;;;; "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
;;;; KIND, either express or implied.  See the License for the
;;;; specific language governing permissions and limitations
;;;; under the License.
;;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "comm"))

(defpackage :http
  (:use :cl :lw :system :comm :re :lexer :parsergen :base64)
  (:export
   #:request
   #:response
   #:url

   ;; url helpers
   #:parse-url
   #:encode-url
   #:decode-url
   #:format-url

   ;; macros
   #:with-url
   #:with-headers

   ;; data post body functions
   #:make-query-string
   #:parse-query-string

   ;; request functions
   #:http-perform
   #:http-follow
   #:http-head
   #:http-get
   #:http-options
   #:http-trace
   #:http-delete
   #:http-put
   #:http-post
   #:http-patch

   ;; url accessors
   #:url-domain
   #:url-port
   #:url-auth
   #:url-scheme
   #:url-secure
   #:url-path
   #:url-query
   #:url-fragment
   
   ;; http request accessors
   #:request-url
   #:request-method
   #:request-headers
   #:request-data

   ;; response accessors
   #:response-code
   #:response-status
   #:response-headers
   #:response-body
   #:response-request))

(in-package :http)

(defclass url ()
  ((domain   :initarg :domain   :accessor url-domain)
   (port     :initarg :port     :accessor url-port     :initform nil)
   (auth     :initarg :auth     :accessor url-auth     :initform nil)
   (scheme   :initarg :scheme   :accessor url-scheme   :initform :http)
   (path     :initarg :path     :accessor url-path     :initform "/")
   (query    :initarg :query    :accessor url-query    :initform nil)
   (fragment :initarg :fragment :accessor url-fragment :initform nil))
  (:documentation "Universal Resource Locator."))

(defclass request ()
  ((url      :initarg :url      :accessor request-url)
   (method   :initarg :method   :accessor request-method  :initform "GET")
   (headers  :initarg :headers  :accessor request-headers :initform nil)
   (data     :initarg :data     :accessor request-data    :initform nil))
  (:documentation "A request for a URL from an HTTP server."))

(defclass response ()
  ((code     :initarg :code     :accessor response-code)
   (status   :initarg :status   :accessor response-status)
   (headers  :initarg :headers  :accessor response-headers)
   (body     :initarg :body     :accessor response-body)
   (request  :initarg :request  :accessor response-request))
  (:documentation "The response from a request to an HTTP server."))

(defmethod print-object ((url url) s)
  "Output a URL to a stream."
  (print-unreadable-object (url s :type t) (format s "~s" (format-url url))))

(defmethod print-object ((req request) s)
  "Output an HTTP request to a stream."
  (print-unreadable-object (req s :type t)
    (with-slots (method url)
        req
      (format s "~a ~s" method (format-url url)))))

(defmethod print-object ((resp response) stream)
  "Output an HTTP response to a stream."
  (print-unreadable-object (resp stream :type t)
    (with-slots (code status)
        resp
      (format stream "~a ~s" code status))))

(defparameter *status-re* (compile-re "^HTTP/[^%s]+%s+(%d+)%s+([^%n]+)")
  "Pattern for parsing a response status code and message.")
(defparameter *header-re* (compile-re "^([^:]+):%s*([^%n]*)")
  "Pattern for parsing a response header line.")

(defconstant +reserved-chars+ '(#\% #\$ #\& #\+ #\, #\/ #\: #\; #\= #\? #\@)
  "Reserved URL characters that *must* be encoded.")
(defconstant +unwise-chars+ '(#\{ #\} #\| #\\ #\^ #\[ #\] #\`)
  "Characters presenting a possibility of being misunderstood and should be encoded.")
(defconstant +http-schemes+ '((:http 80) (:https 443))
  "A list of valid HTTP schemes and their default ports.")
(defconstant +url-format+ "~(~a~)://~@[~a@~]~a~:[:~a~;~*~]~a~@[?~a~]~@[#~a~]"
  "The format options used to recreate a URL string.")

(defun http-scheme (name)
  "Return the scheme keyword for a given scheme or NIL."
  (flet ((scheme-equal (a b)
           (string-equal a (symbol-name b))))
    (or (first (assoc name +http-schemes+ :test #'scheme-equal))

        ;; signal an error
        (error "Unknown HTTP scheme ~s" name))))

(defun http-port (url)
  "Returns the proper port for a URL given scheme."
  (or (url-port url) (second (assoc (url-scheme url) +http-schemes+))))

(deflexer url-lexer
  ("%."                       (values :dot))
  ("^([^/:]+)://"             (values :scheme (http-scheme $1)))
  ("([^:]+:[^@]+)@"           (values :auth $1))
  ("/[^?#]*"                  (values :path $$))
  ("%?([^#]+)"                (values :query $1))
  ("#(.*)"                    (values :fragment $1))
  ("[%a%d%-]+"                (values :domain $$))
  (":(%d+)"                   (values :port (parse-integer $1))))

(defparser url-parser
  ((start url) $1)

  ;; http://login:password@www.host.com:80/index.html
  ((url scheme) $1)
  ((url :error) (error "Invalid URL"))

  ;; http://
  ((scheme :scheme auth) `(:scheme ,$1 ,@$2))
  ((scheme auth) `(:scheme :http ,@$1))

  ;; login:password@
  ((auth :auth domain) `(:auth ,$1 ,@$2))
  ((auth domain) `(:auth nil ,@$1))

  ;; www.host.com
  ((domain host port) `(:domain ,$1 ,@$2))

  ;; host.com
  ((host :domain :dot host) (string-append $1 #\. $3))
  ((host :domain) $1)

  ;; :80
  ((port :port path) `(:port ,$1 ,@$2))
  ((port path) `(:port nil ,@$1))

  ;; /index.html
  ((path :path query) `(:path ,$1 ,@$2))
  ((path query) `(:path "/" ,@$1))

  ;; ?q=value
  ((query :query fragment) `(:query ,(parse-query-string $1) ,@$2))
  ((query fragment) $1)

  ;; #anchor
  ((fragment :fragment) `(:fragment ,$1))
  ((fragment)) nil)

(defmacro with-url ((url url-expr) &body body)
  "Parse a URL if necessary, bind it, and execute a body."
  (let ((p (gensym)))
    `(let ((,p ,url-expr))
       (let ((,url (if (eq (type-of ,p) 'url)
                       ,p
                     (parse-url ,p))))
         (progn ,@body)))))

(defmacro with-headers ((&rest bindings) headers-expr &body body)
  "Extract a value from an HTTP header assoc list."
  (let ((headers (gensym)))
    `(let ((,headers ,headers-expr))
       (let (,@(loop :for binding :in bindings
                     :collect (destructuring-bind (var key &key if-not-found)
                                  binding
                                `(,var (or (second (assoc ,key ,headers :test #'string=)) ,if-not-found)))))
         (progn ,@body)))))

(defun parse-url (url)
  "Parse a URL and return. If URL is relative, set what it's relative to."
  (let ((spec (parse #'url-parser (tokenize #'url-lexer url))))
    (apply #'make-instance (cons 'url spec))))

(defun format-url (url &optional stream)
  "Print a URL as a complete string."
  (with-slots (scheme auth domain port path query fragment)
      url
    (let ((qs (when query (make-query-string query))))
      (format stream +url-format+ scheme auth domain (null port) port path qs fragment))))

(defun escape-char-p (c)
  "T if a character needs to be escaped in a URL."
  (or (char< c #\!)
      (char> c #\~)

      ;; reserved and unsafe characters
      (find c +unwise-chars+ :test #'char=)
      (find c +reserved-chars+ :test #'char=)))

(defun encode-url (string)
  "Convert a string into a URL-safe, encoded string."
  (with-output-to-string (url)
    (loop :for c :across string
          :do (if (escape-char-p c)
                  (if (char= c #\space)
                      (princ #\+ url)
                    (format url "%~16,2,'0r" (char-code c)))
                (princ c url)))))

(defun decode-url (url)
  "Decode an encoded URL into a string. Returns NIL if malformed."
  (with-output-to-string (string)
    (with-input-from-string (s url)
      (loop :for c := (read-char s nil nil)
            :while c
            :do (case c
                  (#\+ (princ #\space string))
                  (#\% (let ((c1 (read-char s nil nil))
                             (c2 (read-char s nil nil)))
                         (when (and c1 c2)
                           (let ((code (logior (ash (parse-integer (string c1) :radix 16) 4)
                                               (ash (parse-integer (string c2) :radix 16) 0))))
                             (princ (code-char code) string)))))
                  (otherwise
                   (princ c string)))))))

(defun make-query-string (query)
  "Build a k=v&.. query string from an associative list, properly url-encoded."
  (with-output-to-string (qs)
    (loop :for p :in query :and i :from 0
          :do (destructuring-bind (key value)
                  p
                (format qs "~:[~;&~]~a=~a" (plusp i) key (encode-url (princ-to-string value)))))))

(defun parse-query-string (qs)
  "Return an associative list of query string parameters."
  (let ((q (split-sequence "&=" qs)))
    (loop :for k := (pop q)
          :for v := (pop q)
          :while k
          :collect (list k (if v (decode-url v) "")))))

(defun basic-auth-string (login)
  "Create the basic auth value for the Authorization header."
  (format nil "Basic ~a" (base64-encode login)))

(defun read-http-status (http)
  "Parse the line and parse it. Return the code and value."
  (with-re-match (match (match-re *status-re* (read-line http)))
    (values (parse-integer $1) $2)))

(defun read-http-headers (http)
  "Parse a header line. Return the key and value."
  (flet ((read-header ()
           (with-re-match (match (match-re *header-re* (read-line http)))
             (list $1 $2))))
    (loop :for header := (read-header) :while header :collect header)))

(defun read-http-content-chunked (http)
  "Read the body from the HTTP server using a chunked Transfer-Encoding."
  (with-output-to-string (body)
    (loop :for len := (parse-integer (read-line http) :radix 16 :junk-allowed t)
          :while (plusp len)
          :do (let ((chunk (make-string len)))
                (write-sequence chunk body :end (read-sequence chunk http))
                (read-line http)))))

(defun read-http-content (http &optional content-length)
  "Read the rest of the response from the HTTP server."
  (if content-length
      (let ((body (make-string (parse-integer content-length))))
        (prog1 body (read-sequence body http)))
    (with-output-to-string (body)
      (loop :with chunk := (make-string 4000)
            :for bytes-read := (read-sequence chunk http)
            :while (plusp bytes-read)
            :do (write-sequence chunk body :end bytes-read)))))

(defun read-http-response (http req)
  "Read a response string from an HTTP socket stream and parse it."
  (multiple-value-bind (code status)
      (read-http-status http)
    (let ((headers (read-http-headers http)))
      (with-headers ((encoding "Transfer-Encoding" :if-not-found "identity")
                     (content-length "Content-Length"))
          headers
        (let ((body (cond
                     ((string= encoding "identity") (read-http-content http content-length))
                     ((string= encoding "chunked") (read-http-content-chunked http))
                     (t
                      (error "Unknown Transfer-Encoding ~s" encoding)))))
          (make-instance 'response :request req :code code :status status :headers headers :body body))))))

(defun http-perform (req)
  "Perform a generic HTTP request, return the request and body."
  (with-slots (url method headers data)
      req
    (with-slots (scheme domain path query auth)
        url
      (with-open-stream (http (open-tcp-stream domain (http-port url) :element-type 'base-char))
        (when (eq scheme :https)
          (attach-ssl http :ssl-side :client))

        (format http "~a ~a?~a HTTP/1.1~c~c" method path (make-query-string query) #\return #\linefeed)

        ;; send headers
        (format http "Host: ~a~c~c" domain #\return #\linefeed)
        (format http "Connection: close~c~c" #\return #\linefeed)

        ;; optionally sent
        (when data
          (format http "Content-Length: ~a~c~c" (length data) #\return #\linefeed))
        (when auth
          (format http "Authorization: ~a~c~c" (basic-auth-string auth) #\return #\linefeed))

        ;; user headers
        (dolist (header headers)
          (format http "~a: ~a~c~c" (first header) (second header) #\return #\linefeed))

        ;; complete the request
        (format http "~c~c" #\return #\linefeed)

        ;; write optional data to the body
        (when data
          (write-sequence data http))

        ;; send all data
        (force-output http)

        ;; return the response
        (read-http-response http req)))))

(defun http-simple-perform (url &rest request-initargs)
  "Parse a URL, create a simple request, and perform the request."
  (with-url (url url)
    (let ((req (apply #'make-instance 'request :url url request-initargs)))
      (http-perform req))))

(defun http-follow (resp &key (limit 3))
  "Follow a reponse's redirection to a new resource location."
  (with-slots (code request headers)
      resp
    (case code
      ((301 302 303 304 305 307)
       (if (zerop limit)
           resp
         (let ((req (with-headers ((loc "Location" :if-not-found (error "No \"Location\" header.")))
                        headers
                      (let ((url (parse-url loc)))
                        (with-slots (query fragment)
                            (request-url request)
                          
                          ;; if the new url doesn't have a query or fragment, use the old one
                          (unless (url-query url)
                            (setf (url-query url) query))
                          (unless (url-fragment url)
                            (setf (url-fragment url) fragment))
                          
                          ;; create the new request
                          (make-instance 'request
                                         :url url
                                         :data (request-data request)
                                         :headers (request-headers request)
                                         :method (if (= code 303) "GET" (request-method request))))))))
           (http-follow (http-perform req) :limit (1- limit)))))
      (otherwise resp))))

(defun http-head (url &key headers)
  "Perform a HEAD request for a URL, return the response."
  (http-simple-perform url :method "HEAD" :headers headers))

(defun http-get (url &key headers)
  "Perform a GET request for a URL, return the response."
  (http-simple-perform url :method "GET" :headers headers))

(defun http-options (url &key headers)
  "Perform an OPTIONS request for a URL, return the response."
  (http-simple-perform url :method "OPTIONS" :headers headers))

(defun http-trace (url &key headers)
  "Perform an OPTIONS request for a URL, return the response."
  (http-simple-perform url :method "TRACE" :headers headers))

(defun http-delete (url &key headers)
  "Perform a DELETE request for a URL, return the response."
  (http-simple-perform url :method "DELETE" :headers headers))

(defun http-put (url &key headers data)
  "Perform a PUT request for a URL, return the response."
  (http-simple-perform url :method "PUT" :headers headers :data data))

(defun http-post (url &key headers data)
  "Perform a POST request for a URL, return the response."
  (http-simple-perform url :method "POST" :headers headers :data data))

(defun http-patch (url &key headers data)
  "Perform a PATCH request for a URL, return the response."
  (http-simple-perform url :method "PATCH" :headers headers :data data))
