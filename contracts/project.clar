;; Basic Staking Platform Contract
;; A decentralized staking platform where users can stake STX tokens and earn rewards

;; Define the reward token
(define-fungible-token staking-reward-token)

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-no-stake-found (err u104))
(define-constant err-insufficient-stake (err u105))
(define-constant err-staking-paused (err u106))
(define-constant err-withdrawal-locked (err u107))
(define-constant err-reward-calculation-error (err u108))

;; Staking parameters
(define-data-var staking-enabled bool true)
(define-data-var minimum-stake-amount uint u1000000) ;; 1 STX minimum (1,000,000 microSTX)
(define-data-var annual-reward-rate uint u1000) ;; 10% APY (1000/10000)
(define-data-var lock-period uint u52560) ;; ~1 year in blocks (assuming 10-minute blocks)
(define-data-var total-staked uint u0)
(define-data-var total-rewards-distributed uint u0)

;; Reward token parameters
(define-data-var reward-token-name (string-ascii 32) "Staking Reward Token")
(define-data-var reward-token-symbol (string-ascii 10) "SRT")
(define-data-var reward-token-decimals uint u6)
(define-data-var reward-token-supply uint u0)

;; Staking pool info
(define-map stakes principal {
    amount: uint,
    start-block: uint,
    last-claim-block: uint,
    total-claimed: uint
})

;; Pool statistics
(define-map user-stats principal {
    total-staked: uint,
    total-rewards: uint,
    stake-count: uint,
    last-action-block: uint
})

;; Initialize the staking platform
(define-public (initialize (initial-reward-supply uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (> initial-reward-supply u0) err-invalid-amount)
        (try! (ft-mint? staking-reward-token initial-reward-supply tx-sender))
        (var-set reward-token-supply initial-reward-supply)
        (ok true)))

;; Stake STX tokens
(define-public (stake (amount uint))
    (let (
        (current-stake (default-to {amount: u0, start-block: u0, last-claim-block: u0, total-claimed: u0}
                                   (map-get? stakes tx-sender)))
        (new-amount (+ (get amount current-stake) amount))
        (start-block (if (> (get amount current-stake) u0)
                        (get start-block current-stake)
                        block-height))
    )
    (begin
        (asserts! (var-get staking-enabled) err-staking-paused)
        (asserts! (>= amount (var-get minimum-stake-amount)) err-invalid-amount)
        (asserts! (>= (stx-get-balance tx-sender) amount) err-insufficient-balance)
        
        ;; Transfer STX to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Update stake record
        (map-set stakes tx-sender {
            amount: new-amount,
            start-block: start-block,
            last-claim-block: (if (> (get amount current-stake) u0)
                                 (get last-claim-block current-stake)
                                 block-height),
            total-claimed: (get total-claimed current-stake)
        })
        
        ;; Update global stats
        (var-set total-staked (+ (var-get total-staked) amount))
        
        ;; Update user stats
        (update-user-stats tx-sender amount u0)
        
        (print {
            event: "stake-created",
            user: tx-sender,
            amount: amount,
            total-staked: new-amount,
            block-height: block-height
        })
        
        (ok true))))

;; Unstake STX tokens
(define-public (unstake (amount uint))
    (let (
        (stake-data (unwrap! (map-get? stakes tx-sender) err-no-stake-found))
        (staked-amount (get amount stake-data))
        (start-block (get start-block stake-data))
        (remaining-amount (- staked-amount amount))
    )
    (begin
        (asserts! (> amount u0) err-invalid-amount)
        (asserts! (>= staked-amount amount) err-insufficient-stake)
        (asserts! (>= block-height (+ start-block (var-get lock-period))) err-withdrawal-locked)
        
        ;; Claim pending rewards before unstaking
        (try! (claim-rewards))
        
        ;; Update or remove stake record
        (if (> remaining-amount u0)
            (map-set stakes tx-sender (merge stake-data {
                amount: remaining-amount
            }))
            (map-delete stakes tx-sender))
        
        ;; Transfer STX back to user
        (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
        
        ;; Update global stats
        (var-set total-staked (- (var-get total-staked) amount))
        
        (print {
            event: "stake-withdrawn",
            user: tx-sender,
            amount: amount,
            remaining-stake: remaining-amount,
            block-height: block-height
        })
        
        (ok true))))

;; Claim staking rewards
(define-public (claim-rewards)
    (let (
        (stake-data (unwrap! (map-get? stakes tx-sender) err-no-stake-found))
        (pending-rewards (try! (calculate-pending-rewards tx-sender)))
    )
    (begin
        (asserts! (> pending-rewards u0) err-invalid-amount)
        
        ;; Mint reward tokens to user
        (try! (ft-mint? staking-reward-token pending-rewards tx-sender))
        
        ;; Update stake record
        (map-set stakes tx-sender (merge stake-data {
            last-claim-block: block-height,
            total-claimed: (+ (get total-claimed stake-data) pending-rewards)
        }))
        
        ;; Update global stats
        (var-set total-rewards-distributed (+ (var-get total-rewards-distributed) pending-rewards))
        (var-set reward-token-supply (+ (var-get reward-token-supply) pending-rewards))
        
        ;; Update user stats
        (update-user-stats tx-sender u0 pending-rewards)
        
        (print {
            event: "rewards-claimed",
            user: tx-sender,
            rewards: pending-rewards,
            total-claimed: (+ (get total-claimed stake-data) pending-rewards),
            block-height: block-height
        })
        
        (ok pending-rewards))))

;; Emergency unstake (forfeit rewards)
(define-public (emergency-unstake)
    (let (
        (stake-data (unwrap! (map-get? stakes tx-sender) err-no-stake-found))
        (staked-amount (get amount stake-data))
    )
    (begin
        (asserts! (> staked-amount u0) err-invalid-amount)
        
        ;; Remove stake record
        (map-delete stakes tx-sender)
        
        ;; Transfer STX back (minus penalty - could be implemented)
        (try! (as-contract (stx-transfer? staked-amount tx-sender tx-sender)))
        
        ;; Update global stats
        (var-set total-staked (- (var-get total-staked) staked-amount))
        
        (print {
            event: "emergency-unstake",
            user: tx-sender,
            amount: staked-amount,
            block-height: block-height
        })
        
        (ok true))))

;; Helper function to update user statistics
(define-private (update-user-stats (user principal) (staked uint) (rewards uint))
    (let (
        (current-stats (default-to {total-staked: u0, total-rewards: u0, stake-count: u0, last-action-block: u0}
                                   (map-get? user-stats user)))
    )
    (map-set user-stats user {
        total-staked: (+ (get total-staked current-stats) staked),
        total-rewards: (+ (get total-rewards current-stats) rewards),
        stake-count: (+ (get stake-count current-stats) (if (> staked u0) u1 u0)),
        last-action-block: block-height
    })))

;; Calculate pending rewards for a user
(define-read-only (calculate-pending-rewards (user principal))
    (match (map-get? stakes user)
        stake-data 
        (let (
            (staked-amount (get amount stake-data))
            (last-claim-block (get last-claim-block stake-data))
            (blocks-since-claim (- block-height last-claim-block))
            (annual-rate (var-get annual-reward-rate))
            ;; Simplified reward calculation: (staked * rate * blocks) / (blocks_per_year * 10000)
            (reward-amount (/ (* (* staked-amount annual-rate) blocks-since-claim) (* u52560 u10000)))
        )
        (ok reward-amount))
        (ok u0)))

;; Read-only functions

;; Get stake information for a user
(define-read-only (get-stake-info (user principal))
    (ok (map-get? stakes user)))

;; Get user statistics
(define-read-only (get-user-stats (user principal))
    (ok (map-get? user-stats user)))

;; Get platform statistics
(define-read-only (get-platform-stats)
    (ok {
        total-staked: (var-get total-staked),
        total-rewards-distributed: (var-get total-rewards-distributed),
        annual-reward-rate: (var-get annual-reward-rate),
        minimum-stake-amount: (var-get minimum-stake-amount),
        lock-period: (var-get lock-period),
        staking-enabled: (var-get staking-enabled)
    }))

;; Get reward token info
(define-read-only (get-reward-token-info)
    (ok {
        name: (var-get reward-token-name),
        symbol: (var-get reward-token-symbol),
        decimals: (var-get reward-token-decimals),
        total-supply: (var-get reward-token-supply)
    }))

;; Get reward token balance
(define-read-only (get-reward-balance (user principal))
    (ok (ft-get-balance staking-reward-token user)))

;; Check if user can unstake
(define-read-only (can-unstake (user principal))
    (match (map-get? stakes user)
        stake-data
        (let (
            (start-block (get start-block stake-data))
            (unlock-block (+ start-block (var-get lock-period)))
        )
        (ok {
            can-unstake: (>= block-height unlock-block),
            unlock-block: unlock-block,
            blocks-remaining: (if (>= block-height unlock-block) u0 (- unlock-block block-height))
        }))
        (ok {can-unstake: false, unlock-block: u0, blocks-remaining: u0})))

;; Get contract balance
(define-read-only (get-contract-balance)
    (ok (stx-get-balance (as-contract tx-sender))))

;; Admin functions

;; Set staking parameters (only owner)
(define-public (set-staking-params (enabled bool) (min-stake uint) (reward-rate uint) (lock-blocks uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (<= reward-rate u5000) err-invalid-amount) ;; Max 50% APY
        (var-set staking-enabled enabled)
        (var-set minimum-stake-amount min-stake)
        (var-set annual-reward-rate reward-rate)
        (var-set lock-period lock-blocks)
        (ok true)))

;; Emergency pause staking (only owner)
(define-public (pause-staking)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set staking-enabled false)
        (ok true)))

;; Resume staking (only owner)
(define-public (resume-staking)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set staking-enabled true)
        (ok true)))

;; Withdraw contract STX (emergency only - owner)
(define-public (emergency-withdraw (amount uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (try! (as-contract (stx-transfer? amount tx-sender contract-owner)))
        (ok true)))

;; SIP-010 compliance for reward token
(define-public (transfer-reward-token (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
    (begin
        (asserts! (or (is-eq tx-sender sender) (is-eq contract-caller sender)) err-not-authorized)
        (try! (ft-transfer? staking-reward-token amount sender recipient))
        (match memo to-print (print to-print) 0x)
        (ok true)))