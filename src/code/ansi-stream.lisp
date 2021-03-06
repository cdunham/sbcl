;;;; the abstract class ANSI-STREAM

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-IMPL")

;;; HOW THE ANSI-STREAM STRUCTURE IS USED
;;;
;;; Many of the slots of the ANSI-STREAM structure contain functions
;;; which are called to perform some operation on the stream. Closed
;;; streams have #'CLOSED-FLAME in all of their function slots. If
;;; one side of an I/O or echo stream is closed, the whole stream is
;;; considered closed. The functions in the operation slots take
;;; arguments as follows:
;;;
;;; In:                 Stream, Eof-Errorp, Eof-Value
;;; Bin:                Stream, Eof-Errorp, Eof-Value
;;; N-Bin:              Stream, Buffer, Start, Numbytes, Eof-Errorp
;;; Out:                Stream, Character
;;; Bout:               Stream, Integer
;;; Sout:               Stream, String, Start, End
;;; Misc:               Stream, Operation, &Optional Arg1, Arg2
;;;
;;; In order to save space, some of the less common stream operations
;;; are handled by just one function, the MISC method. This function
;;; is passed a keyword which indicates the operation to perform.
;;; The following keywords are used:
;;;  :listen            - Return the following values:
;;;                          t if any input waiting.
;;;                          :eof if at eof.
;;;                          nil if no input is available and not at eof.
;;;  :unread            - Unread the character Arg.
;;;  :close             - Do any stream specific stuff to close the stream.
;;;                       The methods are set to closed-flame by the close
;;;                       function, so that need not be done by this
;;;                       function.
;;;  :clear-input       - Clear any unread input
;;;  :finish-output,
;;;  :force-output      - Cause output to happen
;;;  :clear-output      - Clear any undone output
;;;  :element-type      - Return the type of element the stream deals with.
;;;  :line-length       - Return the length of a line of output.
;;;  :charpos           - Return current output position on the line.
;;;  :file-length       - Return the file length of a file stream.
;;;  :file-position     - Return or change the current position of a
;;;                       file stream.
;;;  :file-name         - Return the name of an associated file.
;;;  :interactive-p     - Is this an interactive device?
;;;
;;; In order to do almost anything useful, it is necessary to
;;; define a new type of structure that includes stream, so that the
;;; stream can have some state information.
;;;
;;; THE STREAM IN-BUFFER:
;;;
;;; The IN-BUFFER in the stream holds characters or bytes that
;;; are ready to be read by some input function. If there is any
;;; stuff in the IN-BUFFER, then the reading function can use it
;;; without calling any stream method. Any stream may put stuff in
;;; the IN-BUFFER, and may also assume that any input in the IN-BUFFER
;;; has been consumed before any in-method is called. If a text
;;; stream has in IN-BUFFER, then the first character should not be
;;; used to buffer normal input so that it is free for unreading into.
;;;
;;; When the ANSI-STREAM-IN-BUFFER slot, and its index, is only
;;; accessed by the normal stream functions, the number of function
;;; calls is halved, thus potentially doubling the speed of simple
;;; operations. If the FAST-READ-CHAR and FAST-READ-BYTE macros are
;;; used, nearly all function call overhead is removed, vastly
;;; speeding up these important operations.

;;; the size of a stream in-buffer
;;;
;;; This constant it is used in a read-time-eval, and some implementations
;;; draw a sharp distinction between a constant being known only to
;;; the file-compiler during compilation, and known also to the evaluator.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +ansi-stream-in-buffer-length+ 512))

(deftype ansi-stream-in-buffer ()
  `(simple-array (unsigned-byte 8) (,+ansi-stream-in-buffer-length+)))

(deftype ansi-stream-cin-buffer ()
  `(simple-array character (,+ansi-stream-in-buffer-length+)))

;;; base class for ANSI standard streams (as opposed to the Gray
;;; streams extension)
(defstruct (ansi-stream (:constructor nil)
                        (:copier nil))

  ;; input buffer
  ;;
  ;; (If a stream does not have an input buffer, then the IN-BUFFER
  ;; slot must must be NIL, and the IN-INDEX must be
  ;; +ANSI-STREAM-IN-BUFFER-LENGTH+.)
  (in-buffer nil :type (or ansi-stream-in-buffer null))
  (cin-buffer nil :type (or ansi-stream-cin-buffer null))
  (in-index +ansi-stream-in-buffer-length+
            :type (integer 0 #.+ansi-stream-in-buffer-length+))

  ;; buffered input functions
  (in #'ill-in :type function)                  ; READ-CHAR function
  (bin #'ill-bin :type function)                ; byte input function
  ;; 'n-bin' might not transfer bytes to the consumer.
  ;; A character FD-STREAM uses this method to transfer octets from the
  ;; source buffer into characters of the destination buffer.
  (n-bin #'ill-bin :type function)              ; n-byte input function

  ;; output functions
  (out #'ill-out :type function)                ; WRITE-CHAR function
  (bout #'ill-bout :type function)              ; byte output function
  (sout #'ill-out :type function)               ; string output function

  ;; other, less-used methods
  (misc #'no-op-placeholder :type function)

  ;; Absolute character position, acting also as a generalized boolean
  ;; in lieu of testing FORM-TRACKING-STREAM-P to see if we must
  ;; maintain correctness of the slot in ANSI-STREAM-UNREAD-CHAR.
  (input-char-pos nil))

;;; SYNONYM-STREAM type is needed by ANSI-STREAM-{INPUT,OUTPUT}-STREAM-P
;;; and also needed by OPEN (though not obviously), which is compiled
;;; prior to some of the stream type definitions in src/code/stream,
;;; so let's define that one here as soon as we can.
(defstruct (synonym-stream (:include ansi-stream
                                     (in #'synonym-in)
                                     (bin #'synonym-bin)
                                     (n-bin #'synonym-n-bin)
                                     (out #'synonym-out)
                                     (bout #'synonym-bout)
                                     (sout #'synonym-sout)
                                     (misc #'synonym-misc))
                           (:constructor make-synonym-stream (symbol))
                           (:copier nil))
  ;; This is the symbol, the value of which is the stream we are synonym to.
  (symbol nil :type symbol :read-only t))
(declaim (freeze-type synonym-stream))

(defmethod print-object ((x stream) stream)
  (print-unreadable-object (x stream :type t :identity t)))

(defmacro with-standard-io-syntax (&body body)
  "Bind the reader and printer control variables to values that enable READ
   to reliably read the results of PRINT. These values are:

         *PACKAGE*                        the COMMON-LISP-USER package
         *PRINT-ARRAY*                    T
         *PRINT-BASE*                     10
         *PRINT-CASE*                     :UPCASE
         *PRINT-CIRCLE*                   NIL
         *PRINT-ESCAPE*                   T
         *PRINT-GENSYM*                   T
         *PRINT-LENGTH*                   NIL
         *PRINT-LEVEL*                    NIL
         *PRINT-LINES*                    NIL
         *PRINT-MISER-WIDTH*              NIL
         *PRINT-PPRINT-DISPATCH*          the standard pprint dispatch table
         *PRINT-PRETTY*                   NIL
         *PRINT-RADIX*                    NIL
         *PRINT-READABLY*                 T
         *PRINT-RIGHT-MARGIN*             NIL
         *READ-BASE*                      10
         *READ-DEFAULT-FLOAT-FORMAT*      SINGLE-FLOAT
         *READ-EVAL*                      T
         *READ-SUPPRESS*                  NIL
         *READTABLE*                      the standard readtable
  SB-EXT:*SUPPRESS-PRINT-ERRORS*          NIL
  SB-EXT:*PRINT-VECTOR-LENGTH*            NIL
"
  (let ((name (make-symbol "THUNK")))
    `(dx-flet ((,name () ,@body))
       (%with-standard-io-syntax #',name))))

;;; Note that this macro may display problems (as do most) with out-of-order
;;; evaluation of keyword args if passed in a different order from listed,
;;; in situations where evaluation order matters.
(defmacro with-input-from-string ((var string &key index
                                                   (start 0 start-suppliedp)
                                                   end)
                                  &body forms-decls
                                  &environment env)
  (let* ((dummy '#:stream) ; in case VAR is declared special
         (offset '#:offset)
         ;; CLHS says in WITH-INPUT-FROM-STRING:
         ;;  "The input string stream is automatically closed on exit from with-input-from-string,
         ;;   no matter whether the exit is normal or abnormal. The input string stream to which
         ;;   the variable var is bound has dynamic extent; its extent ends when the form is exited."
         ;; In light of the second point, we need not close the stream if the object is
         ;; stack-allocated, because any attempt to access it after the forms exit will surely
         ;; crash, and there are otherwise no observable effects from closing the stream.
         ;; The choice to avoid DX-LET in safe code is strictly unecessary, because it is
         ;; *always* undefined behavior to use the DX object after its extent ends,
         ;; however it might help expose user code bugs by keeping the stream accessible
         ;; but closed.
         (bind (if (sb-c:policy env (= safety 3)) 'let 'dx-let))
         (ctor `(%init-string-input-stream
                 ,dummy ,string
                 ;; not (OR START 0), because ":START NIL" should err
                 ,@(cond (start-suppliedp (list start)) (end '(0)))
                 ,@(when end (list end)))))
    (flet ((uwp (forms)
             (if (eq bind 'let)
                 ;; "The consequences are undefined if an attempt is made to assign
                 ;;  the variable var." - so we can read it here with impunity.
                 `(unwind-protect (progn ,@forms) (close ,var))
                 `(progn ,@forms)))) ; don't bother closing
      `(,bind ((,dummy (%make-instance ,(dd-length (find-defstruct-description
                                                    'string-input-stream)))))
              ,(multiple-value-bind (forms decls) (parse-body forms-decls nil)
                 (if index
                     `(multiple-value-bind (,var ,offset) ,ctor
                        ,@decls
                        (multiple-value-prog1 ,(uwp forms)
                          (setf ,index (- (string-input-stream-index ,var) ,offset))))
                     `(let ((,var ,ctor))
                        (declare (ignorable ,var))
                        ,@decls
                        ,(uwp forms)))))))) ; easy way

