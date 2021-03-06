#!/bin/sh

. ./subr.sh

set -e

### Test 1: assert that no package name string has a reference from any
### heap object aside from the package itself.
### Because SAVE-LISP-AND-DIE coalesces strings, this test provides confidence
### that no string anywhere in the heap is STRING= to a package name.
### The better test is Test 2 below, which only passes on x86[-64] as yet.

run_sbcl <<EOF
#+cheneygc (exit) ; not much can be done for cheney to make this pass
#+sb-devel (exit) ; doesn't pass either

(defvar *weak-ptrs* nil)
(progn
  ;; Remove features that are also names of packages.
  ;; This form needs to obfuscate the spellings of victim symbols, or else
  ;; they end up in the *SOURCE-INFO* for this file, which is pinned while
  ;; loading the file, which would enliven the symbols.
  (dolist (x '("EVAL" "THREAD" "UNICODE"))
    (let ((sym (find-symbol (concatenate 'string '(#\S #\B #\-) x) "KEYWORD")))
      (when sym
        (setf *features* (delete sym *features*))
        (push (make-weak-pointer sym) *weak-ptrs*)
        (unintern sym :keyword))))
  ;; Just clobber these all
  (setq sb-fasl::*features-potentially-affecting-fasl-format* nil)
  (sb-ext:without-package-locks
   (dolist (package (list-all-packages))
     (let ((name (package-name package)))
       (unless (or (string= name "COMMON-LISP")
                   (string= name "KEYWORD"))
         (push (make-weak-pointer name) *weak-ptrs*)
         (rename-package name (concatenate 'string "HIDDEN-" name))))))
  ;; The package hashtable lazily removes keys. Force it do to do so now.
  (sb-impl::%rebuild-package-names sb-kernel::*package-names*))

(gc :gen 7)
(setq *weak-ptrs*
      (remove-if (lambda (x) (not (weak-pointer-value x))) *weak-ptrs*))
(assert (null *weak-ptrs*))
(format t "Package hiding test 1: PASS~%")
EOF

### Test 2: assert that no string anywhere in the heap is STRING= to the
### name of a system package.
run_sbcl <<EOF

;;; It would be nice to get this test to pass on all backends.
;;; That it doesn't pass doesn't mean the packages aren't hidden correctly.
;;; It just means the test is inadequate.
;;; One possible failure reason is that DX strings didn't go on the stack.
#-(or x86 x86-64) (exit)
#-sb-thread (exit) ;; doesn't pass for some reason
#+sb-devel (exit)

;;; Does not pass with interpreter
(setq sb-ext:*evaluator-mode* :compile)

;;; Avoid accidental enlivenment of strings - the forms in this file must
;;; obscure the spellings of package name strings or else they can end up
;;; in the *SOURCE-INFO* which is live as long as this file is being read.
(defvar *pkg-prefix* '(#\S #\B #\-))
(dolist (x '("INT" "KERNEL" "VM"))
  (use-package (concatenate 'string *pkg-prefix* x)))

(defun rename-all-packages ()
  ;; Remove features that are also names of packages.
  (dolist (x '("EVAL" "THREAD" "UNICODE"))
    (let ((sym (find-symbol (concatenate 'string *pkg-prefix* x) "KEYWORD")))
      (when sym
        (setf *features* (delete sym *features*))
        (unintern sym :keyword))))
  ;; Just clobber these all
  (setq sb-fasl::*features-potentially-affecting-fasl-format* nil)
  (without-package-locks
   (dolist (package (list-all-packages))
     (let ((name (package-name package)))
       (rename-package name (concatenate 'string "HIDDEN-" name)))))
  ;; The package hashtable lazily removes keys. Force it do to do so now.
  (sb-impl::%rebuild-package-names sb-kernel::*package-names*))

;;; Place all the strings we want to search for onto the stack.
;;; This little rearrangement here is a hack which causes the last item in
;;; 'packages' to be one that we're not interested in for purposes of the test.
;;; The final iteration of RECURSE seems to pin the string naming the package,
;;; which produces a reference to a string that we may want not to see.
(named-let recurse ((packages
                     (append (remove *cl-package* (list-all-packages))
                             (list *cl-package*)))
                    (strings nil))
  (cond ((null packages)
         ;; Do not remove the CL-USER package qualifier here - it's actually
         ;; a trick that gets this test to pass. Essentially we need to ensure
         ;; that the reader's package token buffer contains any string other
         ;; than one of the packages under test.
         (CL-USER::rename-all-packages)
         #+nil
         (format t "Scanning for ~D strings: ~S~%" (length strings) strings)
         (gc :gen 7)
         (let (found-strings)
           (map-allocated-objects
            (lambda (obj type size)
              (declare (ignore type size))
              (when (and (stringp obj) (find obj strings :test #'string-equal))
                (format t "Found string in g~d @ ~x ~S~%"
                        (generation-of obj) (get-lisp-obj-address obj) obj)
                (push (make-weak-pointer obj) found-strings)))
            :all)
           (assert (not found-strings))
           (format t "Package hiding test 2: PASS~%")))
        (t
         (dx-let ((s (make-array (the (mod 64)
                                      (length (package-name (car packages))))
                                 :element-type 'base-char)))
           (replace s (package-name (car packages)))
           (recurse (cdr packages)
                    (if (member s '("COMMON-LISP" "COMMON-LISP-USER" "KEYWORD")
                                :test #'string=)
                        strings
                        (cons s strings)))))))
EOF

exit $EXIT_TEST_WIN
