;; Basic Staking Platform
;; Users can stake STX and track their staked balance

(define-map staked-balances principal uint)
(define-data-var total-staked uint u0)

(define-constant err-invalid-amount (err u100))

;; Stake STX into the contract
(define-public (stake (amount uint))
  (begin
    (asserts! (> amount u0) err-invalid-amount)
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (map-set staked-balances tx-sender
             (+ (default-to u0 (map-get? staked-balances tx-sender)) amount))
    (var-set total-staked (+ (var-get total-staked) amount))
    (ok true)))

;; View staked balance for caller
(define-read-only (get-my-stake)
  (ok (default-to u0 (map-get? staked-balances tx-sender))))
