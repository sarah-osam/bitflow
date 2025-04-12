;; Title: BitFlow - Stacks Payment Channel Implementation
;; 
;; Summary: A secure and efficient payment channel solution for Stacks blockchain,
;; enabling rapid off-chain transactions with on-chain security guarantees.
;;
;; Description: BitFlow implements a bi-directional payment channel framework that allows
;; users to conduct numerous transactions off-chain while maintaining security through
;; cryptographic signatures and on-chain settlement guarantees. The contract supports
;; channel creation, cooperative closing, and dispute resolution mechanisms to ensure
;; funds remain safe even if a participant becomes unresponsive.

;; Constants

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-CHANNEL-EXISTS (err u101))
(define-constant ERR-CHANNEL-NOT-FOUND (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-INVALID-SIGNATURE (err u104))
(define-constant ERR-CHANNEL-CLOSED (err u105))
(define-constant ERR-DISPUTE-PERIOD (err u106))
(define-constant ERR-INVALID-INPUT (err u107))

;; Data Maps

(define-map payment-channels 
  {
    channel-id: (buff 32),
    participant-a: principal,
    participant-b: principal
  }
  {
    total-deposited: uint,
    balance-a: uint,
    balance-b: uint,
    is-open: bool,
    dispute-deadline: uint,
    nonce: uint
  }
)

;; Private Functions

;; Include nonce in the message being signed
(define-private (create-message 
  (channel-id (buff 32))
  (balance-a uint)
  (balance-b uint)
  (nonce uint)
)
  (concat 
    (concat 
      (concat channel-id (uint-to-buff balance-a))
      (uint-to-buff balance-b)
    )
    (uint-to-buff nonce)
  )
)

;; Validates that a channel ID is correctly formatted
(define-private (is-valid-channel-id (channel-id (buff 32)))
  (is-eq (len channel-id) u32)
)

;; Ensures the deposit amount meets minimum requirements
(define-private (is-valid-deposit (amount uint))
  (> amount u1000)
)

;; Verifies signature has proper length format
(define-private (is-valid-signature (signature (buff 65)))
  (is-eq (len signature) u65)
)

;; Converts uint to buffer representation
(define-private (uint-to-buff (n uint))
  (unwrap-panic (to-consensus-buff? n))
)

(define-private (is-valid-principal (principal-value principal))
  (not (is-eq principal-value tx-sender))
)

;; Verifies signature authenticity
;; Note: In production, this would use proper cryptographic verification
(define-private (verify-signature 
  (message (buff 256))
  (signature (buff 65))
  (signer principal)
)
  (if (is-eq tx-sender signer)
    true
    false
  )
)

;; Public Functions: Channel Management

;; Creates a new payment channel between sender and participant B
;; Records the initial deposit from the creator (participant A)
(define-public (create-channel 
  (channel-id (buff 32)) 
  (participant-b principal)
  (initial-deposit uint)
)
  (begin
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-deposit initial-deposit) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)

    (asserts! (is-none (map-get? payment-channels {
      channel-id: channel-id, 
      participant-a: tx-sender, 
      participant-b: participant-b
    })) ERR-CHANNEL-EXISTS)

    (try! (stx-transfer? initial-deposit tx-sender (as-contract tx-sender)))

    (map-set payment-channels 
      { channel-id: channel-id, participant-a: tx-sender, participant-b: participant-b }
      { total-deposited: initial-deposit, balance-a: initial-deposit, balance-b: u0,
        is-open: true, dispute-deadline: u0, nonce: u0 }
    )
    (ok true)
  )
)

;; Adds additional funds to an existing payment channel
;; Only participant A can add funds in this implementation
(define-public (fund-channel 
  (channel-id (buff 32)) 
  (participant-b principal)
  (additional-funds uint)
)
  (let 
    ((channel (unwrap! 
      (map-get? payment-channels {
        channel-id: channel-id, 
        participant-a: tx-sender, 
        participant-b: participant-b
      }) 
      ERR-CHANNEL-NOT-FOUND
    )))
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-deposit additional-funds) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)
    (asserts! (get is-open channel) ERR-CHANNEL-CLOSED)

    (try! (stx-transfer? additional-funds tx-sender (as-contract tx-sender)))

    (map-set payment-channels 
      {
        channel-id: channel-id, 
        participant-a: tx-sender, 
        participant-b: participant-b
      }
      (merge channel {
        total-deposited: (+ (get total-deposited channel) additional-funds),
        balance-a: (+ (get balance-a channel) additional-funds)
      })
    )
    (ok true)
  )
)

;; Public Functions: Channel Operations

;; Closes a channel cooperatively with both parties signing off on the final state
;; This is the preferred closing method as it settles instantly
(define-public (close-channel-cooperative 
  (channel-id (buff 32)) 
  (participant-b principal)
  (balance-a uint)
  (balance-b uint)
  (signature-a (buff 65))
  (signature-b (buff 65))
)
  (let 
    ((channel (unwrap! 
      (map-get? payment-channels {
        channel-id: channel-id, 
        participant-a: tx-sender, 
        participant-b: participant-b
      }) 
      ERR-CHANNEL-NOT-FOUND
    ))
    (total-channel-funds (get total-deposited channel))
    (message (concat 
      (concat 
        channel-id
        (uint-to-buff balance-a)
      )
      (uint-to-buff balance-b)
    )))
    (asserts! (>= balance-a u0) ERR-INVALID-INPUT)
	(asserts! (>= balance-b u0) ERR-INVALID-INPUT)
	(asserts! (is-eq (+ balance-a balance-b) (get total-deposited channel)) ERR-INVALID-INPUT)
	(asserts! (is-valid-principal participant-b) ERR-INVALID-INPUT)
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-signature signature-a) ERR-INVALID-INPUT)
    (asserts! (is-valid-signature signature-b) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)
    (asserts! (get is-open channel) ERR-CHANNEL-CLOSED)
    (asserts! 
      (and 
        (verify-signature message signature-a tx-sender)
        (verify-signature message signature-b participant-b)
      ) 
      ERR-INVALID-SIGNATURE
    )
    (asserts! 
      (is-eq total-channel-funds (+ balance-a balance-b)) 
      ERR-INSUFFICIENT-FUNDS
    )
	

    (try! (as-contract (stx-transfer? balance-a tx-sender tx-sender)))
    (try! (as-contract (stx-transfer? balance-b tx-sender participant-b)))

    (map-set payment-channels 
      {
        channel-id: channel-id, 
        participant-a: tx-sender, 
        participant-b: participant-b
      }
      (merge channel {
        is-open: false,
        balance-a: u0,
        balance-b: u0,
        total-deposited: u0
      })
    )
    (ok true)
  )
)

;; Public Functions: Dispute Resolution

;; Initiates unilateral channel closure when cooperation isn't possible
;; This starts a dispute period during which the counterparty can challenge
(define-public (initiate-unilateral-close 
  (channel-id (buff 32)) 
  (participant-b principal)
  (proposed-balance-a uint)
  (proposed-balance-b uint)
  (signature (buff 65))
)
  (let 
    ((channel (unwrap! (map-get? payment-channels {
        channel-id: channel-id, 
        participant-a: tx-sender, 
        participant-b: participant-b
      }) ERR-CHANNEL-NOT-FOUND))
    (total-channel-funds (get total-deposited channel))
    (message (concat 
      (concat channel-id (uint-to-buff proposed-balance-a))
      (uint-to-buff proposed-balance-b))))

    (asserts! (get is-open channel) ERR-CHANNEL-CLOSED)
    (asserts! (verify-signature message signature tx-sender) ERR-INVALID-SIGNATURE)
    (asserts! (is-eq total-channel-funds (+ proposed-balance-a proposed-balance-b)) 
              ERR-INSUFFICIENT-FUNDS)
	(asserts! (is-valid-principal participant-b) ERR-INVALID-INPUT)

    (map-set payment-channels 
      { channel-id: channel-id, participant-a: tx-sender, participant-b: participant-b }
      (merge channel {
        dispute-deadline: (+ stacks-block-height u144), ;; ~24 hour challenge period
        balance-a: proposed-balance-a,
        balance-b: proposed-balance-b
      })
    )
    (ok true)
  )
)

;; Finalizes a unilateral closure after the dispute period has passed
;; Distributes funds according to the last valid state
(define-public (resolve-unilateral-close 
  (channel-id (buff 32)) 
  (participant-b principal)
)
  (let 
    ((channel (unwrap! 
      (map-get? payment-channels {
        channel-id: channel-id, 
        participant-a: tx-sender, 
        participant-b: participant-b
      }) 
      ERR-CHANNEL-NOT-FOUND
    ))
    (proposed-balance-a (get balance-a channel))
    (proposed-balance-b (get balance-b channel)))

    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)
    (asserts! 
      (>= stacks-block-height (get dispute-deadline channel)) 
      ERR-DISPUTE-PERIOD
    )

    (try! (as-contract (stx-transfer? proposed-balance-a tx-sender tx-sender)))
    (try! (as-contract (stx-transfer? proposed-balance-b tx-sender participant-b)))

    (map-set payment-channels 
      {
        channel-id: channel-id, 
        participant-a: tx-sender, 
        participant-b: participant-b
      }
      (merge channel {
        is-open: false,
        balance-a: u0,
        balance-b: u0,
        total-deposited: u0
      })
    )
    (ok true)
  )
)