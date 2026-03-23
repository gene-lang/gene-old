import ../helpers

test_vm """
  (fn test_break []
    (var a 1)
    (var b 2)
    (loop
      (if true
        (var x 3)
        (break)
      )
    )
    b
  )
  (test_break)
""", 2

test_vm """
  (fn test_continue []
    (var a 1)
    (var b 2)
    (var i 0)
    (loop
      (i += 1)
      (if (i == 1)
        (var x 3)
        (continue)
      )
      (break)
    )
    b
  )
  (test_continue)
""", 2
