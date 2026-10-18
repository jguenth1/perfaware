;; Test Accumulator behavior
bits 16

;; Word width register
mov ax, [2555]
mov ax, [16]

; Accumulator-to-memory test
mov [2554], ax
mov [15], ax

;; byte width register
mov al, [2555]
mov al, [16]

; Accumulator-to-memory test
mov [2554], al
mov [15], al

